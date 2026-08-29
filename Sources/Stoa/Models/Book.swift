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
    var formatRaw: String     // stored as String for SwiftData; computed `format` accessor below
    var sourcePath: String    // sourceURL.path — stored as String because URL isn't Codable by SwiftData
    var libraryPath: String?  // libraryURL?.path
    var coverImagePath: String?
    var addedAt: Date
    var tags: [String]
    var readingProgress: Double?   // 0.0...1.0, optional
    var contentHash: String        // SHA256 of file bytes, for dedup
    var sizeBytes: Int64
    var modifiedAt: Date?
    var lastOpenedAt: Date?         // when the reader was last opened — drives "Continue Reading"
    var extractedTextPath: String?  // cached plain-text extraction on disk, for full-text search

    init(
        title: String,
        author: String? = nil,
        format: BookFormat,
        sourceURL: URL,
        libraryURL: URL? = nil,
        coverImagePath: String? = nil,
        addedAt: Date = Date(),
        tags: [String] = [],
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
        (readingProgress ?? 0) >= 0.98
    }
}
