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

    @Published private(set) var books: [Book] = []

    /// True while the import pipeline is running (scan + import cycle).
    @Published var isImporting: Bool = false

    /// Fraction of discovered files imported so far (0.0 ... 1.0).
    @Published var importProgress: Double = 0

    /// Drives the in-window Settings sheet — Settings lives inside the main
    /// window (sidebar gear button, or Cmd+,) rather than as a separate
    /// macOS Settings window.
    @Published var showSettings: Bool = false

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

        let schema = Schema([Book.self, BookClassification.self, DismissedDuplicatePair.self, Bookmark.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
            self.modelContext = modelContainer.mainContext
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        loadBooks()
        loadClassifications()
        loadDismissedDuplicates()
        loadBookmarks()
        buildSearchIndexIfNeeded()
        SpotlightIndexer.reindex(books)
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
        try? modelContext.save()
    }

    // MARK: - Classifications

    @Published private(set) var classifications: [BookClassification] = []

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
        try? modelContext.save()
        return bookmark
    }

    /// Remove a bookmark.
    func removeBookmark(_ bookmark: Bookmark) {
        modelContext.delete(bookmark)
        bookmarks.removeAll { $0.persistentModelID == bookmark.persistentModelID }
        try? modelContext.save()
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
        try? modelContext.save()
    }

    /// Files the user has dismissed ("not a book") — checked during import
    /// to prevent re-importing after rescan.
    var dismissedHashes: Set<String> {
        Set(classifications.filter { $0.decision == .userDismissed }.map { $0.fileHash })
    }

    /// Files sitting in the "Needs Review" tray.
    var needsReview: [BookClassification] {
        classifications.filter { $0.decision == .needsReview }
    }

    /// Look up an existing classification by content hash.
    func classification(for hash: String) -> BookClassification? {
        classifications.first { $0.fileHash == hash }
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
    func isHeroEligible(_ book: Book) -> Bool {
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
    func addClassification(_ classification: BookClassification) {
        // Upsert: replace if already exists for this hash
        if let idx = classifications.firstIndex(where: { $0.fileHash == classification.fileHash }) {
            classifications[idx] = classification
        } else {
            modelContext.insert(classification)
            classifications.append(classification)
        }
        try? modelContext.save()
    }

    /// Move a classification to user-confirmed (add to library from review
    /// tray). Runs the file through the same ImportPipeline extraction
    /// auto-added books get (real PDF title/author, not just the filename) —
    /// a confirmed book is already in the library afterward, so rescans skip
    /// it forever and would never get a chance to backfill real metadata later.
    @MainActor
    func confirmClassification(_ classification: BookClassification) async {
        classification.decision = .userConfirmed
        classification.decidedAt = Date()
        try? modelContext.save()

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
        }
    }

    /// Dismiss a classification ("not a book"). Never resurfaces on rescan.
    func dismissClassification(_ classification: BookClassification) {
        classification.decision = .userDismissed
        classification.decidedAt = Date()
        try? modelContext.save()
    }

    /// Moves the book's underlying source file to the Trash (plus its
    /// cached cover and extracted-text sidecar files, which are deleted
    /// outright — they're Stoa's own derived data, not something worth
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
                try FileManager.default.trashItem(at: book.sourceURL, resultingItemURL: nil)
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
        try? modelContext.save()
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
        modelContext.insert(book)
        try? modelContext.save()
        books.insert(book, at: 0) // newest first
        buildSearchIndexIfNeeded()
        SpotlightIndexer.reindex([book])
    }

    /// Remove a book from the library and persist.
    func remove(_ book: Book) {
        SpotlightIndexer.remove(hash: book.contentHash)
        modelContext.delete(book)
        try? modelContext.save()
        books.removeAll { $0.id == book.id }
    }

    /// Update the tags for a specific book.
    func updateTags(for book: Book, tags: [String]) {
        book.tags = tags
        try? modelContext.save()
    }

    /// Update the shelves a specific book belongs to.
    func updateShelves(for book: Book, shelves: [String]) {
        book.shelfNames = shelves
        try? modelContext.save()
    }

    /// Update reading progress for a specific book.
    func updateProgress(for book: Book, progress: Double) {
        book.readingProgress = min(max(progress, 0), 1.0)
        book.lastOpenedAt = Date()
        try? modelContext.save()
    }

    /// Stamp a book as opened without necessarily changing progress — called
    /// when a reader is presented, so "Continue Reading" picks it up even
    /// before the first page-change fires an updateProgress call.
    func markOpened(_ book: Book) {
        book.lastOpenedAt = Date()
        try? modelContext.save()
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
        try? modelContext.save()
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
        books
            .filter { book in
                guard let progress = book.readingProgress else { return false }
                return progress > 0 && !book.isFinished
            }
            .sorted { (lhs, rhs) in
                (lhs.lastOpenedAt ?? lhs.addedAt) > (rhs.lastOpenedAt ?? rhs.addedAt)
            }
    }

    /// Refresh the books array from the persistent store.
    func refresh() {
        loadBooks()
        loadClassifications()
        loadDismissedDuplicates()
        loadBookmarks()
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
            return (book.contentHash, book.sourceURL, book.format)
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
            await MainActor.run { [weak self] in
                guard let self else { return }
                for result in results {
                    if let book = self.books.first(where: { $0.contentHash == result.hash }) {
                        book.extractedTextPath = result.path
                    }
                }
                try? self.modelContext.save()
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
            for candidate in candidates {
                if Task.isCancelled { return }
                guard let text = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
                if text.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    matches.insert(candidate.hash)
                }
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                self?.contentSearchMatchHashes = matches
            }
        }
    }

    // MARK: - Book lookup

    /// Find a book by its source file path.
    func book(for sourcePath: String) -> Book? {
        books.first { $0.sourcePath == sourcePath }
    }
}
