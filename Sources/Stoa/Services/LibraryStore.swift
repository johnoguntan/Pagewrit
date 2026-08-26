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

        let schema = Schema([Book.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
            self.modelContext = modelContainer.mainContext
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        loadBooks()
    }

    // MARK: - Data access

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
        try? modelContext.save()
    }

    /// Refresh the books array from the persistent store.
    func refresh() {
        loadBooks()
    }

    // MARK: - Book lookup

    /// Find a book by its source file path.
    func book(for sourcePath: String) -> Book? {
        books.first { $0.sourcePath == sourcePath }
    }
}
