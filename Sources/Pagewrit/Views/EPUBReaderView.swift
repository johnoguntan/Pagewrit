import SwiftUI
import WebKit
import SwiftData

#if canImport(EPUBKit)
import EPUBKit
#endif

import Foundation

// MARK: - EPUBReaderView

/// In-app EPUB reader.
///
/// Layout: the page fills the whole window and the controls float above it
/// in a translucent header and footer, so nothing reflows when they hide.
///
/// - Header: contents drawer, book + chapter title, search, bookmark,
///   appearance ("Aa"), read aloud, focus mode.
/// - Appearance panel: text size slider, theme swatches, typeface, line
///   spacing, column width, justification.
/// - Drawer: Contents / Bookmarks / Search-results tabs.
/// - Footer: a draggable scrubber across the whole book with chapter ticks,
///   the chapter you are in, percent read and time left.
/// - Focus mode: hides the header and footer; hover the top or bottom edge
///   to bring them back.
struct EPUBReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismissWindow) private var dismissWindow
    /// Pagewrit's own light or dark look, read straight from the app rather
    /// than this window, which the reader theme may have forced. "Auto"
    /// follows this, and it updates the instant the app look changes.
    @ObservedObject private var appearanceWatcher = AppearanceWatcher.shared
    private var colorScheme: ColorScheme { appearanceWatcher.scheme }

    // Book state
    @State private var epub: EPUBDocument?
    @State private var chapterURLs: [URL] = []
    @State private var chapterTitles: [String] = []
    @State private var currentChapterIndex: Int = 0
    @State private var isLoading = true
    @State private var isOpeningFile = false
    @State private var searchRunTask: Task<Void, Never>?
    @State private var loadFailed = false
    /// The book opened but its pages are locked by a store's copy protection.
    @State private var isCopyProtected = false
    @State private var tocEntries: [TOCEntry] = []
    @StateObject private var speech = SpeechController()
    @State private var webBridge = EPUBWebBridge()
    @AppStorage("stoa.speechRate") private var speechRate: Double = 1.0

    // Position
    @State private var chapterScroll: Double = 0
    @State private var scrollSaver = ReaderDebouncer()
    @State private var scaleDebouncer = ReaderDebouncer()
    @State private var draftScale: Double?
    @State private var cssBox = ReaderCSSBox()
    @State private var restoreTarget: (index: Int, fraction: Double)?
    @State private var scrollRequest: ScrollRequest?
    @State private var wordCounts: [Int] = []
    @State private var scrubValue: Double?
    @State private var pinch: CGFloat = 0
    @State private var lastSavedProgress: Double = -1

    // Highlights
    @State private var hasSelection = false
    @State private var selectHint = false
    @State private var selectedHighlightID: PersistentIdentifier?
    @State private var revealRequest: EPUBRevealRequest?

    // Search
    @State private var searchQuery = ""
    @State private var searchResults: [EPUBSearchResult] = []
    @State private var currentSearchIndex: Int = 0
    @State private var pendingHighlightQuery: String?
    @State private var pendingHighlightOccurrence: Int = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var searchCapped = false
    @State private var chapterTextCache: [Int: String] = [:]
    @State private var collapsedSearchChapters: Set<Int> = []
    @State private var searchChapterOnly = false
    @AppStorage("pagewrit.searchMatchCase") private var searchMatchCase = false
    @AppStorage("pagewrit.searchWholeWord") private var searchWholeWord = false
    @AppStorage(SearchHistory.key) private var searchHistoryRaw = ""
    @FocusState private var searchFocused: Bool

    // Chrome
    @State private var sidebarTab: ReaderSidebarTab?
    @State private var showAppearance = false
    @State private var focusMode = false
    @State private var hoverTop = false
    @State private var hoverBottom = false

    // Preferences
    @AppStorage("stoa.epubFontScale") private var fontScale: Double = 1.0
    @AppStorage("stoa.epubFace") private var faceRaw: String = ReaderFace.serif.rawValue
    @AppStorage("stoa.epubLineHeight") private var lineHeight: Double = 1.65
    @AppStorage("stoa.epubMeasure") private var measure: Double = 34
    @AppStorage("stoa.epubJustify") private var justify: Bool = false
    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue

    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .system }
    private var palette: ReaderPalette { readerTheme.palette(for: colorScheme) }
    private var typography: ReaderTypography {
        ReaderTypography(
            fontScale: fontScale,
            face: ReaderFace(rawValue: faceRaw) ?? .serif,
            lineHeight: lineHeight,
            measure: measure,
            justified: justify
        )
    }

    /// The page's stylesheet, rebuilt only when a setting actually changes —
    /// not on every scroll-driven redraw.
    private var cachedCSS: String {
        let key = "\(readerThemeRaw)|\(colorScheme == .dark)|\(fontScale)|\(faceRaw)|\(lineHeight)|\(measure)|\(justify)"
        if cssBox.key == key { return cssBox.value }
        let value = readerTheme.epubCSS(scheme: colorScheme, typography: typography)
        cssBox.key = key
        cssBox.value = value
        return value
    }

    private let fontScaleRange: ClosedRange<Double> = 0.7...2.2
    private let fontScaleStep: Double = 0.125
    private let headerHeight: CGFloat = 52
    private let footerHeight: CGFloat = 78

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
            ) { color, note in addHighlightFromSelection(color: color, wantsNote: note) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, footerHeight + 18)
            drawer
            chromeLayer
            if focusMode && !chromeVisible { FocusExitPill(tint: tint) { focusMode = false } }
            speechBar
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(ReaderWindowAppearance(theme: readerTheme))
        // Native controls (tab pickers, switches) follow the reader theme, not the Mac.
        .environment(\.colorScheme, readerTheme.controlScheme(system: colorScheme))
        .background(pageColor.ignoresSafeArea())
        .background(shortcuts)
        .onAppear(perform: load)
        .onAppear(perform: configureSpeech)
        .onAppear { library.markOpened(book) }
        .onDisappear { library.commitReading() }
        .onChange(of: focusMode) { _, on in if on { sidebarTab = nil; showAppearance = false } }
        .onAppear {
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { checkExternalJump() }
            }
        }
        .onChange(of: library.jumpRequest) { _, _ in checkExternalJump() }
        .onChange(of: currentChapterIndex) { _, newIndex in
            speech.stop()
            if searchChapterOnly && sidebarTab == .search { runSearch() }
            chapterScroll = 0
            if restoreTarget?.index != newIndex { restoreTarget = nil }
        }
        .onDisappear { speech.stop() }
        .focusable()
        .onKeyPress(.rightArrow) { advance(1); return .handled }
        .onKeyPress(.leftArrow) { advance(-1); return .handled }
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
        } else if !chapterURLs.isEmpty {
            EPUBPageView(
                chapterURL: chapterURLs[min(max(currentChapterIndex, 0), chapterURLs.count - 1)],
                contentDirectory: epub?.contentDirectory,
                css: cachedCSS,
                pageBackground: palette.background,
                highlightQuery: pendingHighlightQuery,
                highlightOccurrence: pendingHighlightOccurrence,
                restoreFraction: restoreTarget?.index == currentChapterIndex ? (restoreTarget?.fraction ?? 0) : 0,
                scrollRequest: scrollRequest,
                hasPrevious: currentChapterIndex > 0,
                hasNext: currentChapterIndex < chapterURLs.count - 1,
                onScroll: { chapterScroll = $0; scrollSaver.call { persistScroll() }; saveProgressIfNeeded() },
                onNavigate: { advance($0) },
                onMagnify: { handlePinch($0, $1) },
                bridge: webBridge,
                chapterIndex: currentChapterIndex,
                highlights: library.highlights(for: book).filter { $0.rangeLength > 0 },
                revealRequest: revealRequest,
                onSelectionChange: { hasSelection = $0 },
                onTapHighlight: { id in
                    selectedHighlightID = id
                    sidebarTab = .notes
                }
            )
            .overlay(alignment: .top) {
                if selectHint {
                    Label("Select some text in the book first, then highlight it.", systemImage: "text.cursor")
                        .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
                        .foregroundStyle(textColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(chromeColor))
                        .overlay(Capsule().strokeBorder(rule, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var failureState: some View {
        VStack(spacing: 12) {
            Image(systemName: isCopyProtected ? "lock" : "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint)
            Text(isCopyProtected ? "This book is copy-protected" : "This book couldn't be opened")
                .font(DesignTokens.serifFont(size: 20, weight: .bold))
                .foregroundStyle(textColor)
            Text(isCopyProtected
                 ? "The store it came from locks it to their own app (this is called DRM), so Pagewrit can't show its pages. Books without DRM, from Project Gutenberg, Standard Ebooks, many authors and publishers, open fine."
                 : "The file may be damaged or incomplete. Try downloading it again, or open it in another app to check.")
                .font(DesignTokens.sansFont(size: 13.5))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Button("Close") { dismissWindow() }
                .buttonStyle(.pw(.neutral, size: .regular))
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chrome layer (header + footer, fades in focus mode)

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

    /// Invisible edge zones that reveal the chrome while in focus mode.
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

    private var currentChapterTitle: String {
        chapterTitle(at: currentChapterIndex)
    }

    private func chapterTitle(at index: Int) -> String {
        if let entry = tocEntries.first(where: { $0.chapterIndex == index }) { return entry.title }
        if let entry = tocEntries.last(where: { $0.chapterIndex < index }) { return entry.title }
        return "Chapter \(index + 1)"
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
                if !chapterURLs.isEmpty {
                    Text(currentChapterTitle)
                        .font(DesignTokens.sansFont(size: 11))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
            .padding(.leading, 6)

            Spacer(minLength: 12)

            ReaderIconButton(
                systemName: "magnifyingglass", help: "Search this book (\u{2318}F)",
                isActive: sidebarTab == .search, tint: tint, accent: accent
            ) { openSearch() }
            .disabled(chapterURLs.isEmpty)

            highlightMenu

            ReaderIconButton(
                systemName: isCurrentChapterBookmarked ? "bookmark.fill" : "bookmark",
                help: isCurrentChapterBookmarked ? "Remove bookmark" : "Bookmark this chapter",
                isActive: isCurrentChapterBookmarked, tint: tint, accent: accent
            ) { toggleBookmark() }
            .disabled(chapterURLs.isEmpty)

            ReaderIconButton(
                systemName: "textformat.size", help: "Appearance",
                isActive: showAppearance, tint: tint, accent: accent
            ) { showAppearance.toggle() }
            .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                appearancePanel
                    .background(ReaderWindowAppearance(theme: readerTheme))
                    .readerControls(readerTheme, system: colorScheme)
            }

            ReaderIconButton(
                systemName: speech.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2",
                help: speech.isSpeaking ? "Stop reading aloud" : "Read aloud from your selection, or from the top of the page",
                isActive: speech.isSpeaking, tint: tint, accent: accent
            ) {
                if speech.isSpeaking { speech.stop() } else { speakCurrentChapter() }
            }
            .disabled(chapterURLs.isEmpty)

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
                systemName: "xmark", help: "Close book",
                isActive: false, tint: tint, accent: accent
            ) { dismissWindow() }
        }
        .padding(.horizontal, 12)
        .frame(height: headerHeight)
        .background(chromeSurface(edge: .bottom))
    }

    // MARK: - Appearance panel

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Text size
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Text size")
                        .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int(((draftScale ?? fontScale) * 100).rounded()))%")
                        .font(DesignTokens.sansFont(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Button("Reset") { fontScale = 1.0 }
                        .buttonStyle(.plain)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(accent)
                        .disabled(abs(fontScale - 1.0) < 0.001)
                }
                HStack(spacing: 10) {
                    Text("A").font(.system(size: 12, design: .serif)).foregroundStyle(tint)
                    // Smooth, no snap points. The page re-flows a moment after
                    // you pause and again when you let go, instead of on every
                    // pixel of movement (that re-flow is what made it lag).
                    Slider(
                        value: Binding(
                            get: { draftScale ?? fontScale },
                            set: { newValue in
                                draftScale = newValue
                                scaleDebouncer.call(after: 0.18) { commitDraftScale() }
                            }
                        ),
                        in: fontScaleRange,
                        onEditingChanged: { editing in
                            if !editing { commitDraftScale() }
                        }
                    )
                    .tint(accent)
                    Text("A").font(.system(size: 22, design: .serif)).foregroundStyle(tint)
                }
            }

            // Theme
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme").font(DesignTokens.sansFont(size: 12, weight: .semibold))
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

            // Typeface
            VStack(alignment: .leading, spacing: 8) {
                Text("Typeface").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                HStack(spacing: 10) {
                    ForEach(ReaderFace.allCases) { face in
                        FaceChip(face: face, isSelected: faceRaw == face.rawValue,
                                 accent: accent, tint: tint, text: textColor) {
                            faceRaw = face.rawValue
                        }
                    }
                }
            }

            // Spacing + width
            VStack(alignment: .leading, spacing: 8) {
                Text("Line spacing").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Line spacing", selection: $lineHeight) {
                    Text("Tight").tag(1.45)
                    Text("Normal").tag(1.65)
                    Text("Airy").tag(1.9)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Column width").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Column width", selection: $measure) {
                    Text("Narrow").tag(28.0)
                    Text("Medium").tag(34.0)
                    Text("Wide").tag(44.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(isOn: $justify) {
                Text("Justify text").font(DesignTokens.sansFont(size: 13))
            }
            .toggleStyle(.switch)
            .tint(accent)

            Divider().overlay(rule)

            Button {
                fontScale = 1.0
                faceRaw = ReaderFace.serif.rawValue
                lineHeight = 1.65
                measure = 34
                justify = false
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

    // MARK: - Drawer (contents / bookmarks / search)

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
                .frame(width: 360)
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

    private var displayEntries: [TOCEntry] {
        if !tocEntries.isEmpty { return tocEntries }
        return chapterTitles.indices.map {
            TOCEntry(title: "Chapter \($0 + 1)", depth: 0, chapterIndex: $0)
        }
    }

    private var currentTOCEntryID: UUID? {
        displayEntries.last(where: { $0.chapterIndex <= currentChapterIndex })?.id
    }

    private var contentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(displayEntries) { entry in
                        let isCurrent = entry.id == currentTOCEntryID
                        Button {
                            jump(toChapter: entry.chapterIndex, fraction: 0)
                            sidebarTab = nil
                        } label: {
                            HStack(spacing: 8) {
                                Text(entry.title)
                                    .font(DesignTokens.sansFont(size: 13, weight: isCurrent ? .semibold : .regular))
                                    .foregroundStyle(isCurrent ? accent : textColor)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                if entry.chapterIndex < currentChapterIndex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(tint.opacity(0.6))
                                }
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
                if let id = currentTOCEntryID { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // Bookmarks

    private var bookmarksList: some View {
        let saved = library.bookmarks(for: book)
        return VStack(spacing: 0) {
            Button {
                toggleBookmark()
            } label: {
                Label(
                    isCurrentChapterBookmarked ? "Remove bookmark from this chapter" : "Bookmark this chapter",
                    systemImage: isCurrentChapterBookmarked ? "bookmark.slash" : "bookmark"
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
                            let index = chapterIndex(forBookmarkPosition: bookmark.position)
                            HStack(spacing: 8) {
                                Button {
                                    jump(toChapter: index, fraction: 0)
                                    sidebarTab = nil
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.label)
                                            .font(DesignTokens.sansFont(size: 13))
                                            .foregroundStyle(textColor)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text("Chapter \(index + 1)")
                                            .font(DesignTokens.sansFont(size: 11))
                                            .foregroundStyle(tint)
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

    private func chapterIndex(forBookmarkPosition position: Double) -> Int {
        let index = Int((position * Double(max(chapterURLs.count - 1, 1))).rounded())
        return min(max(index, 0), max(chapterURLs.count - 1, 0))
    }

    // Search

    private var searchColors: SearchColors { SearchColors(text: textColor, tint: tint, accent: accent) }

    private func rememberSearch() {
        searchHistoryRaw = SearchHistory.adding(searchQuery, to: searchHistoryRaw)
    }

    private var visibleSearchIndices: [Int] {
        searchResults.indices.filter { !collapsedSearchChapters.contains(searchResults[$0].chapterIndex) }
    }

    private var searchGroups: [(chapter: Int, indices: [Int])] {
        var order: [Int] = []
        var map: [Int: [Int]] = [:]
        for (i, r) in searchResults.enumerated() {
            if map[r.chapterIndex] == nil { order.append(r.chapterIndex) }
            map[r.chapterIndex, default: []].append(i)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var searchPanel: some View {
        VStack(spacing: 0) {
            SearchFieldBar(
                query: $searchQuery,
                prompt: "Search this book",
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
                firstScope: "This chapter", secondScope: "Whole book",
                firstScopeSelected: $searchChapterOnly,
                matchCase: $searchMatchCase, wholeWord: $searchWholeWord,
                colors: searchColors
            )
            .onChange(of: searchChapterOnly) { _, _ in runSearch() }
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
                            ForEach(searchGroups, id: \.chapter) { group in
                                SearchGroupHeader(
                                    title: chapterTitle(at: group.chapter),
                                    count: group.indices.count,
                                    collapsed: collapsedSearchChapters.contains(group.chapter),
                                    colors: searchColors
                                ) {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        if collapsedSearchChapters.contains(group.chapter) {
                                            collapsedSearchChapters.remove(group.chapter)
                                        } else {
                                            collapsedSearchChapters.insert(group.chapter)
                                        }
                                    }
                                }
                                if !collapsedSearchChapters.contains(group.chapter) {
                                    ForEach(group.indices.filter { searchResults.indices.contains($0) }, id: \.self) { i in
                                        SearchResultRow(
                                            text: highlighted(searchResults[i]),
                                            selected: i == currentSearchIndex,
                                            colors: searchColors
                                        ) {
                                            currentSearchIndex = i
                                            jumpToCurrentSearchResult()
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
                        if searchChapterOnly { h.append(SearchHint(title: "Search whole book") { searchChapterOnly = false }) }
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
        let chapters = Set(searchResults.map(\.chapterIndex)).count
        let n = searchResults.count
        if searchChapterOnly { return "\(n)\(searchCapped ? "+" : "") in this chapter" }
        return "\(n)\(searchCapped ? "+" : "") match\(n == 1 ? "" : "es") in \(chapters) chapter\(chapters == 1 ? "" : "s")"
    }

    private func highlighted(_ result: EPUBSearchResult) -> AttributedString {
        var text = AttributedString(result.snippet)
        let start = text.index(text.startIndex, offsetByCharacters: min(result.matchOffset, text.characters.count))
        let end = text.index(start, offsetByCharacters: min(result.matchLength, text.characters.distance(from: start, to: text.endIndex)))
        text[start..<end].font = .system(size: 13, weight: .bold)
        text[start..<end].foregroundColor = accent
        return text
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { runSearch() }
        }
    }

    private func runSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            clearSearch()
            return
        }
        webBridge.matchCase = searchMatchCase
        webBridge.wholeWord = searchWholeWord

        var pattern = NSRegularExpression.escapedPattern(for: trimmed)
        if searchWholeWord { pattern = "\\b" + pattern + "\\b" }
        var options: NSRegularExpression.Options = []
        if !searchMatchCase { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            clearSearch()
            return
        }

        // Reading and stripping every chapter, then matching, can take seconds
        // on a long book. It happens in the background so typing and scrolling
        // stay smooth, and a newer search replaces an older one still running.
        let indices: [Int] = (searchChapterOnly ? [currentChapterIndex] : Array(chapterURLs.indices))
            .filter { chapterURLs.indices.contains($0) }
        let urls = chapterURLs
        let cacheSnapshot = chapterTextCache
        searchRunTask?.cancel()
        searchRunTask = Task.detached(priority: .userInitiated) {
            let outcome = Self.searchChapters(regex: regex, indices: indices, urls: urls, cache: cacheSnapshot)
            if Task.isCancelled { return }
            await MainActor.run {
                for (index, text) in outcome.newlyCached { chapterTextCache[index] = text }
                searchCapped = outcome.capped
                searchResults = outcome.results
                collapsedSearchChapters = []
                currentSearchIndex = 0
            }
        }
    }

    nonisolated private static func searchChapters(
        regex: NSRegularExpression, indices: [Int], urls: [URL], cache: [Int: String]
    ) -> (results: [EPUBSearchResult], capped: Bool, newlyCached: [Int: String]) {
        let maxTotal = 500, maxPerChapter = 100
        var results: [EPUBSearchResult] = []
        var capped = false
        var newlyCached: [Int: String] = [:]
        outer: for index in indices {
            if Task.isCancelled { break }
            let text: String
            if let cached = cache[index] {
                text = cached
            } else if let html = try? String(contentsOf: urls[index], encoding: .utf8) {
                text = TextExtractor.stripHTML(html)
                newlyCached[index] = text
            } else {
                continue
            }
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for (occurrence, m) in matches.enumerated() {
                if occurrence >= maxPerChapter { break }
                let r = m.range
                let s = max(0, r.location - 50)
                let e = min(ns.length, r.location + r.length + 70)
                let snippet = ns.substring(with: NSRange(location: s, length: e - s))
                    .replacingOccurrences(of: "\n", with: " ")
                let prefix = ns.substring(with: NSRange(location: s, length: r.location - s))
                results.append(EPUBSearchResult(
                    chapterIndex: index,
                    occurrence: occurrence,
                    snippet: snippet,
                    matchOffset: prefix.count,
                    matchLength: ns.substring(with: r).count
                ))
                if results.count >= maxTotal { capped = true; break outer }
            }
        }
        return (results, capped, newlyCached)
    }

    private func moveSearchSelection(_ delta: Int) {
        let visible = visibleSearchIndices
        guard !visible.isEmpty else { return }
        let pos = visible.firstIndex(of: currentSearchIndex) ?? (delta > 0 ? -1 : 0)
        let next = visible[(pos + delta + visible.count) % visible.count]
        currentSearchIndex = next
        jumpToCurrentSearchResult()
    }

    private func cachedChapterText(at index: Int) -> String {
        if let cached = chapterTextCache[index] { return cached }
        guard chapterURLs.indices.contains(index),
              let html = try? String(contentsOf: chapterURLs[index], encoding: .utf8) else {
            return ""
        }
        let stripped = TextExtractor.stripHTML(html)
        chapterTextCache[index] = stripped
        return stripped
    }

    private func clearSearch() {
        searchRunTask?.cancel()
        searchResults = []
        currentSearchIndex = 0
        pendingHighlightQuery = nil
    }

    private func stepSearch(_ delta: Int) { moveSearchSelection(delta) }

    private func jumpToCurrentSearchResult() {
        guard searchResults.indices.contains(currentSearchIndex) else { return }
        let result = searchResults[currentSearchIndex]
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentChapterIndex == result.chapterIndex {
            // Same chapter already loaded: bump the query so the page
            // re-runs window.find even though the chapter didn't change.
            pendingHighlightQuery = nil
            pendingHighlightOccurrence = result.occurrence
            DispatchQueue.main.async { pendingHighlightQuery = trimmed }
        } else {
            currentChapterIndex = result.chapterIndex
            chapterScroll = 0
            pendingHighlightOccurrence = result.occurrence
            pendingHighlightQuery = trimmed
            saveProgress()
        }
    }

    // MARK: - Highlights

    private var highlightMenu: some View {
        Menu {
            ForEach(HighlightColor.allCases) { color in
                Button {
                    addHighlightFromSelection(color: color, wantsNote: false)
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
                addHighlightFromSelection(color: .yellow, wantsNote: true)
            } label: {
                Label("Highlight and add note", systemImage: "square.and.pencil")
            }
        } label: {
            ReaderToolbarLabel(systemName: "highlighter", title: "Highlight")
            .foregroundStyle(hasSelection ? accent : tint)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(chapterURLs.isEmpty)
        .help(hasSelection ? "Highlight the selected text" : "Select some text first, then highlight it")
    }

    private func showSelectHint() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selectHint = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeOut(duration: 0.25)) { selectHint = false }
        }
    }

    private func addHighlightFromSelection(color: HighlightColor, wantsNote: Bool) {
        let chapter = currentChapterIndex
        let position = chapterPosition
        webBridge.captureSelection { selection in
            guard let selection else {
                showSelectHint()
                return
            }
            let created = library.addHighlight(
                bookHash: book.contentHash,
                pageIndex: chapter,
                rangeStart: selection.start,
                rangeLength: selection.length,
                position: position,
                text: selection.text,
                color: color
            )
            webBridge.clearSelection()
            hasSelection = false
            if wantsNote {
                selectedHighlightID = created.persistentModelID
                sidebarTab = .notes
            }
        }
    }

    private var notesPanel: some View {
        HighlightsPanel(
            highlights: library.highlights(for: book),
            selectedID: selectedHighlightID,
            textColor: textColor, tint: tint, accent: accent,
            locationLabel: { highlight in
                chapterURLs.indices.contains(highlight.pageIndex)
                    ? chapterTitle(at: highlight.pageIndex)
                    : "Chapter \(highlight.pageIndex + 1)"
            },
            onJump: { highlight in jump(to: highlight) },
            onAddNote: { addNoteHere() }
        )
    }

    /// A note with no selected text, pinned to the chapter being read.
    private func addNoteHere() {
        let created = library.addHighlight(
            bookHash: book.contentHash,
            pageIndex: currentChapterIndex,
            rangeStart: 0, rangeLength: 0,
            position: chapterPosition,
            text: ""
        )
        selectedHighlightID = created.persistentModelID
    }

    private func jump(to highlight: Highlight) {
        selectedHighlightID = highlight.persistentModelID
        guard chapterURLs.indices.contains(highlight.pageIndex) else { return }
        let request = EPUBRevealRequest(
            chapterIndex: highlight.pageIndex,
            start: highlight.rangeStart,
            length: highlight.rangeLength
        )
        pendingHighlightQuery = nil
        if highlight.pageIndex != currentChapterIndex {
            currentChapterIndex = highlight.pageIndex
            chapterScroll = 0
            saveProgress()
        }
        revealRequest = highlight.rangeLength > 0 ? request : nil
    }

    /// A highlight chosen in the library: open at that exact passage.
    private func checkExternalJump() {
        guard !chapterURLs.isEmpty, let highlight = library.consumeJump(for: book.contentHash) else { return }
        jump(to: highlight)
    }

    // MARK: - Bookmarks

    private var chapterPosition: Double {
        Double(currentChapterIndex) / Double(max(chapterURLs.count - 1, 1))
    }

    private var isCurrentChapterBookmarked: Bool {
        guard !chapterURLs.isEmpty else { return false }
        return library.bookmarks(for: book).contains {
            abs($0.position - chapterPosition) < (1.0 / Double(max(chapterURLs.count, 1))) / 2
        }
    }

    private func toggleBookmark() {
        guard !chapterURLs.isEmpty else { return }
        if let existing = library.bookmarks(for: book).first(where: {
            abs($0.position - chapterPosition) < (1.0 / Double(max(chapterURLs.count, 1))) / 2
        }) {
            library.removeBookmark(existing)
        } else {
            library.addBookmark(for: book, position: chapterPosition, label: currentChapterTitle)
        }
    }

    // MARK: - Read aloud

    private func configureSpeech() {
        speech.setRate(speechRate)
        speech.onProgress = { [webBridge] location, length in
            webBridge.highlightSpeech(location: location, length: length)
        }
        speech.onFinish = { [webBridge] in
            webBridge.clearSpeechHighlight()
        }
    }

    private func speakCurrentChapter() {
        guard chapterURLs.indices.contains(currentChapterIndex) else { return }
        let index = currentChapterIndex
        webBridge.prepareSpeech(
            completion: { text, start in speech.speak(text, from: start) },
            fallback: { speech.speak(cachedChapterText(at: index)) }
        )
    }

    /// Floating controls shown while reading aloud.
    @ViewBuilder
    private var speechBar: some View {
        if speech.isSpeaking {
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Button { speech.togglePause() } label: {
                        Image(systemName: speech.isPaused ? "play.fill" : "pause.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(speech.isPaused ? "Resume" : "Pause")
                    .accessibilityLabel(speech.isPaused ? "Resume" : "Pause")

                    Text(speech.isPaused ? "Paused" : "Reading aloud")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 84, alignment: .leading)

                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { value in
                            Button {
                                speechRate = value
                                speech.setRate(value)
                            } label: {
                                Text(String(format: "%gx", value) + (value == speechRate ? "  \u{2713}" : ""))
                            }
                        }
                    } label: {
                        Text(String(format: "%gx", speechRate))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Reading speed")

                    Button { speech.stop() } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                    .accessibilityLabel("Stop")
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(pageColor))
                .overlay(Capsule().stroke(rule, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .padding(.bottom, 96)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Footer (scrubber)

    /// Word counts weight chapters by their real length once they are known;
    /// until then every chapter counts the same.
    private var weights: [Double] {
        if wordCounts.count == chapterURLs.count, !wordCounts.isEmpty {
            return wordCounts.map { Double(max($0, 1)) }
        }
        return Array(repeating: 1, count: chapterURLs.count)
    }

    private var weightsAreReal: Bool {
        wordCounts.count == chapterURLs.count && !wordCounts.isEmpty
    }

    private var bookProgress: Double {
        let w = weights
        let total = w.reduce(0, +)
        guard total > 0, w.indices.contains(currentChapterIndex) else { return 0 }
        let before = w.prefix(currentChapterIndex).reduce(0, +)
        return min(1, (before + w[currentChapterIndex] * chapterScroll) / total)
    }

    private var chapterTicks: [Double] {
        let w = weights
        let total = w.reduce(0, +)
        guard total > 0, w.count > 1 else { return [] }
        var running = 0.0
        var ticks: [Double] = []
        for value in w.dropLast() {
            running += value
            ticks.append(running / total)
        }
        return ticks
    }

    private func chapterIndex(forBookFraction value: Double) -> Int {
        let w = weights
        let total = w.reduce(0, +)
        guard total > 0, !w.isEmpty else { return 0 }
        var target = min(max(value, 0), 1) * total
        var index = 0
        while index < w.count - 1 && target >= w[index] {
            target -= w[index]
            index += 1
        }
        return index
    }

    private func seek(toBookFraction value: Double) {
        let w = weights
        let total = w.reduce(0, +)
        guard total > 0, !w.isEmpty else { return }
        var target = min(max(value, 0), 1) * total
        var index = 0
        while index < w.count - 1 && target >= w[index] {
            target -= w[index]
            index += 1
        }
        let fraction = w[index] > 0 ? min(1, target / w[index]) : 0
        jump(toChapter: index, fraction: fraction)
    }

    private func jump(toChapter index: Int, fraction: Double) {
        guard chapterURLs.indices.contains(index) else { return }
        pendingHighlightQuery = nil
        scrollRequest = ScrollRequest(fraction: fraction)
        if index != currentChapterIndex { currentChapterIndex = index }
        chapterScroll = fraction
        saveProgress()
    }

    private var minutesLeft: Int? {
        guard weightsAreReal, chapterURLs.indices.contains(currentChapterIndex) else { return nil }
        let w = weights
        let remaining = w[currentChapterIndex] * (1 - chapterScroll)
            + w.dropFirst(currentChapterIndex + 1).reduce(0, +)
        return Int((remaining / 240).rounded(.up))
    }

    private func formatLeft(_ minutes: Int) -> String {
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min left" }
        return "\(max(minutes, 1)) min left"
    }

    private var footer: some View {
        let shown = scrubValue ?? bookProgress
        let leftLabel = scrubValue != nil
            ? chapterTitle(at: chapterIndex(forBookFraction: shown))
            : currentChapterTitle
        var rightLabel = "\(Int((shown * 100).rounded()))%"
        if scrubValue == nil, let minutes = minutesLeft {
            rightLabel += "  \u{00B7}  " + formatLeft(minutes)
        }

        return VStack(spacing: 6) {
            HStack {
                Text(leftLabel)
                    .lineLimit(1)
                Spacer()
                Text(rightLabel)
                    .monospacedDigit()
            }
            .font(DesignTokens.sansFont(size: 11, weight: .medium))
            .foregroundStyle(tint)

            HStack(spacing: 10) {
                ReaderIconButton(
                    systemName: "chevron.left", help: "Previous chapter (\u{2318}\u{2190})",
                    isActive: false, tint: tint, accent: accent
                ) { advance(-1) }
                .disabled(currentChapterIndex <= 0)

                ReaderScrubber(
                    progress: shown,
                    ticks: chapterTicks,
                    isScrubbing: scrubValue != nil,
                    accent: accent,
                    track: tint.opacity(0.25),
                    onScrub: { scrubValue = $0 },
                    onCommit: { value in
                        scrubValue = nil
                        seek(toBookFraction: value)
                    }
                )

                ReaderIconButton(
                    systemName: "chevron.right", help: "Next chapter (\u{2318}\u{2192})",
                    isActive: false, tint: tint, accent: accent
                ) { advance(1) }
                .disabled(currentChapterIndex >= chapterURLs.count - 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(height: footerHeight)
        .background(chromeSurface(edge: .top))
    }

    // MARK: - Keyboard shortcuts

    private var shortcuts: some View {
        Group {
            Button("") { toggleSidebar(.contents) }.keyboardShortcut("l", modifiers: .command)
            Button("") { openSearch() }.keyboardShortcut("f", modifiers: .command)
            Button("") { focusMode.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { stepFont(1) }.keyboardShortcut("=", modifiers: .command)
            Button("") { stepFont(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("") { fontScale = 1.0 }.keyboardShortcut("0", modifiers: .command)
            Button("") { advance(1) }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { advance(-1) }.keyboardShortcut(.leftArrow, modifiers: .command)
            Button("") { stepSearch(1) }.keyboardShortcut("g", modifiers: .command)
            Button("") { stepSearch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    private func stepFont(_ direction: Double) {
        fontScale = min(fontScaleRange.upperBound, max(fontScaleRange.lowerBound, fontScale + direction * fontScaleStep))
    }

    private func commitDraftScale() {
        guard let draft = draftScale else { return }
        let rounded = (draft * 100).rounded() / 100
        if abs(rounded - fontScale) > 0.001 { fontScale = rounded }
        if !scaleDebouncer.isPending { draftScale = nil }
    }

    // MARK: - Word counts (for accurate progress and time left)

    nonisolated private static func countWords(_ urls: [URL]) -> [Int] {
        urls.map { url -> Int in
            guard let html = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
            let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            return text.split(whereSeparator: { $0.isWhitespace }).count
        }
    }

    // MARK: - Chapter Navigation

    private func advance(_ delta: Int) {
        let newIndex = currentChapterIndex + delta
        guard chapterURLs.indices.contains(newIndex) else { return }
        currentChapterIndex = newIndex
        chapterScroll = 0
        pendingHighlightQuery = nil
        saveProgress()
    }

    // MARK: - Scroll position & pinch

    private var scrollKey: String { "stoa.epubScroll.\(book.sourceURL.path.hashValue)" }

    private func persistScroll() {
        UserDefaults.standard.set("\(currentChapterIndex):\(chapterScroll)", forKey: scrollKey)
    }

    @discardableResult
    private func loadSavedScroll(chapterCount: Int) -> Bool {
        guard let saved = UserDefaults.standard.string(forKey: scrollKey) else { return false }
        let parts = saved.split(separator: ":")
        guard parts.count == 2, let index = Int(parts[0]), let fraction = Double(parts[1]),
              index >= 0, index < chapterCount else { return false }
        currentChapterIndex = index
        restoreTarget = (index, fraction)
        return true
    }

    /// Trackpad pinch: text size moves in the same detents as A-/A+.
    private func handlePinch(_ magnification: CGFloat, _ phase: NSEvent.Phase) {
        if phase.contains(.began) { pinch = 0 }
        pinch += magnification
        while pinch > 0.1 {
            fontScale = min(fontScaleRange.upperBound, fontScale + fontScaleStep)
            pinch -= 0.1
        }
        while pinch < -0.1 {
            fontScale = max(fontScaleRange.lowerBound, fontScale - fontScaleStep)
            pinch += 0.1
        }
    }

    // MARK: - Loading

    /// Unzips and reads the EPUB off the main thread, so the reader window
    /// opens at once and shows its loading state instead of freezing.
    private func load() {
        guard epub == nil, !isOpeningFile else { return }
        #if canImport(EPUBKit)
        isOpeningFile = true
        let url = library.readableURL(for: book)

        struct Opened: @unchecked Sendable {
            let doc: EPUBDocument?
            let protected: Bool
        }

        Task.detached(priority: .userInitiated) {
            let doc = EPUBDocument(url: url)
            let protected = doc.map { EPUBProtection.isProtected(root: $0.directory) } ?? false
            let opened = Opened(doc: doc, protected: protected)
            await MainActor.run {
                isOpeningFile = false
                finishLoad(opened.doc, protected: opened.protected)
            }
        }
        #else
        loadFailed = true
        isLoading = false
        #endif
    }

    #if canImport(EPUBKit)
    private func finishLoad(_ parsed: EPUBDocument?, protected: Bool) {
        guard let epubDoc = parsed else {
            loadFailed = true
            isLoading = false
            return
        }
        // Store copy protection (Adobe, Apple, Readium LCP) leaves the pages
        // scrambled. Say so plainly instead of showing gibberish.
        if protected {
            isCopyProtected = true
            loadFailed = true
            isLoading = false
            return
        }
        self.epub = epubDoc

        // Build ordered chapter URLs from the spine
        let contentDir = epubDoc.contentDirectory
        var urls: [URL] = []
        var titles: [String] = []

        for spineItem in epubDoc.spine.items {
            guard let manifestItem = epubDoc.manifest.items[spineItem.idref] else { continue }
            let chapterURL = contentDir.appendingPathComponent(manifestItem.path)

            // Only include HTML/XHTML content documents
            let ext = chapterURL.pathExtension.lowercased()
            if ext == "html" || ext == "xhtml" || ext == "htm" {
                urls.append(chapterURL)
                // Use the filename without extension as a chapter title fallback
                let name = chapterURL.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                titles.append(name)
            }
        }

        guard !urls.isEmpty else {
            loadFailed = true
            isLoading = false
            return
        }

        chapterURLs = urls
        chapterTitles = titles
        tocEntries = flattenTOC(epubDoc.tableOfContents, chapterURLs: urls)
        isLoading = false

        // Resume at the exact saved spot straight away — the book opens now.
        let hadSavedSpot = loadSavedScroll(chapterCount: urls.count)
        let savedProgress = book.readingProgress

        // Word counts weight each chapter by its real length, so progress and
        // time-left mean the same thing here and in the library. Counting reads
        // every chapter, so it happens in the background instead of blocking
        // the reader from opening.
        let chapterList = urls
        Task.detached(priority: .userInitiated) {
            let counts = Self.countWords(chapterList)
            await MainActor.run {
                wordCounts = counts
                // No saved spot: map the library's progress back to a chapter.
                if !hadSavedSpot, let progress = savedProgress, chapterList.count > 1 {
                    let weights = counts.map { Double(max($0, 1)) }
                    var target = min(max(progress, 0), 1) * weights.reduce(0, +)
                    var index = 0
                    while index < weights.count - 1 && target >= weights[index] {
                        target -= weights[index]
                        index += 1
                    }
                    currentChapterIndex = index
                    restoreTarget = (index, min(1, target / weights[index]))
                }
            }
        }
    }
    #endif

    private func saveProgressIfNeeded() {
        if abs(bookProgress - lastSavedProgress) >= 0.01 { saveProgress() }
    }

    private func saveProgress() {
        guard chapterURLs.count > 1 else { return }
        let progress = bookProgress
        lastSavedProgress = progress
        library.updateProgress(for: book, progress: progress)
    }

    // MARK: - Table of Contents Flattening
    //
    // EPUBKit's tableOfContents is a tree (NCX navMap) keyed by `item`, a
    // src path that may carry a "#fragment" anchor. Pagewrit's reader only
    // navigates at chapter granularity, so each entry is resolved down to
    // the matching chapter's index by filename, ignoring any fragment \u{2014}
    // and dropped if it can't be matched to a real chapter document.
    #if canImport(EPUBKit)
    private func flattenTOC(
        _ node: EPUBTableOfContents,
        depth: Int = 0,
        chapterURLs: [URL]
    ) -> [TOCEntry] {
        var entries: [TOCEntry] = []

        let label = node.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty, let itemPath = node.item {
            let barePath = itemPath.components(separatedBy: "#").first ?? itemPath
            let fileName = (barePath as NSString).lastPathComponent
            if let index = chapterURLs.firstIndex(where: { $0.lastPathComponent == fileName }) {
                entries.append(TOCEntry(title: label, depth: depth, chapterIndex: index))
            }
        }

        for child in node.subTable ?? [] {
            entries.append(contentsOf: flattenTOC(child, depth: depth + 1, chapterURLs: chapterURLs))
        }

        return entries
    }
    #endif
}

/// One flattened, navigable row in the EPUB's table of contents.
struct TOCEntry: Identifiable {
    let id = UUID()
    let title: String
    let depth: Int
    let chapterIndex: Int
}

/// One search hit \u{2014} which chapter it's in, plus a short snippet of
/// surrounding text so the results list is scannable without opening
/// every chapter.
struct EPUBSearchResult: Identifiable {
    let id = UUID()
    let chapterIndex: Int
    /// 0-based index of this hit among the matches in its chapter.
    let occurrence: Int
    let snippet: String
    let matchOffset: Int
    let matchLength: Int
}

// MARK: - Reader UI components

enum ReaderSidebarTab: String, CaseIterable, Identifiable {
    case contents = "Contents"
    case bookmarks = "Bookmarks"
    case notes = "Notes"
    case search = "Search"

    var id: String { rawValue }
}

/// 30pt icon button with a soft hover/active plate, used across the reader
/// chrome so every control has the same hit target and feedback.
private struct ReaderToolbarCompactKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the reader window is too narrow for words in the toolbar.
    var readerToolbarCompact: Bool {
        get { self[ReaderToolbarCompactKey.self] }
        set { self[ReaderToolbarCompactKey.self] = newValue }
    }
}

/// Holds a reader's toolbar. With room, buttons show their words; when the
/// window narrows, the same toolbar switches to icons only, so nothing ever
/// pushes the page wider than the window.
struct ReaderToolbarFit<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            content.environment(\.readerToolbarCompact, true)
        }
        // Whatever happens inside, the toolbar never widens the window.
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

/// A toolbar label that drops its word when the toolbar is compact.
struct ReaderToolbarLabel: View {
    let systemName: String
    let title: String
    @Environment(\.readerToolbarCompact) private var compact

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemName).font(.system(size: 14))
            if !compact {
                Text(title).font(.system(size: 12)).lineLimit(1).fixedSize()
            }
        }
    }
}

struct ReaderIconButton: View {
    let systemName: String
    let help: String
    let isActive: Bool
    let tint: Color
    let accent: Color
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.readerToolbarCompact) private var compact

    /// The main controls carry a word, so nobody has to guess what an icon does.
    private var label: String? {
        switch systemName {
        case "sidebar.left": return "Contents"
        case "magnifyingglass": return "Search"
        case "bookmark", "bookmark.fill": return "Bookmark"
        case "textformat.size", "slider.horizontal.3": return "Display"
        case "square.grid.2x2": return "Pages"
        case "speaker.wave.2", "speaker.wave.2.fill": return "Listen"
        case "arrow.up.left.and.arrow.down.right": return "Focus"
        case "arrow.down.right.and.arrow.up.left": return "Exit focus"
        case "xmark": return "Close"
        default: return nil
        }
    }

    var body: some View {
        Button(action: action) {
            // Never wraps mid word: in a narrow window the whole toolbar
            // switches to icons (the tooltip still names each one).
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .regular))
                if let label, !compact {
                    Text(label)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
                .foregroundStyle(isActive ? accent : tint)
                .padding(.horizontal, label == nil || compact ? 0 : 8)
                .frame(minWidth: 30, minHeight: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((isActive ? accent : tint).opacity(isActive ? 0.16 : (hovering ? 0.14 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Appears over the page the moment text is selected, so nobody has to hunt
/// the toolbar: tap Highlight (or Cmd-Shift-H) for the last colour used, pick
/// another colour, or add a note.
struct SelectionHighlightBar: View {
    let visible: Bool
    let tint: Color
    let accent: Color
    let pageColor: Color
    let onHighlight: (HighlightColor, Bool) -> Void

    @AppStorage("pagewrit.lastHighlightColor") private var lastColorRaw = HighlightColor.yellow.rawValue

    private var lastColor: HighlightColor { HighlightColor(rawValue: lastColorRaw) ?? .yellow }

    var body: some View {
        HStack(spacing: 6) {
            Button { pick(lastColor, note: false) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "highlighter").font(.system(size: 13, weight: .medium))
                    Text("Highlight").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .help("Highlight the selection (\u{21E7}\u{2318}H)")

            Rectangle().fill(tint.opacity(0.25)).frame(width: 1, height: 16)

            ForEach(HighlightColor.allCases) { color in
                SwatchDot(color: color, isLast: color == lastColor) { pick(color, note: false) }
            }

            Rectangle().fill(tint.opacity(0.25)).frame(width: 1, height: 16)

            Button { pick(lastColor, note: true) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12.5))
                    Text("Note").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Highlight and write a note")
        }
        .padding(.horizontal, 6)
        .background(
            Capsule(style: .continuous)
                .fill(pageColor.opacity(0.97))
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 5)
        )
        .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
        .fixedSize()
        .opacity(visible ? 1 : 0)
        .offset(y: visible ? 0 : 10)
        .allowsHitTesting(visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: visible)
    }

    private func pick(_ color: HighlightColor, note: Bool) {
        lastColorRaw = color.rawValue
        Haptics.tick()
        onHighlight(color, note)
    }

    private struct SwatchDot: View {
        let color: HighlightColor
        let isLast: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Circle()
                    .fill(color.color)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 1))
                    .padding(2)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(isLast ? 0.55 : 0), lineWidth: 1.5))
                    .scaleEffect(hovering ? 1.15 : 1)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help("Highlight in \(color.label.lowercased())")
        }
    }
}

/// The Close control every reader header ends with: a divider, then a
/// "Close" pill that picks up the reader's own theme colours. Cmd-W works too.
struct ReaderCloseButton: View {
    let help: String
    let tint: Color
    let rule: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(rule).frame(width: 1, height: 18)
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Close")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint.opacity(hovering ? 0.18 : 0.08))
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("w", modifiers: .command)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(help)
            .accessibilityLabel(help)
        }
        .fixedSize()
    }
}

/// A round preview of a reading theme ("Aa" on that theme's page color).
struct ThemeSwatch: View {
    let theme: ReaderTheme
    let isSelected: Bool
    let systemScheme: ColorScheme
    let accent: Color
    let label: Color
    let action: () -> Void

    private var fill: AnyShapeStyle {
        if theme == .system {
            return AnyShapeStyle(LinearGradient(
                stops: [
                    .init(color: Color(nsColor: ReaderPalette.paper.background), location: 0.5),
                    .init(color: Color(nsColor: ReaderPalette.night.background), location: 0.5)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(Color(nsColor: theme.palette(for: systemScheme).background))
    }

    private var glyph: Color {
        theme == .system
            ? Color.gray
            : Color(nsColor: theme.palette(for: systemScheme).text)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(fill)
                    Circle().strokeBorder(label.opacity(0.18), lineWidth: 1)
                    Text("Aa")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(glyph)
                    if isSelected {
                        Circle().strokeBorder(accent, lineWidth: 2.5).padding(-4)
                    }
                }
                .frame(width: 42, height: 42)
                .padding(4)

                Text(theme.label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? accent : label.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.label) theme")
    }
}

/// A typeface option rendered in its own face.
struct FaceChip: View {
    let face: ReaderFace
    let isSelected: Bool
    let accent: Color
    let tint: Color
    let text: Color
    let action: () -> Void

    private var font: Font {
        switch face {
        case .serif: .system(size: 22, design: .serif)
        case .classic: .custom("Georgia", size: 22)
        case .sans: .system(size: 22)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("Aa").font(font).foregroundStyle(isSelected ? accent : text)
                Text(face.label)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? accent : tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : text.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(face.label) typeface")
    }
}

/// Book-wide progress bar you can drag. Tick marks show where chapters
/// begin. Dragging previews the position (parent shows the chapter name);
/// the jump happens on release so scrubbing never loads dozens of chapters.
struct ReaderScrubber: View {
    let progress: Double
    let ticks: [Double]
    let isScrubbing: Bool
    let accent: Color
    let track: Color
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Capsule().fill(track).frame(height: isScrubbing ? 6 : 4)
                Capsule().fill(accent).frame(width: x, height: isScrubbing ? 6 : 4)

                ForEach(Array(ticks.enumerated()), id: \.offset) { _, tick in
                    Rectangle()
                        .fill(tick * width <= x ? Color.white.opacity(0.7) : track.opacity(1))
                        .frame(width: 1.5, height: 8)
                        .offset(x: tick * width - 0.75)
                }

                Circle()
                    .fill(accent)
                    .frame(width: isScrubbing ? 16 : 12, height: isScrubbing ? 16 : 12)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: x - (isScrubbing ? 8 : 6))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        onCommit(min(max(value.location.x / width, 0), 1))
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isScrubbing)
        }
        .frame(height: 24)
        .accessibilityElement()
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onCommit(min(progress + 0.02, 1))
            case .decrement: onCommit(max(progress - 0.02, 0))
            @unknown default: break
            }
        }
    }
}


/// Shown only in focus mode, when every other control is hidden. It is the one
/// way back to the toolbar with the mouse (the keyboard shortcut also works).
struct FocusExitPill: View {
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: action) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Show controls")
                            .font(.system(size: 13, weight: .medium))
                    }
                    // Frosted-glass pill: blurs whatever page is behind it, with
                    // a bright rim on top and a soft shadow, so it reads on
                    // white, sepia and dark pages alike.
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(hovering ? 0.22 : 0.14), lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                    .scaleEffect(hovering ? 1.04 : 1)
                    .animation(.easeOut(duration: 0.15), value: hovering)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Leave focus mode (\u{2318}\u{21E7}F)")
            }
            Spacer()
        }
        .padding(16)
    }
}


// MARK: - Small performance helpers

/// Runs the latest block after a quiet moment; earlier pending blocks are dropped.
final class ReaderDebouncer {
    private var work: DispatchWorkItem?
    var isPending: Bool { work != nil }

    func call(after delay: Double = 0.4, _ block: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.work = nil
            block()
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// Remembers the last stylesheet so it isn't rebuilt on every redraw.
final class ReaderCSSBox {
    var key = ""
    var value = ""
}


// MARK: - Copy protection

/// Spots EPUBs locked by store DRM. Font obfuscation (which every publisher
/// may use to protect embedded fonts) is not DRM and is ignored.
enum EPUBProtection {
    private static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC"
    ]

    static func isProtected(root: URL) -> Bool {
        let metaInf = root.appendingPathComponent("META-INF", isDirectory: true)
        let fm = FileManager.default
        // Adobe ADEPT, Apple FairPlay and Readium LCP each leave a marker file.
        for marker in ["rights.xml", "sinf.xml", "license.lcpl"]
        where fm.fileExists(atPath: metaInf.appendingPathComponent(marker).path) {
            return true
        }
        guard let data = try? Data(contentsOf: metaInf.appendingPathComponent("encryption.xml")),
              let xml = String(data: data, encoding: .utf8) else { return false }
        // Any encryption algorithm other than font obfuscation means locked pages.
        let pattern = #"Algorithm\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            guard let r = Range(match.range(at: 1), in: xml) else { continue }
            let algorithm = String(xml[r])
            // EncryptionMethod lines name the cipher; skip key-wrapping lines.
            if algorithm.contains("xmldsig") { continue }
            if !fontObfuscation.contains(algorithm) { return true }
        }
        return false
    }
}
