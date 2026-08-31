import XCTest
@testable import Stoa

final class DuplicateDetectorTests: XCTestCase {
    private func makeBook(
        title: String,
        author: String? = nil,
        format: BookFormat = .epub,
        contentHash: String
    ) -> Book {
        Book(
            title: title,
            author: author,
            format: format,
            sourceURL: URL(fileURLWithPath: "/tmp/\(contentHash).\(format.rawValue)"),
            contentHash: contentHash
        )
    }

    func testFindsCrossFormatDuplicateByNormalizedTitleAndAuthor() {
        let epub = makeBook(title: "The 33 Strategies of War", author: "Robert Greene", format: .epub, contentHash: "hash-a")
        let pdf = makeBook(title: "the 33 strategies of war!", author: "robert greene", format: .pdf, contentHash: "hash-b")
        let unrelated = makeBook(title: "Some Other Book", author: "Someone Else", contentHash: "hash-c")

        let groups = DuplicateDetector.findGroups(in: [epub, pdf, unrelated], dismissedPairKeys: [])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(Set(groups.first!.map { $0.contentHash }), ["hash-a", "hash-b"])
    }

    func testDoesNotGroupDifferentTitles() {
        let a = makeBook(title: "Book One", contentHash: "hash-a")
        let b = makeBook(title: "Book Two", contentHash: "hash-b")

        let groups = DuplicateDetector.findGroups(in: [a, b], dismissedPairKeys: [])

        XCTAssertTrue(groups.isEmpty)
    }

    func testDismissedPairIsExcludedFromResults() {
        let a = makeBook(title: "Same Title", author: "Same Author", contentHash: "hash-a")
        let b = makeBook(title: "Same Title", author: "Same Author", contentHash: "hash-b")

        let key = DismissedDuplicatePair.makeKey("hash-a", "hash-b")
        let groups = DuplicateDetector.findGroups(in: [a, b], dismissedPairKeys: [key])

        XCTAssertTrue(groups.isEmpty, "A pair the user already dismissed should never resurface")
    }

    func testDismissingOnePairAlsoDropsBothBooksFromAThreeWayGroup() {
        // findGroups excludes any book that has a dismissed pairing with
        // *any* other book still in the group, not just the specific
        // pair dismissed -- so a/b vanish here even though c still
        // matches both, leaving c alone (which isn't a duplicate on its
        // own, so the group disappears entirely). Documenting the actual
        // behavior here rather than what might feel more intuitive, so a
        // future change to that semantic shows up as a deliberate test
        // update instead of a silent behavior change.
        let a = makeBook(title: "Same Title", author: "Same Author", contentHash: "hash-a")
        let b = makeBook(title: "Same Title", author: "Same Author", contentHash: "hash-b")
        let c = makeBook(title: "Same Title", author: "Same Author", contentHash: "hash-c")

        let key = DismissedDuplicatePair.makeKey("hash-a", "hash-b")
        let groups = DuplicateDetector.findGroups(in: [a, b, c], dismissedPairKeys: [key])

        XCTAssertTrue(groups.isEmpty)
    }
}
