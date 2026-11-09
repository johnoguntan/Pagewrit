import Foundation
import CryptoKit
import PDFKit
import AppKit

#if canImport(EPUBKit)
import EPUBKit
#endif

#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Imports a `DiscoveredFile` into a `Book` record: computes a content hash
/// for dedup, extracts metadata (title/author), and pulls cover art for
/// EPUB/CBZ (PDFs are handled live by CoverThumbnailCache in the grid).
///
/// Thread-safe: all heavy work happens off the main thread. Call `importFile`
/// from any context; the callback fires on the main thread.
/// Remembers each file's hash by path, size and modification time, so a
/// rescan only reads files that are new or changed instead of re-hashing the
/// whole library every time a download lands.
final class HashCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String] = [:]

    func hash(for file: DiscoveredFile, compute: () -> String) -> String {
        let key = "\(file.url.path)|\(file.sizeBytes)|\(file.modifiedAt?.timeIntervalSince1970 ?? 0)"
        lock.lock()
        let cached = map[key]
        lock.unlock()
        if let cached { return cached }
        let value = compute()
        if !value.isEmpty {
            lock.lock()
            map[key] = value
            lock.unlock()
        }
        return value
    }
}

enum ImportPipeline {
    static let hashCache = HashCache()

    static func cachedContentHash(for file: DiscoveredFile) -> String {
        hashCache.hash(for: file) { contentHash(for: file.url) }
    }


    // MARK: - Public entry point

    /// Import a single file. Returns nil if the file is a duplicate (already
    /// in the library by content hash) or if extraction fails completely.
    ///
    /// Pass `precomputedHash` when the caller already hashed this file this
    /// scan pass (e.g. `classifyFile` did it moments ago) — avoids hashing
    /// the same file's full contents twice per rescan.
    @MainActor
    static func importFile(
        _ file: DiscoveredFile,
        libraryFolder: URL,
        precomputedHash: String? = nil
    ) async -> Book? {
        // 1. Content hash — reuse if the caller already computed one
        let hash: String
        if let precomputedHash {
            hash = precomputedHash
        } else {
            hash = await Task.detached(priority: .userInitiated) {
                Self.contentHash(for: file.url)
            }.value
        }
        guard !hash.isEmpty else { return nil }

        // 2. Extract metadata + cover off the main thread
        let result = await Task.detached(priority: .userInitiated) {
            Self.extractMetadata(for: file, contentHash: hash, libraryFolder: libraryFolder)
        }.value

        guard let result else { return nil }

        // 3. Build and return the Book
        return Book(
            title: result.title,
            author: result.author,
            format: file.format,
            sourceURL: file.url,
            libraryURL: nil,
            coverImagePath: result.coverImagePath,
            addedAt: dateAddedToMac(file.url) ?? Date(),
            tags: [],
            readingProgress: nil,
            contentHash: hash,
            sizeBytes: file.sizeBytes,
            modifiedAt: file.modifiedAt
        )
    }

    /// When the file first landed on this Mac (its creation date, which a move
    /// or a copy within the Mac keeps), not when Pagewrit noticed it. Nil when
    /// the file can't be read.
    static func dateAddedToMac(_ url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey]) else { return nil }
        let now = Date()
        if let created = values.creationDate, created <= now { return created }
        if let added = values.addedToDirectoryDate, added <= now { return added }
        return nil
    }

    /// Classify a file and return both the hash and classification result.
    /// EPUB/CBZ return nil (skip classification). Only PDFs are scored.
    @MainActor
    static func classifyFile(
        _ file: DiscoveredFile,
        library: LibraryStore,
        precomputedHash: String? = nil
    ) async -> (hash: String, classification: BookClassification)? {
        // 1. Content hash — reuse if the caller already computed one
        let hash: String
        if let precomputedHash {
            hash = precomputedHash
        } else {
            hash = await Task.detached(priority: .userInitiated) {
                Self.contentHash(for: file.url)
            }.value
        }

        // An unreadable file has no identity yet; leave it for the next scan.
        guard !hash.isEmpty else { return nil }

        // 2. Skip if already classified
        if let existing = library.classification(for: hash) {
            return (hash, existing)
        }

        // 3. Skip if user previously dismissed
        if library.dismissedHashes.contains(hash) {
            return nil
        }

        // 4. Classify (returns nil for EPUB/CBZ — those bypass)
        guard let result = BookClassifier.classify(file) else {
            return nil
        }

        // 5. Persist the classification
        let classification = BookClassification(
            fileHash: hash,
            score: result.score,
            decision: result.decision,
            sourcePath: file.url.path,
            fileName: file.url.lastPathComponent
        )
        library.addClassification(classification)

        return (hash, classification)
    }

    // MARK: - Content hash (SHA256 via CryptoKit)

    /// SHA-256 of the file's bytes, read in 1 MB chunks so a large PDF or
    /// comic archive never has to fit in memory at once.
    ///
    /// Returns "" if the file can't be read (missing, permission not yet
    /// granted, iCloud file not downloaded). Callers must treat "" as
    /// "couldn't identify this file" and skip it, never as a real identity:
    /// every unreadable file would otherwise share the same hash.
    static func contentHash(for url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return ""
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Metadata extraction

    private struct ExtractionResult {
        let title: String
        let author: String?
        let coverImagePath: String? // nil for PDFs (they use CoverThumbnailCache live)
    }

    private static func extractMetadata(
        for file: DiscoveredFile,
        contentHash: String,
        libraryFolder: URL
    ) -> ExtractionResult? {
        switch file.format {
        case .pdf:
            return extractPDFMetadata(for: file)
        case .epub:
            return extractEPUBMetadata(for: file, contentHash: contentHash, libraryFolder: libraryFolder)
        case .cbz:
            return extractCBZMetadata(for: file, contentHash: contentHash, libraryFolder: libraryFolder)
        case .pptx:
            return extractPPTXMetadata(for: file)
        case .docx, .text:
            return extractTextDocumentMetadata(for: file)
        case .kindle:
            return extractKindleMetadata(for: file, contentHash: contentHash, libraryFolder: libraryFolder)
        }
    }

    // MARK: - PDF extraction

    private static func extractPDFMetadata(for file: DiscoveredFile) -> ExtractionResult? {
        guard let document = PDFDocument(url: file.url) else { return nil }

        let attrs = document.documentAttributes
        let metaTitle = attrs?[PDFDocumentAttribute.titleAttribute] as? String
        let metaAuthor = attrs?[PDFDocumentAttribute.authorAttribute] as? String
        let title = (metaTitle?.isEmpty == false ? metaTitle : nil)
            ?? file.url.deletingPathExtension().lastPathComponent
        let author = (metaAuthor?.isEmpty == false ? metaAuthor : nil)

        // PDFs don't need a saved cover file — CoverThumbnailCache renders them live in the grid
        return ExtractionResult(title: title, author: author, coverImagePath: nil)
    }

    // MARK: - PowerPoint extraction

    private static func extractPPTXMetadata(for file: DiscoveredFile) -> ExtractionResult? {
        let fallback = file.url.deletingPathExtension().lastPathComponent
        // The filename is usually the better title for a deck than slide 1,
        // so only trust the document's own title property, not the first slide.
        let deck = PPTXDocument.load(from: file.url)
        let docTitle = deck?.title
        let title = (docTitle?.isEmpty == false ? docTitle : nil) ?? fallback
        // Cover comes from CoverThumbnailCache (Quick Look), like PDFs.
        return ExtractionResult(title: title, author: deck?.author, coverImagePath: nil)
    }

    // MARK: - Word / text / Markdown extraction

    private static func extractTextDocumentMetadata(for file: DiscoveredFile) -> ExtractionResult? {
        let fallback = file.url.deletingPathExtension().lastPathComponent
        let loaded = TextDocumentLoader.load(url: file.url, format: file.format)
        // Word's own title property is often empty or "Document1"; prefer the filename then.
        var title = loaded?.title ?? fallback
        if title.lowercased().hasPrefix("document") || title.lowercased().hasPrefix("untitled") { title = fallback }
        return ExtractionResult(title: title, author: loaded?.author, coverImagePath: nil)
    }

    // MARK: - Kindle extraction

    /// Reads the book's own title/author/cover and converts it to an EPUB in
    /// the library so it's ready to read and search. DRM or unsupported books
    /// are still added (with what we can read) so they show up in the library;
    /// opening them explains why they can't be read.
    private static func extractKindleMetadata(
        for file: DiscoveredFile,
        contentHash: String,
        libraryFolder: URL
    ) -> ExtractionResult? {
        let fallback = file.url.deletingPathExtension().lastPathComponent
        let info = KindleConverter.inspect(url: file.url)
        let title = (info?.title?.isEmpty == false ? info?.title : nil) ?? fallback

        var coverPath: String?
        if let cover = info?.coverData,
           let saved = saveCoverImage(cover, contentHash: contentHash, libraryFolder: libraryFolder) {
            coverPath = saved
        }

        let converted = libraryFolder
            .appendingPathComponent("Converted", isDirectory: true)
            .appendingPathComponent("\(contentHash).epub")
        _ = try? KindleConverter.convert(source: file.url, destination: converted)

        return ExtractionResult(title: title, author: info?.author, coverImagePath: coverPath)
    }

    // MARK: - EPUB extraction

    private static func extractEPUBMetadata(
        for file: DiscoveredFile,
        contentHash: String,
        libraryFolder: URL
    ) -> ExtractionResult? {
        #if canImport(EPUBKit)
        guard let epub = EPUBDocument(url: file.url) else {
            return ExtractionResult(
                title: file.url.deletingPathExtension().lastPathComponent,
                author: nil,
                coverImagePath: nil
            )
        }

        let title = epub.title?.isEmpty == false ? epub.title! : file.url.deletingPathExtension().lastPathComponent
        let author = epub.author?.isEmpty == false ? epub.author : nil

        // Extract cover image if available (EPUBKit provides a URL to the cover file)
        var coverPath: String? = nil
        if let coverURL = epub.cover, let coverData = try? Data(contentsOf: coverURL),
           let savedPath = saveCoverImage(coverData, contentHash: contentHash, libraryFolder: libraryFolder) {
            coverPath = savedPath
        }

        return ExtractionResult(title: title, author: author, coverImagePath: coverPath)
        #else
        return ExtractionResult(
            title: file.url.deletingPathExtension().lastPathComponent,
            author: nil,
            coverImagePath: nil
        )
        #endif
    }

    // MARK: - CBZ extraction

    private static func extractCBZMetadata(
        for file: DiscoveredFile,
        contentHash: String,
        libraryFolder: URL
    ) -> ExtractionResult? {
        let title = file.url.deletingPathExtension().lastPathComponent

        #if canImport(ZIPFoundation)
        guard let archive = try? Archive(url: file.url, accessMode: .read, pathEncoding: nil) else {
            return ExtractionResult(title: title, author: nil, coverImagePath: nil)
        }

        // Find first image entry in filename order — that's the cover
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic"]
        // Real pages only: Mac archives carry hidden "__MACOSX" and "._" copies
        // of every image that are not pictures, and would make a broken cover.
        let entries = archive
            .filter { entry in
                guard entry.type == .file, entry.uncompressedSize < 60_000_000 else { return false }
                let name = (entry.path as NSString).lastPathComponent
                return !entry.path.hasPrefix("__MACOSX") && !name.hasPrefix(".")
            }
            .sorted { ($0.path).localizedStandardCompare($1.path) == .orderedAscending }

        if let coverEntry = entries.first(where: { entry in
            let ext = (entry.path as NSString).pathExtension.lowercased()
            return imageExtensions.contains(ext)
        }) {
            var coverData = Data()
            do {
                _ = try archive.extract(coverEntry) { data in
                    coverData.append(data)
                }
                if !coverData.isEmpty, let savedPath = saveCoverImage(coverData, contentHash: contentHash, libraryFolder: libraryFolder) {
                    return ExtractionResult(title: title, author: nil, coverImagePath: savedPath)
                }
            } catch {
                print("ImportPipeline: failed to extract CBZ cover: \(error)")
            }
        }
        #endif

        return ExtractionResult(title: title, author: nil, coverImagePath: nil)
    }

    // MARK: - Cover image persistence

    /// Save raw image data to StoaLibrary/Covers/<hash>.jpg and return the
    /// relative path string to store in Book.coverImagePath.
    private static func saveCoverImage(
        _ data: Data,
        contentHash: String,
        libraryFolder: URL
    ) -> String? {
        let coversDir = libraryFolder.appendingPathComponent("Covers", isDirectory: true)
        let filename = "\(contentHash).jpg"
        let fileURL = coversDir.appendingPathComponent(filename)

        do {
            // Convert to NSImage → TIFF → JPEG for consistent output
            guard let nsImage = NSImage(data: data),
                  let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                // Fallback: save raw data if conversion fails
                try data.write(to: fileURL)
                return fileURL.path
            }
            try jpegData.write(to: fileURL)
            return fileURL.path
        } catch {
            print("ImportPipeline: failed to save cover image: \(error)")
            return nil
        }
    }
}
