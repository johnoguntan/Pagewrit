import Foundation

/// Features that will sit behind Pagewrit Pro. The pricing model (one-time
/// unlock or subscription) isn't decided yet, so everything is unlocked for
/// now; call sites already ask `Entitlements.isUnlocked(_:)`, so turning on
/// the paywall later is a change in this one file.
enum ProFeature: String, CaseIterable {
    case presenterMode      // PowerPoint presenter view with notes and timer
    case slideExport        // Export decks to PDF or images
    case ocr                // Searchable scanned PDFs
    case sync               // Progress, notes and shelves across devices
    case notesExport        // Export highlights and notes to other apps
    case kindleFormats      // MOBI / AZW3 reading

    var title: String {
        switch self {
        case .presenterMode: "Presenter mode"
        case .slideExport: "Slide export"
        case .ocr: "Scanned-page search (OCR)"
        case .sync: "Sync across devices"
        case .notesExport: "Notes export"
        case .kindleFormats: "Kindle formats"
        }
    }
}

enum Entitlements {
    /// Flip to true when the paid tier launches.
    static let paywallEnabled = false

    /// Replace with a StoreKit check when the purchase model is chosen.
    static var hasPro: Bool { !paywallEnabled }

    static func isUnlocked(_ feature: ProFeature) -> Bool { hasPro }
}
