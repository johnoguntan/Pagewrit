import XCTest
@testable import Marginalia

final class ContentHashTests: XCTestCase {
    /// Guards the one property dedup depends on: identical bytes hash
    /// identical, different bytes hash different -- whatever the file
    /// extension or location. Import, rescans, and duplicate suppression
    /// all key off this.
    func testIdenticalContentProducesIdenticalHash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let contents = Data("Marginalia test fixture -- identical content".utf8)
        let fileA = dir.appendingPathComponent("a.epub")
        let fileB = dir.appendingPathComponent("b.epub")
        try contents.write(to: fileA)
        try contents.write(to: fileB)

        let hashA = ImportPipeline.contentHash(for: fileA)
        let hashB = ImportPipeline.contentHash(for: fileB)

        XCTAssertFalse(hashA.isEmpty)
        XCTAssertEqual(hashA, hashB, "Byte-identical files must hash identically regardless of filename")
    }

    func testDifferentContentProducesDifferentHash() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("a.epub")
        let fileB = dir.appendingPathComponent("b.epub")
        try Data("first book".utf8).write(to: fileA)
        try Data("second book".utf8).write(to: fileB)

        let hashA = ImportPipeline.contentHash(for: fileA)
        let hashB = ImportPipeline.contentHash(for: fileB)

        XCTAssertNotEqual(hashA, hashB)
    }

    func testMissingFileReturnsEmptyString() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("stoa-does-not-exist-\(UUID().uuidString).epub")
        XCTAssertEqual(ImportPipeline.contentHash(for: missing), "")
    }
}
