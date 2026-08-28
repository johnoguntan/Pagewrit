import Foundation
import SwiftData

/// What happened to a file after scoring. Declared at the top level (not
/// nested inside `BookClassification`) — a nested enum inside an `@Model`
/// class body appears to confuse the macro's synthesized `Equatable`
/// conformance (this exact nesting produced "Type 'BookClassification'
/// does not conform to protocol 'Equatable'" from Xcode; `Book`'s analogous
/// `BookFormat` enum has always been top-level, and that model has never
/// hit this).
enum BookClassificationDecision: String, CaseIterable {
    case autoAdded       // score ≥ 0.7 → went straight to library
    case needsReview     // 0.3–0.7 → sitting in the review tray
    case autoSkipped     // < 0.3 → silently not imported
    case userConfirmed   // user explicitly added from review tray
    case userDismissed   // user said "not a book" — never resurfaces
}

/// A persisted classification decision for a single file, keyed by its
/// content hash. Lives in the same SwiftData store as `Book` records.
///
/// Once a decision is made (auto-added, dismissed, etc.), the file never
/// resurfaces on rescan — the classifier checks this model first.
@Model
final class BookClassification: Hashable {

    /// SHA-256 content hash of the file (same key used by Book.contentHash).
    var fileHash: String

    /// Classifier score 0...1 (higher = more likely to be a book).
    var score: Double

    /// What happened to this file after scoring.
    var decisionRaw: String

    /// When the decision was made.
    var decidedAt: Date

    /// Source file path (stored so the review tray can display the filename
    /// and resolve the URL when the user confirms "Add to Library").
    var sourcePath: String

    /// Display name derived from the filename (set at classification time).
    var fileName: String

    typealias Decision = BookClassificationDecision

    var decision: Decision {
        get { Decision(rawValue: decisionRaw) ?? .autoSkipped }
        set { decisionRaw = newValue.rawValue }
    }

    // MARK: - Computed

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    // MARK: - Init

    init(fileHash: String, score: Double, decision: Decision, sourcePath: String = "", fileName: String = "") {
        self.fileHash = fileHash
        self.score = score
        self.decisionRaw = decision.rawValue
        self.decidedAt = Date()
        self.sourcePath = sourcePath
        self.fileName = fileName
    }

    // MARK: - Hashable via persistentModelID

    static func == (lhs: BookClassification, rhs: BookClassification) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}
