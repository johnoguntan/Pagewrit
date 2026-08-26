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
    @Environment(\.dismiss) private var dismiss

    @State private var pagePaths: [String] = []
    @State private var currentPageIndex: Int = 0
    @State private var currentImage: NSImage?
    @State private var isLoading = true
    @State private var loadFailed = false

    #if canImport(ZIPFoundation)
    @State private var archive: Archive?
    #endif

    private let extractionQueue = DispatchQueue(label: "com.sam.stoa.cbz-extraction")

    var body: some View {
        VStack(spacing: 0) {
            header
            pageArea
            footer
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(DesignTokens.background.ignoresSafeArea())
        .onAppear(perform: openArchive)
        .onChange(of: currentPageIndex) { _, newValue in
            loadPage(at: newValue)
            saveProgress()
        }
        .focusable()
        .onKeyPress(.rightArrow) { advance(1); return .handled }
        .onKeyPress(.leftArrow) { advance(-1); return .handled }
        .onKeyPress(.space) { advance(1); return .handled }
    }

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
                .fill(.primary.opacity(0.08))
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
                tapZone { advance(-1) }
                tapZone { advance(1) }
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
                advance(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(currentPageIndex <= 0)

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
                advance(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(currentPageIndex >= pagePaths.count - 1)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(DesignTokens.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.primary.opacity(0.08))
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

    // MARK: - Archive Loading

    private func openArchive() {
        #if canImport(ZIPFoundation)
        guard let archive = Archive(url: book.sourceURL, accessMode: .read) else {
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
