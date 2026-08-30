import SwiftUI
import AppKit

/// Reading-focused color theme, shared by the EPUB and PDF readers.
/// Deliberately independent of the app's own light/dark appearance \u{2014} a
/// long reading session often wants a background choice that doesn't
/// follow whatever the rest of macOS is doing (a warm "sepia" page while
/// the Mac stays in light mode, or a true "night" reader without forcing
/// dark mode system-wide).
///
/// For EPUB, the theme recolors the actual page (CSS injected into the
/// chapter's HTML), so it's a full night/sepia reading mode. For PDF, a
/// page's content is baked into the document itself \u{2014} there's no honest
/// way to recolor a scanned page's ink without risking scanned photos and
/// diagrams looking wrong \u{2014} so PDF theming only recolors the app's own
/// chrome and the margin around the page, the same restrained thing
/// Preview.app does.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case night
    case sepia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .night: "Night"
        case .sepia: "Sepia"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .night: "moon.fill"
        case .sepia: "sun.max.fill"
        }
    }

    // MARK: - SwiftUI colors (reader chrome + PDF margin)

    var backgroundColor: Color? {
        switch self {
        case .system: nil
        case .night: Color(red: 0.086, green: 0.086, blue: 0.098)
        case .sepia: Color(red: 0.965, green: 0.929, blue: 0.831)
        }
    }

    var chromeColor: Color? {
        switch self {
        case .system: nil
        case .night: Color(red: 0.122, green: 0.122, blue: 0.137)
        case .sepia: Color(red: 0.937, green: 0.898, blue: 0.792)
        }
    }

    var textColor: Color? {
        switch self {
        case .system: nil
        case .night: Color(red: 0.86, green: 0.86, blue: 0.84)
        case .sepia: Color(red: 0.290, green: 0.212, blue: 0.129)
        }
    }

    var secondaryTextColor: Color? {
        switch self {
        case .system: nil
        case .night: Color(red: 0.86, green: 0.86, blue: 0.84).opacity(0.6)
        case .sepia: Color(red: 0.290, green: 0.212, blue: 0.129).opacity(0.65)
        }
    }

    /// PDFView's own `backgroundColor` (the margin around the page, not the
    /// page content itself).
    var pdfBackgroundNSColor: NSColor? {
        switch self {
        case .system: nil
        case .night: NSColor(red: 0.086, green: 0.086, blue: 0.098, alpha: 1)
        case .sepia: NSColor(red: 0.937, green: 0.898, blue: 0.792, alpha: 1)
        }
    }

    // MARK: - EPUB CSS injection

    var epubBackgroundHex: String? {
        switch self {
        case .system: nil
        case .night: "#16161A"
        case .sepia: "#F6EBD4"
        }
    }

    var epubTextHex: String? {
        switch self {
        case .system: nil
        case .night: "#DBDBD6"
        case .sepia: "#4A3621"
        }
    }
}
