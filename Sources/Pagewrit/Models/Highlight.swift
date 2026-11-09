import Foundation
import SwiftData
import SwiftUI

/// The marker colors a reader can pick from. Stored by raw value so the
/// palette can change later without breaking saved highlights.
enum HighlightColor: String, CaseIterable, Codable, Identifiable {
    case yellow, green, blue, pink, purple

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    /// Soft marker tint, readable on both light and dark pages.
    var color: Color {
        switch self {
        case .yellow: return Color(red: 1.00, green: 0.88, blue: 0.35)
        case .green:  return Color(red: 0.55, green: 0.85, blue: 0.55)
        case .blue:   return Color(red: 0.50, green: 0.75, blue: 1.00)
        case .pink:   return Color(red: 1.00, green: 0.62, blue: 0.75)
        case .purple: return Color(red: 0.75, green: 0.62, blue: 1.00)
        }
    }

    var nsColor: NSColor { NSColor(color) }

    /// CSS rgba() string used by the EPUB reader.
    var css: String {
        switch self {
        case .yellow: return "rgba(255,224,89,0.55)"
        case .green:  return "rgba(140,217,140,0.55)"
        case .blue:   return "rgba(128,191,255,0.55)"
        case .pink:   return "rgba(255,158,191,0.55)"
        case .purple: return "rgba(191,158,255,0.55)"
        }
    }
}

/// A passage the reader marked, with an optional note.
///
/// One model serves every format:
/// - PDF: `pageIndex` is the page, `rangeStart/rangeLength` are character
///   offsets within that page's text.
/// - EPUB: `pageIndex` is the chapter (spine) index, offsets are within the
///   chapter's text content.
/// - Text / Word / Markdown: `pageIndex` is 0, offsets are within the whole
///   document text.
///
/// `text` keeps the quoted passage so the notes screen and Markdown export
/// work without opening the book, and so a highlight can be re-found if the
/// offsets ever drift.
@Model
final class Highlight: Hashable {
    var bookHash: String
    var pageIndex: Int
    var rangeStart: Int
    var rangeLength: Int
    /// 0...1 fraction through the book, same convention as `Bookmark.position`,
    /// used to sort highlights in reading order across formats.
    var position: Double
    var text: String
    var colorRaw: String
    var note: String
    var createdAt: Date

    init(
        bookHash: String,
        pageIndex: Int,
        rangeStart: Int,
        rangeLength: Int,
        position: Double,
        text: String,
        color: HighlightColor = .yellow,
        note: String = ""
    ) {
        self.bookHash = bookHash
        self.pageIndex = pageIndex
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.position = position
        self.text = text
        self.colorRaw = color.rawValue
        self.note = note
        self.createdAt = Date()
    }

    var color: HighlightColor {
        get { HighlightColor(rawValue: colorRaw) ?? .yellow }
        set { colorRaw = newValue.rawValue }
    }

    // MARK: - Hashable via persistentModelID

    static func == (lhs: Highlight, rhs: Highlight) -> Bool {
        lhs.persistentModelID == rhs.persistentModelID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(persistentModelID)
    }
}

extension HighlightColor {
    /// A small solid dot, drawn as a non-template image so it keeps its
    /// colour inside menus (which otherwise flatten icons to grey).
    var dotImage: NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
