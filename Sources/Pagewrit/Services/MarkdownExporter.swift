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
}
