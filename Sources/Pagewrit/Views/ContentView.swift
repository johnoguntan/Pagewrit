import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - GridDensity

/// How much of the library grid a viewer sees at once. Persisted across
/// launches via @AppStorage so a chosen density sticks.
enum LibrarySearchScope: String, CaseIterable, Identifiable {
    case everything, title, author, contents

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everything: "Everything"
        case .title: "Title"
        case .author: "Author"
        case .contents: "Inside books"
        }
    }
}

enum GridDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .large: "Large"
        }
    }

    var systemImage: String {
        switch self {
        case .compact: "square.grid.4x3.fill"
        case .comfortable: "square.grid.3x2.fill"
        case .large: "square.grid.2x2.fill"
        }
    }

    /// Minimum tile width fed into the adaptive grid column. Compact is
    /// ~64% of comfortable's width, per the "60-65%" target.
    var columnMinimum: CGFloat {
        switch self {
        case .compact: 96
        case .comfortable: DesignTokens.Grid.columnMinimum
        case .large: 210
        }
    }

    var gridSpacing: CGFloat {
        switch self {
        case .compact: 16
        case .comfortable: DesignTokens.Grid.spacing
        case .large: 28
        }
    }

    /// One line at Compact (there isn't room for two without the grid
    /// feeling cramped); two lines everywhere else, unchanged from before.
    var titleLineLimit: Int {
        self == .compact ? 1 : 2
    }
}

// MARK: - ContentView

/// Library grid view with warm, luxurious palette and serif-accented typography.
/// All values sourced from DesignTokens. Reads from `LibraryStore.books` (real
/// persisted `Book` records) rather than the scanner's raw `DiscoveredFile` list.
struct ContentView: View {
    @EnvironmentObject private var scanner: ScannerService
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var searchScope: LibrarySearchScope = .everything
    @State private var formatFilter: BookFormat?
    @State private var filterStatus: ReadingStatus?
    @State private var filterMinRating = 0
    @State private var filterTag: String?
    @State private var filterSeries: String?
    @State private var showSaveList = false
    @State private var newListName = ""
    @AppStorage("pagewrit.savedLists") private var savedListsRaw = ""
    @State private var sortOrder: SortOption = .recentlyAdded
    @AppStorage("pagewrit.libraryGrouping") private var groupingRaw = "reading"
    @State private var importTaskID: UUID?
    @AppStorage("stoa.gridDensity") private var gridDensityRaw: String = GridDensity.comfortable.rawValue
    @State private var showDownloadBooks = false
    @AppStorage("stoa.hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("pagewrit.hasMetDog") private var hasMetDog = false
    /// Sidebar sections folded away. Long lists start folded.
    @AppStorage("pagewrit.sidebarCollapsed") private var collapsedSectionsRaw = "authors,tags"
    @AppStorage("pagewrit.showDog") private var showDogSetting = true
    @State private var showDogIntro = false
    @State private var showOnboarding = false
    @State private var navigationPath = NavigationPath()

    private var gridDensity: GridDensity {
        GridDensity(rawValue: gridDensityRaw) ?? .comfortable
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case title
        case author
        case recentlyAdded
        case format
        case rating

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .title: "Title"
            case .author: "Author"
            case .recentlyAdded: "Recently Added"
            case .format: "Format"
            case .rating: "Rating"
            }
        }

        var systemImage: String {
            switch self {
            case .title: "textformat.abc"
            case .author: "person"
            case .recentlyAdded: "clock"
            case .format: "doc.plaintext"
            case .rating: "dog"
            }
        }
    }

    // MARK: - Derived-data cache
    //
    // Filtering and sorting a big library (with locale-aware title compares)
    // is expensive, and the old code redid it several times on every screen
    // update — every hover, click and heart. It now runs once, and again only
    // when something it depends on actually changes.

    private final class DerivedCache {
        var key: DerivedKey?
        var sorted: [Book] = []
        var sections: [(title: String, books: [Book])] = []
        var hashes: Set<String> = []
        var heroKey: DerivedKey?
        var heroLight = -1
        var hero: [(book: Book, kind: HeroKind)] = []
        var listsKey = -1
        var tags: [String] = []
        var series: [String] = []
        var shelves: [String] = []
        var authors: [String] = []
    }

    private struct DerivedKey: Equatable {
        var version: Int
        var count: Int
        var selection: SidebarSelection?
        var search: String
        var scope: LibrarySearchScope
        var sort: SortOption
        var filter: LibraryFilter
        var hits: Int
        var highlights: Int
        var lists: String
        var light: Int
        var grouping: String
    }

    @State private var cache = DerivedCache()

    /// Favorites, status, ratings and saved lists change which books show,
    /// so those views re-run when a small per-book change happens.
    private var lightRelevant: Bool {
        switch sidebarSelection {
        case .favorites, .status, .topRated, .savedList: return true
        default: return sortOrder == .rating || !currentFilter.isEmpty || grouping == .reading
        }
    }

    private var derivedKey: DerivedKey {
        DerivedKey(
            version: library.dataVersion, count: library.books.count,
            selection: sidebarSelection, search: searchText, scope: searchScope,
            sort: sortOrder, filter: currentFilter,
            hits: library.contentSearchMatchHashes.count,
            highlights: library.highlights.count,
            lists: savedLists.map { $0.id.uuidString }.joined(),
            light: lightRelevant ? library.lightVersion : 0,
            grouping: groupingRaw
        )
    }

    private func refreshDerived() {
        let key = derivedKey
        guard cache.key != key else { return }
        cache.key = key
        let sorted = computeSortedBooks
        cache.sorted = sorted
        cache.hashes = Set(sorted.map(\.contentHash))
        cache.sections = sections(for: sorted)
    }

    /// How the grid is split up. By reading (the default) puts what you are
    /// reading first and paperwork last; by format is the older file view.
    enum LibraryGrouping: String, CaseIterable, Identifiable {
        case reading, format, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reading: return "Reading"
            case .format: return "Format"
            case .none: return "None"
            }
        }
    }

    private var grouping: LibraryGrouping { LibraryGrouping(rawValue: groupingRaw) ?? .reading }

    private func sections(for sorted: [Book]) -> [(title: String, books: [Book])] {
        switch grouping {
        case .none:
            return sorted.isEmpty ? [] : [("All", sorted)]
        case .format:
            let grouped = Dictionary(grouping: sorted) { $0.format }
            return BookFormat.allCases.compactMap { format in
                guard let books = grouped[format], !books.isEmpty else { return nil }
                return (format.sectionTitle, books)
            }
        case .reading:
            var reading: [Book] = [], upNext: [Book] = [], finished: [Book] = [], documents: [Book] = []
            for book in sorted {
                guard library.isBookLike(book) else { documents.append(book); continue }
                switch book.status {
                case .reading: reading.append(book)
                case .unread: upNext.append(book)
                case .finished: finished.append(book)
                }
            }
            let all: [(String, [Book])] = [
                ("Reading", reading), ("Up Next", upNext),
                ("Finished", finished), ("Documents & Slides", documents)
            ]
            return all.filter { !$0.1.isEmpty }.map { (title: $0.0, books: $0.1) }
        }
    }

    private func refreshLists() {
        let k = library.dataVersion &* 100_003 &+ library.books.count
        guard cache.listsKey != k else { return }
        cache.listsKey = k
        cache.tags = computeAllTags
        cache.series = computeAllSeries
        cache.shelves = computeAllShelves
        cache.authors = computeAllAuthors
    }

    private var sortedBooks: [Book] { refreshDerived(); return cache.sorted }
    private var booksByFormat: [(title: String, books: [Book])] { refreshDerived(); return cache.sections }
    private var allTags: [String] { refreshLists(); return cache.tags }
    private var allSeries: [String] { refreshLists(); return cache.series }
    private var allShelves: [String] { refreshLists(); return cache.shelves }
    private var allAuthors: [String] { refreshLists(); return cache.authors }

    private var heroEntries: [(book: Book, kind: HeroKind)] {
        refreshDerived()
        if cache.heroKey == cache.key && cache.heroLight == library.lightVersion { return cache.hero }
        cache.heroKey = cache.key
        cache.heroLight = library.lightVersion
        cache.hero = computeHeroEntries
        return cache.hero
    }

    // MARK: - Computed data

    /// Books scoped by the sidebar selection, then narrowed by search.
    private var filteredBooks: [Book] {
        var books = library.books

        switch sidebarSelection {
        case .library, .needsReview, .duplicates, .recycleBin, .bookmarks, .invoices, .none:
            break  // show all books
        case .favorites:
            books = books.filter(\.isFavorite)
        case .status(let raw):
            books = books.filter { $0.status.rawValue == raw }
        case .topRated:
            books = books.filter { $0.rating > 0 }
        case .highlighted:
            let marked = Set(library.highlights.map(\.bookHash))
            books = books.filter { marked.contains($0.contentHash) }
        case .savedList(let id):
            if let list = savedLists.first(where: { $0.id.uuidString == id }) {
                books = books.filter { list.filter.matches($0) }
            }
        case .series(let name):
            books = books.filter { $0.seriesName == name }
                .sorted { ($0.seriesIndex ?? .greatestFiniteMagnitude) < ($1.seriesIndex ?? .greatestFiniteMagnitude) }
        case .folder(let path):
            let folderPath = path.hasSuffix("/") ? path : path + "/"
            books = books.filter { $0.sourcePath.hasPrefix(folderPath) }
        case .format(let rawValue):
            if let format = BookFormat(rawValue: rawValue) {
                books = books.filter { $0.format == format }
            }
        case .tag(let tag):
            books = books.filter { $0.tags.contains(tag) }
        case .author(let name):
            books = books.filter { $0.displayAuthor == name }
        case .shelf(let shelf):
            books = books.filter { $0.shelfNames.contains(shelf) }
        }

        if let formatFilter {
            books = books.filter { $0.format == formatFilter }
        }
        if !currentFilter.isEmpty {
            let extra = LibraryFilter(status: filterStatus?.rawValue, minRating: filterMinRating,
                                      tag: filterTag, series: filterSeries)
            books = books.filter { extra.matches($0) }
        }

        let terms = searchTerms
        guard !terms.isEmpty else { return books }
        return books.filter { searchRank(of: $0, terms: terms) > 0 }
    }

    /// Words in the search box; every word has to match (in any field).
    private var searchTerms: [String] {
        searchText.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// 0 = no match. Higher = better: title start > title > author > tag > text.
    private func searchRank(of book: Book, terms: [String]) -> Int {
        let title = Self.fold(book.title)
        let author = Self.fold(book.author ?? "")
        let tags = book.tags.map(Self.fold)
        let inContent = library.contentSearchMatchHashes.contains(book.contentHash)
        var total = 0
        for raw in terms {
            let term = Self.fold(raw)
            var score = 0
            switch searchScope {
            case .everything:
                if title.hasPrefix(term) { score = 100 }
                else if title.contains(term) { score = 80 }
                else if author.contains(term) { score = 60 }
                else if tags.contains(where: { $0.contains(term) }) { score = 40 }
                else if inContent { score = 20 }
            case .title:
                if title.hasPrefix(term) { score = 100 } else if title.contains(term) { score = 80 }
            case .author:
                if author.contains(term) { score = 60 }
            case .contents:
                if inContent { score = 20 }
            }
            if score == 0 { return 0 }
            total += score
        }
        return total
    }

    /// Every distinct tag across the library, alphabetically, for the
    /// sidebar's TAGS section — only shown once at least one book has one.
    private var computeAllTags: [String] {
        Set(library.books.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every distinct shelf across the library, alphabetically, for the
    /// sidebar's SHELVES section — user-created groupings, same shape as
    /// tags but meant for one-book-per-shelf-at-a-time organization
    /// (a series, a to-read pile) rather than freeform labeling.
    private var computeAllSeries: [String] {
        Set(library.books.compactMap(\.seriesName).filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var computeAllShelves: [String] {
        Set(library.books.flatMap(\.shelfNames)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every distinct author across the library, alphabetically, for the
    /// sidebar's AUTHORS section — books with no author (or a blank one)
    /// have nothing to browse by, so they're simply left out.
    private var computeAllAuthors: [String] {
        let names = library.books.compactMap { $0.displayAuthor }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var computeSortedBooks: [Book] {
        if !searchTerms.isEmpty {
            let terms = searchTerms
            return filteredBooks.sorted {
                let a = searchRank(of: $0, terms: terms), b = searchRank(of: $1, terms: terms)
                if a != b { return a > b }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        switch sortOrder {
        case .title:
            return filteredBooks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return filteredBooks.sorted {
                ($0.author ?? "ZZZ").localizedStandardCompare($1.author ?? "ZZZ") == .orderedAscending
            }
        case .recentlyAdded:
            return filteredBooks.sorted { $0.addedAt > $1.addedAt }
        case .format:
            return filteredBooks.sorted { $0.formatRaw.localizedStandardCompare($1.formatRaw) == .orderedAscending }
        case .rating:
            return filteredBooks.sorted {
                if $0.rating != $1.rating { return $0.rating > $1.rating }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }


    /// Most recently added book for the hero band.
    ///
    /// `max(by:)` returns the element for which the predicate never says
    /// "this one comes after that one" — i.e. the predicate must mean
    /// "is less than", not "is greater than". `{ $0.addedAt > $1.addedAt }`
    /// (the previous version of this line) actually asked max(by:) for the
    /// *oldest* book, which is why Recently Added kept showing an old PDF
    /// instead of whatever was just added.
    private var mostRecentBook: Book? {
        library.books
            .filter {
                visibleHashes.contains($0.contentHash) && library.isHeroEligible($0)
                    // Something you already opened is not "new" any more.
                    && $0.lastOpenedAt == nil && ($0.readingProgress ?? 0) == 0
            }
            .max { $0.addedAt < $1.addedAt }
    }

    /// The book to resume, if anything is in progress.
    private var continueReadingBook: Book? {
        continueReadingBooks.first
    }

    /// Up to two books you are in the middle of, most recently opened first,
    /// so a comic you picked up today sits beside the novel you are reading.
    private var continueReadingBooks: [Book] {
        Array(library.continueReading
            .filter { visibleHashes.contains($0.contentHash) && library.isHeroEligible($0) }
            .prefix(2))
    }

    /// The featured rail belongs to whatever section is open: on All Books it
    /// draws from everything, in a format or folder it draws only from that
    /// section, and it stays out of the way if the section has nothing to feature.
    private var visibleHashes: Set<String> {
        refreshDerived()
        return cache.hashes
    }

    /// A different unread book spotlighted each calendar day, rather
    /// than always the oldest thing on the shelf — a rotating "still on
    /// your shelf" nudge instead of a static one. Excludes whatever's
    /// already shown earlier in the rail so the row never repeats a
    /// book. Keyed by contentHash (not Book's SwiftData id) to match how
    /// the rest of the app already identifies a book — see
    /// SpotlightIndexer, dedup, etc.
    ///
    /// The pick is seeded from today's date, not truly random: reopening
    /// the app, rescanning, or relaunching mid-day all land on the same
    /// book, and only rolls over to a new one at local midnight. Sorting
    /// the eligible pool by contentHash first (SwiftData's fetch order
    /// isn't guaranteed stable) guarantees the same day always maps to
    /// the same index, and therefore the same book.
    private func discoverBook(excluding shownHashes: Set<String>) -> Book? {
        let eligible = library.books
            .filter {
                !shownHashes.contains($0.contentHash)
                    && visibleHashes.contains($0.contentHash)
                    // "Still on your shelf" means not started: not even opened.
                    && $0.status == .unread
                    && library.isHeroEligible($0)
            }
            .sorted { $0.contentHash < $1.contentHash }
        guard !eligible.isEmpty else { return nil }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        var rng = DailySeededGenerator(date: startOfDay)
        return eligible.randomElement(using: &rng)
    }

    /// Cards for the hero rail, in display order. Continue Reading leads
    /// when there's something in progress, then Recently Added, then a
    /// Discover pick — each skipped if it would repeat a book already
    /// shown earlier in the row. More categories (a format or tag
    /// spotlight) can extend this list later without touching the
    /// rail's layout.
    private var computeHeroEntries: [(book: Book, kind: HeroKind)] {
        var entries: [(book: Book, kind: HeroKind)] = []
        var shownHashes: Set<String> = []

        for resuming in continueReadingBooks {
            entries.append((resuming, .continueReading))
            shownHashes.insert(resuming.contentHash)
        }
        if let mostRecent = mostRecentBook, !shownHashes.contains(mostRecent.contentHash) {
            entries.append((mostRecent, .recentlyAdded))
            shownHashes.insert(mostRecent.contentHash)
        }
        if let discover = discoverBook(excluding: shownHashes) {
            entries.append((discover, .discover))
        }
        return entries
    }

    // MARK: - Grid layout

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: gridDensity.columnMinimum),
                spacing: gridDensity.gridSpacing
            )
        ]
    }

    // MARK: - Body

    // The window is built in three parts so the compiler can type-check each
    // one quickly.
    private var libraryNavigation: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // navigationDestination(for:) must live inside the detail
            // column's own navigation stack, not chained onto the
            // NavigationSplitView itself — attached there, SwiftUI logs
            // "misplaced navigationDestination... it will be ignored" and
            // NavigationLink(value:) taps silently do nothing.
            NavigationStack(path: $navigationPath) {
                detailContent
                    .navigationDestination(for: Book.self) { book in
                        BookDetailView(book: book)
                            .environmentObject(library)
                    }
            }
        }
        // The window title names the list you are looking at.
        .navigationTitle(sidebarSelection == .library ? "Library" : currentListTitle)
        // Sidebar selection swaps out `detailContent`, but the detail
        // column's own NavigationStack keeps its push stack regardless \u{2014}
        // without this, picking a sidebar item while a book detail page is
        // pushed on top just silently does nothing, since the pushed page
        // stays on screen either way.
        .onChange(of: sidebarSelection) { _, _ in
            navigationPath = NavigationPath()
            // Filters belong to the page they were set on: leaving it clears them.
            clearFilters()
            showJumpToTop = false
        }
        .searchable(text: $searchText, prompt: "Search titles, authors, tags and text")
        // The Title / Author / Inside books choice only appears once you
        // start typing, when it actually means something.
        .searchScopes($searchScope, activation: .onTextEntry) {
            ForEach(LibrarySearchScope.allCases) { scope in
                Text(scope.label).tag(scope)
            }
        }
        .searchSuggestions {
            if !searchText.isEmpty { searchSuggestionItems }
        }
        .navigationSubtitle(librarySubtitle)
        .onChange(of: searchText) { _, newValue in
            library.searchContent(scopeUsesContent ? newValue : "")
        }
        .onChange(of: searchScope) { _, _ in
            library.searchContent(scopeUsesContent ? searchText : "")
        }
    }

    private var libraryWithEvents: some View {
        libraryNavigation
        .onReceive(NotificationCenter.default.publisher(for: .stoaOpenBookFromSpotlight)) { note in
            guard let hash = note.object as? String,
                  library.books.contains(where: { $0.contentHash == hash })
            else { return }
            openWindow(id: "reader", value: hash)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stoaBooksDownloaded)) { note in
            // Import just the one file that was downloaded, not a full
            // rescan — walking every watched folder and re-hashing all
            // ~40+ existing books for one new file is what made a single
            // download feel like it triggered a long "scanning" pass.
            if let url = note.object as? URL {
                Task { await importSingleFile(at: url) }
            } else {
                Task { await rescanAndImport(quiet: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stoaRequestFullRescan)) { _ in
            Task { await rescanAndImport() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pagewritGo)) { note in
            let target: SidebarSelection?
            switch note.object as? String {
            case "library": target = .library
            case "favorites": target = .favorites
            case "needsReview": target = library.needsReview.isEmpty ? nil : .needsReview
            case "duplicates": target = library.duplicateGroups.isEmpty ? nil : .duplicates
            case "highlighted": target = library.highlights.isEmpty ? nil : .highlighted
            case "bookmarks": target = library.bookmarks.isEmpty ? nil : .bookmarks
            case "invoices": target = .invoices
            case "recycleBin": target = library.recycleBin.isEmpty ? nil : .recycleBin
            default: target = nil
            }
            guard let target else { return }
            chooseSidebar(target)
        }
        // New files in a watched folder are picked up in the background, with
        // no animation.
        .onReceive(NotificationCenter.default.publisher(for: .stoaQuietRescan)) { _ in
            Task { await rescanAndImport(quiet: true) }
        }
        // Coming back to the app: the full, animated rescan runs only if the
        // last one was on an earlier day or more than three hours ago.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard hasSeenOnboarding, !scanner.allWatchedFolders.isEmpty, fullScanIsDue else { return }
            Task { await rescanAndImport() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                formatFilterMenu
                viewMenu
                Button {
                    showDownloadBooks = true
                } label: {
                    toolbarChip("Get Books", systemImage: "arrow.down.circle")
                }
                .help("Search and download free public-domain books")
                Menu {
                    Button {
                        Task { await rescanAndImport() }
                    } label: {
                        Label("Rescan Folders", systemImage: "arrow.clockwise")
                    }
                    .disabled(scanner.isScanning || library.isImporting)
                    Button {
                        exportCurrentListAsMarkdown()
                    } label: {
                        Label("Export This List\u{2026}", systemImage: "square.and.arrow.up")
                    }
                    .disabled(sortedBooks.isEmpty)
                } label: {
                    if (scanner.isScanning || library.isImporting) && !quietScan {
                        ProgressView().controlSize(.small)
                    } else {
                        toolbarChip("More", systemImage: "ellipsis.circle")
                    }
                }
                .help("Rescan, export")
            }
            // Say what each control is, not just draw an icon.
        }
        .tint(DesignTokens.accentFill)
        .scrollIndicators(.hidden)
        .background(DesignTokens.background.ignoresSafeArea())
        .background(WindowShadowFixer())
    }

    var body: some View {
        libraryWithEvents
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay { if isDropTargeted { dropOverlay.allowsHitTesting(false) } }
        .overlay(alignment: .bottom) { dropToast }
        .overlay { CelebrationLayer() }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .task(id: library.books.count) {
            // Quietly look inside new documents for invoices, once each.
            await InvoiceStore.shared.scan(books: library.books)
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task { await addFiles([url], openFirst: true) }
        }
        .alert(
            "Couldn't save your library",
            isPresented: Binding(
                get: { library.lastSaveError != nil },
                set: { if !$0 { library.clearSaveError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.lastSaveError ?? "")
        }
        .task {
            ScrollActivity.start()
            if hasSeenOnboarding {
                // First open of the day (or after a long gap): the full, animated
                // scan. Any other launch only checks quietly for new files.
                await rescanAndImport(quiet: !fullScanIsDue)
                library.backfillAddedDates()
                library.autoBackupIfDue()
            } else if !library.books.isEmpty {
                // A library from before this screen existed — treat as
                // already onboarded rather than showing it retroactively.
                hasSeenOnboarding = true
            } else {
                showOnboarding = true
            }
        }
        // The very first scan is what triggers macOS's native per-folder
        // access prompts — deferred until this is dismissed so those
        // dialogs land right after an explanation, not at cold launch.
        .sheet(isPresented: $showOnboarding, onDismiss: {
            Task {
                if scanner.allWatchedFolders.isEmpty { scanner.chooseStandardFolders() }
                await rescanAndImport()
            }
        }) {
            OnboardingView {
                hasSeenOnboarding = true
                showOnboarding = false
            }
        }
        // People who were here before the dog meet him once, on his own.
        .task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if hasSeenOnboarding && !hasMetDog && showDogSetting && !showOnboarding {
                showDogIntro = true
            }
        }
        .sheet(isPresented: $showDogIntro, onDismiss: { hasMetDog = true }) {
            DogIntroView {
                hasMetDog = true
                showDogIntro = false
            }
        }
        .onChange(of: library.showWelcome) { _, wanted in
            if wanted {
                showOnboarding = true
                library.showWelcome = false
            }
        }
        // Settings floats over the library: click anywhere outside it,
        // press Esc or use Done to close it.
        .overlay {
            if library.showSettings {
                ZStack {
                    Color.black.opacity(colorScheme == .dark ? 0.45 : 0.22)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { library.showSettings = false }
                        .accessibilityLabel("Close settings")
                        .accessibilityAddTraits(.isButton)
                    SettingsView()
                        .environmentObject(scanner)
                        .environmentObject(library)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
                        .padding(24)
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: library.showSettings)
        .sheet(isPresented: $showDownloadBooks) {
            DownloadBooksView()
        }
    }

    // MARK: - Export

    /// A human-readable label for whatever the sidebar is currently
    /// scoped to, used as both the exported list's title and its default
    /// filename.
    private var currentListTitle: String {
        switch sidebarSelection {
        case .library, .none:
            return "All Books"
        case .needsReview: return "Needs Review"
        case .duplicates: return "Duplicates"
        case .recycleBin: return "Recycle Bin"
        case .bookmarks: return "Bookmarks"
        case .invoices: return "Invoices"
        case .favorites:
            return "Favorites"
        case .status(let raw):
            if raw == ReadingStatus.reading.rawValue { return "Reading Now" }
            return ReadingStatus(rawValue: raw)?.label ?? "Books"
        case .topRated:
            return "Rated"
        case .highlighted:
            return "Highlights & Notes"
        case .series(let name):
            return name
        case .savedList(let id):
            return savedLists.first(where: { $0.id.uuidString == id })?.name ?? "List"
        case .folder(let path):
            return ScannerService.displayName(for: URL(fileURLWithPath: path))
        case .format(let rawValue):
            return BookFormat(rawValue: rawValue)?.sectionTitle ?? "Books"
        case .tag(let tag):
            return "#\(tag)"
        case .author(let name):
            return name
        case .shelf(let shelf):
            return shelf
        }
    }

    private func exportCurrentListAsMarkdown() {
        let markdown = MarkdownExporter.export(books: sortedBooks, listTitle: currentListTitle)

        let panel = NSSavePanel()
        panel.title = "Export Reading List"
        panel.nameFieldStringValue = currentListTitle
            .replacingOccurrences(of: "/", with: "-")
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Scan + Import pipeline

    /// Import one already-known file directly — used for a book that was
    /// just downloaded, where a full rescanAndImport() would walk every
    /// watched folder and re-hash every existing book just to notice the
    /// one new file. PDFs still get classified so a low-quality PDF landed
    /// this way goes to Needs Review rather than skipping the check that
    /// rescanAndImport() applies to everything else.
    // MARK: - Files handed to the app directly

    private var dropOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 28, weight: .regular))
            Text("Drop to add to Pagewrit")
                .font(DesignTokens.sansFont(size: 15, weight: .medium))
        }
        .foregroundStyle(DesignTokens.accentInk)
        .padding(.horizontal, 36).padding(.vertical, 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DesignTokens.accent.opacity(0.45), lineWidth: 2)
                .padding(8)
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Drop handling

    private func showDropMessage(_ text: String) {
        withAnimation { dropMessage = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation { if dropMessage == text { dropMessage = nil } }
        }
    }

    @ViewBuilder
    private var dropToast: some View {
        if let dropMessage {
            Text(dropMessage)
                .font(DesignTokens.sansFont(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .padding(.bottom, 28)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    /// Supported files from a mix of files and folders.
    /// Files dragged in from Finder (or any app). Each dropped item is asked
    /// for its file URL directly, which is the most dependable way to receive
    /// files on macOS, including under the App Sandbox.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            if urls.isEmpty {
                showDropMessage("Pagewrit couldn\u{2019}t read that file. Try Add Books from the menu.")
            } else {
                await addFiles(urls, openFirst: false)
            }
        }
        return true
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else if let ns = item as? NSURL {
                    url = ns as URL
                }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    private func supportedFiles(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let walker = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = walker?.nextObject() as? URL {
                    if BookFormat(fileExtension: item.pathExtension) != nil { found.append(item) }
                }
            } else if BookFormat(fileExtension: url.pathExtension) != nil {
                found.append(url)
            }
        }
        return found
    }

    /// Adds files the reader handed over directly: dropped on the window or
    /// Dock icon, or opened from Finder with Open With or a double-click.
    /// These are explicit choices, so they skip the review step. A file that
    /// lives outside the watched folders is copied into the library folder,
    /// so it stays readable after the app restarts.
    private func addFiles(_ urls: [URL], openFirst: Bool) async {
        let files = supportedFiles(in: urls)
        guard !files.isEmpty else {
            showDropMessage("That file type isn\u{2019}t supported yet")
            return
        }
        var firstHash: String?
        var addedCount = 0
        var alreadyCount = 0
        var unreadableCount = 0

        for original in files {
            let accessing = original.startAccessingSecurityScopedResource()
            defer { if accessing { original.stopAccessingSecurityScopedResource() } }

            let hash = await Task.detached(priority: .userInitiated) {
                ImportPipeline.contentHash(for: original)
            }.value
            guard !hash.isEmpty else { unreadableCount += 1; continue }
            if firstHash == nil { firstHash = hash }
            if library.contains(hash: hash) { alreadyCount += 1; continue }

            var url = original
            let libraryPath = library.libraryFolder.path + "/"
            let isKnownLocation = original.path.hasPrefix(libraryPath)
                || scanner.allWatchedFolders.contains { original.path.hasPrefix($0.path + "/") }
            if !isKnownLocation {
                let folder = library.libraryFolder.appendingPathComponent("Added", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                // Copying a big file can take seconds, so it happens off the main thread.
                let copied: URL? = await Task.detached(priority: .userInitiated) {
                    var target = folder.appendingPathComponent(original.lastPathComponent)
                    var counter = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        let name = original.deletingPathExtension().lastPathComponent
                        target = folder.appendingPathComponent("\(name) \(counter).\(original.pathExtension)")
                        counter += 1
                    }
                    return (try? FileManager.default.copyItem(at: original, to: target)) != nil ? target : nil
                }.value
                if let copied { url = copied }
            }

            guard let format = BookFormat(fileExtension: url.pathExtension) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let file = DiscoveredFile(
                url: url, format: format,
                sizeBytes: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate)
            if let book = await ImportPipeline.importFile(file, libraryFolder: library.libraryFolder, precomputedHash: hash) {
                library.add(book)
                addedCount += 1
            }
        }

        if addedCount > 0 {
            DogPet.shared.cheer("Fresh books! Sniffing them now.")
            showDropMessage(addedCount == 1 ? "Added 1 book to your library" : "Added \(addedCount) books to your library")
        } else if alreadyCount > 0 {
            showDropMessage(alreadyCount == 1 ? "That book is already in your library" : "Those books are already in your library")
        } else if unreadableCount > 0 {
            showDropMessage("Pagewrit couldn\u{2019}t read that file. Try Add Books from the menu.")
        }

        if openFirst, let firstHash, library.contains(hash: firstHash) {
            openWindow(id: "reader", value: firstHash)
        }
    }

    private func importSingleFile(at url: URL) async {
        guard let format = BookFormat(fileExtension: url.pathExtension) else { return }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let file = DiscoveredFile(
            url: url,
            format: format,
            sizeBytes: Int64(values?.fileSize ?? 0),
            modifiedAt: values?.contentModificationDate
        )

        let hash = await Task.detached(priority: .userInitiated) {
            ImportPipeline.contentHash(for: file.url)
        }.value

        guard !hash.isEmpty else { return }
        guard !library.contains(hash: hash), library.classification(for: hash) == nil else { return }

        if let result = await ImportPipeline.classifyFile(file, library: library, precomputedHash: hash) {
            switch result.classification.decision {
            case .autoAdded, .userConfirmed:
                if let book = await ImportPipeline.importFile(file, libraryFolder: library.libraryFolder, precomputedHash: hash) {
                    library.add(book)
                }
            case .needsReview, .autoSkipped, .userDismissed:
                break
            }
        } else if let book = await ImportPipeline.importFile(file, libraryFolder: library.libraryFolder, precomputedHash: hash) {
            library.add(book)
        }
    }

    /// Scan for files, classify PDFs, and import books into the library.
    /// EPUB/CBZ bypass classification; PDFs are scored and routed to
    /// auto-add, needs-review, or auto-skip.
    ///
    /// Each file's content hash is computed exactly once per rescan (off the
    /// main thread) and threaded through both the membership check and the
    /// classify/import calls below, rather than re-hashing the same file's
    /// full contents two or three times in a row.
    private func rescanAndImport(quiet: Bool = false) async {
        // Folder changes can arrive while a scan is running; remember them
        // and go round again instead of dropping them.
        guard !isRescanning, !scanner.isScanning, !library.isImporting else {
            rescanPending = true
            return
        }
        isRescanning = true
        quietScan = quiet
        repeat {
            rescanPending = false
            await performRescan()
            // Any extra rounds (folder changes during the scan) run quietly.
            quietScan = true
        } while rescanPending
        if !quiet {
            UserDefaults.standard.set(Date(), forKey: Self.lastFullScanKey)
        }
        quietScan = false
        isRescanning = false
    }

    private static let lastFullScanKey = "pagewrit.lastFullScan"
    /// How long the app waits before another animated full rescan.
    private static let fullScanCooldown: TimeInterval = 3 * 60 * 60

    /// True on the first open of a day, or when the last full scan was more
    /// than three hours ago.
    private var fullScanIsDue: Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastFullScanKey) as? Date else { return true }
        if !Calendar.current.isDateInToday(last) { return true }
        return Date().timeIntervalSince(last) > Self.fullScanCooldown
    }

    private func performRescan() async {
        await scanner.scan()

        // A file that is still being written (a download in progress) would
        // be hashed half-finished; leave it and look again shortly.
        let now = Date()
        let settleDate = now.addingTimeInterval(-6)
        let candidates = scanner.discoveredFiles.filter {
            let modified = $0.modifiedAt ?? .distantPast
            // A date in the future is a wrong clock on the file, not a download.
            return modified < settleDate || modified > now.addingTimeInterval(60)
        }
        // Look again once, quietly, for files still being written. This used
        // to start a full, visible scan every 8 seconds for as long as any
        // file kept changing, which looked like scanning that never ended.
        if candidates.count < scanner.discoveredFiles.count, !settleCheckScheduled {
            settleCheckScheduled = true
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                settleCheckScheduled = false
                await rescanAndImport(quiet: true)
            }
        }

        let hashedFiles: [(file: DiscoveredFile, hash: String)] = await withTaskGroup(of: (DiscoveredFile, String).self) { group in
            for file in candidates {
                group.addTask {
                    let hash = await Task.detached(priority: .userInitiated) {
                        ImportPipeline.cachedContentHash(for: file)
                    }.value
                    return (file, hash)
                }
            }
            var results: [(DiscoveredFile, String)] = []
            for await pair in group {
                results.append(pair)
            }
            return results
        }

        // A file we couldn't read has no hash yet; skip it now and pick it up
        // on a later scan instead of filing it under a shared empty identity.
        let newFiles = hashedFiles.filter { _, hash in
            !hash.isEmpty && !library.contains(hash: hash) && library.classification(for: hash) == nil
        }

        guard !newFiles.isEmpty else { return }

        library.isImporting = true
        importTaskID = UUID()

        for (index, entry) in newFiles.enumerated() {
            let (file, hash) = entry
            library.importProgress = Double(index) / Double(newFiles.count)

            // Classify the file (EPUB/CBZ return nil — skip classification)
            if let result = await ImportPipeline.classifyFile(file, library: library, precomputedHash: hash) {
                switch result.classification.decision {
                case .autoAdded, .userConfirmed:
                    // Import as a book
                    if let book = await ImportPipeline.importFile(file, libraryFolder: library.libraryFolder, precomputedHash: hash) {
                        library.add(book)
                    }
                case .needsReview:
                    // Leave in the review tray — don't import to library yet
                    break
                case .autoSkipped, .userDismissed:
                    // Don't import
                    break
                }
            } else {
                // EPUB/CBZ or already classified — import directly
                if let book = await ImportPipeline.importFile(file, libraryFolder: library.libraryFolder, precomputedHash: hash) {
                    library.add(book)
                }
            }
        }

        library.importProgress = 1.0
        library.isImporting = false
    }

    // MARK: - Toolbar menus

    @ViewBuilder
    private var searchSuggestionItems: some View {
        let q = Self.fold(searchText)
        let titles = library.books.filter { Self.fold($0.title).contains(q) }.prefix(4)
        let authors = allAuthors.filter { Self.fold($0).contains(q) }.prefix(3)
        let tags = allTags.filter { Self.fold($0).contains(q) }.prefix(3)
        ForEach(Array(titles), id: \.contentHash) { book in
            Label(book.title, systemImage: "book.closed").searchCompletion(book.title)
        }
        ForEach(Array(authors), id: \.self) { name in
            Label(name, systemImage: "person").searchCompletion(name)
        }
        ForEach(Array(tags), id: \.self) { tag in
            Label(tag, systemImage: "tag").searchCompletion(tag)
        }
    }

    private var scopeUsesContent: Bool {
        searchScope == .everything || searchScope == .contents
    }

    private var librarySubtitle: String {
        let n = sortedBooks.count
        var parts = ["\(n) book\(n == 1 ? "" : "s")"]
        if let formatFilter { parts.append(formatFilter.label) }
        if let filterStatus { parts.append(filterStatus.label) }
        if filterMinRating > 0 { parts.append("\(filterMinRating)+ dogs") }
        if let filterTag { parts.append("#\(filterTag)") }
        if let filterSeries { parts.append(filterSeries) }
        if !searchText.isEmpty { parts.append("matching \u{201C}\(searchText)\u{201D}") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Icon and word together, drawn by us so the toolbar adds nothing underneath.
    private func toolbarChip(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
        }
    }

    // MARK: - Filters

    /// Decoded once per change of the stored text, not on every screen update.
    private static var savedListsCache: (raw: String, lists: [SavedList]) = ("", [])

    private var savedLists: [SavedList] {
        if Self.savedListsCache.raw == savedListsRaw { return Self.savedListsCache.lists }
        var lists: [SavedList] = []
        if !savedListsRaw.isEmpty, let data = savedListsRaw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SavedList].self, from: data) {
            lists = decoded
        }
        Self.savedListsCache = (savedListsRaw, lists)
        return lists
    }

    private func storeSavedLists(_ lists: [SavedList]) {
        if let data = try? JSONEncoder().encode(lists), let text = String(data: data, encoding: .utf8) {
            savedListsRaw = text
        }
    }

    /// Everything the toolbar Filter menu has set, as one value.
    private var currentFilter: LibraryFilter {
        LibraryFilter(format: formatFilter?.rawValue, status: filterStatus?.rawValue,
                      minRating: filterMinRating, tag: filterTag, series: filterSeries)
    }

    private var activeFilterCount: Int {
        [formatFilter != nil, filterStatus != nil, filterMinRating > 0, filterTag != nil, filterSeries != nil]
            .filter { $0 }.count
    }

    private func clearFilters() {
        formatFilter = nil
        filterStatus = nil
        filterMinRating = 0
        filterTag = nil
        filterSeries = nil
    }

    private var formatFilterMenu: some View {
        Menu {
            Menu("Format") {
                ForEach(BookFormat.allCases, id: \.self) { format in
                    Button {
                        formatFilter = (formatFilter == format) ? nil : format
                    } label: {
                        Label(format.label, systemImage: formatFilter == format ? "checkmark" : "doc")
                    }
                }
            }
            Menu("Status") {
                ForEach(ReadingStatus.allCases) { status in
                    Button {
                        filterStatus = (filterStatus == status) ? nil : status
                    } label: {
                        Label(status.label, systemImage: filterStatus == status ? "checkmark" : status.systemImage)
                    }
                }
            }
            Menu("Rating") {
                ForEach([5, 4, 3, 2, 1], id: \.self) { n in
                    Button {
                        filterMinRating = (filterMinRating == n) ? 0 : n
                    } label: {
                        Label(n == 1 ? "Any rating" : "\(n) dogs or more",
                              systemImage: filterMinRating == n ? "checkmark" : "dog")
                    }
                }
            }
            if !allTags.isEmpty {
                Menu("Tag") {
                    ForEach(allTags, id: \.self) { tag in
                        Button {
                            filterTag = (filterTag == tag) ? nil : tag
                        } label: {
                            Label(tag, systemImage: filterTag == tag ? "checkmark" : "tag")
                        }
                    }
                }
            }
            if !allSeries.isEmpty {
                Menu("Series") {
                    ForEach(allSeries, id: \.self) { name in
                        Button {
                            filterSeries = (filterSeries == name) ? nil : name
                        } label: {
                            Label(name, systemImage: filterSeries == name ? "checkmark" : "books.vertical")
                        }
                    }
                }
            }
            if activeFilterCount > 0 {
                Divider()
                Button("Save as List\u{2026}") { newListName = ""; showSaveList = true }
                Button("Clear Filters") { clearFilters() }
            }
        } label: {
            toolbarChip(activeFilterCount > 0 ? "Filter \u{00B7} \(activeFilterCount)" : "Filter",
                        systemImage: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by format, status, rating, tag or series")
    }

    /// The filters that are on, as chips you can click away.
    @ViewBuilder
    private var activeFilterBar: some View {
        if activeFilterCount > 0 {
            HStack(spacing: 8) {
                if let f = formatFilter { filterChip(f.label, icon: "doc") { formatFilter = nil } }
                if let s = filterStatus { filterChip(s.label, icon: s.systemImage) { filterStatus = nil } }
                if filterMinRating > 0 {
                    filterChip("\(filterMinRating)+ dogs", icon: "dog") { filterMinRating = 0 }
                }
                if let t = filterTag { filterChip("#\(t)", icon: "tag") { filterTag = nil } }
                if let s = filterSeries { filterChip(s, icon: "books.vertical") { filterSeries = nil } }
                Button("Clear all") { clearFilters() }
                    .buttonStyle(.borderless)
                Button("Save as List\u{2026}") { newListName = ""; showSaveList = true }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(DesignTokens.sansFont(size: 12))
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.sm)
        }
    }

    private func filterChip(_ title: String, icon: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(DesignTokens.accent.opacity(0.16), in: Capsule())
            .foregroundStyle(DesignTokens.accentInk)
        }
        .buttonStyle(.plain)
        .help("Remove this filter")
    }

    private var viewMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortOrder) {
                ForEach(SortOption.allCases) { option in
                    Label(option.displayName, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.inline)
            Picker("Group by", selection: $groupingRaw) {
                ForEach(LibraryGrouping.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            Picker("Cover size", selection: $gridDensityRaw) {
                ForEach(GridDensity.allCases) { density in
                    Label(density.displayName, systemImage: density.systemImage).tag(density.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            toolbarChip("View", systemImage: "slider.horizontal.3")
        }
        .help("Sort order and cover size")
    }

    // MARK: - Sidebar selection

    enum SidebarSelection: Hashable {
        case library
        case favorites
        case status(String)
        case topRated
        case highlighted
        case series(String)
        case savedList(String)
        case needsReview
        case duplicates
        case recycleBin
        case bookmarks
        case invoices
        case folder(String)
        case format(String)
        case tag(String)
        case author(String)
        case shelf(String)
    }

    @State private var sidebarSelection: SidebarSelection? = .library
    @Namespace private var sidebarSelectionNamespace
    @State private var isRescanning = false
    @State private var quietScan = false
    @State private var settleCheckScheduled = false
    @State private var sidebarHeaderHeight: CGFloat = 110
    @FocusState private var focusedSidebar: SidebarSelection?
    @State private var didSetInitialFocus = false
    @State private var showJumpToTop = false
    @ObservedObject private var invoiceStore =  InvoiceStore.shared
    @State private var sidebarTopInset: CGFloat = 28
    @State private var isDropTargeted = false
    @State private var dropMessage: String?
    @State private var rescanPending = false

    // MARK: - Sidebar
    //
    // Built as a plain ScrollView/VStack rather than List(.sidebar): List's
    // implicit AppKit row insets don't line up with a custom safeAreaInset
    // header, which left the "Pagewrit" mark, section labels, and row icons all
    // starting at very slightly different x-positions. Composing the inset
    // ourselves (outerMargin + rowContentInset, both applied consistently
    // below) guarantees the app mark, section labels, and every row icon
    // share one left edge.

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                sidebarTopRows
                sidebarReadingRows
                sidebarCollections
                sidebarBrowse
                sidebarTidyUp
            }
            .padding(.horizontal, DesignTokens.Sidebar.outerMargin)
            .padding(.bottom, DesignTokens.Spacing.md)
        }
        // Keyboard focus starts on the sidebar, not in the search field, so
        // the window opens calm. Set once at launch only: a standing default
        // (defaultFocus) pulled focus back to All Books whenever it was lost,
        // which made the sidebar jump up and down while picking an author.
        .task {
            guard !didSetInitialFocus else { return }
            didSetInitialFocus = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            if focusedSidebar == nil { focusedSidebar = sidebarSelection }
        }
        .background {
            // A quiet tinted panel with a faint wash of the accent at the top,
            // so the sidebar reads as its own surface instead of flat black.
            ZStack(alignment: .top) {
                DesignTokens.surface
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1).ignoresSafeArea()
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SidebarTopInsetKey.self, value: geo.safeAreaInsets.top)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            sidebarAppMark
                .padding(.horizontal, DesignTokens.Sidebar.contentInset)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xs)
                // Solid, so rows that scroll up under the logo disappear behind
                // it. It reaches the top of the window, and it is part of the
                // header itself, so it can never drift out of line with the rows.
                .background(DesignTokens.surface.ignoresSafeArea(edges: .top))
                // Report where the header ends, so the list can fade out
                // exactly there.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: SidebarHeaderBottomKey.self, value: geo.frame(in: .global).maxY)
                    }
                )
        }
        .onPreferenceChange(SidebarHeaderBottomKey.self) { sidebarHeaderHeight = $0 }
        .onPreferenceChange(SidebarTopInsetKey.self) { sidebarTopInset = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            DogCompanion()
                .background(DesignTokens.surface)
        }
        .frame(width: DesignTokens.Sidebar.width)
    }

    private func chooseSidebar(_ selection: SidebarSelection) {
        // A book page pushed on top always gives way, even when the row
        // you click is the one already selected underneath it.
        if !navigationPath.isEmpty {
            Haptics.tick()
            withAnimation(.smooth(duration: 0.26)) { navigationPath = NavigationPath() }
        }
        guard sidebarSelection != selection else { return }
        Haptics.tick()
        withAnimation(.smooth(duration: 0.26)) {
            sidebarSelection = selection
        }
    }

    /// One selectable row, wired to `sidebarSelection` directly — replaces
    /// List's native tap-to-select now that the sidebar isn't a List.
    private func sidebarRow(
        title: String,
        icon: String,
        selection: SidebarSelection,
        iconColor: Color? = nil,
        badge: String? = nil,
        badgeNeedsAttention: Bool = false
    ) -> some View {
        let isSelected = sidebarSelection == selection
        return SidebarRow(
            title: title,
            icon: icon,
            isSelected: isSelected,
            iconColor: iconColor,
            badge: badge,
            badgeNeedsAttention: badgeNeedsAttention,
            namespace: sidebarSelectionNamespace
        )
        .contentShape(Rectangle())
        .onTapGesture { chooseSidebar(selection) }
        // Keyboard: Tab (with Full Keyboard Access) or the arrow keys land on a
        // row; Return or Space opens it.
        .focusable()
        .focusEffectDisabled()
        .focused($focusedSidebar, equals: selection)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DesignTokens.accent.opacity(0.7), lineWidth: 1.5)
                .opacity(focusedSidebar == selection && !isSelected ? 1 : 0)
                .allowsHitTesting(false)
        )
        .onKeyPress(.return) { chooseSidebar(selection); return .handled }
        .onKeyPress(.space) { chooseSidebar(selection); return .handled }
        // The sidebar is hand-built (not List(.sidebar)), so none of the
        // selection/activation semantics VoiceOver gets from a native
        // List row come for free -- spelled out explicitly here instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Sidebar App Mark

    private var sidebarAppMark: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image("PagewritMark")
                .resizable()
                .interpolation(.high)
                .frame(
                    width: DesignTokens.Sidebar.AppMark.size,
                    height: DesignTokens.Sidebar.AppMark.size
                )

            Text("Pagewrit")
                .font(DesignTokens.serifFont(
                    size: DesignTokens.Sidebar.AppMark.titleSize,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                library.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(TactileButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    // MARK: - Sidebar Row

    /// A single sidebar row: "All Books", a watched folder, or a format
    /// filter. Format rows pass `iconColor` so EPUB/PDF/CBZ each carry a
    /// small, consistent identity color — everything else uses `.primary`.
    /// Has its own hover state so the sidebar gives feedback on mouse-over,
    /// not just on click.
    ///
    /// `contentInset` (applied here, inside the selection pill) plus the
    /// container's `outerMargin` (applied once, around the whole sidebar
    /// VStack) is what lines this row's icon up with the app mark and
    /// section labels above — see the comment on `sidebar`.
    private struct SidebarRow: View {
        let title: String
        let icon: String
        let isSelected: Bool
        var iconColor: Color?
        var badge: String?
        var badgeNeedsAttention = false
        let namespace: Namespace.ID

        @State private var isHovered = false

        var body: some View {
            HStack(spacing: DesignTokens.Sidebar.iconLabelGap) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Sidebar.fontSize, weight: .medium))
                    .foregroundStyle(isSelected ? DesignTokens.accentInk : (iconColor ?? .secondary))
                    .frame(width: 16, alignment: .leading)
                Text(title)
                    .font(.system(size: DesignTokens.Sidebar.fontSize))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .foregroundColor(isSelected ? DesignTokens.accentInk : .primary)

                Spacer(minLength: 0)

                // A quiet count at the trailing edge. Only the row that wants
                // you to do something (Needs Review) is tinted coral.
                if let badge {
                    Text(badge)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(badgeNeedsAttention
                            ? DesignTokens.accentSecondary
                            : (isSelected ? DesignTokens.accentInk : Color.secondary))
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 20)
                        .background(
                            Capsule(style: .continuous).fill(
                                badgeNeedsAttention
                                    ? DesignTokens.accentSecondary.opacity(0.16)
                                    : (isSelected ? DesignTokens.accent.opacity(0.18) : Color.primary.opacity(0.07))
                            )
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, DesignTokens.Sidebar.rowPaddingV)
            .padding(.horizontal, DesignTokens.Sidebar.contentInset)
            .frame(height: DesignTokens.Sidebar.rowHeight)
            .background {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowCornerRadius, style: .continuous)
                            .fill(DesignTokens.accent.opacity(0.12))
                            .matchedGeometryEffect(id: "sidebarSelection", in: namespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    // MARK: - Sidebar Section Label

    /// `contentInset` here (matching the row icon's own leading padding)
    /// is what makes section labels start flush with the icons in the
    /// rows beneath them, not the row's highlighted-pill edge.
    // MARK: Sidebar groups

    @ViewBuilder
    private var sidebarTopRows: some View {
            // What you reach for most: everything, what you are in the
            // middle of, what you love, and bills that need attention.
            sidebarRow(title: "All Books", icon: "books.vertical", selection: .library)
            sidebarRow(
                title: "Reading Now",
                icon: ReadingStatus.reading.systemImage,
                selection: .status(ReadingStatus.reading.rawValue),
                badge: library.continueReading.isEmpty ? nil : "\(library.continueReading.count)"
            )
            sidebarRow(title: "Favorites", icon: "heart", selection: .favorites)
            // Only for people who have invoices; others never see an empty list.
            if !invoiceStore.invoices.isEmpty || sidebarSelection == .invoices {
                sidebarRow(
                    title: "Invoices",
                    icon: "doc.text",
                    selection: .invoices,
                    badge: (invoiceStore.overdueCount + invoiceStore.dueSoonCount) > 0
                        ? "\(invoiceStore.overdueCount + invoiceStore.dueSoonCount)" : nil,
                    badgeNeedsAttention: invoiceStore.overdueCount > 0
                )
            }
    }

    @ViewBuilder
    private var sidebarReadingRows: some View {
            // Your reading life
            sidebarSectionLabel("My Reading")
            sidebarRow(
                title: ReadingStatus.unread.label,
                icon: ReadingStatus.unread.systemImage,
                selection: .status(ReadingStatus.unread.rawValue)
            )
            sidebarRow(
                title: ReadingStatus.finished.label,
                icon: ReadingStatus.finished.systemImage,
                selection: .status(ReadingStatus.finished.rawValue)
            )
            if !library.highlights.isEmpty {
                sidebarRow(title: "Highlights & Notes", icon: "highlighter", selection: .highlighted)
            }
            if !library.bookmarks.isEmpty {
                sidebarRow(title: "Bookmarks", icon: "bookmark", selection: .bookmarks,
                           badge: "\(library.bookmarks.count)")
            }
            sidebarRow(title: "Rated", icon: "dog", selection: .topRated)
    }

    @ViewBuilder
    private var sidebarCollections: some View {
            // Things you made: shelves, series and saved lists, together.
            if !allShelves.isEmpty || !allSeries.isEmpty || !savedLists.isEmpty {
                collapsibleSection("Collections", id: "collections",
                                   count: allShelves.count + allSeries.count + savedLists.count) {
                    ForEach(allShelves, id: \.self) { shelf in
                        sidebarRow(title: shelf, icon: "books.vertical", selection: .shelf(shelf))
                    }
                    ForEach(allSeries, id: \.self) { name in
                        sidebarRow(title: name, icon: "square.stack", selection: .series(name))
                    }
                    ForEach(savedLists) { list in
                        sidebarRow(title: list.name, icon: "line.3.horizontal.decrease.circle",
                                   selection: .savedList(list.id.uuidString))
                            .contextMenu {
                                Button("Delete List", role: .destructive) {
                                    storeSavedLists(savedLists.filter { $0.id != list.id })
                                    if sidebarSelection == .savedList(list.id.uuidString) {
                                        sidebarSelection = .library
                                    }
                                }
                            }
                    }
                }
            }
    }

    @ViewBuilder
    private var sidebarBrowse: some View {
            // Ways to browse. Long lists start folded so the sidebar stays short.
            // Only the kinds of file the library actually holds; an empty
            // "Kindle" or "CBZ" row is just something to wonder about.
            let presentFormats = Set(library.books.map(\.format))
            let shownFormats = BookFormat.allCases.filter { presentFormats.contains($0) }
            if shownFormats.count > 1 {
            collapsibleSection("Formats", id: "formats", count: shownFormats.count) {
                ForEach(shownFormats, id: \.self) { format in
                    sidebarRow(
                        title: format.sectionTitle,
                        icon: format.systemImage,
                        selection: .format(format.rawValue),
                        iconColor: DesignTokens.formatColor(for: format)
                    )
                }
            }
            }

            if !allAuthors.isEmpty {
                collapsibleSection("Authors", id: "authors", count: allAuthors.count) {
                    ForEach(allAuthors, id: \.self) { author in
                        sidebarRow(title: author, icon: "person", selection: .author(author))
                    }
                }
            }

            if !allTags.isEmpty {
                collapsibleSection("Tags", id: "tags", count: allTags.count) {
                    ForEach(allTags, id: \.self) { tag in
                        sidebarRow(title: tag, icon: "tag", selection: .tag(tag))
                    }
                }
            }

            collapsibleSection("Watched Folders", id: "folders", count: scanner.allWatchedFolders.count) {
                ForEach(scanner.allWatchedFolders, id: \.self) { folder in
                    sidebarRow(
                        title: ScannerService.displayName(for: folder),
                        icon: ScannerService.icon(for: folder),
                        selection: .folder(folder.path)
                    )
                }
            }
    }

    @ViewBuilder
    private var sidebarTidyUp: some View {
            // Housekeeping last, and only when there is something to do.
            if !library.needsReview.isEmpty || !library.duplicateGroups.isEmpty || !library.recycleBin.isEmpty {
                sidebarSectionLabel("Tidy Up")
                if !library.needsReview.isEmpty {
                    sidebarRow(
                        title: "Needs Review",
                        icon: "questionmark.diamond",
                        selection: .needsReview,
                        badge: "\(library.needsReview.count)",
                        badgeNeedsAttention: true
                    )
                }
                if !library.duplicateGroups.isEmpty {
                    sidebarRow(
                        title: "Duplicates",
                        icon: "doc.on.doc",
                        selection: .duplicates,
                        badge: "\(library.duplicateGroups.count)"
                    )
                }
                if !library.recycleBin.isEmpty {
                    sidebarRow(
                        title: "Recycle Bin",
                        icon: "trash",
                        selection: .recycleBin,
                        badge: "\(library.recycleBin.count)"
                    )
                }
            }
    }

    // MARK: Folding sections

    private var collapsedSections: Set<String> {
        Set(collapsedSectionsRaw.split(separator: ",").map(String.init))
    }

    private func toggleSection(_ id: String) {
        var sections = collapsedSections
        if sections.contains(id) { sections.remove(id) } else { sections.insert(id) }
        Haptics.tick()
        withAnimation(.smooth(duration: 0.22)) {
            collapsedSectionsRaw = sections.sorted().joined(separator: ",")
        }
    }

    /// A section heading you can click to fold away. Folded, it shows how many
    /// rows are hidden, and Pagewrit remembers it next time.
    @ViewBuilder
    private func collapsibleSection<Rows: View>(
        _ title: String, id: String, count: Int,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        let collapsed = collapsedSections.contains(id)
        Button { toggleSection(id) } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(DesignTokens.sansFont(size: DesignTokens.Sidebar.SectionLabel.fontSize, weight: .medium))
                    .foregroundStyle(.tertiary)
                if collapsed {
                    Text("\(count)")
                        .font(DesignTokens.sansFont(size: DesignTokens.Sidebar.SectionLabel.fontSize))
                        .monospacedDigit()
                        .foregroundStyle(.quaternary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .padding(.horizontal, DesignTokens.Sidebar.contentInset)
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(title)" : "Hide \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "Collapsed, \(countText(count, "item"))" : "Expanded")
        .accessibilityHint("Shows or hides this section")
        if !collapsed {
            rows()
        }
    }

    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.sansFont(
                size: DesignTokens.Sidebar.SectionLabel.fontSize,
                weight: .medium
            ))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, DesignTokens.Sidebar.contentInset)
            .padding(.top, DesignTokens.Spacing.lg)
            .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        detailBody
            .alert("Save this list", isPresented: $showSaveList) {
                TextField("List name", text: $newListName)
                Button("Save") {
                    let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let list = SavedList(name: name, filter: currentFilter)
                    storeSavedLists(savedLists + [list])
                    clearFilters()
                    sidebarSelection = .savedList(list.id.uuidString)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It will appear in the sidebar under Lists.")
            }
    }

    private var detailBody: some View {
        VStack(spacing: 0) {
            activeFilterBar

            if scanner.isScanning && !quietScan {
                if library.books.isEmpty {
                    // The very first scan: something to watch while it fills.
                    ScanningIndicator(detail: scanner.discoveredFiles.isEmpty
                                      ? nil : "\(countText(scanner.discoveredFiles.count, "file")) found")
                        .padding(.vertical, DesignTokens.Spacing.md)
                } else {
                    // Later scans: the same page shuffle, as one slim row that never pushes the page around.
                    ScanningIndicator(label: scanner.discoveredFiles.isEmpty
                                      ? "Checking your folders for new books"
                                      : "Checking your folders",
                                      detail: scanner.discoveredFiles.isEmpty
                                      ? nil : "\(countText(scanner.discoveredFiles.count, "file")) so far",
                                      compact: true)
                        .padding(.horizontal, DesignTokens.Spacing.xl)
                        .padding(.vertical, 6)
                        .transition(.opacity)
                }
            }

            if library.isImporting && library.importProgress < 1.0 && !quietScan {
                ProgressView(value: library.importProgress) {
                    Text("Importing\u{2026}")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.top, DesignTokens.Spacing.xs)
            }

            if let error = scanner.lastScanError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.vertical, DesignTokens.Spacing.lg)
            }

            if sidebarSelection == .needsReview {
                NeedsReviewTray()
                    .environmentObject(library)
            } else if sidebarSelection == .duplicates {
                DuplicatesTray()
                    .environmentObject(library)
            } else if sidebarSelection == .recycleBin {
                RecycleBinView { Task { await rescanAndImport(quiet: true) } }
                    .environmentObject(library)
            } else if sidebarSelection == .invoices {
                InvoicesView(searchText: searchText)
                    .environmentObject(library)
            } else if sidebarSelection == .bookmarks {
                BookmarksBrowser(searchText: searchText)
                    .environmentObject(library)
            } else if sidebarSelection == .highlighted {
                HighlightsBrowser(searchText: searchText)
                    .environmentObject(library)
            } else if sortedBooks.isEmpty && !scanner.isScanning && !library.isImporting {
                emptyState
            } else {
                ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("libraryTop")
                    if searchText.isEmpty, sidebarSelection == .library, !library.books.isEmpty {
                        LibraryGreeting()
                            .padding(.horizontal, DesignTokens.Spacing.xl)
                            .padding(.top, DesignTokens.Spacing.lg)
                    }
                    if searchText.isEmpty, !heroEntries.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
                                ForEach(Array(heroEntries.enumerated()), id: \.element.book.contentHash) { pair in
                                    HeroBand(book: pair.element.book, kind: pair.element.kind)
                                        // Share the visible width when there is room, but never
                                        // narrower than the card's own design: its cover, words
                                        // and progress bar need 440 points, and squeezing below
                                        // that made cards spill over each other. In a narrow
                                        // window the row scrolls instead.
                                        .containerRelativeFrame(.horizontal) { length, _ in
                                            let count = CGFloat(max(heroEntries.count, 1))
                                            let room = length - DesignTokens.Spacing.xl * 2
                                                - DesignTokens.Spacing.lg * (count - 1)
                                            return min(max(room / count, DesignTokens.Hero.cardWidth),
                                                       DesignTokens.Hero.cardWidth + 120)
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius,
                                                                    style: .continuous))
                                        .riseIn(delay: Double(pair.offset) * 0.06)
                                }
                            }
                            .padding(.horizontal, DesignTokens.Spacing.xl)
                            .padding(.vertical, DesignTokens.Spacing.sm)
                        }
                        // Only claims horizontal swipes when the cards really overflow,
                        // so a vertical scroll over this row is never stolen.
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .padding(.top, DesignTokens.Spacing.lg)
                    }

                    LazyVGrid(columns: columns, spacing: gridDensity.gridSpacing) {
                        ForEach(booksByFormat, id: \.title) { section in
                            Section {
                                ForEach(section.books) { book in
                                    BookCoverTile(
                                        book: book,
                                        density: gridDensity,
                                        onShowDetails: { navigationPath.append(book) }
                                    )
                                    // The first cover leaving the screen is what shows the
                                    // jump to top button. A plain VStack keeps filtering from
                                    // re-measuring the page and bouncing the scroll position.
                                    .onAppear {
                                        if book === booksByFormat.first?.books.first, showJumpToTop { showJumpToTop = false }
                                    }
                                    .onDisappear {
                                        if book === booksByFormat.first?.books.first, !showJumpToTop { showJumpToTop = true }
                                    }
                                }
                            } header: {
                                sectionHeader(
                                    section.title,
                                    count: section.books.count
                                )
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.top, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.xxl)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if showJumpToTop {
                        Button {
                            withAnimation(.smooth(duration: 0.45)) {
                                scrollProxy.scrollTo("libraryTop", anchor: .top)
                            }
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .background(.regularMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
                                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .help("Back to the top (\u{2318}\u{2191})")
                        .accessibilityLabel("Back to the top")
                        .padding(.trailing, 22)
                        .padding(.bottom, 22)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(.smooth(duration: 0.25), value: showJumpToTop)
                }
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.serifFont(
                    size: DesignTokens.SectionHeader.fontSize,
                    weight: .bold
                ))
                .tracking(DesignTokens.SectionHeader.tracking)
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.SectionHeader.Count.fontSize
                ))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Group {
            if !searchText.isEmpty {
                noSearchResults
            } else if !library.books.isEmpty {
                emptySection
            } else {
                emptyLibraryState
            }
        }
    }

    private var noSearchResults: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No books match \u{201C}\(searchText)\u{201D}")
                .font(DesignTokens.serifFont(size: 20, weight: .semibold))
            Text("Every word has to match somewhere in the book's title, author, tags or text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack(spacing: 8) {
                if searchScope != .everything {
                    Button("Search everything") { searchScope = .everything }
                }
                if activeFilterCount > 0 {
                    Button("Clear filters") { clearFilters() }
                }
                Button("Clear search") { searchText = "" }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyLibraryState: some View {
        let hasFolders = !scanner.allWatchedFolders.isEmpty
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(hasFolders ? "Nothing to read yet" : "Bring in your books")
                .font(.system(size: 22, weight: .semibold))

            Text(hasFolders
                 ? "Pagewrit looked through your folders and found no books, documents or presentations. Anything you download or save there from now on is added automatically."
                 : "Choose the folders where your books, documents and slide decks live. Pagewrit adds what it finds, and keeps watching for new files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Choose folders") {
                    if scanner.chooseStandardFolders() {
                        Task { await rescanAndImport() }
                    }
                }
                .buttonStyle(InkButtonStyle())

                Button("Pick a different folder\u{2026}") {
                    if scanner.chooseFolders() {
                        Task { await rescanAndImport() }
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.top, DesignTokens.Spacing.xxs)
        }
        .frame(maxWidth: 400, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The library has books, but not in the section or filter being shown.
    private var emptySection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text(sidebarSelection == .favorites ? "No favorites yet" : "Nothing here yet")
                .font(.system(size: 22, weight: .semibold))
            Text(sidebarSelection == .favorites
                 ? "Hover over a book and tap the heart to keep it here."
                 : "No files in this section. New downloads are added automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show all books") {
                clearFilters()
                chooseSidebar(.library)
            }
            .buttonStyle(QuietButtonStyle())
            .padding(.top, DesignTokens.Spacing.xxs)
        }
        .frame(maxWidth: 400, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// True while the scroll wheel or trackpad is moving the page, and for a
/// moment after. Read by tiles so they skip hover effects mid-scroll.
enum ScrollActivity {
    private(set) static var isScrolling = false
    private static var monitor: Any?
    private static var settle: DispatchWorkItem?

    static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            isScrolling = true
            settle?.cancel()
            let work = DispatchWorkItem { isScrolling = false }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return event
        }
    }
}

private struct SidebarHeaderBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 64
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct SidebarTopInsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 28
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - ProgressBar

/// Small reusable capsule progress track, used by the Continue Reading hero.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))

                Capsule()
                    .fill(DesignTokens.accent)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

// MARK: - DailySeededGenerator

/// A minimal seeded RNG (SplitMix64) so a "pick of the day" is
/// reproducible for the same calendar day without pulling in
/// GameplayKit for one random pick — deterministic per seed, not
/// cryptographically random, which is exactly what a book-of-the-day
/// rotation needs.
struct DailySeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(date: Date) {
        state = UInt64(bitPattern: Int64(date.timeIntervalSince1970))
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - HeroKind

/// What a hero card is spotlighting. Each case owns its own eyebrow
/// label, CTA verb, and meta line — adding a new kind of spotlight later
/// (a tag, a format, whatever) means adding a case here, not touching
/// HeroBand's layout.
enum HeroKind {
    case continueReading
    case recentlyAdded
    case discover

    var eyebrow: String {
        switch self {
        case .continueReading: "Continue reading"
        case .recentlyAdded: "Recently added"
        case .discover: "Still on your shelf"
        }
    }

    /// Only Continue Reading gets the accent color on its eyebrow — it's
    /// the one card representing something the user already committed
    /// to, so it earns the one owned color. The other two stay quiet.
    var usesAccentEyebrow: Bool { self == .continueReading }

    var buttonLabel: String {
        switch self {
        case .continueReading: "Resume"
        case .recentlyAdded: "Open"
        case .discover: "Read"
        }
    }

    /// A small directional cue on the button so each card's action reads
    /// at a glance, not just from the label.
    var buttonIcon: String {
        switch self {
        case .continueReading: "play.fill"
        case .recentlyAdded: "arrow.right"
        case .discover: "book.fill"
        }
    }
}

// MARK: - HeroBand

/// One card in the horizontally scrolling hero rail. All cards share a
/// fixed size (DesignTokens.Hero.height/cardWidth) and a fixed-height
/// title block, so the eyebrow, title, and button land at the same Y on
/// every card regardless of how much text any one book contributes.
struct HeroBand: View {
    let book: Book
    var kind: HeroKind = .recentlyAdded
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow

    private var relativeAdded: String {
        Self.relativeString(for: book.addedAt)
    }

    /// "39% read", or "Just started" while you are still on the first page.
    private var progressWords: String {
        let percent = Int(((book.readingProgress ?? 0) * 100).rounded(.down))
        return percent == 0 ? "Just started" : "\(percent)% read"
    }

    private var relativeOpened: String {
        Self.relativeString(for: book.lastOpenedAt ?? book.addedAt)
    }

    /// RelativeDateTimeFormatter reads oddly for anything under a minute —
    /// a book opened moments ago could format as "0 sec ago" or, if the
    /// two Date() calls straddle a clock tick, "in 0 sec" (future tense,
    /// for a book you're looking at right now). Anything under a minute
    /// old just reads as "just now" instead.
    private static func relativeString(for date: Date) -> String {
        guard abs(Date().timeIntervalSince(date)) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius, style: .continuous)
                .fill(DesignTokens.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.07), lineWidth: 0.75)
                }

            HStack(alignment: .center, spacing: DesignTokens.Spacing.xl) {
                MattedCoverView(book: book, cornerRadius: 11)
                    .frame(width: DesignTokens.Hero.coverWidth)
                    .coverShadow(depth: 1.5)

                // Spacing here is deliberately uneven — see
                // DesignTokens.Hero.Rhythm — rather than one repeated
                // VStack gap. The title's reserved blockHeight and the
                // meta block's reserved blockHeight (below) are what keep
                // every card in the rail aligned: with everything above
                // the button at a fixed height, a fixed Rhythm.beforeButton
                // gap (not an elastic Spacer) lands the button at the same
                // Y with the same visual distance from its content on
                // every card, regardless of title length or which meta
                // row it shows.
                VStack(alignment: .leading, spacing: 0) {
                    Text(kind.eyebrow)
                        .font(DesignTokens.sansFont(
                            size: DesignTokens.Hero.Eyebrow.fontSize,
                            weight: .medium
                        ))
                        .foregroundStyle(kind.usesAccentEyebrow ? AnyShapeStyle(DesignTokens.accentInk) : AnyShapeStyle(.secondary))
                        .padding(.bottom, DesignTokens.Hero.Rhythm.afterEyebrow)

                    Text(book.title)
                        .font(DesignTokens.serifFont(
                            size: DesignTokens.Hero.Title.fontSize,
                            weight: .bold
                        ))
                        .tracking(DesignTokens.Hero.Title.tracking)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(height: DesignTokens.Hero.Title.blockHeight, alignment: .topLeading)
                        .padding(.bottom, DesignTokens.Hero.Rhythm.afterTitle)

                    VStack(alignment: .leading, spacing: DesignTokens.Hero.Rhythm.beforeMeta) {
                        switch kind {
                        case .continueReading:
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text("\(progressWords), opened \(relativeOpened)")
                            }
                                .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            ProgressBar(fraction: book.readingProgress ?? 0)
                                .frame(width: 220, height: 4)
                        case .recentlyAdded:
                            TimelineView(.periodic(from: .now, by: 30)) { _ in
                                Text("\(book.format.label), added \(relativeAdded)")
                            }
                                .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        case .discover:
                            // Deliberately the longest of the three meta
                            // strings, and the one most likely to wrap at
                            // this column width — lineLimit(1) keeps it
                            // (truncated, if it must) inside the meta
                            // block's fixed height so it can never spill
                            // into the button below it.
                            Text("Added \(relativeAdded), not started")
                                .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: DesignTokens.Hero.Meta.blockHeight, alignment: .top)

                    Button {
                        openWindow(id: "reader", value: book.contentHash)
                    } label: {
                        // A plain HStack, not Label, so icon size and
                        // icon/text spacing are set explicitly rather
                        // than inherited from Label's own (looser)
                        // defaults — that mismatch was what read as
                        // misaligned.
                        HStack(spacing: 5) {
                            Image(systemName: kind.buttonIcon)
                                .font(.system(size: 10, weight: .semibold))
                            Text(kind.buttonLabel)
                                .font(DesignTokens.sansFont(
                                    size: DesignTokens.Hero.Button.fontSize,
                                    weight: .semibold
                                ))
                        }
                        .foregroundStyle(DesignTokens.solidInk)
                        .padding(.vertical, DesignTokens.Hero.Button.paddingV)
                        .padding(.horizontal, DesignTokens.Hero.Button.paddingH)
                        .background(DesignTokens.solidFill, in: Capsule())
                    }
                    .padding(.top, DesignTokens.Hero.Rhythm.beforeButton)
                    .buttonStyle(TactileButtonStyle())
                }
                .frame(height: DesignTokens.Hero.height - DesignTokens.Hero.paddingV * 2)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Hero.paddingH)
            .padding(.vertical, DesignTokens.Hero.paddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: DesignTokens.Hero.height)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.10), radius: 18, x: 0, y: 8)
    }
}

// MARK: - TactileButtonStyle

/// A button that answers the click instead of just changing a route. On
/// its own a SwiftUI Button with .plain style gives zero physical
/// feedback — this scales it down slightly on press, per the "respond
/// instantly, continuously, and physically" principle behind Apple's own
/// controls. Reach for this on any button that should feel real, not just
/// the hero's Resume/Open.
struct TactileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isDown in
                if isDown { Haptics.tick() }
            }
    }
}

// MARK: - Rise in

/// One quiet entrance per card: a short fade and lift, once, staggered.
/// Skipped entirely when Reduce Motion is on.
private struct RiseIn: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.pagewritReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                withAnimation(.easeOut(duration: 0.45).delay(delay)) { shown = true }
            }
    }
}

private extension View {
    func riseIn(delay: Double) -> some View { modifier(RiseIn(delay: delay)) }
}

// MARK: - Favorite heart with a little celebration

/// The heart on a cover. Liking it pops the heart and sends a small burst of
/// hearts and sparkles outward; unliking is quiet. The state flips instantly —
/// saving happens afterwards in the background.
struct FavoriteHeartButton: View {
    let isFavorite: Bool
    let action: () -> Void

    @State private var burst = 0
    @State private var pop = false
    @Environment(\.pagewritReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            let liking = !isFavorite
            Haptics.tick()
            withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { action() }
            if liking && !reduceMotion {
                CelebrationCenter.shared.celebrateAtPointer()
                DogPet.shared.cheer("A new favorite. Approved.")
                celebrate()
            }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(isFavorite ? Color(red: 1.0, green: 0.23, blue: 0.36) : Color.black.opacity(0.5), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .scaleEffect(pop ? 1.4 : 1)
        }
        .buttonStyle(TactileButtonStyle())
        .accessibilityLabel(isFavorite ? "Remove from Favorites" : "Add to Favorites")
    }

    private func celebrate() {
        burst += 1
        withAnimation(.spring(response: 0.18, dampingFraction: 0.45)) { pop = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = false }
        }
    }
}

// MARK: - Greeting

/// A short, personal line at the top of the library: the time of day, and
/// where you stand with today's reading.
struct LibraryGreeting: View {
    @ObservedObject private var tracker = ReadingTracker.shared

    private var salutation: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Reading late"
        }
    }

    private var detail: String {
        let read = tracker.minutesToday
        if tracker.progressToday >= 1 {
            return "\(readingMinutesText(read)) read today. Goal reached."
        }
        if read == 0 { return "Pick up where you left off, or start something new." }
        let left = max(tracker.goalMinutes - read, 1)
        return "\(readingMinutesText(read)) read today, \(readingMinutesText(left)) to your goal."
    }

    var body: some View {
        TimelineView(.everyMinute) { _ in
            VStack(alignment: .leading, spacing: 4) {
                Text(salutation)
                    .font(DesignTokens.serifFont(size: 28, weight: .bold))
                    .tracking(-0.5)
                Text(detail)
                    .font(DesignTokens.sansFont(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .onAppear { tracker.refreshDay() }
    }
}

// MARK: - BookCoverTile

/// VoiceOver for a cover tile, kept out of the tile's body so the compiler
/// can type-check that long modifier chain quickly.
private struct TileAccessibility: ViewModifier {
    let title: String
    let details: String
    let isFavorite: Bool
    let open: () -> Void
    let showDetails: () -> Void
    let toggleFavorite: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityValue(details)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the book. Use the actions menu for details and favorites.")
            .accessibilityAction { open() }
            .accessibilityAction(named: Text("Show details")) { showDetails() }
            .accessibilityAction(named: Text(isFavorite ? "Remove from Favorites" : "Add to Favorites")) { toggleFavorite() }
    }
}

/// Single cover-art tile in the library grid.
struct BookCoverTile: View {
    let book: Book
    var density: GridDensity = .comfortable
    /// Opens the book's detail page. One click reads the book; details sit
    /// behind the small info button (shown on hover) and the context menu.
    var onShowDetails: (() -> Void)?
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var showDeleteConfirmation = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.pagewritReduceMotion) private var reduceMotion

    private var lifted: Bool { isHovered && !reduceMotion }
    private var liftOffset: CGFloat { lifted ? DesignTokens.Hover.gridLiftY : 0 }
    private var liftScale: CGFloat { lifted ? DesignTokens.Hover.gridScale : 1 }

    private var spokenTitle: String {
        guard let author = book.displayAuthor else { return book.title }
        return "\(book.title), \(author)"
    }

    /// What VoiceOver reads after the title: format, progress, rating, favourite.
    private var spokenDetails: String {
        var parts: [String] = [book.format.label]
        switch book.status {
        case .finished: parts.append("finished")
        case .reading: parts.append("\(Int(((book.readingProgress ?? 0) * 100).rounded())) percent read")
        case .unread: parts.append("not started")
        }
        if book.rating > 0 { parts.append("rated \(book.rating) of 5") }
        if book.isFavorite { parts.append("favorite") }
        return parts.joined(separator: ", ")
    }

    private var secondaryLine: String {
        // No author means no line: showing the file type here ("PDF") read as
        // if it were the author's name.
        if let author = book.displayAuthor {
            return author
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            MattedCoverView(book: book)
                .overlay(alignment: .topLeading) {
                    if isHovered || book.isFavorite {
                        FavoriteHeartButton(isFavorite: book.isFavorite) {
                            library.toggleFavorite(book)
                        }
                        .help(book.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let onShowDetails {
                        Button(action: onShowDetails) {
                            Image(systemName: "info")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(.black.opacity(0.5), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(TactileButtonStyle())
                        .help("Details")
                        .accessibilityLabel("Details for \(book.title)")
                        .padding(8)
                        .opacity(isHovered ? 1 : 0.6)
                    }
                }
                // One shadow instead of two: blurred shadows are the costliest
                // thing to draw while a grid of covers scrolls.
                .shadow(
                    color: (isHovered
                        ? DesignTokens.Shadow.lifted(colorScheme: colorScheme)
                        : DesignTokens.Shadow.soft(colorScheme: colorScheme)).color,
                    radius: (isHovered
                        ? DesignTokens.Shadow.lifted(colorScheme: colorScheme)
                        : DesignTokens.Shadow.soft(colorScheme: colorScheme)).radius,
                    x: 0,
                    y: (isHovered
                        ? DesignTokens.Shadow.lifted(colorScheme: colorScheme)
                        : DesignTokens.Shadow.soft(colorScheme: colorScheme)).y
                )

            // The text under the cover is a real button: it opens the book's
            // details page, and underlines on hover so it reads as clickable.
            Button {
                onShowDetails?()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(DesignTokens.serifFont(
                            size: DesignTokens.Grid.Title.fontSize,
                            weight: .bold
                        ))
                        .underline(isHovered && onShowDetails != nil)
                        .foregroundStyle(.primary)
                        .lineLimit(density.titleLineLimit)
                        .multilineTextAlignment(.leading)
                        .frame(
                            height: density == .compact ? nil : DesignTokens.Grid.Title.blockHeight,
                            alignment: .topLeading
                        )

                    // Author when the file's metadata actually has one — a
                    // one-line title card next to a two-line one otherwise stays
                    // aligned but says less than it could. Falls back to format
                    // when there's no author to show.
                    // A blank line still holds its place so covers stay aligned.
                    Text(secondaryLine.isEmpty ? " " : secondaryLine)
                        .font(DesignTokens.sansFont(size: DesignTokens.Grid.Author.fontSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onShowDetails == nil)
            .help("Open details for \(book.title)")
        }
        .offset(y: liftOffset)
        .scaleEffect(liftScale)
        .animation(
            .spring(
                response: DesignTokens.Hover.gridSpringResponse,
                dampingFraction: DesignTokens.Hover.dampingFraction
            ),
            value: isHovered
        )
        .onHover { hovering in
            // Tiles sliding under a still pointer while the page scrolls are not
            // hovers; starting a lift animation on each one made scrolling stutter.
            if hovering && ScrollActivity.isScrolling { return }
            isHovered = hovering
        }
        .contentShape(Rectangle())
        // One click on the cover reads the book, like any reading app. The title,
        // the info button and the context menu lead to the details page.
        .onTapGesture {
            openWindow(id: "reader", value: book.contentHash)
        }
        // Keyboard and VoiceOver: a tile can be focused, then Return or Space reads it.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { openWindow(id: "reader", value: book.contentHash); return .handled }
        .onKeyPress(.space) { openWindow(id: "reader", value: book.contentHash); return .handled }
        .modifier(TileAccessibility(
            title: spokenTitle,
            details: spokenDetails,
            isFavorite: book.isFavorite,
            open: { openWindow(id: "reader", value: book.contentHash) },
            showDetails: { onShowDetails?() },
            toggleFavorite: { library.toggleFavorite(book) }
        ))
        .contextMenu {
            Button {
                openWindow(id: "reader", value: book.contentHash)
            } label: {
                Label("Read", systemImage: "book.fill")
            }

            Button {
                library.setStatus(book, status: book.isFinished ? .unread : .finished)
            } label: {
                Label(book.isFinished ? "Mark as Unread" : "Mark as Read",
                      systemImage: book.isFinished ? "circle" : "checkmark.circle")
            }

            if [BookFormat.pdf, BookFormat.docx, BookFormat.text].contains(book.format),
               !InvoiceStore.shared.contains(book.contentHash) {
                Button {
                    InvoiceStore.shared.addManually(
                        hash: book.contentHash, title: book.title, author: book.author,
                        url: book.sourceURL, format: book.format)
                } label: {
                    Label("Mark as Invoice", systemImage: "doc.text")
                }
            }

            Menu {
                ForEach((1...5).reversed(), id: \.self) { value in
                    Button {
                        library.setRating(book, rating: value)
                    } label: {
                        Text("\(String(repeating: "\u{1F436}", count: value))  \(DogRating.words(for: value))")
                    }
                }
                if book.rating > 0 {
                    Divider()
                    Button("Clear Rating") { library.setRating(book, rating: 0) }
                }
            } label: {
                Label("Rate", systemImage: "face.smiling")
            }

            Button {
                library.toggleFavorite(book)
            } label: {
                Label(book.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: book.isFavorite ? "heart.slash" : "heart")
            }

            if let onShowDetails {
                Button(action: onShowDetails) {
                    Label("Get Info", systemImage: "info.circle")
                }
            }

            Button {
                NSWorkspace.shared.open(book.sourceURL)
            } label: {
                Label("Open in Default App", systemImage: "arrow.up.forward.app")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(book.sourcePath, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                library.removeAndExclude(book)
            } label: {
                Label("Remove & Never Re-add", systemImage: "xmark.bin")
            }

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete File\u{2026}", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete \u{201c}\(book.title)\u{201d}?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                library.deleteFile(for: book)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the file itself to the Trash, not just Pagewrit's library entry. This can't be undone from inside Pagewrit.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(book.title)\(secondaryLine.isEmpty ? "" : ", \(secondaryLine)")")
        .accessibilityHint("Click to read")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - MattedCoverView

/// A cover for a book that came without one, set like a real book jacket:
/// a deep cloth colour picked from the book itself, a spine, a thin frame,
/// the title in a serif and the author at the foot. Every book gets its own
/// colour, and the same book always gets the same one.
struct GeneratedCover: View {
    let title: String
    let author: String?
    let seed: String

    /// Quiet, close-together cloth colours, so a shelf of them reads as one
    /// calm library instead of a shop window.
    private static let cloths: [Color] = [
        Color(red: 0.20, green: 0.29, blue: 0.31),  // teal grey
        Color(red: 0.35, green: 0.23, blue: 0.22),  // clay
        Color(red: 0.22, green: 0.29, blue: 0.25),  // sage
        Color(red: 0.19, green: 0.23, blue: 0.31),  // ink
        Color(red: 0.40, green: 0.33, blue: 0.23),  // tobacco
        Color(red: 0.25, green: 0.25, blue: 0.27),  // graphite
        Color(red: 0.29, green: 0.31, blue: 0.24),  // moss
        Color(red: 0.31, green: 0.24, blue: 0.27)   // plum grey
    ]
    private static let ink = Color(red: 0.96, green: 0.93, blue: 0.86)

    private var cloth: Color {
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Self.cloths[Int(hash % UInt64(Self.cloths.count))]
    }

    /// The main title and an optional subtitle, split where a real jacket
    /// would split them: "Stoa — Plan & Architecture" sets "Stoa" large.
    private var parts: (main: String, sub: String?) { Self.titleParts(title) }

    static func titleParts(_ title: String) -> (main: String, sub: String?) {
        let cleaned = title.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("Untitled", nil) }
        for separator in [" \u{2014} ", " \u{2013} ", ": ", " - "] {
            if let range = cleaned.range(of: separator) {
                let main = String(cleaned[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let sub = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !main.isEmpty && main.count <= 60 { return (main, sub.isEmpty ? nil : sub) }
            }
        }
        return (cleaned, nil)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let longTitle = parts.main.count > 28
            ZStack(alignment: .topLeading) {
                cloth

                // Spine: a shaded band with a crease beside it.
                HStack(spacing: 0) {
                    Rectangle().fill(Color.black.opacity(0.20)).frame(width: w * 0.05)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: max(w * 0.007, 0.5))
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: h * 0.025) {
                    Text(parts.main)
                        .font(.system(size: max(w * (longTitle ? 0.085 : 0.105), 6), weight: .semibold, design: .serif))
                        .foregroundStyle(Self.ink)
                        .lineLimit(longTitle ? 5 : 4)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let sub = parts.sub {
                        Text(sub)
                            .font(.system(size: max(w * 0.052, 5), weight: .regular, design: .serif))
                            .foregroundStyle(Self.ink.opacity(0.72))
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(Self.ink.opacity(0.4))
                        .frame(width: w * 0.12, height: max(w * 0.006, 0.75))
                    if let author, !author.isEmpty {
                        Text(author)
                            .font(.system(size: max(w * 0.055, 5), weight: .medium, design: .serif))
                            .italic()
                            .foregroundStyle(Self.ink.opacity(0.8))
                            .lineLimit(2)
                    }
                }
                .padding(.leading, w * 0.14)
                .padding(.trailing, w * 0.12)
                .padding(.top, h * 0.11)
                .padding(.bottom, h * 0.09)
                .frame(width: w, height: h, alignment: .topLeading)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Notes, Markdown and plain text: a sheet of paper on a soft mat, with the
/// name at the top and faint lines below. Quiet on purpose, so documents sit
/// in the background and books stand out.
struct DocumentSheetCover: View {
    let title: String
    let kind: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let paperW = w * 0.74
            let paperH = h * 0.78
            ZStack {
                Color(light: NSColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1),
                      dark: NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))

                VStack(alignment: .leading, spacing: paperH * 0.035) {
                    Text(kind)
                        .font(.system(size: max(paperW * 0.06, 5), weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.4))
                    Text(title)
                        .font(.system(size: max(paperW * 0.085, 6), weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.78))
                        .lineLimit(4)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(0..<9, id: \.self) { line in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.black.opacity(0.09))
                            .frame(width: paperW * (line % 3 == 2 ? 0.45 : 0.78), height: max(paperW * 0.018, 1))
                    }
                    Spacer(minLength: 0)
                }
                .padding(paperW * 0.1)
                .frame(width: paperW, height: paperH, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius)
                        .fill(DesignTokens.paper)
                )
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.18), radius: 8, y: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The cover treatment shared by the grid, hero band, and detail view.
///
/// PDFs render "matted": a per-book hashed gradient mat with a warm paper-toned
/// page inset in the center. EPUB/CBZ with a real cover image render that image
/// full-bleed. All formats fall back to gradient+monogram when no cover is available.
struct MattedCoverView: View {
    let book: Book
    var cornerRadius: CGFloat = DesignTokens.Grid.Cover.cornerRadius
    var showBadge: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: NSImage?
    @State private var thumbnailLoaded = false
    @State private var hovering = false

    private var monogram: String {
        String(book.title.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if let coverURL = book.coverImageURL {
                fullBleedCover(url: coverURL)
            } else if book.format.rendersLiveThumbnail {
                mattedPDF
            } else if book.format == .text {
                // Notes and Markdown are paperwork, not books: a quiet sheet.
                DocumentSheetCover(title: book.title, kind: book.sourceURL.pathExtension.lowercased() == "md" ? "Markdown" : "Text")
            } else {
                fullBleedPlaceholder
            }

            // Generated covers and sheets already say what they are.
            // Only on hover: the section and the line under the cover already
            // say the format, and a badge on every cover is clutter.
            if showBadge && hovering && (book.coverImageURL != nil || book.format.rendersLiveThumbnail) {
                formatBadge
                    .padding(DesignTokens.Spacing.xs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .aspectRatio(DesignTokens.Grid.Cover.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 0.5)
        )
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .onAppear {
            loadThumbnail()
        }
    }

    // MARK: - Matted PDF

    /// Width / height of the rendered first page, once loaded.
    private var pageAspect: CGFloat? {
        guard thumbnailLoaded, let thumbnail, thumbnail.size.height > 1 else { return nil }
        return thumbnail.size.width / thumbnail.size.height
    }

    private var mattedPDF: some View {
        ZStack {
            // Always matted, never cropped: a full-bleed fill used to be
            // applied to any roughly book-shaped page (a wide band that
            // also caught ordinary Letter/A4 documents — resumes, pitch
            // decks), which cut off the very text that makes the thumbnail
            // recognizable. Showing the whole first page on a paper mat
            // costs a little size but never hides content.
            matBackdrop

            GeometryReader { geo in
                let paperSize = paperSize(in: geo.size)

                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius)
                        .fill(DesignTokens.paper)
                        .frame(width: paperSize.width, height: paperSize.height)
                        .shadow(color: .black.opacity(0.30), radius: 10, x: 0, y: 5)

                    if let thumbnail, thumbnailLoaded {
                        // Fit, never crop: the whole page is visible.
                        Image(nsImage: thumbnail)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: paperSize.width, height: paperSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius))
                    } else {
                        skeletonLines
                            .frame(width: paperSize.width, height: paperSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius))
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }

    /// The mat takes its colour from the page itself: the first page, blown up,
    /// blurred and dimmed. Every deck and document gets a backdrop that suits
    /// it, instead of a random flat colour. A neutral tone shows until the
    /// thumbnail loads.
    private var matBackdrop: some View {
        ZStack {
            Color(light: NSColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1),
                  dark: NSColor(red: 0.16, green: 0.17, blue: 0.20, alpha: 1))
            if thumbnailLoaded, let thumbnail {
                Color.clear.overlay {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .scaleEffect(1.5)
                        .blur(radius: 24)
                        .saturation(0.9)
                }
                .clipped()
                // Flatten the blur once so scrolling moves a picture, not a live blur.
                .drawingGroup()
                Color.black.opacity(colorScheme == .dark ? 0.34 : 0.16)
            }
        }
    }

    /// The page, at its real proportions, as large as the mat allows.
    private func paperSize(in mat: CGSize) -> CGSize {
        guard let aspect = pageAspect else {
            return CGSize(
                width: mat.width * DesignTokens.Mat.paperWidthFraction,
                height: mat.height * DesignTokens.Mat.paperHeightFraction
            )
        }
        let maxWidth = mat.width * 0.9
        let maxHeight = mat.height * 0.9
        let width = min(maxWidth, maxHeight * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    /// Skeleton lines on the paper while the thumbnail loads.
    private var skeletonLines: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonTitleBarOpacity))
                .frame(width: 34, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonBarOpacity))
                .frame(height: 2.5)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonBarOpacity))
                .frame(width: 46, height: 2.5)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonBarOpacity))
                .frame(height: 2.5)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Full-bleed cover (EPUB/CBZ with real cover art)

    private func fullBleedCover(url: URL) -> some View {
        Group {
            if thumbnailLoaded, let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fullBleedPlaceholder
            }
        }
        .aspectRatio(DesignTokens.Grid.Cover.aspectRatio, contentMode: .fill)
    }

    // MARK: - Full-bleed placeholder (no cover available)

    private var fullBleedPlaceholder: some View {
        GeneratedCover(title: book.title, author: book.displayAuthor, seed: book.contentHash.isEmpty ? book.sourcePath : book.contentHash)
            .aspectRatio(DesignTokens.Grid.Cover.aspectRatio, contentMode: .fill)
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        Text(book.format.label)
            .font(DesignTokens.sansFont(
                size: DesignTokens.Badge.fontSize + 1,
                weight: .semibold
            ))
            .tracking(DesignTokens.Badge.tracking)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.vertical, DesignTokens.Badge.paddingV + 1)
            .padding(.horizontal, DesignTokens.Badge.paddingH)
            .background(
                .black.opacity(0.34),
                in: Capsule()
            )
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() {
        guard !thumbnailLoaded else { return }
        // Already in memory: show it at once, no fade, no work.
        if book.format.rendersLiveThumbnail {
            if let cached = CoverThumbnailCache.shared.thumbnail(for: book.sourceURL.path) {
                thumbnail = cached
                thumbnailLoaded = true
                return
            }
        } else if let coverURL = book.coverImageURL,
                  let cached = CoverThumbnailCache.shared.cachedImage(at: coverURL) {
            thumbnail = cached
            thumbnailLoaded = true
            return
        }

        if book.format.rendersLiveThumbnail {
            // PDFs and slide decks: use CoverThumbnailCache for live rendering
            CoverThumbnailCache.shared.loadThumbnail(for: book.sourceURL) { image in
                if let image {
                    withAnimation(.easeIn(duration: 0.2)) {
                        thumbnail = image
                        thumbnailLoaded = true
                    }
                }
            }
        } else if let coverURL = book.coverImageURL {
            // EPUB/CBZ with persisted cover art, decoded down to thumbnail size
            CoverThumbnailCache.shared.loadImage(at: coverURL) { img in
                if let img {
                    withAnimation(.easeIn(duration: 0.2)) {
                        thumbnail = img
                        thumbnailLoaded = true
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ScannerService())
        .environmentObject(LibraryStore())
}

// MARK: - NeedsReviewTray

/// Triage for files the classifier wasn't sure about. A quiet list on the
/// left, and one large preview on the right that you decide on. Return adds
/// the file, Delete skips it, the arrow keys move; after each decision the
/// next file is already waiting.
struct NeedsReviewTray: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var filter: ReviewFilter = .all
    @State private var selection: String?
    @State private var pendingBulk: BulkAction?
    @FocusState private var focused: Bool

    /// Scores at or above this read as "probably a book".
    private static let likelyCutoff = 0.5

    enum ReviewFilter: String, CaseIterable, Identifiable {
        case all, likely, unlikely
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .likely: return "Likely"
            case .unlikely: return "Unlikely"
            }
        }
    }

    enum BulkAction: Identifiable {
        case addLikely, skipUnlikely
        var id: Int { self == .addLikely ? 0 : 1 }
    }

    var body: some View {
        let all = library.needsReview.sorted { $0.score > $1.score }
        let likely = all.filter { $0.score >= Self.likelyCutoff }
        let unlikely = all.filter { $0.score < Self.likelyCutoff }
        let shown: [BookClassification] = {
            switch filter {
            case .all: return all
            case .likely: return likely
            case .unlikely: return unlikely
            }
        }()
        let current = shown.first { $0.fileHash == selection } ?? shown.first

        return Group {
            if all.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    listColumn(all: all, likely: likely, unlikely: unlikely, shown: shown, current: current)
                        .frame(width: 340)
                    Rectangle()
                        .fill(DesignTokens.hairline(colorScheme: colorScheme))
                        .frame(width: 1)
                    detailColumn(current: current, shown: shown)
                }
            }
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { move(-1, in: shown, current: current); return .handled }
        .onKeyPress(.downArrow) { move(1, in: shown, current: current); return .handled }
        .onKeyPress(.return) {
            if let current { add(current, in: shown) }
            return .handled
        }
        .onKeyPress(.delete) {
            if let current { reject(current, in: shown) }
            return .handled
        }
        .confirmationDialog(
            pendingBulk == .addLikely ? "Add every likely book?" : "Skip every unlikely file?",
            isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
            titleVisibility: .visible
        ) {
            if pendingBulk == .addLikely {
                Button("Add \(likely.count) to library") {
                    let batch = likely
                    Task { for item in batch { await library.confirmClassification(item) } }
                }
            } else {
                Button("Mark \(unlikely.count) as not books", role: .destructive) {
                    for item in unlikely { library.dismissClassification(item) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingBulk == .addLikely
                 ? "Everything scoring 50% or more goes into your library."
                 : "Everything scoring under 50% is marked as not a book and won't be suggested again.")
        }
    }

    // MARK: Decisions

    private func neighbor(of item: BookClassification, in shown: [BookClassification]) -> BookClassification? {
        guard let i = shown.firstIndex(where: { $0.fileHash == item.fileHash }) else { return nil }
        if i + 1 < shown.count { return shown[i + 1] }
        if i > 0 { return shown[i - 1] }
        return nil
    }

    private func add(_ item: BookClassification, in shown: [BookClassification]) {
        selection = neighbor(of: item, in: shown)?.fileHash
        Task { await library.confirmClassification(item) }
    }

    private func reject(_ item: BookClassification, in shown: [BookClassification]) {
        selection = neighbor(of: item, in: shown)?.fileHash
        withAnimation(.easeOut(duration: 0.2)) { library.dismissClassification(item) }
    }

    private func move(_ delta: Int, in shown: [BookClassification], current: BookClassification?) {
        guard let current, let i = shown.firstIndex(where: { $0.fileHash == current.fileHash }) else { return }
        let j = min(max(i + delta, 0), shown.count - 1)
        selection = shown[j].fileHash
    }

    // MARK: List

    private func listColumn(
        all: [BookClassification], likely: [BookClassification], unlikely: [BookClassification],
        shown: [BookClassification], current: BookClassification?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Needs review")
                    .font(DesignTokens.serifFont(size: 28, weight: .bold))
                    .tracking(-0.6)
                Text("\(countText(all.count, "file")) the classifier was unsure about")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Segmented filter: one track, the chosen option sits raised in it.
            HStack(spacing: 2) {
                ForEach(ReviewFilter.allCases) { option in
                    let count = option == .all ? all.count : (option == .likely ? likely.count : unlikely.count)
                    let selected = filter == option
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { filter = option }
                        selection = nil
                    } label: {
                        HStack(spacing: 5) {
                            Text(option.label)
                                .font(DesignTokens.sansFont(size: 12.5, weight: selected ? .semibold : .medium))
                            Text("\(count)")
                                .font(DesignTokens.sansFont(size: 11.5))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 22)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown, id: \.fileHash) { item in
                        ReviewListRow(
                            item: item,
                            selected: item.fileHash == current?.fileHash
                        ) { selection = item.fileHash }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 8) {
                Button { pendingBulk = .addLikely } label: {
                    Text("Add \(likely.count) likely")
                }
                .buttonStyle(.pw(.primary, size: .small, fullWidth: true))
                .disabled(likely.isEmpty)

                Button { pendingBulk = .skipUnlikely } label: {
                    Text("Skip \(unlikely.count) unlikely")
                }
                .buttonStyle(.pw(.soft, size: .small, fullWidth: true))
                .disabled(unlikely.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: Detail

    private func detailColumn(current: BookClassification?, shown: [BookClassification]) -> some View {
        Group {
            if let item = current {
                ReviewDetail(
                    item: item,
                    position: (shown.firstIndex { $0.fileHash == item.fileHash } ?? 0) + 1,
                    total: shown.count,
                    onAdd: { add(item, in: shown) },
                    onReject: { reject(item, in: shown) }
                )
                .id(item.fileHash)
            } else {
                Text("Nothing in this list.")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dog.fill")
                .font(.system(size: 46))
                .foregroundStyle(DesignTokens.accent)
            Text("Nothing left to review.")
                .font(DesignTokens.serifFont(size: 26, weight: .bold))
                .tracking(-0.5)
            Text("Files that might be books will show up here for a decision.")
                .font(DesignTokens.sansFont(size: 13.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Review thumbnails

/// Loads the first page of a file from the shared cover cache.
private struct ReviewImageLoader {
    static func load(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if let cached = CoverThumbnailCache.shared.thumbnail(for: url.path) {
            completion(cached)
            return
        }
        CoverThumbnailCache.shared.loadThumbnail(for: url, completion: completion)
    }
}

private enum ReviewNaming {
    /// Turns "_OceanofPDF.com_The_33_strategies_of_war_-_Robert_Greene.pdf"
    /// into "The 33 strategies of war, Robert Greene".
    static func clean(_ raw: String) -> String {
        var s = (raw as NSString).deletingPathExtension
        for junk in ["_OceanofPDF.com_", "OceanofPDF.com", "oceanofpdf.com", "(z-lib.org)", "z-lib.org"] {
            s = s.replacingOccurrences(of: junk, with: " ", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "_-_", with: ", ")
        s = s.replacingOccurrences(of: " - ", with: ", ")
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: "[-_ ][0-9a-fA-F]{8,}$", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,-"))
        guard let first = s.first else { return raw }
        return first.uppercased() + s.dropFirst()
    }
}

private struct ReviewListRow: View {
    let item: BookClassification
    let selected: Bool
    let onSelect: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    private var fileName: String {
        ReviewNaming.clean(item.fileName.isEmpty ? item.sourceURL.lastPathComponent : item.fileName)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ZStack {
                    DesignTokens.paper
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                }
                .frame(width: 32, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(DesignTokens.sansFont(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.sourceURL.deletingLastPathComponent().lastPathComponent)
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(Int(item.score * 100))")
                    .font(DesignTokens.sansFont(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(item.score >= 0.5 ? DesignTokens.accentInk : Color.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.1) : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { ReviewImageLoader.load(item.sourceURL) { image = $0 } }
    }
}

private struct ReviewDetail: View {
    let item: BookClassification
    let position: Int
    let total: Int
    let onAdd: () -> Void
    let onReject: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?

    private var fileName: String {
        ReviewNaming.clean(item.fileName.isEmpty ? item.sourceURL.lastPathComponent : item.fileName)
    }

    private var verdict: String {
        if item.score >= 0.6 { return "Probably a book" }
        if item.score >= 0.45 { return "Could be either" }
        return "Probably not a book"
    }

    private var facts: String {
        let values = try? item.sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let size = values?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let kind = item.sourceURL.pathExtension.uppercased()
        let folder = item.sourceURL.deletingLastPathComponent().lastPathComponent
        return [kind, size, "in \(folder)"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(position) of \(total)")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.top, 26)

            // The cover sits on a small deck: the next files wait behind it.
            ZStack {
                if total - position >= 2 {
                    deckCard.scaleEffect(0.88).offset(y: -26).opacity(0.35)
                }
                if total - position >= 1 {
                    deckCard.scaleEffect(0.94).offset(y: -13).opacity(0.6)
                }
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.2), radius: 24, x: 0, y: 14)
                    } else {
                        Image(systemName: "doc")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: 340, maxHeight: .infinity)
            .padding(.vertical, 36)

            VStack(spacing: 8) {
                Text(fileName)
                    .font(DesignTokens.serifFont(size: 30, weight: .bold))
                    .tracking(-0.8)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("\(verdict), \(Int(item.score * 100))% match")
                    .font(DesignTokens.sansFont(size: 14, weight: .medium))
                    .foregroundStyle(item.score >= 0.5 ? DesignTokens.accentInk : Color.secondary)
                Text(facts)
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 40)

            HStack(spacing: 8) {
                Button(action: onReject) {
                    Label("Not a book", systemImage: "xmark")
                }
                .buttonStyle(.pw(.danger, size: .large))

                Button(action: onAdd) {
                    Label("Add to library", systemImage: "plus")
                }
                .buttonStyle(.pw(.primary, size: .large))

                Button { NSWorkspace.shared.open(item.sourceURL) } label: {
                    Label("Open file", systemImage: "arrow.up.forward")
                }
                .buttonStyle(.pw(.ghost, size: .large))
            }
            .padding(.top, 26)

            Text("Return adds it. Delete skips it.")
                .font(DesignTokens.sansFont(size: 12))
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .onAppear { ReviewImageLoader.load(item.sourceURL) { image = $0 } }
    }

    private var deckCard: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DesignTokens.paper)
            .aspectRatio(0.7, contentMode: .fit)
            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 6)
    }
}

// MARK: - DuplicatesTray

/// Books that look like the same work saved more than once. A quiet list of
/// groups on the left; on the right the copies sit side by side so you can
/// compare format, size and location, then keep one or keep them all.
struct DuplicatesTray: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: String?
    @State private var pendingKeep: Book?
    @State private var pendingDeleteAll: [Book]?
    @State private var pendingDeleteExtras = false

    private func key(_ group: [Book]) -> String { group.first?.contentHash ?? "" }

    var body: some View {
        let groups = library.duplicateGroups
        let current = groups.first { key($0) == selection } ?? groups.first

        return Group {
            if groups.isEmpty {
                emptyState
            } else {
                stage(groups: groups, current: current)
            }
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .confirmationDialog(
            "Keep only this copy?",
            isPresented: Binding(get: { pendingKeep != nil }, set: { if !$0 { pendingKeep = nil } }),
            titleVisibility: .visible
        ) {
            if let keeper = pendingKeep, let current {
                let others = current.filter { $0.persistentModelID != keeper.persistentModelID }
                Button("Move \(others.count) other cop\(others.count == 1 ? "y" : "ies") to the Trash", role: .destructive) {
                    selection = neighbor(of: current, in: groups).map(key)
                    for book in others { library.deleteFile(for: book) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The other files go to the Recycle Bin, so you can still get them back.")
        }
        .confirmationDialog(
            "Delete every copy?",
            isPresented: Binding(get: { pendingDeleteAll != nil }, set: { if !$0 { pendingDeleteAll = nil } }),
            titleVisibility: .visible
        ) {
            if let all = pendingDeleteAll {
                Button("Move all \(all.count) copies to the Recycle Bin", role: .destructive) {
                    selection = neighbor(of: all, in: groups).map(key)
                    for book in all { library.deleteFile(for: book) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The book will leave your library. You can restore it from the Recycle Bin.")
        }
        .confirmationDialog(
            "Delete the extra copies of every book?",
            isPresented: $pendingDeleteExtras,
            titleVisibility: .visible
        ) {
            let extras = groups.reduce(0) { $0 + $1.count - 1 }
            Button("Move \(extras) extra file\(extras == 1 ? "" : "s") to the Recycle Bin", role: .destructive) {
                selection = nil
                library.deleteExtraCopies(in: groups)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps the largest copy of each book. You can restore anything from the Recycle Bin.")
        }
    }

    // MARK: Actions

    private func neighbor(of group: [Book], in groups: [[Book]]) -> [Book]? {
        guard let i = groups.firstIndex(where: { key($0) == key(group) }) else { return nil }
        if i + 1 < groups.count { return groups[i + 1] }
        if i > 0 { return groups[i - 1] }
        return nil
    }

    private func keepAll(_ group: [Book], in groups: [[Book]]) {
        selection = neighbor(of: group, in: groups).map(key)
        withAnimation(.easeOut(duration: 0.2)) {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    library.dismissDuplicate(group[i], group[j])
                }
            }
        }
    }

    // MARK: Stage

    private func stage(groups: [[Book]], current: [Book]?) -> some View {
        let index = current.flatMap { c in groups.firstIndex { key($0) == key(c) } } ?? 0
        let extras = groups.reduce(0) { $0 + $1.count - 1 }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Duplicates")
                        .font(DesignTokens.serifFont(size: 34, weight: .bold))
                        .tracking(-0.9)
                    Text("\(groups.count) book\(groups.count == 1 ? "" : "s") saved more than once, \(extras) extra file\(extras == 1 ? "" : "s") in all.")
                        .font(DesignTokens.sansFont(size: 13.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button { pendingDeleteExtras = true } label: {
                    Label("Clean up all", systemImage: "sparkles")
                }
                .buttonStyle(.pw(.danger, size: .small))
                .help("Keep the largest copy of every book and delete the rest")
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)

            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(groups, id: \.first?.contentHash) { group in
                            DuplicateSetChip(group: group, selected: key(group) == current.map(key)) {
                                withAnimation(.easeOut(duration: 0.18)) { selection = key(group) }
                            }
                            .id(key(group))
                        }
                    }
                    .padding(.horizontal, 36)
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selection) { _, new in
                    if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            .padding(.top, 20)

            if let group = current {
                comparison(group: group, groups: groups, index: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func comparison(group: [Book], groups: [[Book]], index: Int) -> some View {
        let largest = group.map(\.sizeBytes).max() ?? 0
        let best = group.first { $0.sizeBytes == largest }
        let bestIsUnique = group.filter { $0.sizeBytes == largest }.count == 1

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(group.first?.title ?? "Untitled")
                    .font(DesignTokens.serifFont(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .lineLimit(1)
                Text("\(group.count) copies")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(index + 1) of \(groups.count)")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                Button {
                    if index > 0 { withAnimation { selection = key(groups[index - 1]) } }
                } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.pw(.neutral, size: .small))
                    .disabled(index == 0)
                Button {
                    if index + 1 < groups.count { withAnimation { selection = key(groups[index + 1]) } }
                } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.pw(.neutral, size: .small))
                    .disabled(index + 1 >= groups.count)
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(group.enumerated()), id: \.element.persistentModelID) { i, book in
                        DuplicateCopyRow(
                            book: book,
                            isBest: bestIsUnique && book.persistentModelID == best?.persistentModelID,
                            onKeep: { pendingKeep = book },
                            onDelete: {
                                if group.count <= 2 { selection = neighbor(of: group, in: groups).map(key) }
                                library.deleteFile(for: book)
                            }
                        )
                        if i < group.count - 1 {
                            Rectangle()
                                .fill(DesignTokens.hairline(colorScheme: colorScheme))
                                .frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
        }
        .id(key(group))
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Button { pendingKeep = best ?? group.first } label: {
                    Label("Keep best, delete the rest", systemImage: "checkmark")
                }
                .buttonStyle(.pw(.primary))

                Button { keepAll(group, in: groups) } label: { Text("Keep all") }
                    .buttonStyle(.pw(.soft))

                Button { pendingDeleteAll = group } label: {
                    Label("Delete all", systemImage: "trash")
                }
                .buttonStyle(.pw(.danger))
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DesignTokens.elevatedSurface)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.14), radius: 18, x: 0, y: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1))
            .padding(.bottom, 24)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square")
                .font(.system(size: 44))
                .foregroundStyle(DesignTokens.accent)
            Text("No duplicates.")
                .font(DesignTokens.serifFont(size: 26, weight: .bold))
                .tracking(-0.5)
            Text("Every book in your library looks distinct.")
                .font(DesignTokens.sansFont(size: 13.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Duplicate rows and copies

private struct DuplicateSetChip: View {
    let group: [Book]
    let selected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Group {
                    if let first = group.first {
                        MattedCoverView(book: first, cornerRadius: 3, showBadge: false)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 28, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.first?.title ?? "Untitled")
                        .font(DesignTokens.sansFont(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text("\(group.count) copies")
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 56, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.primary.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0.035))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct DuplicateCopyRow: View {
    let book: Book
    let isBest: Bool
    let onKeep: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var size: String {
        ByteCountFormatter.string(fromByteCount: book.sizeBytes, countStyle: .file)
    }

    private var folder: String {
        (book.sourceURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            MattedCoverView(book: book, cornerRadius: 6, showBadge: false)
                .frame(width: 64)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.16), radius: 10, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text(book.format.sectionTitle)
                        .font(DesignTokens.sansFont(size: 16, weight: .semibold))
                    if isBest {
                        Text("Best copy")
                            .font(DesignTokens.sansFont(size: 11.5, weight: .semibold))
                            .foregroundStyle(DesignTokens.accentInk)
                            .padding(.horizontal, 9)
                            .frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignTokens.accent.opacity(0.2)))
                    }
                }
                Text("\(size), added \(book.addedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
                Text(folder)
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.pw(.ghost, size: .small))
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")

                Button(action: onKeep) { Text("Keep this one") }
                    .buttonStyle(.pw(.neutral, size: .small))

                Button(action: onDelete) { Text("Delete") }
                    .buttonStyle(.pw(.danger, size: .small))
            }
        }
        .padding(.vertical, 18)
    }
}


// MARK: - Recycle Bin

/// Deleted books wait here until you restore them or empty the bin.
struct RecycleBinView: View {
    let onRestored: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmEmpty = false
    @State private var hoveredID: UUID?

    private struct DayGroup: Identifiable {
        let title: String
        let items: [RecycledBook]
        var id: String { title }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var today: [RecycledBook] = [], yesterday: [RecycledBook] = [], earlier: [RecycledBook] = []
        for item in library.recycleBin {
            if calendar.isDateInToday(item.deletedAt) { today.append(item) }
            else if calendar.isDateInYesterday(item.deletedAt) { yesterday.append(item) }
            else { earlier.append(item) }
        }
        return [DayGroup(title: "Today", items: today),
                DayGroup(title: "Yesterday", items: yesterday),
                DayGroup(title: "Earlier", items: earlier)].filter { !$0.items.isEmpty }
    }

    var body: some View {
        let items = library.recycleBin
        return Group {
            if items.isEmpty { emptyState } else { content(items) }
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .confirmationDialog("Empty the Recycle Bin?", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("Delete \(items.count) file\(items.count == 1 ? "" : "s") forever", role: .destructive) {
                withAnimation(.easeOut(duration: 0.25)) { library.emptyRecycleBin() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the files. It can\u{2019}t be undone.")
        }
    }

    // MARK: Content

    private func content(_ items: [RecycledBook]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recycle Bin")
                            .font(DesignTokens.serifFont(size: 42, weight: .bold))
                            .tracking(-1.2)
                        Text("\(items.count) deleted \(items.count == 1 ? "book" : "books"). Restoring puts the file back exactly where it was.")
                            .font(DesignTokens.sansFont(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button { confirmEmpty = true } label: {
                        Label("Empty bin", systemImage: "trash")
                    }
                    .buttonStyle(.pw(.danger))
                }

                ForEach(groups) { group in
                    Text(group.title)
                        .font(DesignTokens.sansFont(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 44)
                        .padding(.bottom, 8)
                    VStack(spacing: 2) {
                        ForEach(group.items) { item in
                            row(item)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                }

                Text("These files also sit in your Mac\u{2019}s Trash. Emptying the bin here deletes them for good.")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 40)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, 36)
            .padding(.bottom, DesignTokens.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ item: RecycledBook) -> some View {
        let hovered = hoveredID == item.id
        let size = ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
        let when = item.deletedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))

        return HStack(spacing: 18) {
            // No cover survives deletion, so a flat paper tile stands in.
            Text(String(item.title.prefix(1)).uppercased())
                .font(DesignTokens.serifFont(size: 20, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: 44, height: 58)
                .background(DesignTokens.placeholderGradient(for: item.title),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.14), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(DesignTokens.serifFont(size: 18, weight: .bold))
                    .tracking(-0.2)
                    .lineLimit(1)
                Text([item.author, item.formatName, size, "deleted \(when)"]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", "))
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        if library.restore(item) { onRestored() }
                    }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.pw(.soft, size: .small))

                Button {
                    withAnimation(.easeOut(duration: 0.25)) { library.deleteForever(item) }
                } label: {
                    Text("Delete forever")
                }
                .buttonStyle(.pw(.ghost, size: .small))
                .opacity(hovered ? 1 : 0.55)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.05 : 0))
        )
        .onHover { inside in hoveredID = inside ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dog")
                .font(.system(size: 46))
                .foregroundStyle(DesignTokens.accent)
            Text("Nothing in the bin.")
                .font(DesignTokens.serifFont(size: 30, weight: .bold))
                .tracking(-0.7)
            Text("Nothing here, even after a good sniff.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
