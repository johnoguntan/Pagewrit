import AppKit

/// Reads Word, RTF, OpenDocument, plain-text and Markdown files into
/// something the reader can style. Safe to call off the main thread.
enum TextDocumentLoader {

    struct Loaded {
        /// Rich documents (docx/doc/rtf/odt), exactly as imported.
        var rich: NSAttributedString?
        /// Plain text or Markdown source.
        var rawText: String?
        var isMarkdown = false
        var title: String?
        var author: String?

        /// All text, for search indexing and read-aloud.
        var plain: String { rich?.string ?? rawText ?? "" }
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    /// Beyond this a single text document is not a book, and loading it whole
    /// would exhaust memory.
    private static let maxFileBytes = 250_000_000

    static func load(url: URL, format: BookFormat) -> Loaded? {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes {
            return nil
        }
        switch format {
        case .docx:
            let type: NSAttributedString.DocumentType
            switch url.pathExtension.lowercased() {
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            default: type = .rtf
            }
            var attrs: NSDictionary?
            guard let rich = try? NSAttributedString(
                url: url, options: [.documentType: type], documentAttributes: &attrs) else { return nil }
            let title = attrs?[NSAttributedString.DocumentAttributeKey.title.rawValue] as? String
            let author = attrs?[NSAttributedString.DocumentAttributeKey.author.rawValue] as? String
            return Loaded(rich: rich, title: clean(title), author: clean(author))

        case .text:
            guard let text = readText(url) else { return nil }
            let md = isMarkdown(url)
            return Loaded(rawText: text, isMarkdown: md, title: md ? firstHeading(in: text) : nil)

        default:
            return nil
        }
    }

    private static func readText(_ url: URL) -> String? {
        var encoding = String.Encoding.utf8
        if let s = try? String(contentsOf: url, usedEncoding: &encoding) { return s }
        return (try? String(contentsOf: url, encoding: .isoLatin1))
    }

    private static func firstHeading(in text: String) -> String? {
        for line in text.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true).prefix(40) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("# ") { return clean(String(t.dropFirst(2))) }
        }
        return nil
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
