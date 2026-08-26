import Foundation

/// Full library record. Phase 1 does not populate most of these fields yet —
/// this type exists now so Phase 2 (ImportPipeline + LibraryStore) has a
/// stable shape to build against.
///
/// TODO(Phase 2): back this with SwiftData or GRDB instead of being a plain struct.
struct Book: Identifiable, Hashable {
    let id: UUID
    var title: String
    var author: String?
    var format: BookFormat
    var sourceURL: URL
    var libraryURL: URL?      // location inside the Library folder, once imported
    var coverImagePath: String?
    var addedAt: Date
    var tags: [String]
    var readingProgress: Double?   // 0.0...1.0, optional for now

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        format: BookFormat,
        sourceURL: URL,
        libraryURL: URL? = nil,
        coverImagePath: String? = nil,
        addedAt: Date = Date(),
        tags: [String] = [],
        readingProgress: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.format = format
        self.sourceURL = sourceURL
        self.libraryURL = libraryURL
        self.coverImagePath = coverImagePath
        self.addedAt = addedAt
        self.tags = tags
        self.readingProgress = readingProgress
    }
}
