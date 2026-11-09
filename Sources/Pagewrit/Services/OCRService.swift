import AppKit
import PDFKit
import Vision

/// Makes scanned PDFs searchable.
///
/// A scanned PDF is a stack of page pictures with no text, so find, text
/// selection, read-aloud and library search all see nothing. This reads each
/// page with Apple's Vision text recognition (on-device; nothing is
/// uploaded) and writes a copy of the PDF with the recognized words laid
/// invisibly over the page image, which is how Acrobat's "searchable PDF"
/// works. The original file is never modified.
enum OCRService {

    enum OCRError: LocalizedError {
        case cannotOpen, cannotCreate, cancelled, noTextFound
        var errorDescription: String? {
            switch self {
            case .cannotOpen: "The PDF couldn't be opened."
            case .cannotCreate: "The searchable copy couldn't be created."
            case .cancelled: "Cancelled."
            case .noTextFound: "No readable text was found on these pages."
            }
        }
    }

    /// Pages with more characters than this already have a text layer.
    private static let textLayerThreshold = 40

    // MARK: Detection

    /// True when a sample of pages has (almost) no text: a scan, not a digital PDF.
    static func isScanned(url: URL) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        return isScanned(document: doc)
    }

    static func isScanned(document doc: PDFDocument) -> Bool {
        let n = doc.pageCount
        guard n > 0 else { return false }
        // Up to 5 pages spread through the document.
        let samples = Set((0..<min(5, n)).map { n == 1 ? 0 : $0 * (n - 1) / max(1, min(5, n) - 1) })
        var chars = 0
        for i in samples {
            chars += doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
        }
        return chars / samples.count < 25
    }

    // MARK: Conversion

    /// Writes a searchable copy of `source` to `destination`. Returns the
    /// number of text lines recognized. `progress` is called with 0...1.
    @discardableResult
    static func makeSearchablePDF(source: URL, destination: URL,
                                  progress: @escaping (Double) -> Void,
                                  isCancelled: () -> Bool) throws -> Int {
        guard let doc = PDFDocument(url: source), doc.pageCount > 0 else { throw OCRError.cannotOpen }
        try? FileManager.default.removeItem(at: destination)
        guard let ctx = CGContext(destination as CFURL, mediaBox: nil, nil) else { throw OCRError.cannotCreate }

        var totalLines = 0
        let pageCount = doc.pageCount

        for index in 0..<pageCount {
            if isCancelled() {
                ctx.closePDF()
                try? FileManager.default.removeItem(at: destination)
                throw OCRError.cancelled
            }
            autoreleasepool {
                guard let page = doc.page(at: index) else { return }
                let crop = page.bounds(for: .cropBox)
                let rotated = page.rotation % 180 != 0
                let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
                var box = CGRect(origin: .zero, size: size)

                let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
                let info = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
                ctx.beginPDFPage(info)

                // 1. The original page.
                if let ref = page.pageRef {
                    ctx.saveGState()
                    ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                    ctx.drawPDFPage(ref)
                    ctx.restoreGState()
                }

                // 2. Invisible recognized text, unless the page already has a text layer.
                let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
                if existing <= textLayerThreshold, let image = render(page: page, displaySize: size) {
                    let lines = recognize(image)
                    totalLines += lines.count
                    drawInvisibleText(lines, in: box, context: ctx)
                }
                ctx.endPDFPage()
            }
            progress(Double(index + 1) / Double(pageCount))
        }
        ctx.closePDF()

        if totalLines == 0 && isScanned(url: source) {
            try? FileManager.default.removeItem(at: destination)
            throw OCRError.noTextFound
        }
        return totalLines
    }

    // MARK: Pieces

    /// The page as it is displayed, at about 220 dpi (long side capped at 2600 px).
    private static func render(page: PDFPage, displaySize: CGSize) -> CGImage? {
        guard displaySize.width > 1, displaySize.height > 1 else { return nil }
        let scale = min(2600 / max(displaySize.width, displaySize.height), 3.2)
        let px = NSSize(width: (displaySize.width * scale).rounded(), height: (displaySize.height * scale).rounded())
        let image = page.thumbnail(of: px, for: .cropBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private struct Line {
        let text: String
        let box: CGRect         // normalized 0...1, origin bottom-left
    }

    private static func recognize(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first, !top.string.isEmpty else { return nil }
            return Line(text: top.string, box: obs.boundingBox)
        }
    }

    private static func drawInvisibleText(_ lines: [Line], in page: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * page.width, y: line.box.minY * page.height,
                              width: line.box.width * page.width, height: line.box.height * page.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let fontSize = max(2, rect.height * 0.85)
            guard let font = NSFont(name: "Helvetica", size: fontSize) else { continue }
            let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            guard width > 0 else { continue }
            // Stretch the line horizontally so selection and highlights match the scan.
            ctx.textMatrix = CGAffineTransform(a: rect.width / width, b: 0, c: 0, d: 1,
                                               tx: rect.minX, ty: rect.minY + descent * 0.5)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }
}

// MARK: - Background jobs

/// Runs OCR jobs one book at a time in the background and reports progress
/// to the reader and detail screens.
@MainActor
final class OCRManager: ObservableObject {
    static let shared = OCRManager()

    struct Job {
        var progress: Double = 0
        var done = false
        var error: String?
    }

    @Published private(set) var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func isRunning(_ hash: String) -> Bool {
        guard let job = jobs[hash] else { return false }
        return !job.done && job.error == nil
    }

    func start(book: Book, library: LibraryStore) {
        let hash = book.contentHash
        guard Entitlements.isUnlocked(.ocr), book.format == .pdf, !isRunning(hash) else { return }

        let source = book.sourceURL
        let destination = library.searchableCopyURL(for: book)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")

        jobs[hash] = Job()
        tasks[hash] = Task.detached(priority: .utility) { [library] in
            do {
                try OCRService.makeSearchablePDF(
                    source: source, destination: partial,
                    progress: { p in Task { @MainActor in OCRManager.shared.update(hash, progress: p) } },
                    isCancelled: { Task.isCancelled })
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                await MainActor.run {
                    OCRManager.shared.finish(hash)
                    library.reindexAfterOCR(hash: hash)
                }
            } catch {
                try? FileManager.default.removeItem(at: partial)
                let message = (error as? OCRService.OCRError) == .cancelled ? nil : error.localizedDescription
                await MainActor.run { OCRManager.shared.fail(hash, message: message) }
            }
        }
    }

    func cancel(_ hash: String) {
        tasks[hash]?.cancel()
    }

    fileprivate func update(_ hash: String, progress: Double) {
        guard jobs[hash] != nil, !(jobs[hash]?.done ?? false) else { return }
        jobs[hash]?.progress = progress
    }

    fileprivate func finish(_ hash: String) {
        jobs[hash] = Job(progress: 1, done: true, error: nil)
        tasks[hash] = nil
    }

    fileprivate func fail(_ hash: String, message: String?) {
        if let message { jobs[hash] = Job(progress: 0, done: false, error: message) }
        else { jobs[hash] = nil }
        tasks[hash] = nil
    }
}

// MARK: - Library hooks

extension LibraryStore {
    var ocrFolder: URL { libraryFolder.appendingPathComponent("OCR", isDirectory: true) }

    func searchableCopyURL(for book: Book) -> URL {
        ocrFolder.appendingPathComponent("\(book.contentHash).pdf")
    }

    func hasSearchableCopy(_ book: Book) -> Bool {
        book.format == .pdf && FileManager.default.fileExists(atPath: searchableCopyURL(for: book).path)
    }

    /// The file readers and the text indexer should open: the OCR copy of a
    /// scanned PDF if one has been made, otherwise the original.
    func readableURL(for book: Book) -> URL {
        if book.format == .kindle {
            let converted = convertedURL(for: book)
            return FileManager.default.fileExists(atPath: converted.path) ? converted : book.sourceURL
        }
        return hasSearchableCopy(book) ? searchableCopyURL(for: book) : book.sourceURL
    }

    /// Where a Kindle book's EPUB conversion lives.
    var convertedFolder: URL { libraryFolder.appendingPathComponent("Converted", isDirectory: true) }

    func convertedURL(for book: Book) -> URL {
        convertedFolder.appendingPathComponent("\(book.contentHash).epub")
    }

    /// Re-extracts a book's text from its new searchable copy.
    func reindexAfterOCR(hash: String) {
        guard let book = books.first(where: { $0.contentHash == hash }) else { return }
        book.extractedTextPath = nil
        buildSearchIndexIfNeeded()
    }
}
