import Foundation
import SwiftData
import Combine

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

    /// The library folder where cover images (and eventually source files) are stored.
    /// Default: ~/Documents/StoaLibrary
    let libraryFolder: URL

    // MARK: - Init

    init() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StoaLibrary", isDirectory: true)
        self.libraryFolder = folder

        // Create the library folder if it doesn't exist
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let coversFolder = folder.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coversFolder, withIntermediateDirectories: true)

        let schema = Schema([Book.self, BookClassification.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
            self.modelContext = modelContainer.mainContext
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        loadBooks()
        loadClassifications()
    }

    // MARK: - Classifications

    @Published private(set) var classifications: [BookClassification] = []

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
    }

    /// Remove a book from the library and persist.
    func remove(_ book: Book) {
        modelContext.delete(book)
        try? modelContext.save()
        books.removeAll { $0.id == book.id }
    }

    /// Update the tags for a specific book.
    func updateTags(for book: Book, tags: [String]) {
        book.tags = tags
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
    }

    // MARK: - Book lookup

    /// Find a book by its source file path.
    func book(for sourcePath: String) -> Book? {
        books.first { $0.sourcePath == sourcePath }
    }
}
