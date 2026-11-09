import XCTest
import ZIPFoundation
@testable import Pagewrit

final class KindleTests: XCTestCase {

    // MARK: Synthetic MOBI builder

    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// A minimal uncompressed MOBI6 file with one text record.
    private func makeMOBI(html: String, title: String = "Test Book", encryption: Int = 0, version: Int = 6) -> Data {
        let text = Array(html.utf8)
        var rec0 = [UInt8](repeating: 0, count: 16 + 232)
        func put(_ bytes: [UInt8], at offset: Int) { for (i, b) in bytes.enumerated() { rec0[offset + i] = b } }
        put(be16(1), at: 0)                       // no compression
        put(be32(text.count), at: 4)
        put(be16(1), at: 8)                       // one text record
        put(be16(4096), at: 0xA)
        put(be16(encryption), at: 0xC)
        put(Array("MOBI".utf8), at: 0x10)
        put(be32(232), at: 0x14)
        put(be32(65001), at: 0x1C)
        put(be32(version), at: 0x24)
        put(be32(0xFFFFFFFF), at: 0x6C)
        let titleBytes = Array(title.utf8)
        put(be32(16 + 232), at: 0x54)
        put(be32(titleBytes.count), at: 0x58)
        rec0 += titleBytes

        let records: [[UInt8]] = [rec0, text]
        var file = [UInt8](repeating: 0, count: 78)
        for (i, b) in Array("Test_Book".utf8).enumerated() { file[i] = b }
        for (i, b) in Array("BOOKMOBI".utf8).enumerated() { file[60 + i] = b }
        file[76] = 0; file[77] = UInt8(records.count)
        var offset = 78 + records.count * 8 + 2
        for (i, record) in records.enumerated() {
            file += be32(offset) + [0, 0, 0, UInt8(i)]
            offset += record.count
        }
        file += [0, 0]
        for record in records { file += record }
        return Data(file)
    }

    // MARK: PalmDOC

    func testPalmDocLiteralsAndSpaceCombo() {
        // "ab" via a 2-literal run, then 0xC1 = space + 'A'
        let out = PalmDOC.decompress([0x02, 0x61, 0x62, 0xC1])
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "ab A")
    }

    func testPalmDocBackReference() {
        // "abcabc": literals "abc" then copy 3 bytes from distance 3.
        // pair = 0x8000 | (3 << 3) | (3 - 3) = 0x8018
        let out = PalmDOC.decompress([0x03, 0x61, 0x62, 0x63, 0x80, 0x18])
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "abcabc")
    }

    func testTrailingMultibyteBytesAreTrimmed() {
        // flag bit0: last byte & 3 + 1 bytes removed.
        let trimmed = KindleFile.trimTrailing([0x41, 0x42, 0x43, 0x01], flags: 1)
        XCTAssertEqual(trimmed, [0x41, 0x42])
    }

    // MARK: Parsing

    func testReadsTitleAndText() throws {
        let data = makeMOBI(html: "<html><body><p>Hello</p></body></html>", title: "My Title")
        let file = try KindleFile(data: data)
        XCTAssertEqual(file.info.title, "My Title")
        let raw = try file.rawText()
        XCTAssertEqual(String(decoding: raw, as: UTF8.self), "<html><body><p>Hello</p></body></html>")
    }

    func testDRMIsReported() throws {
        let file = try KindleFile(data: makeMOBI(html: "<p>x</p>", encryption: 2))
        XCTAssertThrowsError(try file.rawText()) { XCTAssertEqual($0 as? KindleError, .drmProtected) }
    }

    func testKF8OnlyIsReported() throws {
        let file = try KindleFile(data: makeMOBI(html: "<p>x</p>", version: 8))
        XCTAssertThrowsError(try file.rawText()) { XCTAssertEqual($0 as? KindleError, .kf8Only) }
    }

    func testNonKindleDataIsRejected() {
        XCTAssertThrowsError(try KindleFile(data: Data(repeating: 0x41, count: 400)))
    }

    // MARK: Conversion

    func testChaptersSplitAndLinksCrossChapters() throws {
        let head = "<html><head></head><body><h1>One</h1><p><a filepos=0000000000>go</a></p><mbp:pagebreak/>"
        let tail = "<h1>Two</h1><p>Target</p></body></html>"
        let offset = Array((head).utf8).count + 0
        // Point the link at the start of chapter two's <h1>.
        let padded = head.replacingOccurrences(of: "filepos=0000000000",
                                               with: String(format: "filepos=%010d", offset))
        // Replacing digits keeps the same length, so `offset` is still right.
        XCTAssertEqual(Array(padded.utf8).count, offset)

        let data = makeMOBI(html: padded + tail)
        let file = try KindleFile(data: data)
        let book = try KindleConverter.buildHTMLBook(raw: try file.rawText(), file: file)

        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertEqual(book.chapters[0].title, "One")
        XCTAssertEqual(book.chapters[1].title, "Two")
        XCTAssertTrue(book.chapters[0].html.contains("href=\"Two.html#filepos\(offset)\""))
        XCTAssertTrue(book.chapters[1].html.contains("id=\"filepos\(offset)\""))
        XCTAssertFalse(book.chapters[0].html.contains("mbp:"))
    }

    func testConvertWritesReadableEPUB() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("book.mobi")
        try makeMOBI(html: "<html><body><h1>Only</h1><p>Some text here.</p></body></html>").write(to: source)
        let epub = dir.appendingPathComponent("out.epub")
        let info = try KindleConverter.convert(source: source, destination: epub)
        XCTAssertEqual(info.title, "Test Book")

        let archive = try Archive(url: epub, accessMode: .read)
        let paths = archive.map { $0.path }
        XCTAssertTrue(paths.contains("mimetype"))
        XCTAssertTrue(paths.contains("META-INF/container.xml"))
        XCTAssertTrue(paths.contains("OEBPS/content.opf"))
        XCTAssertTrue(paths.contains("OEBPS/Only.html"))
        XCTAssertNotNil(TextExtractor.extractText(url: epub, format: .kindle))
    }

    func testKindleExtensionsAreRecognised() {
        for ext in ["mobi", "azw", "azw3", "prc"] {
            XCTAssertEqual(BookFormat(fileExtension: ext), .kindle)
        }
    }
}
