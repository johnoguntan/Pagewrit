import SwiftUI
import PDFKit

// MARK: - PDFReaderView

/// In-app PDF reader. Wraps PDFKit's `PDFView` and brings it up to parity
/// with the EPUB reader: an outline sidebar, manual zoom, a go-to-page
/// jump, in-document search, bookmarks, and a reading theme \u{2014} on top of
/// the page tracking and progress persistence it already had.
struct PDFReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @Environment(\.colorScheme) private var colorScheme
    @State private var document: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var pageCount: Int = 0
    @State private var loadFailed = false

    @State private var outline: [PDFOutlineEntry] = []
    @State private var showOutline = false
    @State private var showBookmarks = false
    @State private var showPageJump = false
    @State private var pageJumpText = ""

    @State private var scaleFactor: CGFloat = 1.0
    @State private var fitScaleFactor: CGFloat = 1.0
    @State private var jumpToPageIndex: Int?

    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [PDFSelection] = []
    @State private var currentSearchIndex: Int = 0
    @State private var activeSelection: PDFSelection?

    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue
    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .system }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSearch {
                searchBar
            }

            if loadFailed {
                failureState
            } else if let document {
                PDFKitRepresentedView(
                    document: document,
                    currentPageIndex: $currentPageIndex,
                    scaleFactor: $scaleFactor,
                    fitScaleFactor: $fitScaleFactor,
                    jumpToPageIndex: $jumpToPageIndex,
                    activeSelection: activeSelection,
                    backgroundColor: readerTheme.pdfBackgroundNSColor
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(readerBackground)
            }
        }
        .frame(minWidth: 780, minHeight: 620)
        .background(readerBackground.ignoresSafeArea())
        .onAppear(perform: load)
        .onAppear { library.markOpened(book) }
        .onChange(of: currentPageIndex) { _, newValue in
            saveProgress(pageIndex: newValue)
        }
        .focusable()
        .onKeyPress(.rightArrow) { goToPage(currentPageIndex + 1); return .handled }
        .onKeyPress(.leftArrow) { goToPage(currentPageIndex - 1); return .handled }
    }

    private var readerBackground: Color {
        readerTheme.backgroundColor ?? DesignTokens.background
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(book.title)
                .font(DesignTokens.serifFont(size: 15, weight: .semibold))
                .foregroundStyle(readerTheme.textColor ?? .primary)
                .lineLimit(1)

            Spacer()

            if pageCount > 0 {
                Button {
                    pageJumpText = String(currentPageIndex + 1)
                    showPageJump = true
                } label: {
                    Text("Page \(currentPageIndex + 1) of \(pageCount)")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPageJump, arrowEdge: .bottom) {
                    pageJumpPopover
                }
            }

            outlineButton
            searchButton
            bookmarkButton
            zoomControls
            themeMenu

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(readerTheme.chromeColor ?? DesignTokens.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.hairline(colorScheme: colorScheme))
                .frame(height: 1)
        }
    }


    // MARK: - Go to Page

    private var pageJumpPopover: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            TextField("Page", text: $pageJumpText)
                .textFieldStyle(.plain)
                .frame(width: 60)
                .onSubmit { submitPageJump() }
            Text("of \(pageCount)")
                .font(DesignTokens.sansFont(size: 12))
                .foregroundStyle(.secondary)
            Button("Go") { submitPageJump() }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.accent)
        }
        .padding(DesignTokens.Spacing.sm)
    }

    private func submitPageJump() {
        guard let target = Int(pageJumpText) else { return }
        goToPage(target - 1)
        showPageJump = false
    }

    private func goToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        jumpToPageIndex = min(max(index, 0), pageCount - 1)
    }

    // MARK: - Outline

    private var outlineButton: some View {
        Button {
            showOutline = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13))
                .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
        }
        .buttonStyle(.plain)
        .disabled(outline.isEmpty)
        .help("Table of contents")
        .popover(isPresented: $showOutline, arrowEdge: .bottom) {
            outlineList
        }
    }

    private var outlineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(outline) { entry in
                    Button {
                        goToPage(entry.pageIndex)
                        showOutline = false
                    } label: {
                        HStack {
                            Text(entry.title)
                                .font(DesignTokens.sansFont(
                                    size: 13,
                                    weight: entry.pageIndex == currentPageIndex ? .semibold : .regular
                                ))
                                .foregroundStyle(
                                    entry.pageIndex == currentPageIndex
                                        ? DesignTokens.accent
                                        : Color.primary
                                )
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, DesignTokens.Spacing.sm + CGFloat(entry.depth) * 14)
                        .padding(.trailing, DesignTokens.Spacing.sm)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, DesignTokens.Spacing.xs)
        }
        .frame(width: 280, height: 360)
    }

    // MARK: - Zoom

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                scaleFactor = max(scaleFactor * 0.87, fitScaleFactor * 0.4)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            .help("Zoom out")

            Button {
                scaleFactor = fitScaleFactor
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            .help("Fit page to window")

            Button {
                scaleFactor = min(scaleFactor * 1.15, fitScaleFactor * 4)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            .help("Zoom in")
        }
        .padding(.trailing, DesignTokens.Spacing.xs)
    }

    // MARK: - Theme

    private var themeMenu: some View {
        Menu {
            ForEach(ReaderTheme.allCases) { theme in
                Button {
                    readerThemeRaw = theme.rawValue
                } label: {
                    if theme == readerTheme {
                        Label(theme.label, systemImage: "checkmark")
                    } else {
                        Text(theme.label)
                    }
                }
            }
        } label: {
            Image(systemName: readerTheme.icon)
                .font(.system(size: 13))
                .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reading theme")
        .padding(.trailing, DesignTokens.Spacing.xs)
    }

    // MARK: - Bookmarks

    private var isCurrentPageBookmarked: Bool {
        guard pageCount > 0 else { return false }
        let position = Double(currentPageIndex) / Double(max(pageCount - 1, 1))
        return library.bookmarks(for: book).contains {
            abs($0.position - position) < (1.0 / Double(max(pageCount, 1))) / 2
        }
    }

    private var bookmarkButton: some View {
        Button {
            if let existing = library.bookmarks(for: book).first(where: { bookmark in
                guard pageCount > 0 else { return false }
                let position = Double(currentPageIndex) / Double(max(pageCount - 1, 1))
                return abs(bookmark.position - position) < (1.0 / Double(max(pageCount, 1))) / 2
            }) {
                library.removeBookmark(existing)
            } else {
                showBookmarks = true
            }
        } label: {
            Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13))
                .foregroundStyle(isCurrentPageBookmarked ? DesignTokens.accent : (readerTheme.secondaryTextColor ?? .secondary))
        }
        .buttonStyle(.plain)
        .help(isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page \u{2014} or hold to browse bookmarks")
        .contextMenu {
            Button("Browse Bookmarks") { showBookmarks = true }
        }
        .padding(.trailing, DesignTokens.Spacing.xs)
        .popover(isPresented: $showBookmarks, arrowEdge: .bottom) {
            bookmarksPopover
        }
    }

    private var bookmarksPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Bookmarks")
                    .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addBookmarkHere()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)

            let saved = library.bookmarks(for: book)
            if saved.isEmpty {
                Text("No bookmarks yet")
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(DesignTokens.Spacing.sm)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(saved, id: \.persistentModelID) { bookmark in
                            HStack {
                                Button {
                                    goToPage(Int((bookmark.position * Double(max(pageCount - 1, 1))).rounded()))
                                    showBookmarks = false
                                } label: {
                                    Text(bookmark.label)
                                        .font(DesignTokens.sansFont(size: 13))
                                        .foregroundStyle(.primary)
                                }
                                .buttonStyle(.plain)

                                Spacer()

                                Button {
                                    library.removeBookmark(bookmark)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 240)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }

    private func addBookmarkHere() {
        guard pageCount > 0 else { return }
        let position = Double(currentPageIndex) / Double(max(pageCount - 1, 1))
        library.addBookmark(for: book, position: position, label: "Page \(currentPageIndex + 1)")
    }

    // MARK: - Search

    private var searchButton: some View {
        Button {
            showSearch.toggle()
            if !showSearch { clearSearch() }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(showSearch ? DesignTokens.accent : (readerTheme.secondaryTextColor ?? .secondary))
        }
        .buttonStyle(.plain)
        .help("Search this document")
        .padding(.trailing, DesignTokens.Spacing.xs)
    }

    private var searchBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search in document\u{2026}", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DesignTokens.sansFont(size: 13))
                .onSubmit { runSearch() }
                .onChange(of: searchQuery) { _, _ in runSearch() }

            if !searchResults.isEmpty {
                Text("\(currentSearchIndex + 1) of \(searchResults.count)")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(.tertiary)

                Button {
                    stepSearch(-1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)

                Button {
                    stepSearch(1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
            } else if !searchQuery.isEmpty {
                Text("No results")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button {
                showSearch = false
                clearSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, 7)
        .background(DesignTokens.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.hairline(colorScheme: colorScheme))
                .frame(height: 1)
        }
    }

    private func runSearch() {
        guard let document else { return }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSearch()
            return
        }
        searchResults = document.findString(trimmed, withOptions: .caseInsensitive)
        currentSearchIndex = 0
        selectCurrentSearchResult()
    }

    private func clearSearch() {
        searchResults = []
        currentSearchIndex = 0
        activeSelection = nil
    }

    private func stepSearch(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + delta + searchResults.count) % searchResults.count
        selectCurrentSearchResult()
    }

    private func selectCurrentSearchResult() {
        guard searchResults.indices.contains(currentSearchIndex) else {
            activeSelection = nil
            return
        }
        let selection = searchResults[currentSearchIndex]
        activeSelection = selection
        if let page = selection.pages.first, let document {
            jumpToPageIndex = document.index(for: page)
        }
    }

    // MARK: - Failure State

    private var failureState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Couldn't open this PDF.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func load() {
        guard document == nil else { return }
        guard let doc = PDFDocument(url: book.sourceURL) else {
            loadFailed = true
            return
        }
        pageCount = doc.pageCount
        if let progress = book.readingProgress, pageCount > 1 {
            currentPageIndex = min(max(Int((progress * Double(pageCount - 1)).rounded()), 0), pageCount - 1)
        }
        outline = flattenOutline(doc.outlineRoot, document: doc)
        document = doc
    }

    private func flattenOutline(_ node: PDFOutline?, depth: Int = 0, document: PDFDocument) -> [PDFOutlineEntry] {
        guard let node else { return [] }
        var entries: [PDFOutlineEntry] = []

        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            if let label = child.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let pageIndex: Int
                if let destPage = child.destination?.page {
                    pageIndex = document.index(for: destPage)
                } else {
                    pageIndex = 0
                }
                entries.append(PDFOutlineEntry(title: label, depth: depth, pageIndex: pageIndex))
            }
            entries.append(contentsOf: flattenOutline(child, depth: depth + 1, document: document))
        }
        return entries
    }

    private func saveProgress(pageIndex: Int) {
        guard pageCount > 1 else { return }
        let progress = Double(pageIndex) / Double(pageCount - 1)
        library.updateProgress(for: book, progress: progress)
    }
}

/// One flattened, navigable row in the PDF's outline (bookmarks/TOC pane).
struct PDFOutlineEntry: Identifiable {
    let id = UUID()
    let title: String
    let depth: Int
    let pageIndex: Int
}

// MARK: - PDFKitRepresentedView

/// NSViewRepresentable bridge to PDFKit's `PDFView`, reporting the current
/// page back up via a binding whenever the user scrolls or navigates, and
/// accepting page-jump, zoom, and search-highlight commands from SwiftUI.
private struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var scaleFactor: CGFloat
    @Binding var fitScaleFactor: CGFloat
    @Binding var jumpToPageIndex: Int?
    let activeSelection: PDFSelection?
    let backgroundColor: NSColor?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = backgroundColor ?? .windowBackgroundColor
        view.autoScales = false

        if let page = document.page(at: currentPageIndex) {
            DispatchQueue.main.async {
                view.go(to: page)
                let fit = view.scaleFactorForSizeToFit
                fitScaleFactor = fit
                scaleFactor = fit
                view.scaleFactor = fit
                view.window?.makeFirstResponder(view)
            }
        }

        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if let backgroundColor {
            nsView.backgroundColor = backgroundColor
        }

        if abs(nsView.scaleFactor - scaleFactor) > 0.001 {
            nsView.scaleFactor = scaleFactor
        }

        if let target = jumpToPageIndex, let page = document.page(at: target) {
            nsView.go(to: page)
            DispatchQueue.main.async { jumpToPageIndex = nil }
        }

        if let activeSelection, activeSelection !== context.coordinator.lastAppliedSelection {
            context.coordinator.lastAppliedSelection = activeSelection
            nsView.setCurrentSelection(activeSelection, animate: true)
            nsView.scrollSelectionToVisible(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        let parent: PDFKitRepresentedView
        weak var pdfView: PDFView?
        var lastAppliedSelection: PDFSelection?

        init(_ parent: PDFKitRepresentedView) {
            self.parent = parent
        }

        // NotificationCenter.addObserver(_:selector:name:object:) retains
        // its target \u{2014} without this, every PDF opened leaves its
        // Coordinator (and the PDFView it references) alive forever, and
        // .PDFViewPageChanged keeps firing into a reader that's long since
        // been dismissed. dismantleNSView (below) is the NSViewRepresentable
        // hook for exactly this kind of teardown.
        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func pageChanged() {
            guard let pdfView, let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            parent.currentPageIndex = index
        }
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: nsView)
    }
}
