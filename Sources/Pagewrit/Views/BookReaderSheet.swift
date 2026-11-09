import SwiftUI

// MARK: - BookReaderSheet

/// Shared reader dispatch by format — the single place that decides which
/// in-app reader a book opens into. Used from both BookDetailView's "Read"
/// button and the grid tile's context menu, so both entry points stay in
/// sync automatically.
struct BookReaderSheet: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        switch book.format {
        case .pdf:
            PDFReaderView(book: book)
                .environmentObject(library)
        case .cbz:
            CBZReaderView(book: book)
                .environmentObject(library)
        case .epub:
            EPUBReaderView(book: book)
                .environmentObject(library)
        case .pptx:
            PPTXReaderView(book: book)
                .environmentObject(library)
        case .kindle:
            KindleReaderView(book: book)
                .environmentObject(library)
        case .docx, .text:
            TextDocumentReaderView(book: book)
                .environmentObject(library)
        }
    }
}
