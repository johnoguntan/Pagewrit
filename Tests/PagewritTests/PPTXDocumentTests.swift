import XCTest
import ZIPFoundation
@testable import Pagewrit

final class PPTXDocumentTests: XCTestCase {

    /// Builds a minimal two-slide .pptx whose slide *order* differs from the
    /// numeric order of the slide files, to prove order comes from the deck.
    private func makeDeck() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).pptx")
        let archive = try Archive(url: url, accessMode: .create)

        func add(_ path: String, _ xml: String) throws {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }

        try add("ppt/presentation.xml", """
        <p:presentation xmlns:p="p" xmlns:r="r"><p:sldIdLst>
        <p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId1"/>
        </p:sldIdLst></p:presentation>
        """)
        try add("ppt/_rels/presentation.xml.rels", """
        <Relationships>
        <Relationship Id="rId1" Target="slides/slide1.xml"/>
        <Relationship Id="rId2" Target="slides/slide2.xml"/>
        </Relationships>
        """)
        try add("ppt/slides/slide1.xml", """
        <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
        <p:txBody><a:p><a:r><a:t>Second Slide</a:t></a:r></a:p></p:txBody></p:sp>
        <p:sp><p:txBody><a:p><a:r><a:t>Body </a:t></a:r><a:r><a:t>text</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        try add("ppt/slides/slide2.xml", """
        <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="ctrTitle"/></p:nvPr></p:nvSpPr>
        <p:txBody><a:p><a:r><a:t>First Slide</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        try add("docProps/core.xml", """
        <cp:coreProperties xmlns:cp="cp" xmlns:dc="dc"><dc:title>My Deck</dc:title><dc:creator>Sam</dc:creator></cp:coreProperties>
        """)
        return url
    }

    func testParsesOrderTitlesAndText() throws {
        let url = try makeDeck()
        defer { try? FileManager.default.removeItem(at: url) }

        let deck = try XCTUnwrap(PPTXDocument.load(from: url))
        XCTAssertEqual(deck.title, "My Deck")
        XCTAssertEqual(deck.author, "Sam")
        XCTAssertEqual(deck.slides.count, 2)
        XCTAssertEqual(deck.slides[0].title, "First Slide")
        XCTAssertEqual(deck.slides[1].title, "Second Slide")
        XCTAssertEqual(deck.slides[1].text, "Second Slide\nBody text")
        XCTAssertTrue(deck.plainText.contains("Body text"))
    }

    func testRejectsNonDeckZip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).pptx")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(PPTXDocument.load(from: url))
    }

    func testFormatRecognisesPPTX() {
        XCTAssertEqual(BookFormat(fileExtension: "PPTX"), .pptx)
        XCTAssertTrue(BookFormat.pptx.rendersLiveThumbnail)
    }
}
