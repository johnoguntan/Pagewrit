import Foundation

// MARK: - Errors

/// Why a Kindle file couldn't be opened. The messages are shown to the reader
/// as-is, so they say what happened and what to do about it.
enum KindleError: LocalizedError, Equatable {
    case notKindle
    case drmProtected
    case newKindleFormat       // KFX container
    case kf8Only               // pure AZW3 / KF8, not converted yet
    case unsupportedCompression(Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notKindle:
            return "This file doesn't look like a Kindle book."
        case .drmProtected:
            return "This book is copy-protected (DRM) by the store it came from, so Pagewrit can't open it. Books without DRM (from Project Gutenberg, authors, or ones you've converted yourself) open fine."
        case .newKindleFormat:
            return "This is Amazon's newest Kindle format (KFX), which Pagewrit can't read yet. If you have an EPUB or an older MOBI/AZW3 copy of the book, that will work."
        case .kf8Only:
            return "This is a newer AZW3 (KF8) file. Pagewrit reads older MOBI books and AZW3 files that include the MOBI layer; this one doesn't, and full AZW3 support is still being built. Converting it to EPUB (for example with Calibre) will open it today."
        case .unsupportedCompression:
            return "This Kindle file uses a compression method Pagewrit doesn't support yet. Converting it to EPUB (for example with Calibre) will open it today."
        case .malformed(let detail):
            return "This Kindle file seems to be damaged (\(detail))."
        }
    }
}

// MARK: - Metadata

struct KindleInfo {
    var title: String?
    var author: String?
    var publisher: String?
    var language: String?
    var summary: String?
    var coverData: Data?
}

// MARK: - Byte helpers

extension Data {
    /// Big-endian reads that return 0 past the end rather than trapping,
    /// since Kindle files in the wild are not always well formed.
    func kBE16(_ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return Int(self[base]) << 8 | Int(self[base + 1])
    }

    func kBE32(_ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return Int(self[base]) << 24 | Int(self[base + 1]) << 16 | Int(self[base + 2]) << 8 | Int(self[base + 3])
    }

    func kASCII(_ offset: Int, _ length: Int) -> String {
        guard offset >= 0, length >= 0, offset + length <= count else { return "" }
        let slice = self[(startIndex + offset)..<(startIndex + offset + length)]
        return String(decoding: slice, as: UTF8.self)
    }
}

// MARK: - PalmDOC

enum PalmDOC {
    /// PalmDOC (LZ77-style) decompression, as used by almost every MOBI.
    static func decompress(_ src: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(src.count * 3)
        var i = 0
        let n = src.count
        while i < n {
            let c = Int(src[i])
            i += 1
            if c == 0 {
                out.append(0)
            } else if c <= 8 {
                let end = min(i + c, n)
                out.append(contentsOf: src[i..<end])
                i = end
            } else if c < 0x80 {
                out.append(UInt8(c))
            } else if c >= 0xC0 {
                out.append(0x20)
                out.append(UInt8(c ^ 0x80))
            } else {
                guard i < n else { break }
                let pair = (c << 8) | Int(src[i])
                i += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                var from = out.count - distance
                for _ in 0..<length {
                    out.append(out[from])
                    from += 1
                }
            }
        }
        return out
    }
}

// MARK: - Container

/// A Palm database holding a MOBI / PalmDOC book: the record table, the
/// MOBI + EXTH headers, and the decompressed text. Pure Foundation, no UI.
struct KindleFile {
    let data: Data
    private let offsets: [Int]

    let identifier: String
    let compression: Int
    let textLength: Int
    let textRecordCount: Int
    let encryption: Int
    let hasMobiHeader: Bool
    let version: Int
    let codepage: Int
    let firstImageRecord: Int?
    let trailingFlags: Int
    let isKF8Only: Bool

    private(set) var info = KindleInfo()
    private(set) var exth: [Int: [Data]] = [:]

    var recordCount: Int { offsets.count }

    init(data: Data) throws {
        self.data = data
        guard data.count > 78 + 8 else { throw KindleError.notKindle }

        let ident = data.kASCII(60, 8)
        if ident != "BOOKMOBI" && ident != "TEXtREAd" {
            let head = data.kASCII(0, 4)
            if head == "CONT" || head == "SEAL" { throw KindleError.newKindleFormat }
            throw KindleError.notKindle
        }
        identifier = ident

        let recCount = data.kBE16(76)
        guard recCount > 1, 78 + recCount * 8 <= data.count else { throw KindleError.malformed("record table") }
        var table = [Int]()
        table.reserveCapacity(recCount + 1)
        for r in 0..<recCount {
            let off = data.kBE32(78 + r * 8)
            guard off <= data.count else { throw KindleError.malformed("record \(r)") }
            table.append(off)
        }
        offsets = table

        let rec0 = KindleFile.slice(data, table, 0)
        guard rec0.count >= 16 else { throw KindleError.malformed("header") }

        compression = rec0.kBE16(0)
        textLength = rec0.kBE32(4)
        textRecordCount = rec0.kBE16(8)
        encryption = rec0.kBE16(0xC)

        hasMobiHeader = rec0.count >= 0x18 && rec0.kASCII(0x10, 4) == "MOBI"
        if hasMobiHeader {
            let headerLength = rec0.kBE32(0x14)
            codepage = rec0.kBE32(0x1C)
            version = rec0.kBE32(0x24)
            let image = rec0.kBE32(0x6C)
            firstImageRecord = (image == 0xFFFFFFFF || image <= 0 || image >= recCount) ? nil : image
            trailingFlags = (headerLength >= 0xE4 && version >= 5) ? rec0.kBE16(0xF2) : 0
            isKF8Only = version >= 8
        } else {
            codepage = 1252
            version = 0
            firstImageRecord = nil
            trailingFlags = 0
            isKF8Only = false
        }

        info = readInfo(rec0: rec0)
    }

    // MARK: Records

    private static func slice(_ data: Data, _ table: [Int], _ index: Int) -> Data {
        guard index >= 0, index < table.count else { return Data() }
        let start = table[index]
        let end = index + 1 < table.count ? table[index + 1] : data.count
        guard start <= end, end <= data.count else { return Data() }
        return Data(data[(data.startIndex + start)..<(data.startIndex + end)])
    }

    func record(_ index: Int) -> Data { KindleFile.slice(data, offsets, index) }

    // MARK: Metadata

    private func decode(_ bytes: Data) -> String {
        if codepage == 65001 { return String(decoding: bytes, as: UTF8.self) }
        return String(data: bytes, encoding: .windowsCP1252)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private mutating func readInfo(rec0: Data) -> KindleInfo {
        var meta = KindleInfo()

        if hasMobiHeader {
            let headerLength = rec0.kBE32(0x14)
            let exthFlags = rec0.kBE32(0x80)
            let exthStart = 16 + headerLength
            if exthFlags & 0x40 != 0, exthStart + 12 <= rec0.count, rec0.kASCII(exthStart, 4) == "EXTH" {
                let count = rec0.kBE32(exthStart + 8)
                var pos = exthStart + 12
                var parsed: [Int: [Data]] = [:]
                for _ in 0..<min(count, 500) {
                    guard pos + 8 <= rec0.count else { break }
                    let id = rec0.kBE32(pos)
                    let size = rec0.kBE32(pos + 4)
                    guard size >= 8, pos + size <= rec0.count else { break }
                    parsed[id, default: []].append(Data(rec0[(pos + 8)..<(pos + size)]))
                    pos += size
                }
                exth = parsed
            }

            func text(_ id: Int) -> String? {
                guard let first = exth[id]?.first else { return nil }
                let s = decode(first).trimmingCharacters(in: .whitespacesAndNewlines)
                return s.isEmpty ? nil : s
            }
            func number(_ id: Int) -> Int? {
                guard let first = exth[id]?.first, first.count == 4 else { return nil }
                return first.kBE32(0)
            }

            meta.author = exth[100]?.map { decode($0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            if meta.author?.isEmpty == true { meta.author = nil }
            meta.publisher = text(101)
            meta.summary = text(103)
            meta.language = text(524)

            let titleOffset = rec0.kBE32(0x54)
            let titleLength = rec0.kBE32(0x58)
            var fullTitle: String?
            if titleLength > 0, titleOffset >= 0, titleOffset + titleLength <= rec0.count {
                fullTitle = decode(Data(rec0[titleOffset..<(titleOffset + titleLength)]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            meta.title = text(503) ?? ((fullTitle?.isEmpty == false) ? fullTitle : nil)

            if let first = firstImageRecord, let coverIndex = number(201), coverIndex != 0xFFFFFFFF {
                let candidate = record(first + coverIndex)
                if KindleFile.imageExtension(candidate) != nil { meta.coverData = candidate }
            }
        }

        if meta.title == nil {
            let name = data.kASCII(0, 32).trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
                .replacingOccurrences(of: "_", with: " ")
            meta.title = name.isEmpty ? nil : name
        }
        return meta
    }

    // MARK: Text

    var isDRMProtected: Bool { encryption != 0 }

    /// Throws for the cases we know we can't decode, before any work is done.
    func checkReadable() throws {
        if isDRMProtected { throw KindleError.drmProtected }
        if isKF8Only { throw KindleError.kf8Only }
        if compression != 1 && compression != 2 { throw KindleError.unsupportedCompression(compression) }
    }

    /// The book's text as raw bytes in its own encoding (HTML for MOBI,
    /// plain text for bare PalmDOC). Byte offsets match what `filepos` links use.
    func rawText() throws -> [UInt8] {
        try checkReadable()
        var out = [UInt8]()
        out.reserveCapacity(min(max(textLength, 0), 64_000_000))
        let last = min(textRecordCount, recordCount - 1)
        guard last >= 1 else { throw KindleError.malformed("no text") }
        for index in 1...last {
            var bytes = [UInt8](record(index))
            bytes = KindleFile.trimTrailing(bytes, flags: trailingFlags)
            switch compression {
            case 2: out.append(contentsOf: PalmDOC.decompress(bytes))
            default: out.append(contentsOf: bytes)
            }
        }
        if textLength > 0, out.count > textLength { out.removeLast(out.count - textLength) }
        guard !out.isEmpty else { throw KindleError.malformed("empty text") }
        return out
    }

    /// Removes the extra data Kindle appends to each text record (indexing
    /// bytes, multibyte overlap) so it doesn't end up in the book text.
    static func trimTrailing(_ record: [UInt8], flags: Int) -> [UInt8] {
        guard flags != 0 else { return record }
        var end = record.count
        var rest = flags >> 1
        while rest != 0 {
            if rest & 1 != 0 {
                end -= trailingEntrySize(record, end: end)
                if end <= 0 { return [] }
            }
            rest >>= 1
        }
        if flags & 1 != 0, end > 0 {
            end -= Int(record[end - 1] & 3) + 1
            if end <= 0 { return [] }
        }
        return Array(record[0..<end])
    }

    /// Backward variable-length integer at the end of a record.
    private static func trailingEntrySize(_ record: [UInt8], end: Int) -> Int {
        var result = 0
        var shift = 0
        var p = end
        while p > 0 {
            let v = Int(record[p - 1])
            result |= (v & 0x7F) << shift
            shift += 7
            p -= 1
            if v & 0x80 != 0 || shift >= 28 { break }
        }
        return result
    }

    // MARK: Images

    static func imageExtension(_ d: Data) -> String? {
        guard d.count > 8 else { return nil }
        let b0 = d[d.startIndex], b1 = d[d.startIndex + 1], b2 = d[d.startIndex + 2], b3 = d[d.startIndex + 3]
        if b0 == 0xFF, b1 == 0xD8, b2 == 0xFF { return "jpg" }
        if b0 == 0x89, b1 == 0x50, b2 == 0x4E, b3 == 0x47 { return "png" }
        if b0 == 0x47, b1 == 0x49, b2 == 0x46, b3 == 0x38 { return "gif" }
        return nil
    }

    /// Image resources keyed by 1-based resource number, as `recindex` uses.
    func images() -> [Int: (ext: String, data: Data)] {
        guard let first = firstImageRecord else { return [:] }
        var result: [Int: (ext: String, data: Data)] = [:]
        for index in first..<recordCount {
            let d = record(index)
            if let ext = KindleFile.imageExtension(d) {
                result[index - first + 1] = (ext, d)
            }
        }
        return result
    }

    var textEncoding: String.Encoding { codepage == 65001 ? .utf8 : .windowsCP1252 }
}
