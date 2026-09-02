import XCTest
import SwiftData
@testable import Stoa

/// A lightweight round-trip smoke test for the SwiftData schema: insert
/// one of every @Model type, save, then fetch each back. This is not a
/// substitute for testing a real on-disk lightweight migration (that
/// needs an actual pre-existing store file, which a fresh in-memory
/// container can't reproduce) -- but it does catch a whole class of
/// mistakes early: a model that doesn't init cleanly, a Schema array
/// that's missing a type, or a stored property that can't round-trip.
///
/// The shelfNames crash (a stored property added without an inline
/// default, which broke lightweight migration for existing on-disk
/// libraries) is exactly the kind of thing this suite exists to make
/// less likely to recur -- see Book.shelfNames's default value.
final class LibraryModelSchemaTests: XCTestCase {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([Book.self, BookClassification.self, DismissedDuplicatePair.self, Bookmark.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testAllModelTypesInsertAndFetchCleanly() throws {
        let context = try makeInMemoryContext()

        let book = Book(
            title: "Test Book",
            format: .epub,
            sourceURL: URL(fileURLWithPath: "/tmp/test.epub"),
            contentHash: "test-hash"
        )
        context.insert(book)

        let classification = BookClassification(
            fileHash: "test-hash-2",
            score: 0.85,
            decision: .autoAdded,
            sourcePath: "/tmp/test2.pdf",
            fileName: "test2.pdf"
        )
        context.insert(classification)

        let dismissed = DismissedDuplicatePair(firstHash: "hash-a", secondHash: "hash-b")
        context.insert(dismissed)

        let bookmark = Bookmark(bookHash: "test-hash", position: 0.42, label: "Chapter 3")
        context.insert(bookmark)

        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BookClassification>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<DismissedDuplicatePair>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bookmark>()).count, 1)
    }

    /// Book's shelfNames (and any future collection-typed property added
    /// to an existing @Model) needs an inline default -- omitting it is
    /// exactly what caused the shelfNames ModelContainer crash. A fresh
    /// insert with no explicit value should come back as an empty array,
    /// never nil/crash.
    func testBookShelfNamesDefaultsToEmptyArray() throws {
        let context = try makeInMemoryContext()
        let book = Book(title: "No Shelves Yet", format: .pdf, sourceURL: URL(fileURLWithPath: "/tmp/x.pdf"))
        context.insert(book)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Book>())
        XCTAssertEqual(fetched.first?.shelfNames, [])
    }

    func testDismissedDuplicatePairKeyIsOrderIndependent() {
        XCTAssertEqual(
            DismissedDuplicatePair.makeKey("hash-a", "hash-b"),
            DismissedDuplicatePair.makeKey("hash-b", "hash-a")
        )
    }
}
