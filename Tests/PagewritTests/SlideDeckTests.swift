import XCTest
import AppKit
import ZIPFoundation
@testable import Pagewrit

final class SlideDeckTests: XCTestCase {

    /// A two-slide deck: slide 1 is a full-slide red rectangle plus a title and
    /// speaker notes; slide 2 is hidden and has a text box.
    private func makeDeck() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString).pptx")
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ xml: String) throws {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        try add("ppt/presentation.xml", """
        <p:presentation xmlns:p="p" xmlns:r="r"><p:sldSz cx="9144000" cy="5143500"/>
        <p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst></p:presentation>
        """)
        try add("ppt/_rels/presentation.xml.rels", """
        <Relationships>
        <Relationship Id="rId1" Type="x/slide" Target="slides/slide1.xml"/>
        <Relationship Id="rId2" Type="x/slide" Target="slides/slide2.xml"/>
        </Relationships>
        """)
        try add("ppt/slides/_rels/slide1.xml.rels", """
        <Relationships><Relationship Id="rId9" Type="x/notesSlide" Target="../notesSlides/notesSlide1.xml"/></Relationships>
        """)
        try add("ppt/slides/slide1.xml", """
        <p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="bg"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="5143500"/></a:xfrm>
          <a:prstGeom prst="rect"/><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></p:spPr></p:sp>
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="t"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="500000" y="500000"/><a:ext cx="8000000" cy="1000000"/></a:xfrm></p:spPr>
          <p:txBody><a:bodyPr/><a:p><a:r><a:rPr sz="4000"/><a:t>Hello deck</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        try add("ppt/notesSlides/notesSlide1.xml", """
        <p:notes xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr>
        <p:txBody><a:p><a:r><a:t>Remember to pause.</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:notes>
        """)
        try add("ppt/slides/slide2.xml", """
        <p:sld xmlns:p="p" xmlns:a="a" show="0"><p:cSld><p:spTree>
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="tb"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>
          <p:spPr><a:xfrm><a:off x="100000" y="100000"/><a:ext cx="3000000" cy="500000"/></a:xfrm></p:spPr>
          <p:txBody><a:bodyPr/><a:p><a:r><a:t>Second slide text</a:t></a:r></a:p></p:txBody></p:sp>
        </p:spTree></p:cSld></p:sld>
        """)
        return url
    }

    func testParsesSlidesTitlesNotesAndHidden() throws {
        let url = try makeDeck()
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = try XCTUnwrap(SlideDeckLoader.load(url: url))
        XCTAssertEqual(deck.slides.count, 2)
        XCTAssertEqual(deck.slides[0].title, "Hello deck")
        XCTAssertEqual(deck.slides[0].notes, "Remember to pause.")
        XCTAssertTrue(deck.slides[1].hidden)
        XCTAssertEqual(deck.presentableIndices, [0])
        XCTAssertTrue(deck.slides[1].text.contains("Second slide text"))
        XCTAssertEqual(deck.aspect, 16.0 / 9.0, accuracy: 0.01)
    }

    func testRenderPaintsShapeAtTheRightPlace() throws {
        let url = try makeDeck()
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = try XCTUnwrap(SlideDeckLoader.load(url: url))
        let image = SlideRenderer.image(deck: deck, index: 0, pixelWidth: 640)
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 640)
        let c = try XCTUnwrap(rep.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(c.redComponent, 0.9)
        XCTAssertLessThan(c.greenComponent, 0.1)
    }

    func testPDFExportSkipsHiddenSlides() throws {
        let url = try makeDeck()
        defer { try? FileManager.default.removeItem(at: url) }
        let deck = try XCTUnwrap(SlideDeckLoader.load(url: url))
        let data = try XCTUnwrap(SlideRenderer.pdfData(deck: deck))
        XCTAssertTrue(String(decoding: data.prefix(5), as: UTF8.self).hasPrefix("%PDF"))
        let pdf = try XCTUnwrap(PDFDocumentHelper.pageCount(of: data))
        XCTAssertEqual(pdf, 1)
    }
}

import PDFKit
private enum PDFDocumentHelper {
    static func pageCount(of data: Data) -> Int? { PDFDocument(data: data)?.pageCount }
}
