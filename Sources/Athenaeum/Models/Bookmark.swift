import Foundation
import SwiftData

/// A saved position inside a book — distinct from `Book.readingProgress`,
/// which only ever tracks the single "resume reading here" spot. A book
/// can carry any number of bookmarks, each independently labeled, so a
/// reader can mark a passage to come back to without losing their actual
/// reading position.
///
/// `position` uses the same 0...1 fraction-through-the-book convention as
/// `Book.readingProgress` (page index / page count, chapter index / chapter
/// count) so every reader — PDF, EPUB, CBZ — can save and jump to a
/// bookmark with the same math it already uses for resume-progress.
@Model
final class Bookmark: Hashable {
    var bookHash: String
    var position: Double
    var label: String
    var createdAt: Date

    init(bookHash: String, position: Double, label: String) {
        self.bookHash = bookHash
        self.position = position
        self.label = label
        self.createdAt = Date()
    }

    // MARK: - Hashable via persistentModelID

    static func == (lhs: Bookmark, rhs: Bookmark) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}
