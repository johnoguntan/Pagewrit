import Foundation
import SwiftData
import Combine
import AppKit

/// Owns the SwiftData ModelContainer and exposes the library as a
/// publishable array of `Book` records. This is the single source of
/// truth for "what's in the library" — the UI reads from `books`,
/// not from the scanner's raw file list.
///
/// Library folder defaults to `~/Documents/StoaLibrary`. Phase 4
/// will make this configurable (iCloud Drive / Google Drive); the
/// path is isolated behind one property so that's a small change.
@MainActor
final class LibraryStore: ObservableObject {

    // MARK: - Published state

    /// Files deleted from the library that can still be put back.
    @Published private(set) var recycleBin: [RecycledBook] = RecycledBook.loadAll()

    @Published private(set) var books: [Book] = []
    private var continueReadingCache: [Book] = []
    private var continueReadingKey = ""

    /// True while the import pipeline is running (scan + import cycle).
    @Published var isImporting: Bool = false

    /// Set when a database save fails, so the UI can tell the user.
    @Published private(set) var lastSaveError: String?

    func clearSaveError() { lastSaveError = nil }

    /// Bumped whenever the library's contents change (books added/removed,
    /// metadata edited). The library screen re-sorts only when this moves.
    @Published private(set) var dataVersion = 0
    /// Bumped for small per-book changes (favorite, rating, status, progress)
    /// so the screen can skip the expensive re-sort unless it needs to.
    @Published private(set) var lightVersion = 0

    private var pendingSave: DispatchWorkItem?
    private var lastSaveContext = ""

    /// Marks the data changed and saves shortly after, off the click's
    /// critical path. Clicking a heart used to wait for a disk write; now the
    /// screen updates first and the save follows in the background.
    private func persist(light: Bool = false, notify: Bool = true, _ context: String = #function) {
        if notify {
            if light { lightVersion &+= 1 } else { dataVersion &+= 1 }
        }
        lastSaveContext = context
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Writes any pending changes immediately (quit, switching away).
    func flushSaves() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        saveNow()
    }

    private func saveNow() {
        pendingSave = nil
        do {
            try modelContext.save()
        } catch {
            print("Pagewrit: save failed in \(lastSaveContext): \(error)")
            lastSaveError = error.localizedDescription
        }
    }

    private func installSaveFlushers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaves() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSaves() }
        }
    }


    /// Fraction of discovered files imported so far (0.0 ... 1.0).
    @Published var importProgress: Double = 0

    /// Drives the in-window Settings sheet — Settings lives inside the main
    /// window (sidebar gear button, or Cmd+,) rather than as a separate
    /// macOS Settings window.
    @Published var showSettings: Bool = false
    /// Set by Help ▸ Welcome to Pagewrit; ContentView shows the sheet and resets it.
    @Published var showWelcome: Bool = false

    // MARK: - SwiftData

    let modelContainer: ModelContainer
    private var modelContext: ModelContext

    /// The library folder where cover images, cached search text, and
    /// downloaded books are stored. Defaults to ~/Documents/StoaLibrary,
    /// but is user-configurable in Settings via LibraryLocation — see
    /// relocateLibrary(to:) for moving it.
    @Published private(set) var libraryFolder: URL

    // MARK: - Init

    init() {
        let folder = LibraryLocation.folder
        self.libraryFolder = folder

        // Create the library folder if it doesn't exist
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let coversFolder = folder.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coversFolder, withIntermediateDirectories: true)

        let schema = Schema(versionedSchema: PagewritSchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        // Before a new version of the app opens the library for the first
        // time, keep a copy of the database exactly as the old version left it.
        LibraryDatabaseSafety.snapshotBeforeUpgrade(storeURL: config.url)
        do {
            self.modelContainer = try ModelContainer(
                for: schema,
                migrationPlan: PagewritMigrationPlan.self,
                configurations: [config]
            )
        } catch {
            // The saved library could not be opened (a failed migration, a
            // damaged store). Crashing here would loop on every launch, so
            // start with an empty in-memory library instead and say so. The
            // files on disk are untouched.
            print("Pagewrit: could not open the library database: \(error)")
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                self.modelContainer = try ModelContainer(for: schema, configurations: [fallback])
            } catch {
                fatalError("Failed to create even an in-memory ModelContainer: \(error)")
            }
            self.lastSaveError = "Pagewrit couldn't open your saved library, so it started empty. Your book files are safe, and a copy of the library was kept from before this update. Restart the app, or restore your latest backup from Settings \u{25B8} Library \u{25B8} Backup."
        }
        self.modelContext = modelContainer.mainContext

        loadBooks()
        loadClassifications()
        consolidateClassifications()
        loadDismissedDuplicates()
        loadBookmarks()
        loadHighlights()
        buildSearchIndexIfNeeded()
        SpotlightIndexer.reindex(books)
        installSaveFlushers()
    }

    // MARK: - Library Location
    //
    // Moves Covers/SearchIndex/Downloads to a new folder (e.g. inside
    // iCloud Drive or Google Drive) and repairs every already-imported
    // book's coverImagePath/extractedTextPath so existing cover art and
    // cached search text keep working from the new location, instead of
    // silently going stale. Deliberately does not touch the SwiftData
    // store itself — see LibraryLocation's doc comment for why.

    enum RelocateError: Error {
        case notADirectory
    }

    func relocateLibrary(to newFolder: URL) throws {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: newFolder.path, isDirectory: &isDir)
        if exists, !isDir.boolValue {
            throw RelocateError.notADirectory
        }

        let oldFolder = libraryFolder
        try LibraryLocation.relocate(to: newFolder)
        libraryFolder = LibraryLocation.folder

        let oldPrefix = oldFolder.path
        let newPrefix = libraryFolder.path
        guard oldPrefix != newPrefix else { return }

        for book in books {
            if let coverPath = book.coverImagePath, coverPath.hasPrefix(oldPrefix) {
                book.coverImagePath = newPrefix + coverPath.dropFirst(oldPrefix.count)
            }
            if let textPath = book.extractedTextPath, textPath.hasPrefix(oldPrefix) {
                book.extractedTextPath = newPrefix + textPath.dropFirst(oldPrefix.count)
            }
        }
        persist()
    }

    // MARK: - Classifications

    @Published private(set) var classifications: [BookClassification] = [] {
        didSet { classificationIndex = nil }
    }
    private var classificationIndex: [String: BookClassification]?

    // MARK: - Bookmarks

    @Published private(set) var bookmarks: [Bookmark] = []

    /// A book's saved bookmarks, earliest position first.
    func bookmarks(for book: Book) -> [Bookmark] {
        bookmarks
            .filter { $0.bookHash == book.contentHash }
            .sorted { $0.position < $1.position }
    }

    /// Save a new bookmark at the reader's current position.
    @discardableResult
    func addBookmark(for book: Book, position: Double, label: String) -> Bookmark {
        let bookmark = Bookmark(bookHash: book.contentHash, position: position, label: label)
        modelContext.insert(bookmark)
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    /// Remove a bookmark.
    func removeBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        bookmarks.removeAll { $0.persistentModelID == bookmark.persistentModelID }
        persist()
    }

    // MARK: - Highlights & notes

    @Published private(set) var highlights: [Highlight] = []

    /// A book's highlights in reading order.
    func highlights(for book: Book) -> [Highlight] {
        highlights(forHash: book.contentHash)
    }

    func highlights(forHash hash: String) -> [Highlight] {
        highlights
            .filter { $0.bookHash == hash }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.rangeStart < $1.rangeStart
            }
    }

    /// Number of highlights in a book (for badges).
    func highlightCount(forHash hash: String) -> Int {
        highlights.reduce(0) { $0 + ($1.bookHash == hash ? 1 : 0) }
    }

    /// Save a new highlight.
    @discardableResult
    func addHighlight(
        bookHash: String,
        pageIndex: Int,
        rangeStart: Int,
        rangeLength: Int,
        position: Double,
        text: String,
        color: HighlightColor = .yellow,
        note: String = ""
    ) -> Highlight {
        let h = Highlight(
            bookHash: bookHash, pageIndex: pageIndex,
            rangeStart: rangeStart, rangeLength: rangeLength,
            position: position, text: text, color: color, note: note
        )
        modelContext.insert(h)
        highlights.append(h)
        persist()
        return h
    }

    /// Asks the reader for a book to open at a specific highlight. The reader
    /// picks this up whether it is opening fresh or already on screen.
    struct HighlightJump: Equatable {
        let id: UUID
        let bookHash: String
        let highlightID: PersistentIdentifier
    }

    @Published private(set) var jumpRequest: HighlightJump?

    func requestJump(to highlight: Highlight) {
        jumpRequest = HighlightJump(id: UUID(), bookHash: highlight.bookHash, highlightID: highlight.persistentModelID)
    }

    /// Returns the highlight a reader of `hash` should jump to, once.
    func consumeJump(for hash: String) -> Highlight? {
        guard let request = jumpRequest, request.bookHash == hash else { return nil }
        jumpRequest = nil
        return highlights.first { $0.persistentModelID == request.highlightID }
    }

    func setHighlightNote(_ highlight: Highlight, note: String) {
        highlight.note = note
        persist()
        objectWillChange.send()
    }

    func setHighlightColor(_ highlight: Highlight, color: HighlightColor) {
        highlight.color = color
        persist()
        objectWillChange.send()
    }

    func removeHighlight(_ highlight: Highlight) {
        modelContext.delete(highlight)
        highlights.removeAll { $0.persistentModelID == highlight.persistentModelID }
        persist()
    }

    // MARK: - Duplicates

    @Published private(set) var dismissedDuplicatePairs: [DismissedDuplicatePair] = []

    /// Groups of two or more books that look like the same work saved
    /// twice (matched on normalized title+author, not file bytes — so it
    /// catches an EPUB/PDF pair of the same book, which contentHash never
    /// would), excluding any pair the user has already dismissed.
    var duplicateGroups: [[Book]] {
        let dismissedKeys = Set(dismissedDuplicatePairs.map(\.pairKey))
        return DuplicateDetector.findGroups(in: books, dismissedPairKeys: dismissedKeys)
    }

    /// Record that the user looked at these two books and decided to keep
    /// both, so this pair stops showing up in the Duplicates tray.
    func dismissDuplicate(_ first: Book, _ second: Book) {
        let pair = DismissedDuplicatePair(firstHash: first.contentHash, secondHash: second.contentHash)
        modelContext.insert(pair)
        dismissedDuplicatePairs.append(pair)
        persist()
    }

    /// Files the user has dismissed ("not a book") — checked during import
    /// to prevent re-importing after rescan.
    var dismissedHashes: Set<String> {
        Set(classifications.filter { $0.decision == .userDismissed }.map { $0.fileHash })
    }

    /// Files sitting in the "Needs Review" tray.
    ///
    /// Only files that genuinely still need a decision: not already in the
    /// library (added some other way, or reviewed under a duplicate record),
    /// and still on disk (a file that was moved or deleted can't be added).
    var needsReview: [BookClassification] {
        classifications.filter {
            $0.decision == .needsReview
                && !contains(hash: $0.fileHash)
                && FileManager.default.fileExists(atPath: $0.sourcePath)
        }
    }

    /// Look up the classification for a content hash. If more than one
    /// record exists for the same file, a person's decision beats the
    /// classifier's, so a reviewed file always reads as reviewed.
    func classification(for hash: String) -> BookClassification? {
        // Indexed once per change, instead of scanning every record for every
        // book (that was quadratic and slowed the whole library screen).
        if classificationIndex == nil {
            var index: [String: BookClassification] = [:]
            for record in classifications {
                if let existing = index[record.fileHash],
                   existing.decision.precedence >= record.decision.precedence { continue }
                index[record.fileHash] = record
            }
            classificationIndex = index
        }
        return classificationIndex?[hash]
    }

    /// Collapses duplicate records for the same file into one, keeping the
    /// strongest decision (then the most recent), and deletes the rest. This
    /// repairs stores where a reviewed file had a second, still-pending
    /// record that kept bringing it back to Needs Review.
    private func consolidateClassifications() {
        var removedAny = false
        for record in classifications where record.fileHash.isEmpty {
            modelContext.delete(record)
            removedAny = true
        }
        let valid = classifications.filter { !$0.fileHash.isEmpty }
        let grouped = Dictionary(grouping: valid, by: \.fileHash)
        var kept: [BookClassification] = []

        for (_, records) in grouped {
            guard records.count > 1 else {
                kept.append(records[0])
                continue
            }
            let winner = records.max {
                if $0.decision.precedence != $1.decision.precedence {
                    return $0.decision.precedence < $1.decision.precedence
                }
                return $0.decidedAt < $1.decidedAt
            }!
            kept.append(winner)
            for record in records where record !== winner {
                modelContext.delete(record)
                removedAny = true
            }
        }

        if removedAny {
            persist()
            classifications = kept.sorted { $0.decidedAt > $1.decidedAt }
        }
    }

    /// Whether a book belongs on the hero rail (Continue Reading, Recently
    /// Added, Discover), not just in the library. EPUB/CBZ never go
    /// through BookClassifier and are always eligible — there's no signal
    /// against them. A PDF that just cleared the 0.7 auto-add bar can
    /// still be a stray document (a long spec, a dense report) rather
    /// than a real book, so hero placement holds PDFs to a stricter bar
    /// than "good enough to keep in the library." A book someone
    /// explicitly confirmed out of the Needs Review tray is always
    /// eligible — that's a real decision, not a heuristic guess.
    /// Something you read for pleasure or study, as opposed to paperwork:
    /// books and comics always, PDFs when they look like books (not an
    /// invoice, and either a sizeable file or one you added as a book).
    func isBookLike(_ book: Book) -> Bool {
        switch book.format {
        case .epub, .kindle, .cbz:
            return true
        case .docx, .text, .pptx:
            return false
        case .pdf:
            if InvoiceStore.shared.contains(book.contentHash) { return false }
            if classification(for: book.contentHash)?.decision == .userConfirmed { return true }
            return book.sizeBytes >= 1_500_000
        }
    }

    func isHeroEligible(_ book: Book) -> Bool {
        // The featured cards are for books, never invoices or work files.
        guard isBookLike(book) else { return false }
        guard let classification = classification(for: book.contentHash) else { return true }
        switch classification.decision {
        case .userConfirmed:
            return true
        case .autoAdded:
            return classification.score >= 0.8
        case .needsReview, .autoSkipped, .userDismissed:
            // Shouldn't happen — these decisions never reach the library —
            // but err toward showing rather than hiding if it somehow does.
            return true
        }
    }

    /// Record a classification decision (auto-added, needs review, auto-skipped).
    func addClassification(_ incoming: BookClassification) {
        if let existing = self.classification(for: incoming.fileHash) {
            // A reviewed file stays reviewed: never let a fresh scan
            // overwrite a decision the person already made.
            guard !existing.decision.isUserDecision else { return }
            objectWillChange.send()
            existing.score = incoming.score
            existing.decision = incoming.decision
            existing.decidedAt = incoming.decidedAt
            if !incoming.sourcePath.isEmpty { existing.sourcePath = incoming.sourcePath }
            if !incoming.fileName.isEmpty { existing.fileName = incoming.fileName }
        } else {
            modelContext.insert(incoming)
            classifications.append(incoming)
        }
        persist()
    }

    /// Move a classification to user-confirmed (add to library from review
    /// tray). Runs the file through the same ImportPipeline extraction
    /// auto-added books get (real PDF title/author, not just the filename) —
    /// a confirmed book is already in the library afterward, so rescans skip
    /// it forever and would never get a chance to backfill real metadata later.
    @MainActor
    func confirmClassification(_ classification: BookClassification) async {
        objectWillChange.send()
        classification.decision = .userConfirmed
        classification.decidedAt = Date()
        persist()

        let hash = classification.fileHash
        guard !contains(hash: hash) else { return }

        let url = classification.sourceURL
        guard let format = BookFormat(fileExtension: url.pathExtension) else { return }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = DiscoveredFile(
            url: url,
            format: format,
            sizeBytes: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate
        )

        if let book = await ImportPipeline.importFile(file, libraryFolder: libraryFolder, precomputedHash: hash) {
            add(book)
        } else {
            // The import didn't produce a book (file unreadable, moved, ...).
            // Put it back in the tray rather than let it vanish as
            // "confirmed" with nothing in the library.
            objectWillChange.send()
            classification.decision = .needsReview
            persist()
        }
    }

    /// Dismiss a classification ("not a book"). Never resurfaces on rescan.
    func dismissClassification(_ classification: BookClassification) {
        objectWillChange.send()
        classification.decision = .userDismissed
        classification.decidedAt = Date()
        persist()
    }

    /// Moves the book's underlying source file to the Trash (plus its
    /// cached cover and extracted-text sidecar files, which are deleted
    /// outright — they're Pagewrit's own derived data, not something worth
    /// recovering), then removes it from the library. Unlike
    /// removeAndExclude, this doesn't record a dismissed classification —
    /// there's nothing left on disk to re-discover on a future rescan.
    ///
    /// Trash, not permanent delete: this reaches outside StoaLibrary's own
    /// folder into wherever the user's Finder put the file (Documents, a
    /// watched folder, etc.), so a mistaken click should be recoverable
    /// the same way Finder's own Delete is. Errors are non-fatal: even if
    /// the file's already gone or the move fails (permissions, a folder
    /// that went offline), the book still comes out of the library, since
    /// the user asked for the book gone either way.
    @discardableResult
    func deleteFile(for book: Book) -> Bool {
        var success = true

        if FileManager.default.fileExists(atPath: book.sourcePath) {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: book.sourceURL, resultingItemURL: &resulting)
                if let trashed = resulting as URL? {
                    recycleBin.insert(RecycledBook(
                        id: UUID(),
                        title: book.title,
                        author: book.author,
                        formatName: book.format.sectionTitle,
                        originalPath: book.sourcePath,
                        trashPath: trashed.path,
                        deletedAt: Date(),
                        sizeBytes: book.sizeBytes
                    ), at: 0)
                    RecycledBook.saveAll(recycleBin)
                }
            } catch {
                print("LibraryStore: failed to trash source file: \(error)")
                success = false
            }
        }

        if let coverURL = book.coverImageURL {
            try? FileManager.default.removeItem(at: coverURL)
        }
        if let textURL = book.extractedTextURL {
            try? FileManager.default.removeItem(at: textURL)
        }

        remove(book)
        return success
    }

    // MARK: - Recycle Bin

    /// Puts the file back where it came from. The caller rescans afterwards so
    /// the book reappears in the library. Returns false if the file is gone.
    @discardableResult
    func restore(_ item: RecycledBook) -> Bool {
        let fm = FileManager.default
        func forget() {
            recycleBin.removeAll { $0.id == item.id }
            RecycledBook.saveAll(recycleBin)
        }
        // The file is gone from the Trash (emptied in Finder): drop the entry.
        guard fm.fileExists(atPath: item.trashPath) else { forget(); return false }
        var destination = URL(fileURLWithPath: item.originalPath)
        if fm.fileExists(atPath: destination.path) {
            let name = destination.deletingPathExtension().lastPathComponent + " (restored)"
            destination = destination.deletingLastPathComponent()
                .appendingPathComponent(name)
                .appendingPathExtension(destination.pathExtension)
        }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: URL(fileURLWithPath: item.trashPath), to: destination)
            forget()
            return true
        } catch {
            // Keep the entry so the user can try again; the file is still in the Trash.
            print("LibraryStore: failed to restore: \(error)")
            return false
        }
    }

    /// The bin's paths are stored in UserDefaults, so before erasing anything
    /// for good, make sure the path really points into a Trash folder.
    private static func isInTrash(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        return resolved.contains("/.Trash/") && !resolved.contains("/../")
    }

    /// Deletes the file for good.
    func deleteForever(_ item: RecycledBook) {
        if Self.isInTrash(item.trashPath) { try? FileManager.default.removeItem(atPath: item.trashPath) }
        recycleBin.removeAll { $0.id == item.id }
        RecycledBook.saveAll(recycleBin)
    }

    func emptyRecycleBin() {
        for item in recycleBin where Self.isInTrash(item.trashPath) {
            try? FileManager.default.removeItem(atPath: item.trashPath)
        }
        recycleBin = []
        RecycledBook.saveAll(recycleBin)
    }

    /// Keeps the largest copy of every duplicate group and sends the rest to the bin.
    @discardableResult
    func deleteExtraCopies(in groups: [[Book]]) -> Int {
        var count = 0
        for group in groups {
            let keeper = group.max { $0.sizeBytes < $1.sizeBytes }
            for book in group where book.persistentModelID != keeper?.persistentModelID {
                deleteFile(for: book)
                count += 1
            }
        }
        return count
    }

    /// Remove an already-imported book and permanently exclude it from future imports.
    func removeAndExclude(_ book: Book) {
        // Create a dismissed classification so it never comes back
        let hash = book.contentHash
        if let existing = classification(for: hash) {
            existing.decision = .userDismissed
            existing.decidedAt = Date()
        } else {
            let classification = BookClassification(
                fileHash: hash,
                score: 1.0,
                decision: .userDismissed
            )
            modelContext.insert(classification)
            classifications.append(classification)
        }
        remove(book)
        persist()
    }

    // MARK: - Data access

    /// Fetch all classifications from the persistent store.
    private func loadClassifications() {
        let descriptor = FetchDescriptor<BookClassification>(sortBy: [SortDescriptor(\.decidedAt, order: .reverse)])
        do {
            classifications = try modelContext.fetch(descriptor)
        } catch {
            print("LibraryStore: failed to fetch classifications: \(error)")
            classifications = []
        }
    }

    /// Fetch all dismissed-duplicate pair records from the persistent store.
    private func loadDismissedDuplicates() {
        let descriptor = FetchDescriptor<DismissedDuplicatePair>()
        do {
            dismissedDuplicatePairs = try modelContext.fetch(descriptor)
        } catch {
            print("LibraryStore: failed to fetch dismissed duplicate pairs: \(error)")
            dismissedDuplicatePairs = []
        }
    }

    /// Fetch all highlights from the persistent store.
    private func loadHighlights() {
        let descriptor = FetchDescriptor<Highlight>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        do {
            highlights = try modelContext.fetch(descriptor)
        } catch {
            print("LibraryStore: failed to fetch highlights: \(error)")
            highlights = []
        }
    }

    /// Fetch all bookmarks from the persistent store.
    private func loadBookmarks() {
        let descriptor = FetchDescriptor<Bookmark>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        do {
            bookmarks = try modelContext.fetch(descriptor)
        } catch {
            print("LibraryStore: failed to fetch bookmarks: \(error)")
            bookmarks = []
        }
    }

    /// Fetch all books from the persistent store, sorted by addedAt descending.
    private func loadBooks() {
        let descriptor = FetchDescriptor<Book>(sortBy: [SortDescriptor(\.addedAt, order: .reverse)])
        do {
            books = try modelContext.fetch(descriptor)
        } catch {
            print("LibraryStore: failed to fetch books: \(error)")
            books = []
        }
    }

    /// Returns true if a book with the given content hash already exists in the library.
    func contains(hash: String) -> Bool {
        books.contains { $0.contentHash == hash }
    }

    /// Insert a new book into the library and persist.
    func add(_ book: Book) {
        guard !contains(hash: book.contentHash) else { return }
        applyPendingRestore(to: book)
        modelContext.insert(book)
        persist()
        books.insert(book, at: 0) // newest first
        buildSearchIndexIfNeeded()
        SpotlightIndexer.reindex([book])
    }

    /// Remove a book from the library and persist.
    func remove(_ book: Book) {
        SpotlightIndexer.remove(hash: book.contentHash)
        modelContext.delete(book)
        persist()
        books.removeAll { $0.id == book.id }
    }

    /// Update the tags for a specific book.
    func updateTags(for book: Book, tags: [String]) {
        book.tags = tags
        persist()
    }

    /// Update the shelves a specific book belongs to.
    func updateShelves(for book: Book, shelves: [String]) {
        book.shelfNames = shelves
        persist()
    }

    /// One-time pass: books imported before this change were dated by when
    /// Pagewrit found them. Give each its real date on the Mac. Skipped for
    /// files that can't be read yet; tried again next launch until it works.
    func backfillAddedDates() {
        let key = "pagewrit.addedDatesBackfilled.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var updated = 0
        var unreadable = 0
        for book in books {
            if let date = ImportPipeline.dateAddedToMac(book.sourceURL) {
                if abs(book.addedAt.timeIntervalSince(date)) > 1 {
                    book.addedAt = date
                    updated += 1
                }
            } else {
                unreadable += 1
            }
        }
        if updated > 0 { persist(); objectWillChange.send() }
        if unreadable == 0 { UserDefaults.standard.set(true, forKey: key) }
    }

    /// Star or unstar a book.
    func toggleFavorite(_ book: Book) {
        book.isFavorite.toggle()
        persist(light: true)
    }

    /// Set a 1...5 star rating (0 clears it).
    func setRating(_ book: Book, rating: Int) {
        book.rating = min(max(rating, 0), 5)
        persist(light: true)
    }

    /// Mark a book unread, reading or finished by hand.
    func setStatus(_ book: Book, status: ReadingStatus) {
        book.manualStatus = status.rawValue
        if status == .unread { book.readingProgress = nil }
        if status == .finished { book.readingProgress = 1.0 }
        persist(light: true)
    }

    /// Put a book in a series (empty name removes it).
    func setSeries(_ book: Book, name: String, index: Double?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        book.seriesName = trimmed.isEmpty ? nil : trimmed
        book.seriesIndex = trimmed.isEmpty ? nil : index
        persist()
        objectWillChange.send()
    }

    /// Update reading progress for a specific book.
    func updateProgress(for book: Book, progress: Double) {
        let wasFinished = book.isFinished
        defer {
            if !wasFinished && book.isFinished {
                ReadingTracker.shared.celebrate(.finished(title: book.title))
            }
        }
        // Reading again overrides a hand-set status.
        if book.manualStatus != nil, abs((book.readingProgress ?? 0) - progress) > 0.001 {
            book.manualStatus = nil
        }
        let before = Int((book.readingProgress ?? 0) * 100)
        book.readingProgress = min(max(progress, 0), 1.0)
        book.lastOpenedAt = Date()
        // Only tell the library screen when progress moved a visible step.
        persist(light: true, notify: before != Int(book.readingProgress! * 100))
    }

    /// Called when a reader closes: writes the reading position to disk right
    /// away and tells the library screens, so Continue Reading and its
    /// "opened" time are correct the moment the reader is gone.
    /// `countsTime: false` for readers that are not part of the reading
    /// goal (documents), matching how they were opened.
    func commitReading(countsTime: Bool = true) {
        if countsTime { ReadingTracker.shared.end() }
        lightVersion &+= 1
        pendingSave?.cancel()
        saveNow()
    }

    /// Stamp a book as opened without necessarily changing progress — called
    /// when a reader is presented, so "Continue Reading" picks it up even
    /// before the first page-change fires an updateProgress call.
    func markOpened(_ book: Book, countsTime: Bool = true) {
        if countsTime { ReadingTracker.shared.begin() }
        DogPet.shared.touch()
        book.lastOpenedAt = Date()
        persist(light: true)
    }

    /// Apply a chosen Open Library match to a book: replace title/author,
    /// and — if cover art came back with it — save it into StoaLibrary's
    /// Covers folder and point the book at it. Any of the three can be nil
    /// (a lookup with no cover art still lets the user fix just the title).
    func applyMetadata(to book: Book, title: String?, author: String?, coverData: Data?) {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.title = title
        }
        if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            book.author = author
        }
        if let coverData, let savedPath = saveCoverImage(coverData, contentHash: book.contentHash) {
            book.coverImagePath = savedPath
        }
        persist()
    }

    /// Save raw cover image data to StoaLibrary/Covers/<hash>.jpg — mirrors
    /// ImportPipeline's own saveCoverImage, since a metadata-lookup cover
    /// needs the same on-disk convention as one found at import time.
    private func saveCoverImage(_ data: Data, contentHash: String) -> String? {
        let coversDir = libraryFolder.appendingPathComponent("Covers", isDirectory: true)
        let fileURL = coversDir.appendingPathComponent("\(contentHash).jpg")

        do {
            guard let nsImage = NSImage(data: data),
                  let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
                try data.write(to: fileURL)
                return fileURL.path
            }
            try jpegData.write(to: fileURL)
            return fileURL.path
        } catch {
            print("LibraryStore: failed to save cover image: \(error)")
            return nil
        }
    }

    /// Books with progress in (0, 0.98), most recently opened first — the
    /// candidate list for the "Continue Reading" hero.
    var continueReading: [Book] {
        // Cached: the sidebar and home page ask for this on every redraw, and
        // sorting thousands of books each time made big libraries feel slow.
        let key = "\(dataVersion)|\(lightVersion)|\(books.count)"
        if continueReadingKey == key { return continueReadingCache }
        let result = books
            .filter { $0.status == .reading }
            .sorted { (lhs, rhs) in
                (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
            }
        continueReadingCache = result
        continueReadingKey = key
        return result
    }

    /// Refresh the books array from the persistent store.
    func refresh() {
        loadBooks()
        loadClassifications()
        loadDismissedDuplicates()
        loadBookmarks()
        loadHighlights()
        buildSearchIndexIfNeeded()
        SpotlightIndexer.reindex(books)
    }

    // MARK: - Full-text search

    /// Books currently matching an in-progress content search — populated
    /// asynchronously by `searchContent`. Empty means "no content search is
    /// active", not "no matches" (ContentView only consults this when the
    /// search text is long enough to trigger one).
    @Published private(set) var contentSearchMatchHashes: Set<String> = []

    private var contentSearchTask: Task<Void, Never>?
    private var indexingTask: Task<Void, Never>?

    /// Extracts and caches plain text for any book that doesn't have it yet
    /// (new imports, or books from before this feature existed), so search
    /// has something to search against. Runs off the main actor in the
    /// background; safe to call repeatedly — it only touches books that are
    /// still missing an index.
    func buildSearchIndexIfNeeded() {
        let candidates = books.compactMap { book -> (hash: String, url: URL, format: BookFormat)? in
            guard book.extractedTextPath == nil, book.format != .cbz else { return nil }
            return (book.contentHash, self.readableURL(for: book), book.format)
        }
        guard !candidates.isEmpty else { return }

        let indexFolder = libraryFolder.appendingPathComponent("SearchIndex", isDirectory: true)
        try? FileManager.default.createDirectory(at: indexFolder, withIntermediateDirectories: true)

        indexingTask?.cancel()
        indexingTask = Task.detached(priority: .utility) {
            var results: [(hash: String, path: String)] = []
            for candidate in candidates {
                if Task.isCancelled { return }
                guard let text = TextExtractor.extractText(url: candidate.url, format: candidate.format) else { continue }
                let fileURL = indexFolder.appendingPathComponent("\(candidate.hash).txt")
                guard (try? text.write(to: fileURL, atomically: true, encoding: .utf8)) != nil else { continue }
                results.append((candidate.hash, fileURL.path))
            }
            guard !results.isEmpty else { return }
            let finalResults = results
            await MainActor.run { [weak self] in
                guard let self else { return }
                for result in finalResults {
                    if let book = self.books.first(where: { $0.contentHash == result.hash }) {
                        book.extractedTextPath = result.path
                    }
                }
                self.persist("search index")
            }
        }
    }

    /// Searches cached extracted text for `query`, populating
    /// `contentSearchMatchHashes` asynchronously. Cheap no-op for short
    /// queries (avoids scanning the whole index on every keystroke of a
    /// one- or two-letter search).
    func searchContent(_ query: String) {
        contentSearchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            contentSearchMatchHashes = []
            return
        }

        let candidates = books.compactMap { book -> (hash: String, url: URL)? in
            guard let url = book.extractedTextURL else { return nil }
            return (book.contentHash, url)
        }

        contentSearchTask = Task.detached(priority: .userInitiated) {
            var matches: Set<String> = []
            let terms = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            for candidate in candidates {
                if Task.isCancelled { return }
                guard let text = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
                let all = terms.allSatisfy {
                    text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
                if all { matches.insert(candidate.hash) }
            }
            if Task.isCancelled { return }
            let finalMatches = matches
            await MainActor.run { [weak self] in
                self?.contentSearchMatchHashes = finalMatches
            }
        }
    }

    // MARK: - Book lookup

    /// Find a book by its source file path.
    func book(for sourcePath: String) -> Book? {
        books.first { $0.sourcePath == sourcePath }
    }
}


// MARK: - Recycle Bin record

struct RecycledBook: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String?
    let formatName: String
    let originalPath: String
    let trashPath: String
    let deletedAt: Date
    let sizeBytes: Int64

    private static let key = "pagewrit.recycleBin"

    static func loadAll() -> [RecycledBook] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([RecycledBook].self, from: data) else { return [] }
        // Anything already emptied from the Finder Trash can't come back.
        return items.filter { FileManager.default.fileExists(atPath: $0.trashPath) }
    }

    static func saveAll(_ items: [RecycledBook]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}


// MARK: - Backup and restore

/// A backup is one property list file holding everything you made in Pagewrit:
/// per-book details (ratings, favourites, tags, shelves, series, status,
/// progress, edited titles), highlights, notes, bookmarks, covers you chose,
/// and your settings, reading goal and history. The books themselves stay where
/// they are; restoring matches records to files by their content fingerprint,
/// so it works even if the files moved or the Mac is new.
extension LibraryStore {
    static let backupExtension = "pagewritbackup"
    private static let backupVersion = 1
    private static let pendingRestoreKey = "pagewrit.pendingRestore"
    private static let lastAutoBackupKey = "pagewrit.lastAutoBackup"
    static let autoBackupKey = "pagewrit.autoBackup"

    struct RestoreSummary {
        var matched = 0
        var waiting = 0
        var highlights = 0
        var bookmarks = 0
        var settings = 0
    }

    enum BackupError: LocalizedError {
        case unreadable, wrongKind, newerVersion
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file could not be read."
            case .wrongKind: return "This file is not a Pagewrit backup."
            case .newerVersion: return "This backup was made by a newer Pagewrit. Update the app, then try again."
            }
        }
    }

    /// Settings worth carrying over. Window positions and system keys stay out.
    private static func isBackedUpSetting(_ key: String) -> Bool {
        (key.hasPrefix("pagewrit.") || key.hasPrefix("stoa."))
            && key != pendingRestoreKey && key != lastAutoBackupKey
    }

    // MARK: Making one

    func makeBackup() throws -> Data {
        flushSaves()
        let bookRecords = books.map { book -> [String: Any] in
            var record: [String: Any] = [
                "hash": book.contentHash,
                "title": book.title,
                "tags": book.tags,
                "shelves": book.shelfNames,
                "favorite": book.isFavorite,
                "rating": book.rating,
                "addedAt": book.addedAt
            ]
            if let author = book.author { record["author"] = author }
            if let progress = book.readingProgress { record["progress"] = progress }
            if let opened = book.lastOpenedAt { record["lastOpenedAt"] = opened }
            if let series = book.seriesName { record["series"] = series }
            if let index = book.seriesIndex { record["seriesIndex"] = index }
            if let status = book.manualStatus { record["status"] = status }
            if let path = book.coverImagePath,
               path.hasPrefix(libraryFolder.path),
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               data.count < 3_000_000 {
                record["cover"] = data
            }
            return record
        }
        let marks = highlights.map { h -> [String: Any] in
            ["hash": h.bookHash, "page": h.pageIndex, "start": h.rangeStart, "length": h.rangeLength,
             "position": h.position, "text": h.text, "color": h.colorRaw, "note": h.note,
             "createdAt": h.createdAt]
        }
        let saved = bookmarks.map { b -> [String: Any] in
            ["hash": b.bookHash, "position": b.position, "label": b.label, "createdAt": b.createdAt]
        }
        var settings: [String: Any] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where Self.isBackedUpSetting(key) {
            if PropertyListSerialization.propertyList(value, isValidFor: .binary) { settings[key] = value }
        }
        // Books still waiting from an earlier restore travel along too.
        let pending = UserDefaults.standard.dictionary(forKey: Self.pendingRestoreKey) ?? [:]

        let root: [String: Any] = [
            "kind": "pagewrit-backup",
            "version": Self.backupVersion,
            "createdAt": Date(),
            "app": AppInfo.version,
            "books": bookRecords,
            "pendingBooks": Array(pending.values),
            "highlights": marks,
            "bookmarks": saved,
            "settings": settings
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    func writeBackup(to url: URL) throws {
        try makeBackup().write(to: url, options: .atomic)
    }

    static func suggestedBackupName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Pagewrit Backup \(f.string(from: date)).\(backupExtension)"
    }

    /// A quiet weekly copy in the library folder, keeping the five newest.
    func autoBackupIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoBackupKey) as? Bool ?? true, !books.isEmpty else { return }
        if let last = defaults.object(forKey: Self.lastAutoBackupKey) as? Date,
           Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        let folder = backupsFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try writeBackup(to: folder.appendingPathComponent(Self.suggestedBackupName()))
            defaults.set(Date(), forKey: Self.lastAutoBackupKey)
            let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
                .filter { $0.pathExtension == Self.backupExtension }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                } ?? []
            for url in old.dropFirst(5) { try? FileManager.default.removeItem(at: url) }
        } catch {
            print("LibraryStore: automatic backup failed: \(error)")
        }
    }

    var backupsFolder: URL { libraryFolder.appendingPathComponent("Backups", isDirectory: true) }

    var lastAutoBackup: Date? { UserDefaults.standard.object(forKey: Self.lastAutoBackupKey) as? Date }

    // MARK: Restoring

    /// Merges a backup into this library. Nothing you have now is deleted:
    /// details are filled in book by book, and highlights and bookmarks that
    /// already exist are not added twice.
    @discardableResult
    func restoreBackup(from url: URL) throws -> RestoreSummary {
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = object as? [String: Any] else { throw BackupError.unreadable }
        guard root["kind"] as? String == "pagewrit-backup" else { throw BackupError.wrongKind }
        if let version = root["version"] as? Int, version > Self.backupVersion { throw BackupError.newerVersion }

        var summary = RestoreSummary()

        // Settings first, so the reading goal and history land before anything redraws.
        if let settings = root["settings"] as? [String: Any] {
            for (key, value) in settings where Self.isBackedUpSetting(key) {
                UserDefaults.standard.set(value, forKey: key)
                summary.settings += 1
            }
        }

        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingRestoreKey) ?? [:]
        let records = (root["books"] as? [[String: Any]] ?? []) + (root["pendingBooks"] as? [[String: Any]] ?? [])
        let byHash = Dictionary(books.map { ($0.contentHash, $0) }, uniquingKeysWith: { first, _ in first })
        for record in records {
            guard let hash = record["hash"] as? String, !hash.isEmpty else { continue }
            if let book = byHash[hash] {
                apply(record, to: book)
                summary.matched += 1
            } else {
                // The file is not here yet. Keep the details until it turns up.
                var waiting = record
                waiting.removeValue(forKey: "cover")
                pending[hash] = waiting
                summary.waiting += 1
            }
        }
        UserDefaults.standard.set(pending, forKey: Self.pendingRestoreKey)

        // Highlights and notes
        var known = Set(highlights.map { "\($0.bookHash)|\($0.pageIndex)|\($0.rangeStart)|\($0.rangeLength)" })
        for item in root["highlights"] as? [[String: Any]] ?? [] {
            guard let hash = item["hash"] as? String,
                  let page = item["page"] as? Int,
                  let start = item["start"] as? Int,
                  let length = item["length"] as? Int else { continue }
            let key = "\(hash)|\(page)|\(start)|\(length)"
            guard !known.contains(key) else { continue }
            known.insert(key)
            let h = Highlight(
                bookHash: hash, pageIndex: page, rangeStart: start, rangeLength: length,
                position: item["position"] as? Double ?? 0,
                text: item["text"] as? String ?? "",
                color: HighlightColor(rawValue: item["color"] as? String ?? "") ?? .yellow,
                note: item["note"] as? String ?? ""
            )
            if let created = item["createdAt"] as? Date { h.createdAt = created }
            modelContext.insert(h)
            summary.highlights += 1
        }

        // Bookmarks
        var knownMarks = Set(bookmarks.map { "\($0.bookHash)|\($0.position)|\($0.label)" })
        for item in root["bookmarks"] as? [[String: Any]] ?? [] {
            guard let hash = item["hash"] as? String,
                  let position = item["position"] as? Double else { continue }
            let label = item["label"] as? String ?? ""
            let key = "\(hash)|\(position)|\(label)"
            guard !knownMarks.contains(key) else { continue }
            knownMarks.insert(key)
            let b = Bookmark(bookHash: hash, position: position, label: label)
            if let created = item["createdAt"] as? Date { b.createdAt = created }
            modelContext.insert(b)
            summary.bookmarks += 1
        }

        persist()
        saveNow()
        refresh()
        AppAppearance.applySaved()
        ReadingTracker.shared.reloadFromDefaults()
        return summary
    }

    private func apply(_ record: [String: Any], to book: Book) {
        if let title = record["title"] as? String, !title.isEmpty { book.title = title }
        if let author = record["author"] as? String { book.author = author }
        if let tags = record["tags"] as? [String] { book.tags = Array(Set(book.tags + tags)).sorted() }
        if let shelves = record["shelves"] as? [String] { book.shelfNames = Array(Set(book.shelfNames + shelves)).sorted() }
        if record["favorite"] as? Bool == true { book.isFavorite = true }
        if let rating = record["rating"] as? Int, rating > 0 { book.rating = rating }
        if let progress = record["progress"] as? Double, progress > (book.readingProgress ?? 0) {
            book.readingProgress = progress
        }
        if let opened = record["lastOpenedAt"] as? Date, opened > (book.lastOpenedAt ?? .distantPast) {
            book.lastOpenedAt = opened
        }
        if let added = record["addedAt"] as? Date, added < book.addedAt { book.addedAt = added }
        if let series = record["series"] as? String { book.seriesName = series }
        if let index = record["seriesIndex"] as? Double { book.seriesIndex = index }
        if let status = record["status"] as? String { book.manualStatus = status }
        if let cover = record["cover"] as? Data {
            let current = book.coverImagePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            if !current, let saved = saveCoverImage(cover, contentHash: book.contentHash) {
                book.coverImagePath = saved
            }
        }
    }

    /// Called as a book joins the library: details restored earlier, before
    /// its file was found, are put back now.
    fileprivate func applyPendingRestore(to book: Book) {
        var pending = UserDefaults.standard.dictionary(forKey: Self.pendingRestoreKey) ?? [:]
        guard let record = pending[book.contentHash] as? [String: Any] else { return }
        apply(record, to: book)
        pending.removeValue(forKey: book.contentHash)
        UserDefaults.standard.set(pending, forKey: Self.pendingRestoreKey)
    }
}


// MARK: - Schema versions

/// Every shape the library database has had. A future change to a model (a
/// new property, a renamed one) adds PagewritSchemaV2 with copies of the
/// changed models and a stage in PagewritMigrationPlan, so existing libraries
/// are carried forward instead of failing to open.
///
/// Rules for changing a model:
/// 1. A new stored property always gets an inline default value.
/// 2. Renames and type changes need a new schema version and a custom stage.
/// 3. Never ship a change without opening an old library in a test first.
enum PagewritSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [Book.self, BookClassification.self, DismissedDuplicatePair.self, Bookmark.self, Highlight.self]
    }
}

enum PagewritMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [PagewritSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

// MARK: - Database safety net

/// When the app version changes, copies the library database aside before
/// it is opened, so a failed upgrade can always be undone by hand. The three
/// newest copies are kept, in Application Support/DatabaseBackups.
enum LibraryDatabaseSafety {
    private static let lastVersionKey = "pagewrit.lastOpenedAppVersion"

    static func snapshotBeforeUpgrade(storeURL: URL) {
        let defaults = UserDefaults.standard
        let current = "\(AppInfo.version) (\(AppInfo.build))"
        let previous = defaults.string(forKey: lastVersionKey)
        defer { defaults.set(current, forKey: lastVersionKey) }
        guard let previous, previous != current else { return }

        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return }
        let backups = storeURL.deletingLastPathComponent()
            .appendingPathComponent("DatabaseBackups", isDirectory: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = backups.appendingPathComponent("before \(current) \(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // The store and its write-ahead log files travel together.
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: storeURL.path + suffix)
                guard fm.fileExists(atPath: source.path) else { continue }
                try fm.copyItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
            }
            let older = (try? fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: [.creationDateKey])) ?? []
            let sorted = older.sorted {
                let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return a > b
            }
            for stale in sorted.dropFirst(3) { try? fm.removeItem(at: stale) }
            print("Pagewrit: kept a copy of the library from \(previous) before opening it with \(current).")
        } catch {
            print("Pagewrit: could not copy the library before the update: \(error)")
        }
    }
}
