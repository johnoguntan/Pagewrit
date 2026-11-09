import Foundation

/// A raw file found on disk during a scan, before any metadata (title/author/cover)
/// has been extracted. Phase 1 only produces these; Phase 2's ImportPipeline will
/// turn them into full `Book` records.
struct DiscoveredFile: Identifiable, Hashable {
    let id: String          // stable id = file path
    let url: URL
    let format: BookFormat
    let sizeBytes: Int64
    let modifiedAt: Date?

    init(url: URL, format: BookFormat, sizeBytes: Int64, modifiedAt: Date?) {
        self.id = url.path
        self.url = url
        self.format = format
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

enum BookFormat: String, CaseIterable {
    case epub
    case pdf
    case cbz
    case pptx
    case docx   // Word, RTF, OpenDocument
    case text   // plain text and Markdown
    case kindle // MOBI, AZW, AZW3, PRC (converted to EPUB for reading)

    /// Lowercased file extensions (without the dot) this format matches.
    static var supportedExtensions: [String: BookFormat] {
        [
            "epub": .epub,
            "pdf": .pdf,
            "cbz": .cbz,
            "pptx": .pptx,
            "docx": .docx,
            "doc": .docx,
            "rtf": .docx,
            "odt": .docx,
            "txt": .text,
            "md": .text,
            "markdown": .text,
            "mobi": .kindle,
            "azw": .kindle,
            "azw3": .kindle,
            "prc": .kindle
        ]
    }

    init?(fileExtension: String) {
        guard let match = BookFormat.supportedExtensions[fileExtension.lowercased()] else {
            return nil
        }
        self = match
    }

    /// How the format is written on covers and in lists.
    var label: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .cbz: return "CBZ"
        case .pptx: return "PPTX"
        case .docx: return "DOCX"
        case .text: return "Text"
        case .kindle: return "Kindle"
        }
    }

    /// SF Symbol name for this format.
    var systemImage: String {
        switch self {
        case .epub: return "book"
        case .pdf:  return "doc.richtext"
        case .cbz:  return "photo.on.rectangle"
        case .pptx: return "play.rectangle"
        case .docx: return "doc.text"
        case .text: return "text.alignleft"
        case .kindle: return "book.closed"
        }
    }

    /// Human-readable section title for grouping in the UI.
    var sectionTitle: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf:  return "PDF"
        case .cbz:  return "CBZ"
        case .pptx: return "PowerPoint"
        case .docx: return "Documents"
        case .text: return "Text & Markdown"
        case .kindle: return "Kindle"
        }
    }

    /// Formats whose first page/slide is rendered live for the grid cover
    /// (as opposed to a cover image extracted and saved at import).
    var rendersLiveThumbnail: Bool {
        self == .pdf || self == .pptx || self == .docx
    }
}
