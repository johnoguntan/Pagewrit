import XCTest
@testable import Pagewrit

final class ReviewDecisionTests: XCTestCase {
    func testUserDecisionsOutrankAutomaticOnes() {
        XCTAssertGreaterThan(BookClassificationDecision.userConfirmed.precedence, BookClassificationDecision.needsReview.precedence)
        XCTAssertGreaterThan(BookClassificationDecision.userDismissed.precedence, BookClassificationDecision.autoAdded.precedence)
        XCTAssertGreaterThan(BookClassificationDecision.autoAdded.precedence, BookClassificationDecision.needsReview.precedence)
        XCTAssertGreaterThan(BookClassificationDecision.needsReview.precedence, BookClassificationDecision.autoSkipped.precedence)
    }

    func testIsUserDecision() {
        XCTAssertTrue(BookClassificationDecision.userConfirmed.isUserDecision)
        XCTAssertTrue(BookClassificationDecision.userDismissed.isUserDecision)
        XCTAssertFalse(BookClassificationDecision.needsReview.isUserDecision)
        XCTAssertFalse(BookClassificationDecision.autoAdded.isUserDecision)
    }
}
