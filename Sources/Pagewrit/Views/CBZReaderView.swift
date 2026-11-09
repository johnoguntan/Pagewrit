import SwiftUI
import AppKit
import ImageIO
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// MARK: - Supporting types

enum CBZFitMode: String, CaseIterable, Identifiable {
    case page, width

    var id: String { rawValue }
    var label: String { self == .page ? "Fit page" : "Fit width" }
}

enum CBZDrawerTab: String, CaseIterable, Identifiable {
    case pages = "Pages"
    case bookmarks = "Bookmarks"

    var id: String { rawValue }
}

/// Reference-type image caches shared between the view and its background
/// extraction work. Thumbnail requests carry a "still wanted" set so fast
/// scrolling through the page grid does not queue up work for cells that
/// are already gone.
final class CBZImageStore {
    let pages = NSCache<NSNumber, NSImage>()
    let thumbs = NSCache<NSNumber, NSImage>()
    var inFlight = Set<Int>()

    private let lock = NSLock()
    private var wantedThumbs = Set<Int>()

    init() {
        pages.countLimit = 8
        thumbs.countLimit = 600
    }

    func setWanted(_ index: Int, _ wanted: Bool) {
        lock.lock(); defer { lock.unlock() }
        if wanted { wantedThumbs.insert(index) } else { wantedThumbs.remove(index) }
    }

    func isWanted(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return wantedThumbs.contains(index)
    }
}

// MARK: - CBZReaderView

/// In-app comic (CBZ) reader, matching the EPUB and PDF readers: the page
/// fills the window and the controls float above it.
///
/// - Pages: fit page or fit width, pinch or slider zoom with panning, double
///   click to zoom, single or two-page spreads, and left-to-right or manga
///   right-to-left reading.
/// - Header: page grid drawer, title, bookmark, appearance, focus mode.
/// - Footer: a draggable scrubber across the whole issue.
/// - Neighbouring pages are loaded ahead so turning a page is instant.
struct CBZReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismissWindow) private var dismissWindow
    /// Pagewrit's own light or dark look, read straight from the app rather
    /// than this window, which the reader theme may have forced. "Auto"
    /// follows this, and it updates the instant the app look changes.
    @ObservedObject private var appearanceWatcher = AppearanceWatcher.shared
    private var colorScheme: ColorScheme { appearanceWatcher.scheme }

    // Book state
    @State private var pagePaths: [String] = []
    @State private var currentPageIndex: Int = 0
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var store = CBZImageStore()
    @State private var imageTick = 0
    @State private var scrubValue: Double?

    #if canImport(ZIPFoundation)
    @State private var archive: Archive?
    #endif

    // Zoom
    @State private var zoom: CGFloat = 1.0
    @State private var zoomBase: CGFloat = 1.0

    // Chrome
    @State private var drawerTab: CBZDrawerTab?
    @State private var showAppearance = false
    @State private var focusMode = false
    @State private var hoverTop = false
    @State private var hoverBottom = false

    // Preferences
    /// Manga/comics convention: right-to-left, where the "next" page is
    /// physically to the left. Global rather than per-book.
    @AppStorage("stoa.cbzRightToLeft") private var rightToLeft = false
    @AppStorage("stoa.cbzSpread") private var spread = false
    @AppStorage("stoa.cbzFit") private var fitRaw: String = CBZFitMode.page.rawValue
    @AppStorage("stoa.cbzTheme") private var themeRaw: String = ReaderTheme.night.rawValue

    private let extractionQueue = DispatchQueue(label: "com.thehappy.Pagewrit.cbz-extraction")
    private let headerHeight: CGFloat = 52
    private let footerHeight: CGFloat = 78
    private let zoomRange: ClosedRange<CGFloat> = 1.0...4.0

    private var fitMode: CBZFitMode { CBZFitMode(rawValue: fitRaw) ?? .page }
    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .night }
    private var palette: ReaderPalette { theme.palette(for: colorScheme) }

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
            pageArea
            hoverStrips
            drawer
            chromeLayer
            if focusMode && !chromeVisible { FocusExitPill(tint: tint) { focusMode = false } }
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(ReaderWindowAppearance(theme: theme))
        // Native controls (tab pickers, switches) follow the reader theme, not the Mac.
        .environment(\.colorScheme, theme.controlScheme(system: colorScheme))
        .background(pageColor.ignoresSafeArea())
        .background(shortcuts)
        .onAppear(perform: openArchive)
        .onAppear { library.markOpened(book) }
        .onDisappear { library.commitReading() }
        .onChange(of: focusMode) { _, on in if on { drawerTab = nil; showAppearance = false } }
        .onChange(of: currentPageIndex) { _, _ in
            ensureVisiblePagesLoaded()
            saveProgress()
        }
        .onChange(of: spread) { _, _ in ensureVisiblePagesLoaded() }
        .focusable()
        // Space always means "keep reading forward" regardless of
        // direction; only the arrow keys and tap zones are spatial.
        .onKeyPress(.rightArrow) { rightToLeft ? goBack() : goForward(); return .handled }
        .onKeyPress(.leftArrow) { rightToLeft ? goForward() : goBack(); return .handled }
        .onKeyPress(.space) { goForward(); return .handled }
        .onKeyPress(.escape) {
            if drawerTab != nil { drawerTab = nil; return .handled }
            if focusMode { focusMode = false; return .handled }
            return .ignored
        }
    }

    // MARK: - Paging model
    //
    // "Forward"/"back" are always in reading order (index increases moving
    // forward). Everything spatial (arrow keys, tap zones, chevrons) maps to
    // one of the two based on `rightToLeft`.

    /// The page indices on screen. In two-page mode the cover stands alone
    /// and the rest pair up as (1,2), (3,4)...
    private var visibleIndices: [Int] {
        guard !pagePaths.isEmpty else { return [] }
        let current = min(max(currentPageIndex, 0), pagePaths.count - 1)
        guard spread else { return [current] }
        if current == 0 { return [0] }
        let start = current % 2 == 1 ? current : current - 1
        return start + 1 < pagePaths.count ? [start, start + 1] : [start]
    }

    /// Left-to-right order of the visible pages on screen.
    private var displayIndices: [Int] {
        rightToLeft ? Array(visibleIndices.reversed()) : visibleIndices
    }

    private var canGoBack: Bool { (visibleIndices.first ?? 0) > 0 }
    private var canGoForward: Bool { (visibleIndices.last ?? 0) < pagePaths.count - 1 }

    private func goForward() {
        guard canGoForward, let last = visibleIndices.last else { return }
        goTo(last + 1)
    }

    private func goBack() {
        guard canGoBack, let first = visibleIndices.first else { return }
        if spread {
            goTo(first <= 2 ? 0 : first - 2)
        } else {
            goTo(first - 1)
        }
    }

    private func goTo(_ index: Int) {
        guard !pagePaths.isEmpty else { return }
        currentPageIndex = min(max(index, 0), pagePaths.count - 1)
    }

    private var progress: Double {
        guard pagePaths.count > 1 else { return 0 }
        return Double(currentPageIndex) / Double(pagePaths.count - 1)
    }

    private var pageLabel: String {
        let shown = visibleIndices.map { $0 + 1 }
        guard let first = shown.first, let last = shown.last else { return "" }
        let pages = first == last ? "Page \(first)" : "Pages \(first)\u{2013}\(last)"
        return "\(pages) of \(pagePaths.count)"
    }

    // MARK: - Page area

    private var pageArea: some View {
        GeometryReader { geo in
            let _ = imageTick
            ZStack {
                if loadFailed {
                    failureState
                } else if pagePaths.isEmpty {
                    ProgressView()
                } else {
                    zoomablePages(in: geo.size)
                    if zoom <= 1.001 { tapZones }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func zoomablePages(in size: CGSize) -> some View {
        let display = displayIndices
        let count = CGFloat(max(display.count, 1))
        let slotWidth = size.width * zoom / count
        let slotHeight = size.height * zoom

        return ScrollView([.horizontal, .vertical]) {
            HStack(spacing: 0) {
                ForEach(display, id: \.self) { index in
                    pageImageView(index, width: slotWidth, height: slotHeight)
                }
            }
            .frame(minWidth: size.width, minHeight: size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleZoom() }
        }
        .scrollIndicators(zoom > 1.001 ? .automatic : .hidden)
        .id(currentPageIndex)
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    zoom = min(max(zoomBase * value.magnification, zoomRange.lowerBound), zoomRange.upperBound)
                }
                .onEnded { _ in zoomBase = zoom }
        )
    }

    @ViewBuilder
    private func pageImageView(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        if let image = store.pages.object(forKey: NSNumber(value: index)) {
            switch fitMode {
            case .page:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            case .width:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width)
            }
        } else {
            ProgressView()
                .frame(width: width, height: height)
        }
    }

    /// Left third and right third turn the page; double-click the middle to zoom. Disabled while zoomed so panning is not interrupted.
    private var tapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { rightToLeft ? goForward() : goBack() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleZoom() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { rightToLeft ? goBack() : goForward() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, headerHeight)
        .padding(.bottom, footerHeight)
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.18)) {
            zoom = zoom > 1.001 ? 1.0 : 2.0
            zoomBase = zoom
        }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        zoomBase = zoom
    }

    private var failureState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(tint)
            Text("Couldn't open this CBZ file.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(tint)
        }
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

    private var header: some View {
        HStack(spacing: 4) {
            ReaderIconButton(
                systemName: "square.grid.2x2", help: "Pages (\u{2318}L)",
                isActive: drawerTab != nil, tint: tint, accent: accent
            ) { toggleDrawer(.pages) }

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(DesignTokens.serifFont(size: 14, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
                if !pagePaths.isEmpty {
                    Text(pageLabel)
                        .font(DesignTokens.sansFont(size: 11))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)

            Spacer(minLength: 12)

            ReaderIconButton(
                systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark",
                help: isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page",
                isActive: isCurrentPageBookmarked, tint: tint, accent: accent
            ) { toggleBookmark() }
            .disabled(pagePaths.isEmpty)

            ReaderIconButton(
                systemName: "slider.horizontal.3", help: "Appearance and zoom",
                isActive: showAppearance, tint: tint, accent: accent
            ) { showAppearance.toggle() }
            .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                appearancePanel
                    .background(ReaderWindowAppearance(theme: theme))
                    .readerControls(theme, system: colorScheme)
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

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Zoom")
                        .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(DesignTokens.sansFont(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Button("Reset") { setZoom(1) }
                        .buttonStyle(.plain)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(accent)
                        .disabled(zoom <= 1.001)
                }
                HStack(spacing: 10) {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 12)).foregroundStyle(tint)
                    Slider(
                        value: Binding(get: { Double(zoom) }, set: { setZoom(CGFloat($0)) }),
                        in: Double(zoomRange.lowerBound)...Double(zoomRange.upperBound)
                    )
                    .tint(accent)
                    Image(systemName: "plus.magnifyingglass").font(.system(size: 12)).foregroundStyle(tint)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Background").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                HStack(spacing: 14) {
                    ForEach(ReaderTheme.allCases) { option in
                        ThemeSwatch(
                            theme: option,
                            isSelected: option == theme,
                            systemScheme: colorScheme,
                            accent: accent,
                            label: textColor
                        ) { themeRaw = option.rawValue }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Fit").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Fit", selection: $fitRaw) {
                    ForEach(CBZFitMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pages").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Pages", selection: $spread) {
                    Text("Single").tag(false)
                    Text("Two-page").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Reading direction").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Reading direction", selection: $rightToLeft) {
                    Text("Left to right").tag(false)
                    Text("Right to left").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Switch to right to left for manga.")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(tint)
            }

            Divider().overlay(rule)

            Button {
                setZoom(1)
                fitRaw = CBZFitMode.page.rawValue
                spread = false
                rightToLeft = false
                themeRaw = ReaderTheme.night.rawValue
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

    // MARK: - Drawer (page grid / bookmarks)

    @ViewBuilder
    private var drawer: some View {
        if drawerTab != nil {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Picker("Section", selection: Binding(
                        get: { drawerTab ?? .pages },
                        set: { drawerTab = $0 }
                    )) {
                        ForEach(CBZDrawerTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(12)

                    switch drawerTab ?? .pages {
                    case .pages: pageGrid
                    case .bookmarks: bookmarksList
                    }
                }
                .frame(width: 330)
                .background(chromeColor)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(rule).frame(width: 1)
                }

                Color.black.opacity(palette.isDark ? 0.35 : 0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { drawerTab = nil }
            }
            .padding(.top, headerHeight)
            .padding(.bottom, footerHeight)
            .transition(.opacity)
        }
    }

    private func toggleDrawer(_ tab: CBZDrawerTab) {
        withAnimation(.easeOut(duration: 0.2)) {
            drawerTab = (drawerTab == tab) ? nil : tab
        }
    }

    private var pageGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 10)], spacing: 12) {
                    ForEach(pagePaths.indices, id: \.self) { index in
                        Button {
                            goTo(index)
                            drawerTab = nil
                        } label: {
                            VStack(spacing: 4) {
                                CBZThumbnail(
                                    index: index,
                                    isCurrent: visibleIndices.contains(index),
                                    accent: accent,
                                    placeholder: tint.opacity(0.15),
                                    load: loadThumbnail,
                                    setWanted: { store.setWanted(index, $0) }
                                )
                                Text("\(index + 1)")
                                    .font(DesignTokens.sansFont(size: 11, weight: visibleIndices.contains(index) ? .semibold : .regular))
                                    .monospacedDigit()
                                    .foregroundStyle(visibleIndices.contains(index) ? accent : tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .onAppear { proxy.scrollTo(currentPageIndex, anchor: .center) }
        }
    }

    // Bookmarks

    private func bookmarkPosition(forPage index: Int) -> Double {
        Double(index) / Double(max(pagePaths.count - 1, 1))
    }

    private func pageIndex(forBookmarkPosition position: Double) -> Int {
        let index = Int((position * Double(max(pagePaths.count - 1, 1))).rounded())
        return min(max(index, 0), max(pagePaths.count - 1, 0))
    }

    private var currentPageBookmark: Bookmark? {
        guard !pagePaths.isEmpty else { return nil }
        let position = bookmarkPosition(forPage: currentPageIndex)
        let tolerance = (1.0 / Double(max(pagePaths.count, 1))) / 2
        return library.bookmarks(for: book).first { abs($0.position - position) < tolerance }
    }

    private var isCurrentPageBookmarked: Bool { currentPageBookmark != nil }

    private func toggleBookmark() {
        if let existing = currentPageBookmark {
            library.removeBookmark(existing)
        } else {
            guard !pagePaths.isEmpty else { return }
            library.addBookmark(
                for: book,
                position: bookmarkPosition(forPage: currentPageIndex),
                label: "Page \(currentPageIndex + 1)"
            )
        }
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
                            HStack(spacing: 8) {
                                Button {
                                    goTo(pageIndex(forBookmarkPosition: bookmark.position))
                                    drawerTab = nil
                                } label: {
                                    Text(bookmark.label)
                                        .font(DesignTokens.sansFont(size: 13))
                                        .foregroundStyle(textColor)
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

    // MARK: - Footer (scrubber)

    private var footer: some View {
        let shown = scrubValue ?? progress
        let scrubPage = Int((shown * Double(max(pagePaths.count - 1, 0))).rounded())
        let rightLabel = scrubValue != nil
            ? "Page \(scrubPage + 1) of \(pagePaths.count)"
            : pageLabel

        return VStack(spacing: 6) {
            HStack {
                Text(rightToLeft ? "Right to left" : "Left to right")
                    .lineLimit(1)
                Spacer()
                Text("\(rightLabel)  \u{00B7}  \(Int((shown * 100).rounded()))%")
                    .monospacedDigit()
            }
            .font(DesignTokens.sansFont(size: 11, weight: .medium))
            .foregroundStyle(tint)

            HStack(spacing: 10) {
                ReaderIconButton(
                    systemName: "chevron.left",
                    help: rightToLeft ? "Next page (\u{2318}\u{2190})" : "Previous page (\u{2318}\u{2190})",
                    isActive: false, tint: tint, accent: accent
                ) { rightToLeft ? goForward() : goBack() }
                .disabled(rightToLeft ? !canGoForward : !canGoBack)

                // In right-to-left mode the bar fills from the right.
                ReaderScrubber(
                    progress: rightToLeft ? 1 - shown : shown,
                    ticks: [],
                    isScrubbing: scrubValue != nil,
                    accent: accent,
                    track: tint.opacity(0.25),
                    onScrub: { scrubValue = rightToLeft ? 1 - $0 : $0 },
                    onCommit: { value in
                        scrubValue = nil
                        let fraction = rightToLeft ? 1 - value : value
                        goTo(Int((fraction * Double(max(pagePaths.count - 1, 0))).rounded()))
                    }
                )

                ReaderIconButton(
                    systemName: "chevron.right",
                    help: rightToLeft ? "Previous page (\u{2318}\u{2192})" : "Next page (\u{2318}\u{2192})",
                    isActive: false, tint: tint, accent: accent
                ) { rightToLeft ? goBack() : goForward() }
                .disabled(rightToLeft ? !canGoBack : !canGoForward)
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
            Button("") { toggleDrawer(.pages) }.keyboardShortcut("l", modifiers: .command)
            Button("") { focusMode.toggle() }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("") { setZoom(zoom * 1.25) }.keyboardShortcut("=", modifiers: .command)
            Button("") { setZoom(zoom / 1.25) }.keyboardShortcut("-", modifiers: .command)
            Button("") { setZoom(1) }.keyboardShortcut("0", modifiers: .command)
            Button("") { rightToLeft ? goBack() : goForward() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("") { rightToLeft ? goForward() : goBack() }.keyboardShortcut(.leftArrow, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }

    // MARK: - Archive loading

    private func openArchive() {
        #if canImport(ZIPFoundation)
        guard let archive = try? Archive(url: book.sourceURL, accessMode: .read, pathEncoding: nil) else {
            loadFailed = true
            isLoading = false
            return
        }
        self.archive = archive

        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "heic"]
        let paths = archive
            .filter { entry in
                // Skip macOS resource forks ("__MACOSX/._001.jpg") and hidden
                // files: they carry an image extension but are not pages, and
                // used to show up as blank pages in the middle of an issue.
                let path = entry.path
                let name = (path as NSString).lastPathComponent
                return entry.type == .file
                    && !path.contains("__MACOSX")
                    && !name.hasPrefix(".")
                    && imageExtensions.contains((path as NSString).pathExtension.lowercased())
            }
            .map { $0.path }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        guard !paths.isEmpty else {
            loadFailed = true
            isLoading = false
            return
        }

        pagePaths = paths
        isLoading = false

        if let progress = book.readingProgress, paths.count > 1 {
            currentPageIndex = min(max(Int((progress * Double(paths.count - 1)).rounded()), 0), paths.count - 1)
        }
        ensureVisiblePagesLoaded()
        #else
        loadFailed = true
        isLoading = false
        #endif
    }

    /// Loads what is on screen first, then the pages likely to be turned to
    /// next. All archive access happens on one serial queue.
    private func ensureVisiblePagesLoaded() {
        let visible = visibleIndices
        guard let first = visible.first, let last = visible.last else { return }
        let ahead = [last + 1, last + 2, last + 3]
        let behind = [first - 1]
        loadPages(visible + ahead + behind)
    }

    private func loadPages(_ indices: [Int]) {
        #if canImport(ZIPFoundation)
        guard let archive else { return }
        let paths = pagePaths
        let imageStore = store

        for index in indices where paths.indices.contains(index) {
            let key = NSNumber(value: index)
            if imageStore.pages.object(forKey: key) != nil || imageStore.inFlight.contains(index) { continue }
            imageStore.inFlight.insert(index)

            extractionQueue.async {
                var data = Data()
                // Skip absurdly large entries (a damaged or hostile archive).
                if let entry = archive[paths[index]], entry.uncompressedSize < 120_000_000 {
                    do {
                        _ = try archive.extract(entry) { chunk in data.append(chunk) }
                    } catch {
                        data = Data()
                    }
                }
                let image = data.isEmpty ? nil : NSImage(data: data)
                DispatchQueue.main.async {
                    imageStore.inFlight.remove(index)
                    if let image { imageStore.pages.setObject(image, forKey: key) }
                    imageTick += 1
                }
            }
        }
        #endif
    }

    private func loadThumbnail(_ index: Int, completion: @escaping (NSImage?) -> Void) {
        #if canImport(ZIPFoundation)
        let imageStore = store
        let key = NSNumber(value: index)
        if let cached = imageStore.thumbs.object(forKey: key) {
            completion(cached)
            return
        }
        guard let archive, pagePaths.indices.contains(index) else {
            completion(nil)
            return
        }
        let path = pagePaths[index]

        extractionQueue.async {
            // Skip work for cells that scrolled out of view while queued.
            guard imageStore.isWanted(index) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            var data = Data()
            if let entry = archive[path], entry.uncompressedSize < 120_000_000 {
                _ = try? archive.extract(entry) { chunk in data.append(chunk) }
            }
            let thumb = Self.makeThumbnail(from: data)
            DispatchQueue.main.async {
                if let thumb { imageStore.thumbs.setObject(thumb, forKey: key) }
                completion(thumb)
            }
        }
        #else
        completion(nil)
        #endif
    }

    private static func makeThumbnail(from data: Data, maxPixel: Int = 260) -> NSImage? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func saveProgress() {
        guard pagePaths.count > 1 else { return }
        let progress = Double(currentPageIndex) / Double(pagePaths.count - 1)
        library.updateProgress(for: book, progress: progress)
    }
}

// MARK: - CBZThumbnail

/// One cell in the page grid. Loads lazily, and tells the reader whether it
/// is still on screen so abandoned loads can be skipped.
private struct CBZThumbnail: View {
    let index: Int
    let isCurrent: Bool
    let accent: Color
    let placeholder: Color
    let load: (Int, @escaping (NSImage?) -> Void) -> Void
    let setWanted: (Bool) -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(placeholder)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .aspectRatio(0.68, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isCurrent ? accent : Color.clear, lineWidth: 2)
        )
        .onAppear {
            setWanted(true)
            if image == nil { load(index) { image = $0 } }
        }
        .onDisappear { setWanted(false) }
    }
}
