import Foundation

/// Searches and downloads public-domain books from Project Gutenberg, via
/// the free Gutendex API (gutendex.com) — no API key, no account. Every
/// title Gutenberg distributes has already cleared US copyright, so this
/// is the one book source Pagewrit reaches out to on its own; there's no
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

        /// Gutendex exposes exactly one EPUB entry per book, keyed by
        /// MIME type — a dictionary can't hold two "application/epub+zip"
        /// keys, so there's never a choice of variant to make here.
        var epubURL: URL? {
            formats.first { $0.key.hasPrefix("application/epub+zip") }
                .flatMap { URL(string: $0.value) }
                .flatMap { $0.scheme?.lowercased() == "https" ? $0 : URL(string: $0.absoluteString.replacingOccurrences(of: "http://", with: "https://")) }
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
        guard let sourceURL = result.epubURL, DownloadSafety.isTrustedGutenbergHost(sourceURL) else {
            throw ServiceError.noEPUBAvailable
        }

        let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              DownloadSafety.isValid(file: tempURL, response: response, kind: .epub)
        else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ServiceError.badResponse
        }

        let folder = try downloadsDirectory()
        let safeTitle = Self.safeFileName(result.title)
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

    /// A title from the internet turned into a safe file name: no path
    /// separators, control characters or leading dots, and a sane length.
    static func safeFileName(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var cleaned = raw.components(separatedBy: banned).joined(separator: "-")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func downloadsDirectory() throws -> URL {
        let folder = LibraryLocation.folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}


// MARK: - Download safety

/// Checks on anything fetched from the internet before it is allowed into the
/// library. A server (or a captive portal, or an error page) can answer a
/// download with something that is not the book at all, or with a file of
/// absurd size, and the app should refuse it rather than save it.
enum DownloadSafety {
    /// The largest single download accepted (a generous scanned book).
    static let maxBytes: Int64 = 600_000_000

    enum Kind { case epub, pdf }

    /// Only these file types can arrive from Get Books.
    static func kind(forExtension ext: String) -> Kind? {
        switch ext.lowercased() {
        case "epub": .epub
        case "pdf": .pdf
        default: nil
        }
    }

    /// True when the downloaded file is a plausible size and really begins like
    /// the kind of file it claims to be (a ZIP for an EPUB, "%PDF" for a PDF).
    static func isValid(file: URL, response: URLResponse, kind: Kind) -> Bool {
        if response.expectedContentLength > maxBytes { return false }
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 1_000, Int64(size) <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 5)) ?? Data()
        switch kind {
        case .epub: return head.starts(with: [0x50, 0x4B, 0x03, 0x04])          // "PK\u{3}\u{4}"
        case .pdf: return head.starts(with: Array("%PDF".utf8))
        }
    }

    /// Project Gutenberg's own hosts only; a catalogue entry pointing
    /// anywhere else is ignored.
    static func isTrustedGutenbergHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "gutenberg.org" || host.hasSuffix(".gutenberg.org")
    }
}
