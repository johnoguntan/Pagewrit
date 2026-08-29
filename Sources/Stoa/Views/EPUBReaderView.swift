import SwiftUI
import WebKit

#if canImport(EPUBKit)
import EPUBKit
#endif

// MARK: - EPUBReaderView

/// In-app EPUB reader. Renders one chapter at a time in a WKWebView,
/// with forward/back chapter navigation and progress persisted back
/// to the library store.
struct EPUBReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @Environment(\.colorScheme) private var colorScheme
    @State private var epub: EPUBDocument?
    @State private var chapterURLs: [URL] = []
    @State private var chapterTitles: [String] = []
    @State private var currentChapterIndex: Int = 0
    @State private var isLoading = true
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if loadFailed {
                failureState
            } else if !chapterURLs.isEmpty {
                EPUBWebViewRepresented(
                    chapterURL: chapterURLs[currentChapterIndex],
                    contentDirectory: epub?.contentDirectory
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignTokens.background)
            }

            footer
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(DesignTokens.background.ignoresSafeArea())
        .onAppear(perform: load)
        .onAppear { library.markOpened(book) }
        .focusable()
        .onKeyPress(.rightArrow) { advance(1); return .handled }
        .onKeyPress(.leftArrow) { advance(-1); return .handled }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(book.title)
                .font(DesignTokens.serifFont(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if !chapterURLs.isEmpty {
                Text("Chapter \(currentChapterIndex + 1) of \(chapterURLs.count)")
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button {
                dismiss()
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
        .background(DesignTokens.surface)
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
}

// MARK: - EPUBWebViewRepresented

/// NSViewRepresentable bridge to WKWebView for rendering EPUB chapter HTML.
/// Each chapter is loaded via `loadFileURL` so local CSS/images resolve.
private struct EPUBWebViewRepresented: NSViewRepresentable {
    let chapterURL: URL
    let contentDirectory: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the chapter URL actually changes
        guard context.coordinator.lastLoadedURL != chapterURL else { return }
        context.coordinator.lastLoadedURL = chapterURL
        let readAccessTo = contentDirectory ?? chapterURL.deletingLastPathComponent()
        webView.loadFileURL(chapterURL, allowingReadAccessTo: readAccessTo)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var lastLoadedURL: URL?
    }
}
