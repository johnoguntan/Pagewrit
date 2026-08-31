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

    /// Lowercased file extensions (without the dot) this format matches.
    static var supportedExtensions: [String: BookFormat] {
        [
            "epub": .epub,
            "pdf": .pdf,
            "cbz": .cbz
        ]
    }

    init?(fileExtension: String) {
        guard let match = BookFormat.supportedExtensions[fileExtension.lowercased()] else {
            return nil
        }
        self = match
    }

    /// SF Symbol name for this format.
    var systemImage: String {
        switch self {
        case .epub: return "book"
        case .pdf:  return "doc.richtext"
        case .cbz:  return "photo.on.rectangle"
        }
    }

    /// Human-readable section title for grouping in the UI.
    var sectionTitle: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf:  return "PDF"
        case .cbz:  return "CBZ"
        }
    }
}
