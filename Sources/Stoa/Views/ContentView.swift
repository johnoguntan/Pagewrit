import SwiftUI
import Foundation
import UniformTypeIdentifiers

// MARK: - GridDensity

/// How much of the library grid a viewer sees at once. Persisted across
/// launches via @AppStorage so a chosen density sticks.
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
    @State private var searchText = ""
    @State private var sortOrder: SortOption = .recentlyAdded
    @State private var importTaskID: UUID?
    @AppStorage("stoa.gridDensity") private var gridDensityRaw: String = GridDensity.comfortable.rawValue
    @State private var spotlightBook: Book?
    @State private var showDownloadBooks = false

    private var gridDensity: GridDensity {
        GridDensity(rawValue: gridDensityRaw) ?? .comfortable
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case title
        case author
        case recentlyAdded
        case format

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .title: "Title"
            case .author: "Author"
            case .recentlyAdded: "Recently Added"
            case .format: "Format"
            }
        }

        var systemImage: String {
            switch self {
            case .title: "textformat.abc"
            case .author: "person"
            case .recentlyAdded: "clock"
            case .format: "doc.plaintext"
            }
        }
    }

    // MARK: - Computed data

    /// Books scoped by the sidebar selection, then narrowed by search.
    private var filteredBooks: [Book] {
        var books = library.books

        switch sidebarSelection {
        case .library, .needsReview, .none:
            break  // show all books
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
            books = books.filter { $0.author == name }
        }

        guard !searchText.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
                || library.contentSearchMatchHashes.contains($0.contentHash)
        }
    }

    /// Every distinct tag across the library, alphabetically, for the
    /// sidebar's TAGS section — only shown once at least one book has one.
    private var allTags: [String] {
        Set(library.books.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Every distinct author across the library, alphabetically, for the
    /// sidebar's AUTHORS section — books with no author (or a blank one)
    /// have nothing to browse by, so they're simply left out.
    private var allAuthors: [String] {
        let names = library.books.compactMap { $0.author?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var sortedBooks: [Book] {
        switch sortOrder {
        case .title:
            filteredBooks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            filteredBooks.sorted {
                ($0.author ?? "ZZZ").localizedStandardCompare($1.author ?? "ZZZ") == .orderedAscending
            }
        case .recentlyAdded:
            filteredBooks.sorted { $0.addedAt > $1.addedAt }
        case .format:
            filteredBooks.sorted { $0.formatRaw.localizedStandardCompare($1.formatRaw) == .orderedAscending }
        }
    }

    private var booksByFormat: [(title: String, books: [Book])] {
        let grouped = Dictionary(grouping: sortedBooks) { $0.format }
        return BookFormat.allCases.compactMap { format in
            guard let books = grouped[format], !books.isEmpty else { return nil }
            return (format.sectionTitle, books)
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
        library.books.max { $0.addedAt < $1.addedAt }
    }

    /// The book to resume, if anything is in progress.
    private var continueReadingBook: Book? {
        library.continueReading.first
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
            .filter { !shownHashes.contains($0.contentHash) && ($0.readingProgress ?? 0) == 0 }
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
    private var heroEntries: [(book: Book, kind: HeroKind)] {
        var entries: [(book: Book, kind: HeroKind)] = []
        var shownHashes: Set<String> = []

        if let resuming = continueReadingBook {
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

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // navigationDestination(for:) must live inside the detail
            // column's own navigation stack, not chained onto the
            // NavigationSplitView itself — attached there, SwiftUI logs
            // "misplaced navigationDestination... it will be ignored" and
            // NavigationLink(value:) taps silently do nothing.
            NavigationStack {
                detailContent
                    .navigationDestination(for: Book.self) { book in
                        BookDetailView(book: book)
                            .environmentObject(library)
                    }
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search books \u{2014} titles, tags, and book contents")
        .onChange(of: searchText) { _, newValue in
            library.searchContent(newValue)
        }
        .sheet(item: $spotlightBook) { book in
            BookReaderSheet(book: book)
                .environmentObject(library)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stoaOpenBookFromSpotlight)) { note in
            guard let hash = note.object as? String,
                  let book = library.books.first(where: { $0.contentHash == hash })
            else { return }
            spotlightBook = book
        }
        .onReceive(NotificationCenter.default.publisher(for: .stoaBooksDownloaded)) { note in
            // Import just the one file that was downloaded, not a full
            // rescan — walking every watched folder and re-hashing all
            // ~40+ existing books for one new file is what made a single
            // download feel like it triggered a long "scanning" pass.
            if let url = note.object as? URL {
                Task { await importSingleFile(at: url) }
            } else {
                Task { await rescanAndImport() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stoaRequestFullRescan)) { _ in
            Task { await rescanAndImport() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                densityMenu
                sortMenu
                Button {
                    showDownloadBooks = true
                } label: {
                    Label("Get Books", systemImage: "arrow.down.circle")
                }
                .help("Search and download free public-domain books")
                Button {
                    exportCurrentListAsMarkdown()
                } label: {
                    Label("Export List", systemImage: "square.and.arrow.up")
                }
                .disabled(sortedBooks.isEmpty)
                .help("Export the books currently shown as a Markdown list")
                Button {
                    Task { await rescanAndImport() }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(scanner.isScanning || library.isImporting)
            }
        }
        .tint(DesignTokens.accent)
        .background(DesignTokens.background.ignoresSafeArea())
        .task {
            if library.books.isEmpty {
                await rescanAndImport()
            }
        }
        .sheet(isPresented: $library.showSettings) {
            SettingsView()
                .environmentObject(scanner)
                .environmentObject(library)
        }
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
        case .library, .needsReview, .none:
            return "All Books"
        case .folder(let path):
            return URL(fileURLWithPath: path).lastPathComponent
        case .format(let rawValue):
            return BookFormat(rawValue: rawValue)?.sectionTitle ?? "Books"
        case .tag(let tag):
            return "#\(tag)"
        case .author(let name):
            return name
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
    private func rescanAndImport() async {
        await scanner.scan()

        let hashedFiles: [(file: DiscoveredFile, hash: String)] = await withTaskGroup(of: (DiscoveredFile, String).self) { group in
            for file in scanner.discoveredFiles {
                group.addTask {
                    let hash = await Task.detached(priority: .userInitiated) {
                        ImportPipeline.contentHash(for: file.url)
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

        let newFiles = hashedFiles.filter { _, hash in
            !library.contains(hash: hash) && library.classification(for: hash) == nil
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

    // MARK: - Sort Menu

    private var sortMenu: some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    sortOrder = option
                } label: {
                    Label(option.displayName, systemImage: option.systemImage)
                        .overlay(alignment: .trailing) {
                            if sortOrder == option {
                                Image(systemName: "checkmark")
                                    .padding(.trailing, -20)
                            }
                        }
                }
            }
        } label: {
            Label(sortOrder.displayName, systemImage: sortOrder.systemImage)
        }
    }

    // MARK: - Density Menu

    private var densityMenu: some View {
        Menu {
            ForEach(GridDensity.allCases) { density in
                Button {
                    gridDensityRaw = density.rawValue
                } label: {
                    Label(density.displayName, systemImage: density.systemImage)
                        .overlay(alignment: .trailing) {
                            if gridDensity == density {
                                Image(systemName: "checkmark")
                                    .padding(.trailing, -20)
                            }
                        }
                }
            }
        } label: {
            Label(gridDensity.displayName, systemImage: gridDensity.systemImage)
        }
    }

    // MARK: - Sidebar selection

    enum SidebarSelection: Hashable {
        case library
        case needsReview
        case folder(String)
        case format(String)
        case tag(String)
        case author(String)
    }

    @State private var sidebarSelection: SidebarSelection? = .library

    // MARK: - Sidebar
    //
    // Built as a plain ScrollView/VStack rather than List(.sidebar): List's
    // implicit AppKit row insets don't line up with a custom safeAreaInset
    // header, which left the "Stoa" mark, section labels, and row icons all
    // starting at very slightly different x-positions. Composing the inset
    // ourselves (outerMargin + rowContentInset, both applied consistently
    // below) guarantees the app mark, section labels, and every row icon
    // share one left edge.

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                sidebarRow(title: "All Books", icon: "books.vertical", selection: .library)

                if !library.needsReview.isEmpty {
                    sidebarRow(
                        title: "Needs Review",
                        icon: "questionmark.diamond",
                        selection: .needsReview,
                        badge: "\(library.needsReview.count)"
                    )
                }

                sidebarSectionLabel("WATCHED FOLDERS")

                ForEach(scanner.allWatchedFolders, id: \.self) { folder in
                    sidebarRow(
                        title: folder.lastPathComponent,
                        icon: "folder",
                        selection: .folder(folder.path)
                    )
                }

                sidebarSectionLabel("FORMATS")

                ForEach(BookFormat.allCases, id: \.self) { format in
                    sidebarRow(
                        title: format.sectionTitle,
                        icon: format.systemImage,
                        selection: .format(format.rawValue),
                        iconColor: DesignTokens.formatColor(for: format)
                    )
                }

                if !allAuthors.isEmpty {
                    sidebarSectionLabel("AUTHORS")

                    ForEach(allAuthors, id: \.self) { author in
                        sidebarRow(title: author, icon: "person", selection: .author(author))
                    }
                }

                if !allTags.isEmpty {
                    sidebarSectionLabel("TAGS")

                    ForEach(allTags, id: \.self) { tag in
                        sidebarRow(title: tag, icon: "tag", selection: .tag(tag))
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Sidebar.outerMargin)
            .padding(.bottom, DesignTokens.Spacing.md)
        }
        .background(.ultraThinMaterial)
        .safeAreaInset(edge: .top) {
            sidebarAppMark
                .padding(.horizontal, DesignTokens.Sidebar.contentInset)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xxs)
        }
        .frame(width: DesignTokens.Sidebar.width)
    }

    /// One selectable row, wired to `sidebarSelection` directly — replaces
    /// List's native tap-to-select now that the sidebar isn't a List.
    private func sidebarRow(
        title: String,
        icon: String,
        selection: SidebarSelection,
        iconColor: Color? = nil,
        badge: String? = nil
    ) -> some View {
        SidebarRow(
            title: title,
            icon: icon,
            isSelected: sidebarSelection == selection,
            iconColor: iconColor,
            badge: badge
        )
        .contentShape(Rectangle())
        .onTapGesture {
            sidebarSelection = selection
        }
    }

    // MARK: - Sidebar App Mark

    private var sidebarAppMark: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: DesignTokens.Sidebar.AppMark.size,
                    height: DesignTokens.Sidebar.AppMark.size
                )
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(
                    cornerRadius: DesignTokens.Sidebar.AppMark.cornerRadius
                ))

            Text("Stoa")
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

        @State private var isHovered = false

        var body: some View {
            HStack(spacing: DesignTokens.Sidebar.iconLabelGap) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.Sidebar.fontSize, weight: .medium))
                    .foregroundStyle(isSelected ? DesignTokens.accent : (iconColor ?? .secondary))
                    .frame(width: 16, alignment: .leading)
                Text(title)
                    .font(.system(size: DesignTokens.Sidebar.fontSize))
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .foregroundColor(isSelected ? DesignTokens.accent : .primary)

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(DesignTokens.accent, in: Capsule())
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, DesignTokens.Sidebar.rowPaddingV)
            .padding(.horizontal, DesignTokens.Sidebar.contentInset)
            .frame(height: DesignTokens.Sidebar.rowHeight)
            .background(
                isSelected
                    ? DesignTokens.accent.opacity(0.14)
                    : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowCornerRadius))
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
    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.sansFont(
                size: DesignTokens.Sidebar.SectionLabel.fontSize,
                weight: .semibold
            ))
            .tracking(DesignTokens.Sidebar.SectionLabel.tracking)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, DesignTokens.Sidebar.contentInset)
            .padding(.top, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        VStack(spacing: 0) {
            if scanner.isScanning {
                ProgressView("Scanning\u{2026}")
                    .padding(.vertical, DesignTokens.Spacing.lg)
            }

            if library.isImporting && library.importProgress < 1.0 {
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
            } else if sortedBooks.isEmpty && !scanner.isScanning && !library.isImporting {
                emptyState
            } else {
                ScrollView {
                    if searchText.isEmpty, !heroEntries.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
                                ForEach(heroEntries, id: \.book.contentHash) { entry in
                                    HeroBand(book: entry.book, kind: entry.kind)
                                        .frame(width: DesignTokens.Hero.cardWidth)
                                }
                            }
                            .padding(.horizontal, DesignTokens.Spacing.xl)
                        }
                        .padding(.top, DesignTokens.Spacing.lg)
                    }

                    LazyVGrid(columns: columns, spacing: gridDensity.gridSpacing) {
                        ForEach(booksByFormat, id: \.title) { section in
                            Section {
                                ForEach(section.books) { book in
                                    NavigationLink(value: book) {
                                        BookCoverTile(book: book, density: gridDensity)
                                    }
                                    .buttonStyle(.plain)
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
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text("No Books Found")
                .font(DesignTokens.serifFont(size: 20, weight: .semibold))

            Text("Click Rescan to search your Documents, Desktop, and Downloads folders.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
    @State private var showReader = false

    private var relativeAdded: String {
        Self.relativeString(for: book.addedAt)
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
            RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius)
                .fill(DesignTokens.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius)
                        .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1)
                )

            RadialGradient(
                colors: [DesignTokens.accent.opacity(DesignTokens.Hero.glowOpacity), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 360
            )
            .allowsHitTesting(false)

            HStack(alignment: .center, spacing: DesignTokens.Spacing.xl) {
                MattedCoverView(book: book, cornerRadius: 11)
                    .frame(width: DesignTokens.Hero.coverWidth)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.5 : 0.25),
                        radius: 18, x: 0, y: 12
                    )

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
                            weight: .semibold
                        ))
                        .tracking(DesignTokens.Hero.Eyebrow.tracking)
                        .foregroundStyle(kind.usesAccentEyebrow ? AnyShapeStyle(DesignTokens.accent) : AnyShapeStyle(.tertiary))
                        .textCase(.uppercase)
                        .padding(.bottom, DesignTokens.Hero.Rhythm.afterEyebrow)

                    Text(book.title)
                        .font(DesignTokens.serifFont(
                            size: DesignTokens.Hero.Title.fontSize,
                            weight: .semibold
                        ))
                        .tracking(DesignTokens.Hero.Title.tracking)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(height: DesignTokens.Hero.Title.blockHeight, alignment: .topLeading)
                        .padding(.bottom, DesignTokens.Hero.Rhythm.afterTitle)

                    VStack(alignment: .leading, spacing: DesignTokens.Hero.Rhythm.beforeMeta) {
                        switch kind {
                        case .continueReading:
                            Text("\(Int((book.readingProgress ?? 0) * 100))% \u{00b7} last opened \(relativeOpened)")
                                .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            ProgressBar(fraction: book.readingProgress ?? 0)
                                .frame(width: 220, height: 4)
                        case .recentlyAdded:
                            Text("\(book.format.rawValue.uppercased()) \u{00b7} \(relativeAdded)")
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
                            Text("Added \(relativeAdded) \u{00b7} not started yet")
                                .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: DesignTokens.Hero.Meta.blockHeight, alignment: .top)

                    Button {
                        showReader = true
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
                        .foregroundStyle(.white)
                        .padding(.vertical, DesignTokens.Hero.Button.paddingV)
                        .padding(.horizontal, DesignTokens.Hero.Button.paddingH)
                        .background(DesignTokens.accent, in: Capsule())
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
        .sheet(isPresented: $showReader) {
            BookReaderSheet(book: book)
                .environmentObject(library)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius))
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
    }
}

// MARK: - BookCoverTile

/// Single cover-art tile in the library grid.
struct BookCoverTile: View {
    let book: Book
    var density: GridDensity = .comfortable
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var showReader = false
    @State private var showDeleteConfirmation = false

    private var secondaryLine: String {
        if let author = book.author, !author.isEmpty {
            return author
        }
        return book.format.rawValue.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            MattedCoverView(book: book)
                .shadow(
                    color: DesignTokens.Shadow.tight(colorScheme: colorScheme).color,
                    radius: DesignTokens.Shadow.tight(colorScheme: colorScheme).radius,
                    x: 0,
                    y: DesignTokens.Shadow.tight(colorScheme: colorScheme).y
                )
                .shadow(
                    color: DesignTokens.Shadow.soft(colorScheme: colorScheme).color,
                    radius: DesignTokens.Shadow.soft(colorScheme: colorScheme).radius,
                    x: 0,
                    y: DesignTokens.Shadow.soft(colorScheme: colorScheme).y
                )

            Text(book.title)
                .font(DesignTokens.serifFont(
                    size: DesignTokens.Grid.Title.fontSize,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)
                .lineLimit(density.titleLineLimit)
                .frame(
                    height: density == .compact ? nil : DesignTokens.Grid.Title.blockHeight,
                    alignment: .topLeading
                )
                .help(book.title)

            // Author when the file's metadata actually has one — a
            // one-line title card next to a two-line one otherwise stays
            // aligned but says less than it could. Falls back to format
            // when there's no author to show.
            Text(secondaryLine)
                .font(DesignTokens.sansFont(size: DesignTokens.Grid.Author.fontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .offset(y: isHovered ? DesignTokens.Hover.gridLiftY : 0)
        .scaleEffect(isHovered ? DesignTokens.Hover.gridScale : 1.0)
        .animation(
            .spring(
                response: DesignTokens.Hover.gridSpringResponse,
                dampingFraction: DesignTokens.Hover.dampingFraction
            ),
            value: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
        // highPriorityGesture, not gesture: the tile sits inside a
        // NavigationLink (for single-click navigation to the detail
        // view). A plain .gesture() loses the first tap of a double-click
        // to the NavigationLink's own tap recognizer, so double-clicking
        // to jump straight into the reader was unreliable — it would
        // often just navigate to the detail view instead.
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded { showReader = true }
        )
        .contextMenu {
            Button {
                showReader = true
            } label: {
                Label("Read", systemImage: "book.fill")
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
            Text("This moves the file itself to the Trash, not just Stoa's library entry. This can't be undone from inside Stoa.")
        }
        .sheet(isPresented: $showReader) {
            BookReaderSheet(book: book)
                .environmentObject(library)
        }
    }
}

// MARK: - MattedCoverView

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

    private var monogram: String {
        String(book.title.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if let coverURL = book.coverImageURL {
                fullBleedCover(url: coverURL)
            } else if book.format == .pdf {
                mattedPDF
            } else {
                fullBleedPlaceholder
            }

            if showBadge {
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
        .onAppear {
            loadThumbnail()
        }
    }

    // MARK: - Matted PDF

    private var mattedPDF: some View {
        ZStack {
            DesignTokens.placeholderGradient(for: book.sourcePath)

            GeometryReader { geo in
                let paperSize = CGSize(
                    width: geo.size.width * DesignTokens.Mat.paperWidthFraction,
                    height: geo.size.height * DesignTokens.Mat.paperHeightFraction
                )

                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius)
                        .fill(DesignTokens.paper)
                        .frame(width: paperSize.width, height: paperSize.height)
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)

                    if let thumbnail, thumbnailLoaded {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
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
        ZStack {
            DesignTokens.placeholderGradient(for: book.sourcePath)

            Text(monogram)
                .font(DesignTokens.serifFont(size: 48, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .aspectRatio(DesignTokens.Grid.Cover.aspectRatio, contentMode: .fill)
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        Text(book.format.rawValue.uppercased())
            .font(DesignTokens.sansFont(
                size: DesignTokens.Badge.fontSize,
                weight: .bold
            ))
            .tracking(DesignTokens.Badge.tracking)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.vertical, DesignTokens.Badge.paddingV)
            .padding(.horizontal, DesignTokens.Badge.paddingH)
            .background(
                .black.opacity(0.22),
                in: RoundedRectangle(cornerRadius: DesignTokens.Badge.cornerRadius)
            )
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() {
        if book.format == .pdf {
            // PDFs: use CoverThumbnailCache for live rendering
            CoverThumbnailCache.shared.loadThumbnail(for: book.sourceURL) { image in
                if let image {
                    withAnimation(.easeIn(duration: 0.25)) {
                        thumbnail = image
                        thumbnailLoaded = true
                    }
                }
            }
        } else if let coverURL = book.coverImageURL {
            // EPUB/CBZ with persisted cover art
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOf: coverURL)
                DispatchQueue.main.async {
                    if let img {
                        withAnimation(.easeIn(duration: 0.25)) {
                            thumbnail = img
                            thumbnailLoaded = true
                        }
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

/// Lists PDFs that scored in the "needs review" range (0.3...0.7).
/// Each item shows a thumbnail and two actions: Add to Library / Not a Book.
struct NeedsReviewTray: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if library.needsReview.isEmpty {
                emptyState
            } else {
                header
                list
            }
        }
        .background(DesignTokens.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text("Needs Review")
                    .font(DesignTokens.serifFont(
                        size: DesignTokens.SectionHeader.fontSize,
                        weight: .bold
                    ))
                    .tracking(DesignTokens.SectionHeader.tracking)
                    .foregroundStyle(.primary)

                Text("\(library.needsReview.count) file\(library.needsReview.count == 1 ? "" : "s") the classifier wasn't sure about")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.sm)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(library.needsReview) { classification in
                    ReviewRow(classification: classification)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.xxl)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("All clear")
                .font(DesignTokens.serifFont(size: 18, weight: .semibold))

            Text("No files need review right now.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - ReviewRow

/// A single row in the Needs Review tray: thumbnail + title + score + two actions.
private struct ReviewRow: View {
    let classification: BookClassification
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: NSImage?

    private var fileName: String {
        classification.fileName.isEmpty
            ? classification.sourceURL.lastPathComponent
            : classification.fileName
    }

    private var folderName: String {
        classification.sourceURL.deletingLastPathComponent().lastPathComponent
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            // Thumbnail — try to render from PDF if available
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(DesignTokens.paper)
                    .frame(width: 48, height: 64)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 48, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(fileName)
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(folderName)
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Score: \(Int(classification.score * 100))%")
                        .font(DesignTokens.sansFont(size: 11))
                        .foregroundStyle(.secondary)

                    Text("\(classification.decidedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(DesignTokens.sansFont(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            HStack(spacing: DesignTokens.Spacing.xs) {
                Button {
                    library.dismissClassification(classification)
                } label: {
                    Text("Not a Book")
                        .font(DesignTokens.sansFont(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.separator, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    Task { await library.confirmClassification(classification) }
                } label: {
                    Text("Add to Library")
                        .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DesignTokens.accent, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1)
        )
        .onAppear {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        guard classification.sourceURL.pathExtension.lowercased() == "pdf" else { return }
        CoverThumbnailCache.shared.loadThumbnail(for: classification.sourceURL) { image in
            withAnimation(.easeIn(duration: 0.25)) {
                thumbnail = image
            }
        }
    }
}
