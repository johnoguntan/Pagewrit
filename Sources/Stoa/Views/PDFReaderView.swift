import SwiftUI
import PDFKit

// MARK: - PDFReaderView

/// In-app PDF reader. Wraps PDFKit's `PDFView`, tracks the current page,
/// and persists reading progress back to the library store as the user scrolls.
struct PDFReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @Environment(\.colorScheme) private var colorScheme
    @State private var document: PDFDocument?
    @State private var currentPageIndex: Int = 0
    @State private var pageCount: Int = 0
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if loadFailed {
                failureState
            } else if let document {
                PDFKitRepresentedView(document: document, currentPageIndex: $currentPageIndex)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DesignTokens.background)
            }
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(DesignTokens.background.ignoresSafeArea())
        .onAppear(perform: load)
        .onChange(of: currentPageIndex) { _, newValue in
            saveProgress(pageIndex: newValue)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(book.title)
                .font(DesignTokens.serifFont(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            if pageCount > 0 {
                Text("Page \(currentPageIndex + 1) of \(pageCount)")
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
        document = doc
    }

    private func saveProgress(pageIndex: Int) {
        guard pageCount > 1 else { return }
        let progress = Double(pageIndex) / Double(pageCount - 1)
        library.updateProgress(for: book, progress: progress)
    }
}

// MARK: - PDFKitRepresentedView

/// NSViewRepresentable bridge to PDFKit's `PDFView`, reporting the current
/// page back up via a binding whenever the user scrolls or navigates.
private struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var currentPageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor

        if let page = document.page(at: currentPageIndex) {
            DispatchQueue.main.async {
                view.go(to: page)
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
        // Page navigation is driven by the PDFView itself (scroll/keyboard);
        // nothing to push down from SwiftUI state here.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        let parent: PDFKitRepresentedView
        weak var pdfView: PDFView?

        init(_ parent: PDFKitRepresentedView) {
            self.parent = parent
        }

        @objc func pageChanged() {
            guard let pdfView, let page = pdfView.currentPage,
                  let document = pdfView.document else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            parent.currentPageIndex = index
        }
    }
}
