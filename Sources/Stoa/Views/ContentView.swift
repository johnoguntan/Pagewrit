import SwiftUI
import Foundation

// MARK: - ContentView

/// Library grid view with warm, luxurious palette and serif-accented typography.
/// All values sourced from DesignTokens. Reads from `LibraryStore.books` (real
/// persisted `Book` records) rather than the scanner's raw `DiscoveredFile` list.
struct ContentView: View {
    @EnvironmentObject private var scanner: ScannerService
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var selectedFileID: String?
    @State private var sortOrder: SortOption = .recentlyAdded
    @State private var importTaskID: UUID?

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

        if let selectedFileID {
            if let format = BookFormat(rawValue: selectedFileID) {
                books = books.filter { $0.format == format }
            } else {
                let folderPath = selectedFileID.hasSuffix("/") ? selectedFileID : selectedFileID + "/"
                books = books.filter { $0.sourcePath.hasPrefix(folderPath) }
            }
        }

        guard !searchText.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.author?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
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
    private var mostRecentBook: Book? {
        library.books.max { $0.addedAt > $1.addedAt }
    }

    // MARK: - Grid layout

    private let columns = [
        GridItem(
            .adaptive(minimum: DesignTokens.Grid.columnMinimum),
            spacing: DesignTokens.Grid.spacing
        )
    ]

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .navigationTitle("Library")
        .navigationDestination(for: Book.self) { book in
            BookDetailView(book: book)
                .environmentObject(library)
        }
        .searchable(text: $searchText, prompt: "Search books")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                sortMenu
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
    }

    // MARK: - Scan + Import pipeline

    /// Scan for files, then import any new ones into the library.
    private func rescanAndImport() async {
        await scanner.scan()

        let newFiles = scanner.discoveredFiles.filter { file in
            !library.contains(hash: ImportPipeline.contentHash(for: file.url))
        }

        guard !newFiles.isEmpty else { return }

        library.isImporting = true
        importTaskID = UUID()

        for (index, file) in newFiles.enumerated() {
            library.importProgress = Double(index) / Double(newFiles.count)
            if let book = await ImportPipeline.importFile(file, libraryFolder: library.libraryFolder) {
                library.add(book)
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

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedFileID) {
            Section {
                sidebarRow(
                    title: "All Books",
                    icon: "books.vertical",
                    isSelected: selectedFileID == nil
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedFileID = nil
                }
            }

            Section(header: sidebarSectionLabel("WATCHED FOLDERS")) {
                ForEach(scanner.allWatchedFolders, id: \.self) { folder in
                    sidebarRow(
                        title: folder.lastPathComponent,
                        icon: "folder",
                        isSelected: selectedFileID == folder.path
                    )
                    .tag(folder.path)
                }
            }

            Section(header: sidebarSectionLabel("FORMATS")) {
                ForEach(BookFormat.allCases, id: \.self) { format in
                    sidebarRow(
                        title: format.sectionTitle,
                        icon: format.systemImage,
                        isSelected: selectedFileID == format.rawValue
                    )
                    .tag(format.rawValue)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DesignTokens.surface.ignoresSafeArea())
        .safeAreaInset(edge: .top) {
            sidebarAppMark
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xxs)
        }
        .frame(width: DesignTokens.Sidebar.width)
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
        }
    }

    // MARK: - Sidebar Row

    private func sidebarRow(title: String, icon: String, isSelected: Bool) -> some View {
        HStack(spacing: DesignTokens.Sidebar.iconLabelGap) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Sidebar.fontSize, weight: .medium))
                .frame(width: 16)
            Text(title)
                .font(.system(size: DesignTokens.Sidebar.fontSize))
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundColor(isSelected ? DesignTokens.accent : .primary)
            Spacer()
        }
        .padding(.vertical, DesignTokens.Sidebar.rowPaddingV)
        .padding(.horizontal, DesignTokens.Sidebar.rowPaddingH)
        .background(
            isSelected
                ? DesignTokens.accent.opacity(0.12)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowCornerRadius))
    }

    // MARK: - Sidebar Section Label

    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.sansFont(
                size: DesignTokens.Sidebar.SectionLabel.fontSize,
                weight: .semibold
            ))
            .tracking(DesignTokens.Sidebar.SectionLabel.tracking)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
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

            if sortedBooks.isEmpty && !scanner.isScanning && !library.isImporting {
                emptyState
            } else {
                ScrollView {
                    if searchText.isEmpty, let mostRecent = mostRecentBook {
                        HeroBand(book: mostRecent)
                            .padding(.horizontal, DesignTokens.Spacing.xl)
                            .padding(.top, DesignTokens.Spacing.lg)
                    }

                    LazyVGrid(columns: columns, spacing: DesignTokens.Grid.spacing) {
                        ForEach(booksByFormat, id: \.title) { section in
                            Section {
                                ForEach(section.books) { book in
                                    NavigationLink(value: book) {
                                        BookCoverTile(book: book)
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

// MARK: - HeroBand

/// Full-width spotlight above the grid: the most recently added book, big.
/// Structured as a HeroState enum so Phase 3 can swap in a "Continue Reading"
/// variant (progress bar + Resume) without rewriting the view.
struct HeroBand: View {
    let book: Book
    @Environment(\.colorScheme) private var colorScheme

    private var relativeAdded: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: book.addedAt, relativeTo: Date())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius)
                .fill(DesignTokens.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                )

            RadialGradient(
                colors: [DesignTokens.accent.opacity(DesignTokens.Hero.glowOpacity), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 340
            )
            .allowsHitTesting(false)

            HStack(alignment: .center, spacing: DesignTokens.Spacing.xl) {
                MattedCoverView(book: book, cornerRadius: 10)
                    .frame(width: DesignTokens.Hero.coverWidth)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.5 : 0.25),
                        radius: 16, x: 0, y: 10
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recently added")
                        .font(DesignTokens.sansFont(
                            size: DesignTokens.Hero.Eyebrow.fontSize,
                            weight: .semibold
                        ))
                        .tracking(DesignTokens.Hero.Eyebrow.tracking)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    Text(book.title)
                        .font(DesignTokens.serifFont(
                            size: DesignTokens.Hero.Title.fontSize,
                            weight: .semibold
                        ))
                        .tracking(DesignTokens.Hero.Title.tracking)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("\(book.format.rawValue.uppercased()) \u{00b7} \(relativeAdded)")
                        .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, DesignTokens.Spacing.xs)

                    Button {
                        NSWorkspace.shared.open(book.sourceURL)
                    } label: {
                        Text("Open")
                            .font(DesignTokens.sansFont(
                                size: DesignTokens.Hero.Button.fontSize,
                                weight: .semibold
                            ))
                            .foregroundStyle(.white)
                            .padding(.vertical, DesignTokens.Hero.Button.paddingV)
                            .padding(.horizontal, DesignTokens.Hero.Button.paddingH)
                            .background(
                                DesignTokens.accent,
                                in: RoundedRectangle(cornerRadius: DesignTokens.Hero.Button.cornerRadius)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: DesignTokens.Hero.height)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius))
    }
}

// MARK: - BookCoverTile

/// Single cover-art tile in the library grid.
struct BookCoverTile: View {
    let book: Book
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

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
                .lineLimit(2)

            Text(book.format.rawValue.uppercased())
                .font(DesignTokens.sansFont(size: DesignTokens.Grid.Author.fontSize))
                .foregroundStyle(.secondary)
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
        .contextMenu {
            Button {
                NSWorkspace.shared.open(book.sourceURL)
            } label: {
                Label("Open", systemImage: "doc.text")
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

    @State private var thumbnail: NSImage?
    @State private var thumbnailLoaded = false

    private var monogram: String {
        String(book.title.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if book.format == .pdf {
                mattedPDF
            } else if let coverURL = book.coverImageURL {
                fullBleedCover(url: coverURL)
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
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
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
