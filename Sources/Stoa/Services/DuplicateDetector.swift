import Foundation

/// Groups books that are almost certainly the same work saved twice —
/// most often across formats (an EPUB and a PDF of the same title) or as
/// a re-download that landed under a slightly different filename but the
/// same title/author, so `contentHash` (which only catches byte-identical
/// files) never flags it.
///
/// Matching is deliberately exact-on-normalized-strings rather than fuzzy:
/// lowercased, punctuation and whitespace collapsed. That stays inside
/// what this feature is meant to do (catch obvious re-imports) without
/// drifting into Levenshtein-distance territory, where false positives
/// ("The Stranger" vs "A Stranger") get expensive to rule out.
enum DuplicateDetector {
    /// Returns groups of two or more books that share a normalized
    /// title+author, excluding any pair the user has already dismissed.
    static func findGroups(in books: [Book], dismissedPairKeys: Set<String>) -> [[Book]] {
        let grouped = Dictionary(grouping: books, by: normalizedKey)
        let candidateGroups = grouped.values.filter { $0.count > 1 }

        return candidateGroups.compactMap { group -> [Book]? in
            let survivors = group.filter { book in
                !group.contains { other in
                    other.contentHash != book.contentHash
                        && dismissedPairKeys.contains(
                            DismissedDuplicatePair.makeKey(book.contentHash, other.contentHash)
                        )
                }
            }
            return survivors.count > 1 ? survivors.sorted { $0.title < $1.title } : nil
        }
    }

    private static func normalizedKey(for book: Book) -> String {
        let title = normalize(book.title)
        let author = book.author.map(normalize) ?? ""
        return "\(title)|\(author)"
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
