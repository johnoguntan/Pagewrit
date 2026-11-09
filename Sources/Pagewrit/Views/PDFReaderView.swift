import SwiftUI
import PDFKit
import SwiftData
import CoreImage

// MARK: - Layout & page filter

/// How pages are laid out. Scroll is the default; Single turns one page at a
/// time; Two-up shows facing pages like an open book.
enum PDFPageLayout: String, CaseIterable, Identifiable {
    case scroll, single, spread

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: "Scroll"
        case .single: "Single"
        case .spread: "Two-up"
        }
    }

    var mode: PDFDisplayMode {
        switch self {
        case .scroll: .singlePageContinuous
        case .single: .singlePage
        case .spread: .twoUpContinuous
        }
    }
}

/// PDF pages are pictures, so themes work by filtering the rendered page:
/// Sepia warms it, Night inverts it (keeping photo hues roughly right).
enum PDFPageFilter {
    case none, sepia, night

    var filters: [CIFilter] {
        switch self {
        case .none:
            return []
        case .sepia:
            return [CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])].compactMap { $0 }
        case .night:
            return [
                CIFilter(name: "CIColorInvert"),
                CIFilter(name: "CIHueAdjust", parameters: [kCIInputAngleKey: Double.pi]),
                CIFilter(name: "CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.07,
                    kCIInputContrastKey: 0.9
                ])
            ].compactMap { $0 }
        }
    }
}

/// One search hit: where it is and a line of surrounding text.
struct PDFSearchHit: Identifiable {
    let id = UUID()
    let selection: PDFSelection
    let pageIndex: Int
    let context: String
}

// MARK: - PDFReaderView

/// In-app PDF reader, matching the EPUB reader's design: the page fills the
/// window and the controls float above it.
///
/// - Header: contents drawer, title and section, search, bookmark,
///   appearance, focus mode.
/// - Appearance: theme, page layout, zoom.
/// - Drawer: Contents / Bookmarks / Search results.
/// - Footer: draggable scrubber across the whole document with section
///   ticks, the current section, page number and percent.
/// - Focus mode: hides the chrome; hover the top or bottom edge to bring it back.
struct PDFReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismissWindow) private var dismissWindow
    /// Pagewrit's own light or dark look, read straight from the app rather
    /// than this window, which the reader theme may have forced. "Auto"
    /// follows this, and it updates the instant the app look changes.
    @ObservedObject private var appearanceWatcher = AppearanceWatcher.shared
    private var colorScheme: ColorScheme { appearanceWatcher.scheme }

    // Document state
    @State private var document: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var pageCount: Int = 0
    @State private var loadFailed = false
    @State private var looksScanned = false
    @ObservedObject private var ocr = OCRManager.shared
    @State private var outline: [PDFOutlineEntry] = []
    @State private var scrubValue: Double?

    // Highlights
    @State private var hasSelection = false
    @State private var highlightRequest: PDFHighlightRequest?
    @State private var selectedHighlightID: PersistentIdentifier?

    // Zoom & jumps
    @State private var scaleFactor: CGFloat = 1.0
    @State private var fitScaleFactor: CGFloat = 1.0
    @State private var jumpToPageIndex: Int?

    // Search
    @State private var searchQuery = ""
    @State private var searchResults: [PDFSearchHit] = []
    @State private var currentSearchIndex: Int = 0
    @State private var activeSelection: PDFSelection?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchCapped = false
    @State private var collapsedSearchPages: Set<Int> = []
    @State private var searchPageOnly = false
    @AppStorage("pagewrit.searchMatchCase") private var searchMatchCase = false
    @AppStorage("pagewrit.searchWholeWord") private var searchWholeWord = false
    @AppStorage(SearchHistory.key) private var searchHistoryRaw = ""
    @FocusState private var searchFocused: Bool

    // Chrome
    @State private var sidebarTab: ReaderSidebarTab?
    @State private var showAppearance = false
    @State private var showPageJump = false
    @State private var pageJumpText = ""
    @State private var focusMode = false
    @State private var hoverTop = false
    @State private var hoverBottom = false

    // Preferences
    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("stoa.pdfPageTint") private var pageTintRaw: String = "original"
    @AppStorage("stoa.pdfLayout") private var layoutRaw: String = PDFPageLayout.scroll.rawValue

    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .system }
    private var palette: ReaderPalette { readerTheme.palette(for: colorScheme) }
    private var layout: PDFPageLayout { PDFPageLayout(rawValue: layoutRaw) ?? .scroll }

    /// Page colour is its own setting, separate from the reader theme (which
    /// the EPUB reader shares), so a document is never recoloured unless you
    /// ask for it here.
    private var pageFilter: PDFPageFilter {
        switch pageTintRaw {
        case "sepia": .sepia
        case "invert": .night
        default: .none
        }
    }

    private let headerHeight: CGFloat = 52
    private let footerHeight: CGFloat = 78
    private let maxSearchResults = 500

    // Palette shorthands
    private var pageColor: Color { Color(nsColor: palette.background) }
    private var chromeColor: Color { Color(nsColor: palette.chrome) }
    private var textColor: Color { Color(nsColor: palette.text) }
    private var tint: Color { Color(nsColor: palette.secondary) }
    private var accent: Color { Color(nsColor: palette.link) }
    private var rule: Color { Color(nsColor: palette.rule) }

    // MARK: - Body

    var body: some View {
        ZStack {
            page
            hoverStrips
            SelectionHighlightBar(
                visible: hasSelection,
                tint: tint, accent: accent, pageColor: Color(nsColor: palette.background)
            ) { color, note in highlightRequest = PDFHighlightRequest(color: color, wantsNote: note) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, footerHeight + 18)
            drawer
            chromeLayer
            if focusMode && !chromeVisible { FocusExitPill(tint: tint) { focusMode = false } }
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(ReaderWindowAppearance(theme: readerTheme))
        // Native controls (tab pickers, switches) follow the reader theme, not the Mac.
        .environment(\.colorScheme, readerTheme.controlScheme(system: colorScheme))
        .background(pageColor.ignoresSafeArea())
        .background(shortcuts)
        .onAppear(perform: load)
        .onAppear { library.markOpened(book) }
        .onDisappear { library.commitReading() }
        .onChange(of: focusMode) { _, on in if on { sidebarTab = nil; showAppearance = false; showPageJump = false } }
        .onAppear {
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { checkExternalJump() }
            }
        }
        .onChange(of: library.jumpRequest) { _, _ in checkExternalJump() }
        .overlay(alignment: .top) {
            ocrBanner
                .padding(.top, focusMode ? 12 : headerHeight + 10)
                .padding(.horizontal, 16)
        }
        .onChange(of: ocr.jobs[book.contentHash]?.done ?? false) { _, done in
            // The searchable copy is ready: reopen it so find, selection and read-aloud work.
            guard done else { return }
            document = nil
            looksScanned = false
            load()
        }
        .onChange(of: currentPageIndex) { _, newValue in
            if searchPageOnly && sidebarTab == .search { runSearch() }
            saveProgress(pageIndex: newValue)
        }
        .focusable()
        .onKeyPress(.rightArrow) { goToPage(currentPageIndex + 1); return .handled }
        .onKeyPress(.leftArrow) { goToPage(currentPageIndex - 1); return .handled }
        .onKeyPress(.escape) {
            if sidebarTab != nil { sidebarTab = nil; return .handled }
            if focusMode { focusMode = false; return .handled }
            return .ignored
        }
    }

    // MARK: - Page

    @ViewBuilder
    private var page: some View {
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
                highlights: library.highlights(for: book).filter { $0.rangeLength > 0 },
                highlightRequest: $highlightRequest,
                hasSelection: $hasSelection,
                onCreateHighlights: { drafts, color, wantsNote in
                    createHighlights(drafts, color: color, wantsNote: wantsNote)
                },
                onTapHighlight: { id in
                    selectedHighlightID = id
                    sidebarTab = .notes
                },
                backgroundColor: palette.background,
                layout: layout,
                filter: pageFilter,
                topInset: 0,
                bottomInset: 0
            )
            .padding(.top, focusMode ? 0 : headerHeight)
            .padding(.bottom, focusMode ? 0 : footerHeight)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var failureState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(tint)
            Text("Couldn't open this PDF.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome layer

    private var chromeVisible: Bool {
        !focusMode
    }

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            ReaderToolbarFit { header }
                .onHover { hoverTop = $0 }
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
            Spacer(minLength: 0).allowsHitTesting(false)
            footer
                .onHover { hoverBottom = $0 }
                .opacity(chromeVisible ? 1 : 0)
                .allowsHitTesting(chromeVisible)
        }
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
    }

    private var hoverStrips: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40).contentShape(Rectangle())
                .onHover { hoverTop = $0 }
            Spacer(minLength: 0).allowsHitTesting(false)
            Color.clear.frame(height: 40).contentShape(Rectangle())
                .onHover { hoverBottom = $0 }
        }
        .allowsHitTesting(false)
    }

    private func chromeSurface(edge: Alignment) -> some View {
        chromeColor.opacity(0.95)
            .overlay(alignment: edge) {
                Rectangle().fill(rule).frame(height: 1)
            }
    }

    // MARK: - Header

    private var currentSectionTitle: String? {
        outline.last(where: { $0.pageIndex <= currentPageIndex })?.title
    }

    private var header: some View {
        HStack(spacing: 4) {
            ReaderIconButton(
                systemName: "sidebar.left", help: "Contents (\u{2318}L)",
                isActive: sidebarTab == .contents, tint: tint, accent: accent
            ) { toggleSidebar(.contents) }

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(DesignTokens.serifFont(size: 14, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                if let section = currentSectionTitle {
                    Text(section)
                        .font(DesignTokens.sansFont(size: 11))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)

            Spacer(minLength: 12)

            ReaderIconButton(
                systemName: "magnifyingglass", help: "Search this document (\u{2318}F)",
                isActive: sidebarTab == .search, tint: tint, accent: accent
            ) { openSearch() }
            .disabled(document == nil)

            highlightMenu

            ReaderIconButton(
                systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                help: isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page",
                isActive: isCurrentPageBookmarked, tint: tint, accent: accent
            ) { toggleBookmark() }
            .disabled(document == nil)

            ReaderIconButton(
                systemName: "textformat.size", help: "Appearance and zoom",
                isActive: showAppearance, tint: tint, accent: accent
            ) { showAppearance.toggle() }
            .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                appearancePanel
                    .background(ReaderWindowAppearance(theme: readerTheme))
                    .readerControls(readerTheme, system: colorScheme)
            }

            ReaderIconButton(
                systemName: focusMode
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: focusMode ? "Exit focus mode (\u{2318}\u{21E7}F)" : "Focus mode (\u{2318}\u{21E7}F)",
                isActive: focusMode, tint: tint, accent: accent
            ) { focusMode.toggle() }

            ReadingTimerPill(tint: tint, accent: accent)


            Rectangle().fill(rule).frame(width: 1, height: 18).padding(.horizontal, 4)

            ReaderIconButton(
                systemName: "xmark", help: "Close",
                isActive: false, tint: tint, accent: accent
            ) { dismissWindow() }
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
        .background(chromeSurface(edge: .bottom))
    }

    // MARK: - Appearance panel

    private var zoomRatio: Binding<Double> {
        Binding(
            get: { Double(scaleFactor / max(fitScaleFactor, 0.01)) },
            set: { scaleFactor = CGFloat($0) * fitScaleFactor }
        )
    }

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom")
                        .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int((zoomRatio.wrappedValue * 100).rounded()))%")
                        .font(DesignTokens.sansFont(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Button("Fit") { scaleFactor = fitScaleFactor }
                        .buttonStyle(.plain)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(accent)
                        .disabled(abs(zoomRatio.wrappedValue - 1) < 0.005)
                }
                HStack(spacing: 10) {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 12)).foregroundStyle(tint)
                    Slider(value: zoomRatio, in: 0.5...3.0)
                        .tint(accent)
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 12)).foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Background").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                HStack(spacing: 14) {
                    ForEach(ReaderTheme.allCases) { theme in
                        ThemeSwatch(
                            theme: theme,
                            isSelected: theme == readerTheme,
                            systemScheme: colorScheme,
                            accent: accent,
                            label: textColor
                        ) { readerThemeRaw = theme.rawValue }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Page colour").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Page colour", selection: $pageTintRaw) {
                    Text("Original").tag("original")
                    Text("Sepia").tag("sepia")
                    Text("Inverted").tag("invert")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Original shows the document exactly as its author made it.")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Page layout").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Page layout", selection: $layoutRaw) {
                    ForEach(PDFPageLayout.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider().overlay(rule)

            Button {
                scaleFactor = fitScaleFactor
                layoutRaw = PDFPageLayout.scroll.rawValue
                pageTintRaw = "original"
                readerThemeRaw = ReaderTheme.system.rawValue
            } label: {
                Text("Reset all to defaults")
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(textColor)
        .padding(18)
        .frame(width: 320)
        .background(chromeColor)
    }

    // MARK: - Drawer

    @ViewBuilder
    private var drawer: some View {
        if sidebarTab != nil {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Picker("Section", selection: Binding(
                        get: { sidebarTab ?? .contents },
                        set: { sidebarTab = $0 }
                    )) {
                        ForEach(ReaderSidebarTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(12)

                    switch sidebarTab ?? .contents {
                    case .contents: contentsList
                    case .bookmarks: bookmarksList
                    case .notes: notesPanel
                    case .search: searchPanel
                    }
                }
                .frame(width: 330)
                .background(chromeColor)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(rule).frame(width: 1)
                }

                Color.black.opacity(palette.isDark ? 0.35 : 0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { sidebarTab = nil }
            }
            .padding(.top, headerHeight)
            .padding(.bottom, footerHeight)
            .transition(.opacity)
        }
    }

    private func toggleSidebar(_ tab: ReaderSidebarTab) {
        withAnimation(.easeOut(duration: 0.2)) {
            sidebarTab = (sidebarTab == tab) ? nil : tab
        }
    }

    private func openSearch() {
        withAnimation(.easeOut(duration: 0.2)) { sidebarTab = .search }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocused = true }
    }

    // Contents

    private var currentOutlineID: UUID? {
        outline.last(where: { $0.pageIndex <= currentPageIndex })?.id
    }

    @ViewBuilder
    private var contentsList: some View {
        if outline.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "list.bullet").font(.system(size: 24)).foregroundStyle(tint.opacity(0.6))
                Text("This PDF has no table of contents")
                    .font(DesignTokens.sansFont(size: 13)).foregroundStyle(tint)
                Text("Use the scrubber below to move around.")
                    .font(DesignTokens.sansFont(size: 12)).foregroundStyle(tint.opacity(0.8))
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(outline) { entry in
                            let isCurrent = entry.id == currentOutlineID
                            Button {
                                goToPage(entry.pageIndex)
                                sidebarTab = nil
                            } label: {
                                HStack(spacing: 8) {
                                    Text(entry.title)
                                        .font(DesignTokens.sansFont(size: 13, weight: isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? accent : textColor)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Text("\(entry.pageIndex + 1)")
                                        .font(DesignTokens.sansFont(size: 11))
                                        .monospacedDigit()
                                        .foregroundStyle(tint)
                                }
                                .padding(.leading, 10 + CGFloat(entry.depth) * 14)
                                .padding(.trailing, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isCurrent ? accent.opacity(0.14) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .onAppear {
                    if let id = currentOutlineID { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // Bookmarks

    private func bookmarkPosition(forPage index: Int) -> Double {
        Double(index) / Double(max(pageCount - 1, 1))
    }

    private func pageIndex(forBookmarkPosition position: Double) -> Int {
        let index = Int((position * Double(max(pageCount - 1, 1))).rounded())
        return min(max(index, 0), max(pageCount - 1, 0))
    }

    private var currentPageBookmark: Bookmark? {
        guard pageCount > 0 else { return nil }
        let position = bookmarkPosition(forPage: currentPageIndex)
        let tolerance = (1.0 / Double(max(pageCount, 1))) / 2
        return library.bookmarks(for: book).first { abs($0.position - position) < tolerance }
    }

    private var isCurrentPageBookmarked: Bool { currentPageBookmark != nil }

    private func toggleBookmark() {
        if let existing = currentPageBookmark {
            library.removeBookmark(existing)
        } else {
            guard pageCount > 0 else { return }
            library.addBookmark(
                for: book,
                position: bookmarkPosition(forPage: currentPageIndex),
                label: "Page \(currentPageIndex + 1)"
            )
        }
    }

    // MARK: - Highlights

    private var highlightMenu: some View {
        Menu {
            ForEach(HighlightColor.allCases) { color in
                Button {
                    highlightRequest = PDFHighlightRequest(color: color, wantsNote: false)
                } label: {
                    Label {
                        Text(color.label)
                    } icon: {
                        Image(nsImage: color.dotImage)
                    }
                }
            }
            Divider()
            Button {
                highlightRequest = PDFHighlightRequest(color: .yellow, wantsNote: true)
            } label: {
                Label("Highlight and add note", systemImage: "square.and.pencil")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "highlighter")
                    .font(.system(size: 14))
                Text("Highlight").font(.system(size: 12))
            }
            .foregroundStyle(hasSelection ? accent : tint)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(document == nil || !hasSelection)
        .help(hasSelection ? "Highlight the selected text" : "Select some text first, then highlight it")
    }

    private func createHighlights(_ drafts: [PDFHighlightDraft], color: HighlightColor, wantsNote: Bool) {
        var last: Highlight?
        for draft in drafts {
            last = library.addHighlight(
                bookHash: book.contentHash,
                pageIndex: draft.pageIndex,
                rangeStart: draft.rangeStart,
                rangeLength: draft.rangeLength,
                position: pageCount > 0 ? Double(draft.pageIndex) / Double(pageCount) : 0,
                text: draft.text,
                color: color
            )
        }
        if wantsNote, let last {
            selectedHighlightID = last.persistentModelID
            sidebarTab = .notes
        }
    }

    private var notesPanel: some View {
        HighlightsPanel(
            highlights: library.highlights(for: book),
            selectedID: selectedHighlightID,
            textColor: textColor, tint: tint, accent: accent,
            locationLabel: { "Page \($0.pageIndex + 1)" },
            onJump: { highlight in jump(to: highlight) },
            onAddNote: { addNoteHere() }
        )
    }

    /// A note with no selected text, pinned to the page being read.
    private func addNoteHere() {
        let created = library.addHighlight(
            bookHash: book.contentHash,
            pageIndex: currentPageIndex,
            rangeStart: 0, rangeLength: 0,
            position: pageCount > 0 ? Double(currentPageIndex) / Double(pageCount) : 0,
            text: ""
        )
        selectedHighlightID = created.persistentModelID
    }

    private func jump(to highlight: Highlight) {
        selectedHighlightID = highlight.persistentModelID
        guard let page = document?.page(at: highlight.pageIndex) else { return }
        // Go to the page first, then select the exact passage so it is shown.
        jumpToPageIndex = highlight.pageIndex
        if let selection = page.selection(for: NSRange(location: highlight.rangeStart, length: highlight.rangeLength)) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { activeSelection = selection }
        }
    }

    /// A highlight chosen in the library: open at that exact passage.
    private func checkExternalJump() {
        guard document != nil, let highlight = library.consumeJump(for: book.contentHash) else { return }
        jump(to: highlight)
    }

    private var bookmarksList: some View {
        let saved = library.bookmarks(for: book)
        return VStack(spacing: 0) {
            Button {
                toggleBookmark()
            } label: {
                Label(
                    isCurrentPageBookmarked ? "Remove bookmark from this page" : "Bookmark this page",
                    systemImage: isCurrentPageBookmarked ? "bookmark.slash" : "bookmark"
                )
                .font(DesignTokens.sansFont(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if saved.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "bookmark").font(.system(size: 24)).foregroundStyle(tint.opacity(0.6))
                    Text("No bookmarks yet")
                        .font(DesignTokens.sansFont(size: 13)).foregroundStyle(tint)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(saved, id: \.persistentModelID) { bookmark in
                            let index = pageIndex(forBookmarkPosition: bookmark.position)
                            HStack(spacing: 8) {
                                Button {
                                    goToPage(index)
                                    sidebarTab = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.label)
                                            .font(DesignTokens.sansFont(size: 13))
                                            .foregroundStyle(textColor)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        if let section = outline.last(where: { $0.pageIndex <= index })?.title {
                                            Text(section)
                                                .font(DesignTokens.sansFont(size: 11))
                                                .foregroundStyle(tint)
                                                .lineLimit(1)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    library.removeBookmark(bookmark)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(tint)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help("Remove bookmark")
                                .accessibilityLabel("Remove bookmark")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }

    // Search

    private var searchColors: SearchColors { SearchColors(text: textColor, tint: tint, accent: accent) }

    private func rememberSearch() {
        searchHistoryRaw = SearchHistory.adding(searchQuery, to: searchHistoryRaw)
    }

    private var searchGroups: [(page: Int, indices: [Int])] {
        var order: [Int] = []
        var map: [Int: [Int]] = [:]
        for (i, r) in searchResults.enumerated() {
            if map[r.pageIndex] == nil { order.append(r.pageIndex) }
            map[r.pageIndex, default: []].append(i)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var visibleSearchIndices: [Int] {
        searchResults.indices.filter { !collapsedSearchPages.contains(searchResults[$0].pageIndex) }
    }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            SearchFieldBar(
                query: $searchQuery,
                prompt: "Search this document",
                focused: $searchFocused,
                colors: searchColors,
                onSubmit: {
                    rememberSearch()
                    if !searchResults.isEmpty { sidebarTab = nil }
                },
                onUp: { moveSearchSelection(-1) },
                onDown: { moveSearchSelection(1) },
                onEscape: {
                    if !searchQuery.isEmpty { searchQuery = ""; clearSearch() } else { sidebarTab = nil }
                },
                onClear: { searchQuery = ""; clearSearch(); searchFocused = true }
            )
            .onChange(of: searchQuery) { _, _ in scheduleSearch() }

            SearchOptionsBar(
                firstScope: "This page", secondScope: "Whole document",
                firstScopeSelected: $searchPageOnly,
                matchCase: $searchMatchCase, wholeWord: $searchWholeWord,
                colors: searchColors
            )
            .onChange(of: searchPageOnly) { _, _ in runSearch() }
            .onChange(of: searchMatchCase) { _, _ in runSearch() }
            .onChange(of: searchWholeWord) { _, _ in runSearch() }

            if !searchResults.isEmpty {
                SearchStatusBar(
                    summary: searchSummary,
                    position: "\(currentSearchIndex + 1) of \(searchResults.count)",
                    colors: searchColors,
                    onPrevious: { moveSearchSelection(-1) },
                    onNext: { moveSearchSelection(1) }
                )
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(searchGroups, id: \.page) { group in
                                SearchGroupHeader(
                                    title: "Page \(group.page + 1)",
                                    count: group.indices.count,
                                    collapsed: collapsedSearchPages.contains(group.page),
                                    colors: searchColors
                                ) {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if collapsedSearchPages.contains(group.page) {
                                            collapsedSearchPages.remove(group.page)
                                        } else {
                                            collapsedSearchPages.insert(group.page)
                                        }
                                    }
                                }
                                if !collapsedSearchPages.contains(group.page) {
                                    ForEach(group.indices.filter { searchResults.indices.contains($0) }, id: \.self) { i in
                                        SearchResultRow(
                                            text: SearchMatcher.snippet(
                                                searchResults[i].context,
                                                query: searchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                                                matchCase: searchMatchCase, wholeWord: searchWholeWord,
                                                accent: accent
                                            ),
                                            selected: i == currentSearchIndex,
                                            colors: searchColors
                                        ) {
                                            currentSearchIndex = i
                                            selectCurrentSearchResult()
                                            rememberSearch()
                                        }
                                        .id(searchResults[i].id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: currentSearchIndex) { _, new in
                        guard searchResults.indices.contains(new) else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(searchResults[new].id, anchor: .center)
                        }
                    }
                }
            } else {
                SearchEmptyView(
                    query: searchQuery,
                    hints: {
                        var h: [SearchHint] = []
                        if searchPageOnly { h.append(SearchHint(title: "Search whole document") { searchPageOnly = false }) }
                        if searchWholeWord { h.append(SearchHint(title: "Turn off Word") { searchWholeWord = false }) }
                        if searchMatchCase { h.append(SearchHint(title: "Turn off Aa") { searchMatchCase = false }) }
                        return h
                    }(),
                    history: SearchHistory.list(searchHistoryRaw),
                    colors: searchColors,
                    onPickHistory: { searchQuery = $0; searchFocused = true },
                    onClearHistory: { searchHistoryRaw = "" }
                )
            }
        }
    }

    private var searchSummary: String {
        let pages = Set(searchResults.map(\.pageIndex)).count
        let n = searchResults.count
        if searchPageOnly { return "\(n)\(searchCapped ? "+" : "") on this page" }
        return "\(n)\(searchCapped ? "+" : "") match\(n == 1 ? "" : "es") on \(pages) page\(pages == 1 ? "" : "s")"
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { runSearch() }
        }
    }

    private func runSearch() {
        guard let document else { return }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            clearSearch()
            return
        }
        let wordRegex = searchWholeWord
            ? SearchMatcher.regex(for: trimmed, matchCase: searchMatchCase, wholeWord: true)
            : nil

        let options: NSString.CompareOptions = searchMatchCase ? [.literal] : [.caseInsensitive]
        let found = document.findString(trimmed, withOptions: options)

        var hits: [PDFSearchHit] = []
        var capped = false
        for selection in found {
            let pageIndex = selection.pages.first.map { document.index(for: $0) } ?? 0
            if searchPageOnly && pageIndex != currentPageIndex { continue }
            var context = selection.string ?? trimmed
            if let extended = selection.copy() as? PDFSelection {
                extended.extendForLineBoundaries()
                if let line = extended.string?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    context = line
                }
            }
            if let wordRegex,
               wordRegex.firstMatch(in: context, range: NSRange(location: 0, length: (context as NSString).length)) == nil {
                continue
            }
            hits.append(PDFSearchHit(selection: selection, pageIndex: pageIndex, context: context))
            if hits.count >= maxSearchResults { capped = true; break }
        }
        searchCapped = capped
        searchResults = hits
        collapsedSearchPages = []
        currentSearchIndex = 0
        if hits.isEmpty { activeSelection = nil }
    }

    private func clearSearch() {
        searchResults = []
        currentSearchIndex = 0
        activeSelection = nil
        searchCapped = false
    }

    private func moveSearchSelection(_ delta: Int) {
        let visible = visibleSearchIndices
        guard !visible.isEmpty else { return }
        let pos = visible.firstIndex(of: currentSearchIndex) ?? (delta > 0 ? -1 : 0)
        currentSearchIndex = visible[(pos + delta + visible.count) % visible.count]
        selectCurrentSearchResult()
    }

    private func stepSearch(_ delta: Int) { moveSearchSelection(delta) }

    private func selectCurrentSearchResult() {
        guard searchResults.indices.contains(currentSearchIndex) else {
            activeSelection = nil
            return
        }
        let hit = searchResults[currentSearchIndex]
        activeSelection = hit.selection
        jumpToPageIndex = hit.pageIndex
    }

    // MARK: - Footer (scrubber)

    private var progress: Double {
        guard pageCount > 1 else { return 0 }
        return Double(currentPageIndex) / Double(pageCount - 1)
    }

    private var sectionTicks: [Double] {
        guard pageCount > 1 else { return [] }
        let ticks = outline.filter { $0.depth == 0 && $0.pageIndex > 0 }
            .map { Double($0.pageIndex) / Double(pageCount - 1) }
        return ticks.count <= 80 ? ticks : []
    }

    private var footer: some View {
        let shown = scrubValue ?? progress
        let scrubPage = Int((shown * Double(max(pageCount - 1, 0))).rounded())
        let leftLabel: String = {
            let page = scrubValue != nil ? scrubPage : currentPageIndex
            return outline.last(where: { $0.pageIndex <= page })?.title ?? book.title
        }()

        return VStack(spacing: 6) {
            HStack {
                Text(leftLabel)
                    .lineLimit(1)
                Spacer()
                Button {
                    pageJumpText = String(currentPageIndex + 1)
                    showPageJump = true
                } label: {
                    Text("Page \((scrubValue != nil ? scrubPage : currentPageIndex) + 1) of \(pageCount)  \u{00B7}  \(Int((shown * 100).rounded()))%")
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .help("Go to page")
                .popover(isPresented: $showPageJump, arrowEdge: .top) {
                    pageJumpPopover
                        .background(ReaderWindowAppearance(theme: readerTheme))
                        .readerControls(readerTheme, system: colorScheme)
                }
            }
            .font(DesignTokens.sansFont(size: 11, weight: .medium))
            .foregroundStyle(tint)

            HStack(spacing: 10) {
                ReaderIconButton(
                    systemName: "chevron.left", help: "Previous page (\u{2318}\u{2190})",
                    isActive: false, tint: tint, accent: accent
                ) { goToPage(currentPageIndex - 1) }
                .disabled(currentPageIndex <= 0)

                ReaderScrubber(
                    progress: shown,
                    ticks: sectionTicks,
                    isScrubbing: scrubValue != nil,
                    accent: accent,
                    track: tint.opacity(0.25),
                    onScrub: { scrubValue = $0 },
                    onCommit: { value in
                        scrubValue = nil
                        goToPage(Int((value * Double(max(pageCount - 1, 0))).rounded()))
                    }
                )

                ReaderIconButton(
                    systemName: "chevron.right", help: "Next page (\u{2318}\u{2192})",
                    isActive: false, tint: tint, accent: accent
                ) { goToPage(currentPageIndex + 1) }
                .disabled(currentPageIndex >= pageCount - 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(height: footerHeight)
        .background(chromeSurface(edge: .top))
    }

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
        guard let target = Int(pageJumpText.trimmingCharacters(in: .whitespaces)) else { return }
        goToPage(target - 1)
        showPageJump = false
    }

    private func goToPage(_ index: Int) {
        guard pageCount > 0 else { return }
        jumpToPageIndex = min(max(index, 0), pageCount - 1)
    }

    // MARK: - Keyboard shortcuts

    private var shortcuts: some View {
        Group {
            Button("") { toggleSidebar(.contents) }.keyboardShortcut("l", modifiers: .command)
            Button("") { openSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("") { focusMode.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { scaleFactor = min(scaleFactor * 1.15, fitScaleFactor * 3) }.keyboardShortcut("=", modifiers: .command)
            Button("") { scaleFactor = max(scaleFactor / 1.15, fitScaleFactor * 0.5) }.keyboardShortcut("-", modifiers: .command)
            Button("") { scaleFactor = fitScaleFactor }.keyboardShortcut("0", modifiers: .command)
            Button("") { goToPage(currentPageIndex + 1) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { goToPage(currentPageIndex - 1) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("") { stepSearch(1) }.keyboardShortcut("g", modifiers: .command)
            Button("") { stepSearch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Scanned-page search (OCR)

    @ViewBuilder
    private var ocrBanner: some View {
        let hash = book.contentHash
        let job = ocr.jobs[hash]
        if let job, !job.done, job.error == nil {
            banner {
                ProgressView(value: job.progress).frame(width: 140)
                Text("Making this PDF searchable\u{2026} \(Int(job.progress * 100))%")
                Button("Cancel") { ocr.cancel(hash) }
            }
        } else if let error = job?.error {
            banner {
                Image(systemName: "exclamationmark.triangle")
                Text(error)
                Button("Try Again") { ocr.start(book: book, library: library) }
            }
        } else if looksScanned {
            banner {
                Image(systemName: "text.viewfinder")
                Text("This PDF is a scan, so it can't be searched, selected or read aloud yet.")
                if Entitlements.isUnlocked(.ocr) {
                    Button("Make Searchable") { ocr.start(book: book, library: library) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text("Scanned-page search is a Pagewrit Pro feature.").foregroundStyle(tint)
                }
                Button { looksScanned = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Dismiss")
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(DesignTokens.sansFont(size: 12))
            .foregroundStyle(textColor)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(chromeColor.opacity(0.97), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(rule, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }

    // MARK: - Loading

    private func load() {
        guard document == nil else { return }
        guard let doc = PDFDocument(url: library.readableURL(for: book)) else {
            loadFailed = true
            return
        }
        pageCount = doc.pageCount
        if let progress = book.readingProgress, pageCount > 1 {
            currentPageIndex = min(max(Int((progress * Double(pageCount - 1)).rounded()), 0), pageCount - 1)
        }
        outline = flattenOutline(doc.outlineRoot, document: doc)
        document = doc
        looksScanned = !library.hasSearchableCopy(book) && OCRService.isScanned(document: doc)
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

/// One flattened, navigable row in the PDF's outline.
struct PDFOutlineEntry: Identifiable {
    let id = UUID()
    let title: String
    let depth: Int
    let pageIndex: Int
}

// MARK: - PDFKitRepresentedView

/// NSViewRepresentable bridge to PDFKit's `PDFView`. Reports the current
/// page, zoom and fit scale up; accepts page-jump, zoom, layout, theme filter
/// and search-highlight commands from SwiftUI.
private struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int
    @Binding var scaleFactor: CGFloat
    @Binding var fitScaleFactor: CGFloat
    @Binding var jumpToPageIndex: Int?
    let activeSelection: PDFSelection?
    let highlights: [Highlight]
    @Binding var highlightRequest: PDFHighlightRequest?
    @Binding var hasSelection: Bool
    let onCreateHighlights: ([PDFHighlightDraft], HighlightColor, Bool) -> Void
    let onTapHighlight: (PersistentIdentifier) -> Void
    let backgroundColor: NSColor
    let layout: PDFPageLayout
    let filter: PDFPageFilter
    let topInset: CGFloat
    let bottomInset: CGFloat

    func makeNSView(context: Context) -> PDFView {
        let view = HighlightingPDFView()
        view.document = document
        view.displayMode = layout.mode
        view.displayDirection = .vertical
        view.backgroundColor = backgroundColor
        view.autoScales = false
        if !filter.filters.isEmpty {
            view.wantsLayer = true
            view.contentFilters = filter.filters
        }

        context.coordinator.lastLayout = layout
        context.coordinator.lastFilter = filter

        if let page = document.page(at: currentPageIndex) {
            DispatchQueue.main.async {
                view.go(to: page)
                let fit = view.scaleFactorForSizeToFit
                fitScaleFactor = fit
                scaleFactor = fit
                view.scaleFactor = fit
                view.minScaleFactor = fit * 0.4
                view.maxScaleFactor = fit * 4
                view.window?.makeFirstResponder(view)
            }
        }

        context.coordinator.pdfView = view
        view.onClickAnnotation = { [weak coordinator = context.coordinator] annotation in
            coordinator?.handleAnnotationClick(annotation)
        }
        let center = NotificationCenter.default
        center.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged),
                           name: .PDFViewSelectionChanged, object: view)
        center.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged),
                           name: .PDFViewPageChanged, object: view)
        center.addObserver(context.coordinator, selector: #selector(Coordinator.scaleChanged),
                           name: .PDFViewScaleChanged, object: view)
        view.postsFrameChangedNotifications = true
        center.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                           name: NSView.frameDidChangeNotification, object: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        nsView.backgroundColor = backgroundColor

        if let request = highlightRequest, request.id != c.lastRequestID {
            c.lastRequestID = request.id
            c.createHighlights(from: request, in: nsView)
            DispatchQueue.main.async { highlightRequest = nil }
        }
        c.syncHighlights(highlights, in: nsView)

        if c.lastFilter != filter {
            c.lastFilter = filter
            if !filter.filters.isEmpty { nsView.wantsLayer = true }
            nsView.contentFilters = filter.filters
        }

        if c.lastLayout != layout {
            c.lastLayout = layout
            let anchor = nsView.currentPage
            nsView.displayMode = layout.mode
            DispatchQueue.main.async {
                let fit = nsView.scaleFactorForSizeToFit
                nsView.minScaleFactor = fit * 0.4
                nsView.maxScaleFactor = fit * 4
                fitScaleFactor = fit
                scaleFactor = fit
                nsView.scaleFactor = fit
                if let anchor { nsView.go(to: anchor) }
            }
        } else if abs(nsView.scaleFactor - scaleFactor) > 0.001 {
            nsView.scaleFactor = scaleFactor
        }

        if let target = jumpToPageIndex, let page = document.page(at: target) {
            nsView.go(to: page)
            DispatchQueue.main.async { jumpToPageIndex = nil }
        }

        if let activeSelection, activeSelection !== c.lastAppliedSelection {
            c.lastAppliedSelection = activeSelection
            nsView.setCurrentSelection(activeSelection, animate: true)
            nsView.scrollSelectionToVisible(nil)
        } else if activeSelection == nil {
            c.lastAppliedSelection = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: PDFKitRepresentedView
        weak var pdfView: PDFView?
        var lastRequestID: UUID?
        /// What is currently drawn for each saved highlight, so annotations
        /// can be added, recoloured or removed without touching the PDF file.
        var applied: [PersistentIdentifier: AppliedHighlight] = [:]

        struct AppliedHighlight {
            let signature: String
            let items: [(page: PDFPage, annotation: PDFAnnotation)]
        }
        var lastAppliedSelection: PDFSelection?
        var lastLayout: PDFPageLayout?
        var lastFilter: PDFPageFilter?

        init(_ parent: PDFKitRepresentedView) {
            self.parent = parent
        }

        // NotificationCenter retains its target through the selector API, so
        // observers are removed explicitly on teardown (see dismantleNSView).
        deinit {
            NotificationCenter.default.removeObserver(self)
        }


        @objc func selectionChanged() {
            let has = !(pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            DispatchQueue.main.async { [parent] in
                if parent.hasSelection != has { parent.hasSelection = has }
            }
        }

        func createHighlights(from request: PDFHighlightRequest, in view: PDFView) {
            guard let selection = view.currentSelection, let document = view.document else { return }
            let drafts = PDFHighlightDraft.drafts(from: selection, in: document)
            guard !drafts.isEmpty else { return }
            view.clearSelection()
            DispatchQueue.main.async { [parent] in
                parent.onCreateHighlights(drafts, request.color, request.wantsNote)
            }
        }

        func syncHighlights(_ highlights: [Highlight], in view: PDFView) {
            guard let document = view.document else { return }
            let liveIDs = Set(highlights.map(\.persistentModelID))

            for (id, entry) in applied where !liveIDs.contains(id) {
                for item in entry.items {
                    item.page.removeAnnotation(item.annotation)
                    view.annotationsChanged(on: item.page)
                }
                applied[id] = nil
            }

            for highlight in highlights {
                let id = highlight.persistentModelID
                let signature = "\(highlight.pageIndex):\(highlight.rangeStart):\(highlight.rangeLength):\(highlight.colorRaw)"
                if let existing = applied[id] {
                    if existing.signature == signature { continue }
                    for item in existing.items {
                        item.page.removeAnnotation(item.annotation)
                        view.annotationsChanged(on: item.page)
                    }
                    applied[id] = nil
                }
                guard let page = document.page(at: highlight.pageIndex),
                      let selection = page.selection(for: NSRange(location: highlight.rangeStart, length: highlight.rangeLength))
                else { continue }

                var items: [(page: PDFPage, annotation: PDFAnnotation)] = []
                for line in selection.selectionsByLine() {
                    let bounds = line.bounds(for: page)
                    guard bounds.width > 0, bounds.height > 0 else { continue }
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = highlight.color.nsColor.withAlphaComponent(0.5)
                    annotation.userName = HighlightingPDFView.annotationTag
                    annotation.quadrilateralPoints = [
                        NSValue(point: NSPoint(x: 0, y: bounds.height)),
                        NSValue(point: NSPoint(x: bounds.width, y: bounds.height)),
                        NSValue(point: NSPoint(x: 0, y: 0)),
                        NSValue(point: NSPoint(x: bounds.width, y: 0))
                    ]
                    page.addAnnotation(annotation)
                    items.append((page, annotation))
                }
                view.annotationsChanged(on: page)
                applied[id] = AppliedHighlight(signature: signature, items: items)
            }
        }

        func handleAnnotationClick(_ annotation: PDFAnnotation) {
            guard let match = applied.first(where: { entry in
                entry.value.items.contains { $0.annotation === annotation }
            }) else { return }
            let id = match.key
            DispatchQueue.main.async { [parent] in parent.onTapHighlight(id) }
        }

        @objc func scaleChanged() {
            guard let pdfView else { return }
            let current = pdfView.scaleFactor
            DispatchQueue.main.async { [parent] in
                if abs(parent.scaleFactor - current) > 0.001 { parent.scaleFactor = current }
            }
        }

        /// When the window is resized, a page that was at "fit" stays at fit.
        @objc func frameChanged() {
            guard let pdfView else { return }
            let newFit = pdfView.scaleFactorForSizeToFit
            guard newFit > 0 else { return }
            DispatchQueue.main.async { [parent] in
                let wasFit = abs(parent.scaleFactor - parent.fitScaleFactor) < 0.005
                parent.fitScaleFactor = newFit
                pdfView.minScaleFactor = newFit * 0.4
                pdfView.maxScaleFactor = newFit * 4
                if wasFit { parent.scaleFactor = newFit }
            }
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
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewSelectionChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewScaleChanged, object: nsView)
        NotificationCenter.default.removeObserver(coordinator, name: NSView.frameDidChangeNotification, object: nsView)
    }
}


// MARK: - Highlight plumbing

/// A request from the toolbar to turn the current selection into highlights.
struct PDFHighlightRequest: Equatable {
    let id = UUID()
    let color: HighlightColor
    let wantsNote: Bool
}

/// One page's worth of a selection, ready to be saved as a `Highlight`.
struct PDFHighlightDraft {
    let pageIndex: Int
    let rangeStart: Int
    let rangeLength: Int
    let text: String

    /// Splits a (possibly multi-page) selection into one draft per page,
    /// anchored by character range so it can be redrawn on the next open.
    static func drafts(from selection: PDFSelection, in document: PDFDocument) -> [PDFHighlightDraft] {
        var result: [PDFHighlightDraft] = []
        for page in selection.pages {
            let index = document.index(for: page)
            guard index != NSNotFound else { continue }
            var low = Int.max
            var high = -1
            for i in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: i, on: page)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                low = min(low, range.location)
                high = max(high, range.location + range.length)
            }
            guard high > low, let pageText = page.string as NSString?, high <= pageText.length else { continue }
            let range = NSRange(location: low, length: high - low)
            let quoted = pageText.substring(with: range)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !quoted.isEmpty else { continue }
            result.append(PDFHighlightDraft(pageIndex: index, rangeStart: low, rangeLength: range.length, text: quoted))
        }
        return result
    }
}

/// `PDFView` that reports a plain click on one of our highlight annotations
/// (not a drag-selection), so the reader can open that highlight's note.
final class HighlightingPDFView: PDFView {
    static let annotationTag = "pagewrit-highlight"
    var onClickAnnotation: ((PDFAnnotation) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1 else { return }
        let hasSelection = !(currentSelection?.string?.isEmpty ?? true)
        guard !hasSelection else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return }
        let pagePoint = convert(point, to: page)
        if let annotation = page.annotation(at: pagePoint), annotation.userName == Self.annotationTag {
            onClickAnnotation?(annotation)
        }
    }
}
