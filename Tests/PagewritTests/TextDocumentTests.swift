import XCTest
import AppKit
@testable import Pagewrit

final class TextDocumentTests: XCTestCase {

    private let style = ReaderTextStyle()

    func testHeadingIsLargerAndBoldThanBody() {
        let out = MarkdownRenderer.render("# Title\n\nBody text", style: style)
        let titleFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let bodyIndex = (out.string as NSString).range(of: "Body").location
        let bodyFont = out.attribute(.font, at: bodyIndex, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(titleFont)
        XCTAssertGreaterThan(titleFont!.pointSize, bodyFont!.pointSize)
        XCTAssertTrue(titleFont!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testListsAndLinks() {
        let out = MarkdownRenderer.render("- one\n- two\n\n[site](https://example.com)", style: style)
        XCTAssertTrue(out.string.contains("\u{2022}"))
        let linkIndex = (out.string as NSString).range(of: "site").location
        XCTAssertNotNil(out.attribute(.link, at: linkIndex, effectiveRange: nil))
    }

    func testConsecutiveLinesJoinIntoOneParagraph() {
        let out = MarkdownRenderer.render("first line\nsecond line", style: style)
        XCTAssertEqual(out.string.trimmingCharacters(in: .whitespacesAndNewlines), "first line second line")
    }

    func testMarkdownTitleComesFromFirstHeading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).md")
        try "Some intro\n\n# My Essay\n\nText".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = TextDocumentLoader.load(url: url, format: .text)
        XCTAssertEqual(loaded?.title, "My Essay")
        XCTAssertTrue(loaded?.isMarkdown ?? false)
    }

    func testRichRestyleKeepsHeadingLargerThanBody() {
        let source = NSMutableAttributedString()
        source.append(NSAttributedString(string: "Heading\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)]))
        source.append(NSAttributedString(string: String(repeating: "Body text. ", count: 20), attributes: [.font: NSFont.systemFont(ofSize: 11)]))
        let out = RichDocumentStyler.restyle(source, style: style)
        let h = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let b = out.attribute(.font, at: out.length - 2, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(h!.pointSize, b!.pointSize)
        XCTAssertEqual(b!.pointSize, style.size, accuracy: 0.5)
    }

    func testNewExtensionsAreRecognised() {
        XCTAssertEqual(BookFormat(fileExtension: "DOCX"), .docx)
        XCTAssertEqual(BookFormat(fileExtension: "md"), .text)
        XCTAssertEqual(BookFormat(fileExtension: "txt"), .text)
        XCTAssertEqual(BookFormat(fileExtension: "rtf"), .docx)
    }

    func testPaywallIsOffUntilLaunch() {
        for feature in ProFeature.allCases { XCTAssertTrue(Entitlements.isUnlocked(feature)) }
    }
}
