import Foundation

/// Searches and downloads freely-downloadable, non-lending public-domain
/// texts from the Internet Archive, via its public advancedsearch and
/// metadata APIs — no API key, no account.
///
/// Internet Archive's "texts" collection mixes two very different things:
/// plain public-domain scans anyone can download outright, and lending-
/// library scans (Controlled Digital Lending) that require borrowing
/// through archive.org's own reader and are never actually downloadable
/// — even though their metadata often *lists* an EPUB or PDF filename.
/// The only reliable signal is the `access-restricted-item` field (plus
/// the `inlibrary`/`lendinglibrary` collection tags) on each item's own
/// metadata record, which the search index doesn't carry. So this service
/// never trusts a search result on its own: `resolveDownload` re-fetches
/// the item's real metadata and only ever returns a file when that check
/// comes back open. There is no lending circumvention anywhere in this
/// file, by design — same scoping principle as GutenbergService.
enum InternetArchiveService {
    struct SearchResult: Identifiable {
        let identifier: String
        let title: String
        let creator: String?

        var id: String { identifier }

        var authorNames: String { creator ?? "" }
    }

    /// One openly-downloadable file resolved from an item's real metadata.
    struct DownloadCandidate {
        let url: URL
        let fileExtension: String
    }

    enum ServiceError: LocalizedError {
        case invalidQuery
        case noOpenFileAvailable
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidQuery: "Couldn't search for that."
            case .noOpenFileAvailable: "This item isn't freely downloadable \u{2014} it's part of Internet Archive's lending library."
            case .badResponse: "The download didn't complete."
            }
        }
    }

    // MARK: - Search

    private struct SearchResponse: Decodable {
        struct Body: Decodable {
            let docs: [Doc]
        }
        struct Doc: Decodable {
            let identifier: String
            let title: String?
            let creator: FlexibleStringList?
        }
        let response: Body
    }

    static func search(query: String) async throws -> [SearchResult] {
        let sanitized = query.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")
        components?.queryItems = [
            URLQueryItem(name: "q", value: "title:(\(sanitized)) AND mediatype:(texts)"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "rows", value: "25"),
            URLQueryItem(name: "output", value: "json"),
        ]
        guard let url = components?.url else { throw ServiceError.invalidQuery }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.response.docs.map {
            SearchResult(
                identifier: $0.identifier,
                title: $0.title ?? $0.identifier,
                creator: $0.creator?.joined
            )
        }
    }

    // MARK: - Metadata / Access Check

    private struct MetadataResponse: Decodable {
        struct Metadata: Decodable {
            let accessRestrictedItem: FlexibleBool?
            let collection: FlexibleStringList?

            enum CodingKeys: String, CodingKey {
                case accessRestrictedItem = "access-restricted-item"
                case collection
            }
        }
        struct File: Decodable {
            let name: String
            let format: String?
        }
        let metadata: Metadata
        let files: [File]
    }

    /// Re-fetches the item's own metadata record (never trusting the
    /// search index) and resolves it to a real downloadable file, or
    /// throws `.noOpenFileAvailable` if the item turns out to be
    /// lending-restricted.
    static func resolveDownload(for result: SearchResult) async throws -> DownloadCandidate {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encodedID = result.identifier.addingPercentEncoding(withAllowedCharacters: allowed),
              let metadataURL = URL(string: "https://archive.org/metadata/\(encodedID)") else {
            throw ServiceError.invalidQuery
        }
        let (data, metaResponse) = try await URLSession.shared.data(from: metadataURL)
        if let http = metaResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServiceError.badResponse
        }
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)

        let collectionTags = decoded.metadata.collection?.joined.lowercased() ?? ""
        let restricted = (decoded.metadata.accessRestrictedItem?.isTrue ?? false)
            || collectionTags.contains("lendinglibrary")
            || collectionTags.contains("inlibrary")
        guard !restricted else { throw ServiceError.noOpenFileAvailable }

        // Prefer EPUB; fall back to a plain (non-encrypted) PDF, which
        // Pagewrit's PDF reader already handles.
        let epub = decoded.files.first { $0.format == "EPUB" }
        let pdf = decoded.files.first { file in
            guard let format = file.format else { return false }
            return format.localizedCaseInsensitiveContains("pdf")
                && !format.localizedCaseInsensitiveContains("encrypted")
        }
        guard let file = epub ?? pdf,
              let encodedName = file.name
                  .split(separator: "/", omittingEmptySubsequences: true)
                  .map({ String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? "" })
                  .joined(separator: "/") as String?,
              !encodedName.isEmpty,
              let downloadURL = URL(string: "https://archive.org/download/\(encodedID)/\(encodedName)")
        else {
            throw ServiceError.noOpenFileAvailable
        }

        let ext = (file.name as NSString).pathExtension
        return DownloadCandidate(url: downloadURL, fileExtension: ext.isEmpty ? "pdf" : ext)
    }

    // MARK: - Download

    /// Downloads straight into ~/Documents/StoaLibrary/Downloads, same as
    /// GutenbergService — inside Documents, one of the folders
    /// ScannerService already walks automatically.
    @discardableResult
    static func download(_ result: SearchResult) async throws -> URL {
        let candidate = try await resolveDownload(for: result)

        let (tempURL, response) = try await URLSession.shared.download(from: candidate.url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw ServiceError.badResponse
        }

        let folder = try downloadsDirectory()
        let safeTitle = GutenbergService.safeFileName(result.title)
        let fileName = safeTitle.isEmpty ? result.identifier : safeTitle

        var destination = folder.appendingPathComponent("\(fileName).\(candidate.fileExtension)")
        if FileManager.default.fileExists(atPath: destination.path) {
            // Already downloaded before (or a name collision) — disambiguate
            // with the IA identifier rather than overwriting.
            destination = folder.appendingPathComponent(
                "\(fileName) (\(result.identifier)).\(candidate.fileExtension)"
            )
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private static func downloadsDirectory() throws -> URL {
        let folder = LibraryLocation.folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

// MARK: - Flexible JSON Decoding
//
// Internet Archive's metadata API is a thin JSON view over a much older,
// looser schema: a field that's a plain string on one item can be an
// array of strings on another (multi-author books), and a boolean-ish
// flag like `access-restricted-item` shows up as a JSON string, a JSON
// bool, or missing entirely depending on when the item was cataloged.
// These two types absorb that inconsistency once, here, instead of every
// call site guessing.

private enum FlexibleStringList: Decodable {
    case single(String)
    case multiple([String])

    var joined: String {
        switch self {
        case .single(let value): value
        case .multiple(let values): values.joined(separator: ", ")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .single(value)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }
}

private enum FlexibleBool: Decodable {
    case value(Bool)

    var isTrue: Bool {
        if case .value(let flag) = self { return flag }
        return false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .value(flag)
        } else if let text = try? container.decode(String.self) {
            self = .value(text == "true" || text == "1")
        } else if let number = try? container.decode(Int.self) {
            self = .value(number != 0)
        } else {
            self = .value(false)
        }
    }
}
