import SwiftUI

/// Opens a Kindle book (MOBI / AZW / AZW3 / PRC). Pagewrit converts it to an
/// EPUB inside the library the first time (usually already done at import),
/// then hands it to the normal EPUB reader. Books that can't be read — DRM,
/// KFX, KF8-only — get a plain explanation instead of a blank page.
struct KindleReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismissWindow) private var dismissWindow

    private enum Phase { case working, ready, failed(String) }
    @State private var phase: Phase = .working

    var body: some View {
        Group {
            switch phase {
            case .ready:
                EPUBReaderView(book: book)
                    .environmentObject(library)
            case .working:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Preparing \(book.title)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Can't open this book")
                        .font(.title3.weight(.semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button("Close") { dismissWindow() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await prepare() }
    }

    private func prepare() async {
        guard Entitlements.isUnlocked(.kindleFormats) else {
            phase = .failed("Reading Kindle books is part of Pagewrit Pro.")
            return
        }
        let destination = library.convertedURL(for: book)
        if FileManager.default.fileExists(atPath: destination.path) {
            phase = .ready
            return
        }
        let source = book.sourceURL
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) { () -> Result<Void, Error> in
            do {
                try KindleConverter.convert(source: source, destination: destination)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            library.buildSearchIndexIfNeeded()
            phase = .ready
        case .failure(let error):
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Pagewrit couldn't convert this file.")
        }
    }
}
