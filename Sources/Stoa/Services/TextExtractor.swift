import Foundation
import PDFKit

#if canImport(EPUBKit)
import EPUBKit
#endif

/// Extracts plain text from a book's source file, used to build the
/// on-disk full-text search index. CBZ (image comics) has no meaningful
/// extractable text and is skipped.
///
/// Pure value-type input/output (URL/BookFormat in, String? out) so this
/// can run freely off the main actor — it never touches a `Book` instance
/// directly, which keeps LibraryStore's SwiftData context untouched from
/// background threads.
enum TextExtractor {
    static func extractText(url: URL, format: BookFormat) -> String? {
        switch format {
        case .pdf:
            return extractPDFText(url: url)
        case .epub:
            return extractEPUBText(url: url)
        case .cbz:
            return nil
        }
    }

    private static func extractPDFText(url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let pageText = page.string {
                text += pageText
                text += "\n"
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractEPUBText(url: URL) -> String? {
        #if canImport(EPUBKit)
        guard let epub = EPUBDocument(url: url) else { return nil }
        let contentDir = epub.contentDirectory
        var text = ""
        for spineItem in epub.spine.items {
            guard let manifestItem = epub.manifest.items[spineItem.idref] else { continue }
            let chapterURL = contentDir.appendingPathComponent(manifestItem.path)
            guard let html = try? String(contentsOf: chapterURL, encoding: .utf8) else { continue }
            text += stripHTML(html)
            text += "\n"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
        #else
        return nil
        #endif
    }

    /// Minimal, dependency-free HTML-to-text: strips tags and lets adjacent
    /// text runs collapse naturally. Good enough for a search index or for
    /// feeding to speech synthesis — not meant for display.
    static func stripHTML(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var inTag = false
        for char in html {
            if char == "<" {
                inTag = true
            } else if char == ">" {
                inTag = false
                result.append(" ")
            } else if !inTag {
                result.append(char)
            }
        }
        return result
    }
}
