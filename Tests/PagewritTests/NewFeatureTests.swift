import XCTest
import SwiftData
@testable import Pagewrit

/// Tests for the logic added in the November work: the database schema plan,
/// quiet hours, cover titles, copy protection and the reading clock's words.
/// Run with Cmd-U.
@MainActor
final class NewFeatureTests: XCTestCase {

    // MARK: Schema plan

    /// The versioned schema must list every model, or a library saved with
    /// one would fail to open.
    func testVersionedSchemaOpensWithEveryModel() throws {
        let schema = Schema(versionedSchema: PagewritSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, migrationPlan: PagewritMigrationPlan.self, configurations: [config])
        let context = ModelContext(container)

        context.insert(Book(title: "A", format: .epub, sourceURL: URL(fileURLWithPath: "/tmp/a.epub"), contentHash: "h1"))
        context.insert(Highlight(bookHash: "h1", pageIndex: 0, rangeStart: 0, rangeLength: 5, position: 0, text: "Hello"))
        context.insert(Bookmark(bookHash: "h1", position: 0.5, label: "Middle"))
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Highlight>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bookmark>()).count, 1)
        XCTAssertEqual(PagewritSchemaV1.models.count, 5)
    }

    // MARK: Quiet hours

    private let keys = [Wellbeing.quietDaysKey, Wellbeing.quietStartKey, Wellbeing.quietEndKey]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        components.weekOfYear = 20
        components.yearForWeekOfYear = 2026
        return Calendar.current.date(from: components)!
    }

    func testQuietHoursOffWhenNoDaysChosen() {
        UserDefaults.standard.set("", forKey: Wellbeing.quietDaysKey)
        XCTAssertFalse(Wellbeing.isQuietNow(date(weekday: 2, hour: 23)))
    }

    func testQuietHoursAcrossMidnightBelongToTheStartDay() {
        UserDefaults.standard.set("2", forKey: Wellbeing.quietDaysKey)   // Monday only
        UserDefaults.standard.set(22 * 60, forKey: Wellbeing.quietStartKey)
        UserDefaults.standard.set(7 * 60, forKey: Wellbeing.quietEndKey)

        XCTAssertTrue(Wellbeing.isQuietNow(date(weekday: 2, hour: 23)))   // Monday 11pm
        XCTAssertTrue(Wellbeing.isQuietNow(date(weekday: 3, hour: 6)))    // Tuesday 6am, from Monday night
        XCTAssertFalse(Wellbeing.isQuietNow(date(weekday: 3, hour: 23)))  // Tuesday night is not chosen
        XCTAssertFalse(Wellbeing.isQuietNow(date(weekday: 2, hour: 12)))  // Monday noon
    }

    func testQuietHoursWithinOneDay() {
        UserDefaults.standard.set("1", forKey: Wellbeing.quietDaysKey)   // Sunday
        UserDefaults.standard.set(13 * 60, forKey: Wellbeing.quietStartKey)
        UserDefaults.standard.set(15 * 60, forKey: Wellbeing.quietEndKey)
        XCTAssertTrue(Wellbeing.isQuietNow(date(weekday: 1, hour: 14)))
        XCTAssertFalse(Wellbeing.isQuietNow(date(weekday: 1, hour: 15)))
    }

    // MARK: Cover titles

    func testCoverSplitsTitleAtDash() {
        let parts = GeneratedCover.titleParts("Stoa \u{2014} Plan & Architecture")
        XCTAssertEqual(parts.main, "Stoa")
        XCTAssertEqual(parts.sub, "Plan & Architecture")
    }

    func testCoverCleansFileNames() {
        let parts = GeneratedCover.titleParts("the_art_of_war")
        XCTAssertEqual(parts.main, "the art of war")
        XCTAssertNil(parts.sub)
    }

    func testCoverHandlesEmptyTitle() {
        XCTAssertEqual(GeneratedCover.titleParts("   ").main, "Untitled")
    }

    // MARK: Copy protection

    private func makeBook(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meta = root.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(to: meta.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testPlainBookIsNotProtected() throws {
        XCTAssertFalse(EPUBProtection.isProtected(root: try makeBook(files: [:])))
    }

    func testAdobeRightsFileMeansProtected() throws {
        XCTAssertTrue(EPUBProtection.isProtected(root: try makeBook(files: ["rights.xml": "<rights/>"])))
    }

    func testFontObfuscationIsNotDRM() throws {
        let xml = #"<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/></EncryptedData></encryption>"#
        XCTAssertFalse(EPUBProtection.isProtected(root: try makeBook(files: ["encryption.xml": xml])))
    }

    func testEncryptedChaptersMeanProtected() throws {
        let xml = #"<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData></encryption>"#
        XCTAssertTrue(EPUBProtection.isProtected(root: try makeBook(files: ["encryption.xml": xml])))
    }

    // MARK: Reading clock words

    func testMinutesText() {
        XCTAssertEqual(readingMinutesText(1), "1 minute")
        XCTAssertEqual(readingMinutesText(20), "20 minutes")
        XCTAssertEqual(readingMinutesText(20, short: true), "20 min")
        XCTAssertEqual(readingMinutesText(60), "1 h")
        XCTAssertEqual(readingMinutesText(95), "1 h 35 min")
    }

    func testCountdownText() {
        XCTAssertEqual(clockText(65), "1:05")
        XCTAssertEqual(clockText(3_661), "1:01:01")
        XCTAssertEqual(clockText(0.2), "0:01")
    }
}
