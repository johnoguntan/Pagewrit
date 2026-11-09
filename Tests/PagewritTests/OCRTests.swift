import XCTest
import AppKit
import PDFKit
@testable import Pagewrit

final class OCRTests: XCTestCase {

    /// A one-page PDF that is only a picture of text (no text layer), like a scan.
    private func makeScannedPDF() throws -> URL {
        let size = NSSize(width: 612, height: 792)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.black]
            NSAttributedString(string: "PAGEWRIT OCR TEST", attributes: attrs)
                .draw(at: NSPoint(x: 40, y: 380))
            return true
        }
        let doc = PDFDocument()
        doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).pdf")
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    func testScannedPDFIsDetectedAndMadeSearchable() throws {
        let source = try makeScannedPDF()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }

        XCTAssertTrue(OCRService.isScanned(url: source))

        let lines = try OCRService.makeSearchablePDF(source: source, destination: output, progress: { _ in }, isCancelled: { false })
        XCTAssertGreaterThan(lines, 0)

        let result = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue((result.string ?? "").uppercased().contains("OCR"), "recognized text should be searchable: \(result.string ?? "nil")")
        XCTAssertFalse(OCRService.isScanned(document: result))
    }

    func testCancellationLeavesNoFile() throws {
        let source = try makeScannedPDF()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: source) }
        XCTAssertThrowsError(try OCRService.makeSearchablePDF(source: source, destination: output, progress: { _ in }, isCancelled: { true }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
