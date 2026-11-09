import Foundation

/// Turns whatever list of books the sidebar/search is currently showing
/// into a plain Markdown reading list — for a personal log, or to share
/// what's on a shelf with someone else.
enum MarkdownExporter {
    static func export(books: [Book], listTitle: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none

        var lines: [String] = []
        lines.append("# \(listTitle)")
        lines.append("_Exported \(dateFormatter.string(from: Date())) \u{00b7} \(books.count) book\(books.count == 1 ? "" : "s")_")
        lines.append("")

        for book in books {
            var line = "- **\(book.title)**"
            if let author = book.author, !author.isEmpty {
                line += " by \(author)"
            }
            line += " \u{2014} \(book.format.rawValue.uppercased())"
            if let progress = book.readingProgress, progress > 0 {
                line += book.isFinished ? " \u{2014} finished" : " \u{2014} \(Int(progress * 100))% read"
            }
            if !book.tags.isEmpty {
                line += " \u{2014} " + book.tags.map { "#\($0)" }.joined(separator: " ")
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// One book's highlights and notes as Markdown: each passage as a quote,
    /// the reader's note beneath it, and where in the book it came from.
    static func exportNotes(for book: Book, highlights: [Highlight]) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none

        var lines: [String] = ["# \(book.title)"]
        var meta: [String] = []
        if let author = book.author, !author.isEmpty { meta.append("by \(author)") }
        meta.append("\(highlights.count) highlight\(highlights.count == 1 ? "" : "s")")
        meta.append("exported \(dateFormatter.string(from: Date()))")
        lines.append("_" + meta.joined(separator: " \u{00b7} ") + "_")
        lines.append("")

        for highlight in highlights {
            lines.append("> " + highlight.text.replacingOccurrences(of: "\n", with: " "))
            if !highlight.note.isEmpty {
                lines.append("")
                lines.append(highlight.note)
            }
            if let place = location(of: highlight, in: book) {
                lines.append("")
                lines.append("\u{2014} _\(place)_")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func location(of highlight: Highlight, in book: Book) -> String? {
        switch book.format {
        case .pdf: return "Page \(highlight.pageIndex + 1)"
        case .epub, .kindle: return "Chapter \(highlight.pageIndex + 1)"
        default: return nil
        }
    }
}
