import Foundation

/// Looks up better title/author/cover metadata from the Open Library
/// Search API (openlibrary.org) — free, no API key, no account. This is
/// the fix for books whose only metadata is a scanned filename (a raw
/// slug like "teuxdeux_phase1_spec" or a CV with no real title at all):
/// the user searches by whatever title/author Athenaeum already has, picks
/// the right match from Open Library's catalog, and Athenaeum replaces the
/// title, author, and cover with that record's.
enum OpenLibraryService {
    struct SearchResult: Identifiable {
        let workKey: String
        let title: String
        let authorNames: [String]
        let firstPublishYear: Int?
        let coverID: Int?

        var id: String { workKey }

        var authorText: String { authorNames.joined(separator: ", ") }

        /// Small thumbnail for the picker list.
        var thumbnailURL: URL? {
            coverID.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg") }
        }

        /// Full-size art to actually save as the book's cover.
        var fullCoverURL: URL? {
            coverID.flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") }
        }
    }

    private struct SearchResponse: Decodable {
        struct Doc: Decodable {
            let key: String?
            let title: String?
            let author_name: [String]?
            let first_publish_year: Int?
            let cover_i: Int?
        }
        let docs: [Doc]
    }

    enum ServiceError: LocalizedError {
        case invalidQuery
        case noCoverAvailable
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidQuery: "Couldn't search for that."
            case .noCoverAvailable: "This result doesn't have cover art."
            case .badResponse: "The lookup didn't complete."
            }
        }
    }

    static func search(title: String, author: String?) async throws -> [SearchResult] {
        var query = title
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query += " \(author)"
        }
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "12"),
            URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i"),
        ]
        guard let url = components?.url else { throw ServiceError.invalidQuery }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.docs.compactMap { doc in
            guard let key = doc.key, let title = doc.title else { return nil }
            return SearchResult(
                workKey: key,
                title: title,
                authorNames: doc.author_name ?? [],
                firstPublishYear: doc.first_publish_year,
                coverID: doc.cover_i
            )
        }
    }

    /// Downloads the chosen result's full-size cover art. A work with no
    /// real cover still returns a tiny placeholder image from Open
    /// Library's cover server rather than a 404, so a byte-size floor
    /// (a real cover is never this small) is the only reliable way to
    /// tell "no cover" from "here's your cover".
    static func downloadCoverData(for result: SearchResult) async throws -> Data {
        guard let url = result.fullCoverURL else { throw ServiceError.noCoverAvailable }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              data.count > 800
        else {
            throw ServiceError.noCoverAvailable
        }
        return data
    }
}
