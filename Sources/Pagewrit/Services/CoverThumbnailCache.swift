import AppKit
import PDFKit
import QuickLookThumbnailing

/// In-memory cache for PDF page / PowerPoint slide thumbnails, keyed by file path.
/// Uses NSCache for automatic eviction under memory pressure.
final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    /// Renders at most a few covers at once so fast scrolling never floods
    /// the machine with PDF renders.
    private let renderQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private init() {
        cache.countLimit = 800
        cache.totalCostLimit = 160 * 1024 * 1024 // 160 MB
    }

    private func store(_ image: NSImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Loads a cover image file as a small thumbnail (not the full-size
    /// picture), cached by path. Decoding a full-size cover every time a tile
    /// scrolled into view was a big part of the scroll lag.
    func loadImage(at url: URL, maxPixel: Int = 520, completion: @escaping (NSImage?) -> Void) {
        let key = "img:" + url.path
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }
        renderQueue.addOperation { [weak self] in
            var result: NSImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixel
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    result = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                }
            }
            if let result { self?.store(result, for: key) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Synchronous cache peek for a cover image file.
    func cachedImage(at url: URL) -> NSImage? {
        cache.object(forKey: ("img:" + url.path) as NSString)
    }

    /// Returns a cached thumbnail immediately, or nil if not yet loaded.
    func thumbnail(for path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    /// Loads a PDF's first-page thumbnail off the main thread.
    /// Calls back on the main thread when done. Returns immediately if already cached.
    func loadThumbnail(
        for url: URL,
        completion: @escaping (NSImage?) -> Void
    ) {
        let path = url.path

        // Already cached?
        if let cached = cache.object(forKey: path as NSString) {
            completion(cached)
            return
        }

        // PowerPoint and Word: ask Quick Look for the first slide / page.
        if let format = BookFormat(fileExtension: url.pathExtension), format != .pdf {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 640, height: 640),
                scale: 1,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                let image = representation?.nsImage
                DispatchQueue.main.async {
                    if let image { self?.store(image, for: path) }
                    completion(image)
                }
            }
            return
        }

        // Load off main thread, a few at a time
        renderQueue.addOperation { [weak self] in
            guard let self else { return }

            let image = Self.renderPDFThumbnail(url: url)

            if let image {
                self.store(image, for: path)
            }

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    /// Renders a thumbnail of the first page of a PDF using PDFKit.
    private static func renderPDFThumbnail(url: URL) -> NSImage? {
        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else {
            return nil
        }

        // Render at the page's own proportions (slides and landscape PDFs
        // used to be squeezed into a portrait box and cropped), and large
        // enough to stay sharp on the detail screen and Retina displays.
        var bounds = page.bounds(for: .cropBox)
        if page.rotation % 180 != 0 {
            bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
        }
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let longSide: CGFloat = 640
        let scale = longSide / max(bounds.width, bounds.height)
        let thumbnailSize = NSSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
        let thumbnail = page.thumbnail(of: thumbnailSize, for: .cropBox)

        // Validate the thumbnail is usable (not blank / not a tiny error icon)
        guard thumbnail.size.width > 1, thumbnail.size.height > 1 else {
            return nil
        }

        return thumbnail
    }

    /// Clears the entire cache (e.g. on rescan).
    func clear() {
        cache.removeAllObjects()
    }
}
