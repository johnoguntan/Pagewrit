import Foundation
import SwiftData

/// Records that the user looked at two books flagged as likely duplicates
/// and decided to keep both — so the Duplicates tray doesn't keep
/// resurfacing the same pair every time the library reloads.
///
/// Keyed by a stable, order-independent pair key (the two books'
/// `contentHash` values, sorted, joined) rather than by object identity,
/// so the dismissal survives even if the books are later re-imported or
/// the tray recomputes its grouping from scratch.
@Model
final class DismissedDuplicatePair: Hashable {
    var pairKey: String
    var dismissedAt: Date

    init(firstHash: String, secondHash: String) {
        self.pairKey = DismissedDuplicatePair.makeKey(firstHash, secondHash)
        self.dismissedAt = Date()
    }

    static func makeKey(_ first: String, _ second: String) -> String {
        [first, second].sorted().joined(separator: "|")
    }

    // MARK: - Hashable via persistentModelID

    static func == (lhs: DismissedDuplicatePair, rhs: DismissedDuplicatePair) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}
