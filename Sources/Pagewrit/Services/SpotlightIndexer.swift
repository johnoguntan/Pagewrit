import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes the library into macOS Spotlight, so books turn up in system
/// search by title, author, or tag. Each item's uniqueIdentifier is the
/// book's contentHash — stable across rescans, and how a Spotlight tap
/// gets routed back to the right book (see PagewritApp's continue-userActivity
/// handling).
enum SpotlightIndexer {
    static func reindex(_ books: [Book]) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }

        let items = books.map { book -> CSSearchableItem in
            let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
            attributeSet.title = book.title
            attributeSet.contentDescription = book.author
            attributeSet.keywords = [book.format.rawValue.uppercased()] + book.tags

            let item = CSSearchableItem(
                uniqueIdentifier: book.contentHash,
                domainIdentifier: "com.thehappy.Pagewrit.books",
                attributeSet: attributeSet
            )
            item.expirationDate = .distantFuture
            return item
        }

        CSSearchableIndex.default().indexSearchableItems(items, completionHandler: nil)
    }

    static func remove(hash: String) {
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [hash], completionHandler: nil)
    }
}
