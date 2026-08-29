import Foundation

/// Searches and downloads public-domain books from Project Gutenberg, via
/// the free Gutendex API (gutendex.com) — no API key, no account. Every
/// title Gutenberg distributes has already cleared US copyright, so this
/// is the one book source Stoa reaches out to on its own; there's no
/// general-purpose "download books from the internet" beyond it.
enum GutenbergService {
    struct SearchResult: Identifiable, Decodable {
        let id: Int
        let title: String
        let authors: [Author]
        let formats: [String: String]
        let downloadCount: Int?

        struct Author: Decodable {
            let name: String
        }

        enum CodingKeys: String, CodingKey {
            case id, title, authors, formats
            case downloadCount = "download_count"
        }

        var authorNames: String {
            authors.map(\.name).joined(separator: ", ")
        }

        /// Gutendex often lists more than one EPUB variant for the same
        /// book (a "with images" and a smaller "noimages" text-only one).
        /// Prefer the smaller one — faster download, and Stoa's readers
        /// don't need illustration plates to render the text.
        var epubURL: URL? {
            let epubEntries = formats.filter { $0.key.hasPrefix("application/epub+zip") }
            if let noImages = epubEntries.first(where: { $0.key.contains("noimages") }) {
                return URL(string: noImages.value)
            }
            return epubEntries.first.flatMap { URL(string: $0.value) }
        }
    }

    private struct SearchResponse: Decodable {
        let results: [SearchResult]
    }

    enum ServiceError: LocalizedError {
        case invalidQuery
        case noEPUBAvailable
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidQuery: "Couldn't search for that."
            case .noEPUBAvailable: "This book doesn't have an EPUB available."
            case .badResponse: "The download didn't complete."
            }
        }
    }

    static func search(query: String) async throws -> [SearchResult] {
        var components = URLComponents(string: "https://gutendex.com/books")
        components?.queryItems = [URLQueryItem(name: "search", value: query)]
        guard let url = components?.url else { throw ServiceError.invalidQuery }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }

    /// Downloads the EPUB straight into ~/Documents/StoaLibrary/Downloads.
    /// That's inside Documents, one of the folders ScannerService already
    /// walks automatically — no separate "watched folder" bookkeeping
    /// needed, the next rescan just finds it.
    @discardableResult
    static func download(_ result: SearchResult) async throws -> URL {
        guard let sourceURL = result.epubURL else {
            throw ServiceError.noEPUBAvailable
        }

        let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw ServiceError.badResponse
        }

        let folder = try downloadsDirectory()
        let safeTitle = result.title
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = safeTitle.isEmpty ? "Gutenberg \(result.id)" : safeTitle

        var destination = folder.appendingPathComponent("\(fileName).epub")
        if FileManager.default.fileExists(atPath: destination.path) {
            // Already downloaded before (or a name collision) — disambiguate
            // with the Gutenberg id rather than overwriting.
            destination = folder.appendingPathComponent("\(fileName) (\(result.id)).epub")
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private static func downloadsDirectory() throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("StoaLibrary/Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
