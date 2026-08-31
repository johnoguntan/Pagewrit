import SwiftUI
import AppKit
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// MARK: - CBZReaderView

/// In-app paged comic-book (CBZ) reader. Extracts one image at a time from
/// the zip archive on a background queue, with left/right keyboard paging
/// and progress persisted back to the library store.
struct CBZReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismissWindow) private var dismissWindow

    @Environment(\.colorScheme) private var colorScheme
    @State private var pagePaths: [String] = []
    @State private var currentPageIndex: Int = 0
    @State private var currentImage: NSImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    #if canImport(ZIPFoundation)
    @State private var archive: Archive?
    #endif

    /// Manga/comics convention: right-to-left, where the "next" page is
    /// physically to the left. Global rather than per-book — switching
    /// mid-series would be the annoying case, not the common one, and a
    /// per-book toggle would mean a schema migration on Book for a
    /// preference most libraries only need in one direction anyway.
    @AppStorage("stoa.cbzRightToLeft") private var rightToLeft = false
    @State private var showBookmarks = false

    private let extractionQueue = DispatchQueue(label: "com.sam.pagewrit.cbz-extraction")

    var body: some View {
        VStack(spacing: 0) {
            header
            pageArea
            footer
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(DesignTokens.background.ignoresSafeArea())
        .onAppear(perform: openArchive)
        .onAppear { library.markOpened(book) }
        .onChange(of: currentPageIndex) { _, newValue in
            loadPage(at: newValue)
            saveProgress()
        }
        .focusable()
        // Space always means "keep reading forward" regardless of
        // direction — only the arrow keys and tap zones are spatial.
        .onKeyPress(.rightArrow) { rightToLeft ? goBack() : goForward(); return .handled }
        .onKeyPress(.leftArrow) { rightToLeft ? goForward() : goBack(); return .handled }
        .onKeyPress(.space) { goForward(); return .handled }
    }

    // MARK: - Directional Navigation
    //
    // "Forward"/"back" are always in reading order (index increases moving
    // forward). Everything spatial — which arrow key, which tap zone,
    // which chevron button — maps to one of these two based on
    // `rightToLeft`, rather than every call site re-deriving the mapping.

    private func goForward() { advance(1) }
    private func goBack() { advance(-1) }

    private var canGoBack: Bool { currentPageIndex > 0 }
    private var canGoForward: Bool { currentPageIndex < pagePaths.count - 1 }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(book.title)
                .font(DesignTokens.serifFont(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if !pagePaths.isEmpty {
                Text("Page \(currentPageIndex + 1) of \(pagePaths.count)")
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button {
                rightToLeft.toggle()
            } label: {
                Label(
                    rightToLeft ? "Right to Left" : "Left to Right",
                    systemImage: rightToLeft ? "arrow.left" : "arrow.right"
                )
                .font(DesignTokens.sansFont(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DesignTokens.surface, in: Capsule())
                .overlay(Capsule().stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Reading direction \u{2014} switch for manga/right-to-left comics")
            .accessibilityLabel("Reading direction \u{2014} switch for manga/right-to-left comics")

            bookmarkButton

            Button {
                dismissWindow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.hairline(colorScheme: colorScheme))
                .frame(height: 1)
        }
    }

    // MARK: - Page Area

    private var pageArea: some View {
        ZStack {
            Color.black.opacity(0.92)

            if loadFailed {
                failureState
            } else if let currentImage {
                Image(nsImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(DesignTokens.Spacing.lg)
            } else {
                ProgressView()
                    .tint(.white)
            }

            HStack(spacing: 0) {
                tapZone { rightToLeft ? goForward() : goBack() }
                tapZone { rightToLeft ? goBack() : goForward() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tapZone(_ action: @escaping () -> Void) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var failureState: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.7))
            Text("Couldn't open this CBZ file.")
                .font(DesignTokens.sansFont(size: 14))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            Button {
                rightToLeft ? goForward() : goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(rightToLeft ? !canGoForward : !canGoBack)

            if !pagePaths.isEmpty {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.black.opacity(0.08))
                            .frame(height: 3)
                        Capsule()
                            .fill(DesignTokens.accent)
                            .frame(
                                width: geo.size.width * pageProgress,
                                height: 3
                            )
                    }
                }
                .frame(height: 3)
            }

            Button {
                rightToLeft ? goBack() : goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(rightToLeft ? !canGoBack : !canGoForward)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairline(colorScheme: colorScheme))
                .frame(height: 1)
        }
    }

    private var pageProgress: CGFloat {
        guard pagePaths.count > 1 else { return 0 }
        return CGFloat(currentPageIndex) / CGFloat(pagePaths.count - 1)
    }

    // MARK: - Paging

    private func advance(_ delta: Int) {
        let newIndex = currentPageIndex + delta
        guard pagePaths.indices.contains(newIndex) else { return }
        currentPageIndex = newIndex
    }

    // MARK: - Bookmarks

    private var isCurrentPageBookmarked: Bool {
        guard pagePaths.count > 0 else { return false }
        let position = Double(currentPageIndex) / Double(max(pagePaths.count - 1, 1))
        return library.bookmarks(for: book).contains {
            abs($0.position - position) < (1.0 / Double(max(pagePaths.count, 1))) / 2
        }
    }

    private var bookmarkButton: some View {
        Button {
            if let existing = library.bookmarks(for: book).first(where: { bookmark in
                guard pagePaths.count > 0 else { return false }
                let position = Double(currentPageIndex) / Double(max(pagePaths.count - 1, 1))
                return abs(bookmark.position - position) < (1.0 / Double(max(pagePaths.count, 1))) / 2
            }) {
                library.removeBookmark(existing)
            } else {
                showBookmarks = true
            }
        } label: {
            Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13))
                .foregroundStyle(isCurrentPageBookmarked ? DesignTokens.accent : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(pagePaths.isEmpty)
        .help(isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page \u{2014} or hold to browse bookmarks")
        .accessibilityLabel(isCurrentPageBookmarked ? "Remove bookmark" : "Bookmark this page \u{2014} or hold to browse bookmarks")
        .contextMenu {
            Button("Browse Bookmarks") { showBookmarks = true }
        }
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
                                    let index = Int((bookmark.position * Double(max(pagePaths.count - 1, 1))).rounded())
                                    currentPageIndex = min(max(index, 0), max(pagePaths.count - 1, 0))
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
        guard pagePaths.count > 0 else { return }
        let position = Double(currentPageIndex) / Double(max(pagePaths.count - 1, 1))
        library.addBookmark(for: book, position: position, label: "Page \(currentPageIndex + 1)")
    }

    // MARK: - Archive Loading

    private func openArchive() {
        #if canImport(ZIPFoundation)
        guard let archive = try? Archive(url: book.sourceURL, accessMode: .read, pathEncoding: nil) else {
            loadFailed = true
            isLoading = false
            return
        }
        self.archive = archive

        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]
        let paths = archive
            .filter { imageExtensions.contains(($0.path as NSString).pathExtension.lowercased()) }
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
        loadPage(at: currentPageIndex)
        #else
        loadFailed = true
        isLoading = false
        #endif
    }

    private func loadPage(at index: Int) {
        #if canImport(ZIPFoundation)
        guard let archive, pagePaths.indices.contains(index),
              let entry = archive[pagePaths[index]] else { return }

        let requestedIndex = index
        extractionQueue.async {
            var data = Data()
            do {
                _ = try archive.extract(entry) { chunk in data.append(chunk) }
            } catch {
                return
            }
            let image = NSImage(data: data)
            DispatchQueue.main.async {
                guard requestedIndex == currentPageIndex else { return }
                currentImage = image
            }
        }
        #endif
    }

    private func saveProgress() {
        guard pagePaths.count > 1 else { return }
        let progress = Double(currentPageIndex) / Double(pagePaths.count - 1)
        library.updateProgress(for: book, progress: progress)
    }
}
