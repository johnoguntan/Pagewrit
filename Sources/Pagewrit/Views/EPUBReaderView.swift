import SwiftUI
import WebKit

#if canImport(EPUBKit)
import EPUBKit
#endif

import Foundation

// MARK: - EPUBReaderView

/// In-app EPUB reader. Renders one chapter at a time in a WKWebView,
/// with forward/back chapter navigation and progress persisted back
/// to the library store. Also carries in-book search, bookmarks, and a
/// reading theme (night/sepia), on top of the table of contents, font
/// sizing, and read-aloud it already had.
struct EPUBReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismissWindow) private var dismissWindow

    @Environment(\.colorScheme) private var colorScheme
    @State private var epub: EPUBDocument?
    @State private var chapterURLs: [URL] = []
    @State private var chapterTitles: [String] = []
    @State private var currentChapterIndex: Int = 0
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var tocEntries: [TOCEntry] = []
    @State private var showTOC = false
    @AppStorage("stoa.epubFontScale") private var fontScale: Double = 1.0
    @StateObject private var speech = SpeechController()

    @State private var showBookmarks = false

    @State private var showSearch = false
    @State private var searchQuery = ""
    @State private var searchResults: [EPUBSearchResult] = []
    @State private var currentSearchIndex: Int = 0
    @State private var pendingHighlightQuery: String?
    @State private var chapterTextCache: [Int: String] = [:]

    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue
    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .system }

    private let fontScaleRange: ClosedRange<Double> = 0.75...2.0
    private let fontScaleStep: Double = 0.125

    var body: some View {
        VStack(spacing: 0) {
            header
            if showSearch {
                searchBar
            }

            if loadFailed {
                failureState
            } else if !chapterURLs.isEmpty {
                EPUBWebViewRepresented(
                    chapterURL: chapterURLs[currentChapterIndex],
                    contentDirectory: epub?.contentDirectory,
                    fontScale: fontScale,
                    backgroundHex: readerTheme.epubBackgroundHex,
                    textHex: readerTheme.epubTextHex,
                    highlightQuery: pendingHighlightQuery
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(readerBackground)
            }

            footer
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(readerBackground.ignoresSafeArea())
        .onAppear(perform: load)
        .onAppear { library.markOpened(book) }
        .onChange(of: currentChapterIndex) { _, _ in speech.stop() }
        .onDisappear { speech.stop() }
        .focusable()
        .onKeyPress(.rightArrow) { advance(1); return .handled }
        .onKeyPress(.leftArrow) { advance(-1); return .handled }
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

            if !chapterURLs.isEmpty {
                Text("Chapter \(currentChapterIndex + 1) of \(chapterURLs.count)")
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            }

            tocButton
            searchButton
            bookmarkButton
            fontSizeControls
            themeMenu
            readAloudButton

            Button {
                dismissWindow()
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

    // MARK: - Table of Contents

    private var tocButton: some View {
        Button {
            showTOC = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13))
                .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
        }
        .buttonStyle(.plain)
        .disabled(tocEntries.isEmpty)
        .help("Table of contents")
        .accessibilityLabel("Table of contents")
        .padding(.trailing, DesignTokens.Spacing.xs)
        .popover(isPresented: $showTOC, arrowEdge: .bottom) {
            tocList
        }
    }

    private var tocList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tocEntries) { entry in
                    Button {
                        currentChapterIndex = entry.chapterIndex
                        saveProgress()
                        showTOC = false
                    } label: {
                        HStack {
                            Text(entry.title)
                                .font(DesignTokens.sansFont(
                                    size: 13,
                                    weight: entry.chapterIndex == currentChapterIndex ? .semibold : .regular
                                ))
                                .foregroundStyle(
                                    entry.chapterIndex == currentChapterIndex
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

    // MARK: - Bookmarks

    private var isCurrentChapterBookmarked: Bool {
        guard chapterURLs.count > 0 else { return false }
        let position = Double(currentChapterIndex) / Double(max(chapterURLs.count - 1, 1))
        return library.bookmarks(for: book).contains {
            abs($0.position - position) < (1.0 / Double(max(chapterURLs.count, 1))) / 2
        }
    }

    private var bookmarkButton: some View {
        Button {
            if let existing = library.bookmarks(for: book).first(where: { bookmark in
                guard !chapterURLs.isEmpty else { return false }
                let position = Double(currentChapterIndex) / Double(max(chapterURLs.count - 1, 1))
                return abs(bookmark.position - position) < (1.0 / Double(max(chapterURLs.count, 1))) / 2
            }) {
                library.removeBookmark(existing)
            } else {
                showBookmarks = true
            }
        } label: {
            Image(systemName: isCurrentChapterBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13))
                .foregroundStyle(isCurrentChapterBookmarked ? DesignTokens.accent : (readerTheme.secondaryTextColor ?? .secondary))
        }
        .buttonStyle(.plain)
        .disabled(chapterURLs.isEmpty)
        .help(isCurrentChapterBookmarked ? "Remove bookmark" : "Bookmark this chapter \u{2014} or hold to browse bookmarks")
        .accessibilityLabel(isCurrentChapterBookmarked ? "Remove bookmark" : "Bookmark this chapter \u{2014} or hold to browse bookmarks")
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
                                    let index = Int((bookmark.position * Double(max(chapterURLs.count - 1, 1))).rounded())
                                    currentChapterIndex = min(max(index, 0), max(chapterURLs.count - 1, 0))
                                    saveProgress()
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
        guard !chapterURLs.isEmpty else { return }
        let position = Double(currentChapterIndex) / Double(max(chapterURLs.count - 1, 1))
        let label = chapterTitles.indices.contains(currentChapterIndex)
            ? chapterTitles[currentChapterIndex]
            : "Chapter \(currentChapterIndex + 1)"
        library.addBookmark(for: book, position: position, label: label)
    }

    // MARK: - Search
    //
    // Searches every chapter's plain text (stripped HTML, cached per
    // chapter once extracted) rather than only the one currently on
    // screen \u{2014} a reader looking something up usually doesn't know which
    // chapter it's in. Jumping to a result loads that chapter, then hands
    // the query down to the WKWebView so it can run the browser's own
    // `window.find` to scroll to and highlight the first match.

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
        .disabled(chapterURLs.isEmpty)
        .help("Search this book")
        .accessibilityLabel("Search this book")
        .padding(.trailing, DesignTokens.Spacing.xs)
    }

    private var searchBar: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search this book\u{2026}", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(DesignTokens.sansFont(size: 13))
                .onSubmit { runSearch() }

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
            } else if !searchQuery.isEmpty && !isLoading {
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
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            clearSearch()
            return
        }

        var results: [EPUBSearchResult] = []
        for index in chapterURLs.indices {
            let text = cachedChapterText(at: index)
            guard let range = text.range(of: trimmed, options: .caseInsensitive) else { continue }
            let snippetStart = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
            let snippetEnd = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = text[snippetStart..<snippetEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(EPUBSearchResult(chapterIndex: index, snippet: snippet))
        }

        searchResults = results
        currentSearchIndex = 0
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
        searchResults = []
        currentSearchIndex = 0
        pendingHighlightQuery = nil
    }

    private func stepSearch(_ delta: Int) {
        guard !searchResults.isEmpty else { return }
        currentSearchIndex = (currentSearchIndex + delta + searchResults.count) % searchResults.count
        jumpToCurrentSearchResult()
    }

    private func jumpToCurrentSearchResult() {
        guard searchResults.indices.contains(currentSearchIndex) else { return }
        let result = searchResults[currentSearchIndex]
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentChapterIndex == result.chapterIndex {
            // Same chapter already loaded \u{2014} bump the query so the
            // representable's onChange re-runs window.find even though
            // chapterURL itself didn't change.
            pendingHighlightQuery = nil
            DispatchQueue.main.async { pendingHighlightQuery = trimmed }
        } else {
            currentChapterIndex = result.chapterIndex
            pendingHighlightQuery = trimmed
            saveProgress()
        }
    }

    // MARK: - Font Size Controls

    private var fontSizeControls: some View {
        HStack(spacing: 2) {
            Button {
                fontScale = max(fontScaleRange.lowerBound, fontScale - fontScaleStep)
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            .disabled(fontScale <= fontScaleRange.lowerBound)
            .help("Smaller text")
            .accessibilityLabel("Smaller text")

            Button {
                fontScale = min(fontScaleRange.upperBound, fontScale + fontScaleStep)
            } label: {
                Image(systemName: "textformat.size.larger")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(readerTheme.secondaryTextColor ?? .secondary)
            .disabled(fontScale >= fontScaleRange.upperBound)
            .help("Larger text")
            .accessibilityLabel("Larger text")
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
        .accessibilityLabel("Reading theme")
        .padding(.trailing, DesignTokens.Spacing.xs)
    }

    // MARK: - Read Aloud

    private var readAloudButton: some View {
        Button {
            if speech.isSpeaking {
                speech.stop()
            } else {
                speakCurrentChapter()
            }
        } label: {
            Image(systemName: speech.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 13))
                .foregroundStyle(speech.isSpeaking ? DesignTokens.accent : (readerTheme.secondaryTextColor ?? .secondary))
        }
        .buttonStyle(.plain)
        .disabled(chapterURLs.isEmpty)
        .help(speech.isSpeaking ? "Stop reading aloud" : "Read this chapter aloud")
        .accessibilityLabel(speech.isSpeaking ? "Stop reading aloud" : "Read this chapter aloud")
        .padding(.trailing, DesignTokens.Spacing.xs)
    }

    private func speakCurrentChapter() {
        guard chapterURLs.indices.contains(currentChapterIndex) else { return }
        speech.speak(cachedChapterText(at: currentChapterIndex))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            Button {
                advance(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(currentChapterIndex <= 0)

            if !chapterURLs.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.black.opacity(0.08))
                            .frame(height: 3)
                        Capsule()
                            .fill(DesignTokens.accent)
                            .frame(
                                width: geo.size.width * chapterProgress,
                                height: 3
                            )
                    }
                }
                .frame(height: 3)
            }

            Button {
                advance(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(currentChapterIndex >= chapterURLs.count - 1)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(readerTheme.chromeColor ?? DesignTokens.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairline(colorScheme: colorScheme))
                .frame(height: 1)
        }
    }

    private var chapterProgress: CGFloat {
        guard chapterURLs.count > 1 else { return 0 }
        return CGFloat(currentChapterIndex) / CGFloat(chapterURLs.count - 1)
    }

    // MARK: - Failure State

    private var failureState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Couldn't open this EPUB file.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chapter Navigation

    private func advance(_ delta: Int) {
        let newIndex = currentChapterIndex + delta
        guard chapterURLs.indices.contains(newIndex) else { return }
        currentChapterIndex = newIndex
        pendingHighlightQuery = nil
        saveProgress()
    }

    // MARK: - Loading

    private func load() {
        guard epub == nil else { return }

        #if canImport(EPUBKit)
        guard let epubDoc = EPUBDocument(url: book.sourceURL) else {
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

        // Resume at saved chapter position
        if let progress = book.readingProgress, urls.count > 1 {
            currentChapterIndex = min(
                max(Int((progress * Double(urls.count - 1)).rounded()), 0),
                urls.count - 1
            )
        }
        saveProgress()
        #else
        loadFailed = true
        isLoading = false
        #endif
    }

    private func saveProgress() {
        guard chapterURLs.count > 1 else { return }
        let progress = Double(currentChapterIndex) / Double(chapterURLs.count - 1)
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
    let snippet: String
}

// MARK: - EPUBWebViewRepresented

/// NSViewRepresentable bridge to WKWebView for rendering EPUB chapter HTML.
/// Each chapter is loaded via `loadFileURL` so local CSS/images resolve.
private struct EPUBWebViewRepresented: NSViewRepresentable {
    let chapterURL: URL
    let contentDirectory: URL?
    var fontScale: Double = 1.0
    var backgroundHex: String?
    var textHex: String?
    var highlightQuery: String?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.fontScale = fontScale
        context.coordinator.backgroundHex = backgroundHex
        context.coordinator.textHex = textHex

        guard context.coordinator.lastLoadedURL != chapterURL else {
            // Same chapter \u{2014} just re-apply style, and re-run a search
            // highlight if one was requested for the chapter already on
            // screen (the query changing doesn't reload the page).
            context.coordinator.applyStyle(to: webView)
            if let highlightQuery, highlightQuery != context.coordinator.lastHighlightQuery {
                context.coordinator.lastHighlightQuery = highlightQuery
                context.coordinator.highlight(query: highlightQuery, in: webView)
            }
            return
        }
        context.coordinator.lastLoadedURL = chapterURL
        context.coordinator.pendingHighlightQuery = highlightQuery
        context.coordinator.lastHighlightQuery = highlightQuery
        let readAccessTo = contentDirectory ?? chapterURL.deletingLastPathComponent()
        webView.loadFileURL(chapterURL, allowingReadAccessTo: readAccessTo)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Applies the user's chosen font scale and reading theme by injecting
    /// a <style> override after each page load, re-injecting (without
    /// reloading) whenever either changes on the same chapter \u{2014} a full
    /// page reload would lose scroll position for no reason. Also runs a
    /// pending search highlight once the page has actually finished
    /// loading.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoadedURL: URL?
        var fontScale: Double = 1.0
        var backgroundHex: String?
        var textHex: String?
        var pendingHighlightQuery: String?
        var lastHighlightQuery: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyStyle(to: webView)
            if let query = pendingHighlightQuery {
                pendingHighlightQuery = nil
                highlight(query: query, in: webView)
            }
        }

        func applyStyle(to webView: WKWebView) {
            let pixelSize = Int((17.0 * fontScale).rounded())
            var css = "html, body, p, div, span, li, td { font-size: \(pixelSize)px !important; line-height: 1.6 !important; }"
            if let backgroundHex, let textHex {
                css += " html, body { background-color: \(backgroundHex) !important; color: \(textHex) !important; }"
                css += " a { color: \(textHex) !important; }"
            }
            let js = "(function(){var s=document.getElementById('stoa-style-override');if(!s){s=document.createElement('style');s.id='stoa-style-override';document.head.appendChild(s);}s.textContent=\(css.debugDescription);})();"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func highlight(query: String, in webView: WKWebView) {
            guard !query.isEmpty else { return }
            let js = "window.find(\(query.debugDescription), false, false, true, false, true, false);"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
