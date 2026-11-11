import Foundation
import SwiftData

/// Full library record backed by SwiftData.
///
/// Phase 2 converts this from a plain struct to a `@Model` so the library
/// persists across relaunches via SwiftData's on-disk SQLite store.
@Model
final class Book: Hashable {
    var title: String
    var author: String?

    /// The author as a reader should see it. File metadata often holds a
    /// publisher, a program name or a placeholder instead of a person; those
    /// read as wrong, so they are left out.
    var displayAuthor: String? {
        guard let raw = author?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let junk = [
            "unknown", "anonymous", "admin", "administrator", "user", "author", "n/a", "none", "null",
            "publishing", "publishers", "publisher", "press", "microsoft", "word", "adobe", "acrobat",
            "calibre", "libreoffice", "pdf", "scan", "scanner", ".com", ".org", ".net", "www", "http",
            "online", "ebook", "e-book", "digital", "library", "document"
        ]
        let words = lower.split(whereSeparator: { !$0.isLetter && $0 != "." && $0 != "-" }).map(String.init)
        if junk.contains(where: { key in key.hasPrefix(".") || key == "www" || key == "http" ? lower.contains(key) : words.contains(key) }) { return nil }
        return raw
    }
    var formatRaw: String     // stored as String for SwiftData; computed `format` accessor below
    var sourcePath: String    // sourceURL.path — stored as String because URL isn't Codable by SwiftData
    var libraryPath: String?  // libraryURL?.path
    var coverImagePath: String?
    var addedAt: Date
    var tags: [String]
    var shelfNames: [String] = []
    var readingProgress: Double?   // 0.0...1.0, optional
    var contentHash: String        // SHA256 of file bytes, for dedup
    var sizeBytes: Int64
    var modifiedAt: Date?
    var lastOpenedAt: Date?         // when the reader was last opened — drives "Continue Reading"
    var extractedTextPath: String?  // cached plain-text extraction on disk, for full-text search
    var isFavorite: Bool = false    // starred by the reader; shown under Favorites
    var rating: Int = 0             // 0 = unrated, otherwise 1...5 stars
    var seriesName: String?         // e.g. "The Expanse"
    var seriesIndex: Double?        // book number within the series
    var manualStatus: String?       // "unread" / "reading" / "finished" when the reader set it by hand

    init(
        title: String,
        author: String? = nil,
        format: BookFormat,
        sourceURL: URL,
        libraryURL: URL? = nil,
        coverImagePath: String? = nil,
        addedAt: Date = Date(),
        tags: [String] = [],
        shelfNames: [String] = [],
        readingProgress: Double? = nil,
        contentHash: String = "",
        sizeBytes: Int64 = 0,
        modifiedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        extractedTextPath: String? = nil
    ) {
        self.title = title
        self.author = author
        self.formatRaw = format.rawValue
        self.sourcePath = sourceURL.path
        self.libraryPath = libraryURL?.path
        self.coverImagePath = coverImagePath
        self.addedAt = addedAt
        self.tags = tags
        self.shelfNames = shelfNames
        self.readingProgress = readingProgress
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.lastOpenedAt = lastOpenedAt
        self.extractedTextPath = extractedTextPath
    }

    // MARK: - Hashable via persistentModelID

    static func == (lhs: Book, rhs: Book) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }

    // MARK: - Computed convenience

    var format: BookFormat {
        BookFormat(rawValue: formatRaw) ?? .pdf
    }

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var libraryURL: URL? {
        libraryPath.map { URL(fileURLWithPath: $0) }
    }

    var coverImageURL: URL? {
        coverImagePath.map { URL(fileURLWithPath: $0) }
    }

    var extractedTextURL: URL? {
        extractedTextPath.map { URL(fileURLWithPath: $0) }
    }

    /// True once reading progress is close enough to the end to count as done.
    var isFinished: Bool {
        status == .finished
    }

    /// Where the reader is with this book. A status the reader set by hand
    /// wins; otherwise it follows reading progress.
    var status: ReadingStatus {
        if let manualStatus, let chosen = ReadingStatus(rawValue: manualStatus) { return chosen }
        let progress = readingProgress ?? 0
        if progress >= 0.98 { return .finished }
        // Opening a book starts it, even before the first page turn.
        return (progress > 0 || lastOpenedAt != nil) ? .reading : .unread
    }
}


/// Unread, in progress, or done.
enum ReadingStatus: String, CaseIterable, Identifiable {
    case unread, reading, finished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unread: "Unread"
        case .reading: "Reading"
        case .finished: "Finished"
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "circle"
        case .reading: "book"
        case .finished: "checkmark.circle"
        }
    }
}
