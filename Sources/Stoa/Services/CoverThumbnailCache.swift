import AppKit
import PDFKit

/// In-memory cache for PDF page thumbnails, keyed by file path.
/// Uses NSCache for automatic eviction under memory pressure.
final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
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

        // Load off main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let image = Self.renderPDFThumbnail(url: url)

            if let image {
                self.cache.setObject(image, forKey: path as NSString)
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

        let thumbnailSize = NSSize(width: 300, height: 450)
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
