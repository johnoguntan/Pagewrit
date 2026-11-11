import SwiftUI

/// "Get Books" sheet — search and download free, openly-downloadable
/// titles from Project Gutenberg or the Internet Archive straight into
/// the library. Debounces as you type, shows per-row download state, and
/// posts .stoaBooksDownloaded so ContentView rescans once a file lands
/// on disk.
struct DownloadBooksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var source: BookSource = .gutenberg
    @State private var query = ""
    @State private var results: [UnifiedResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var downloadStates: [String: DownloadState] = [:]
    @State private var searchTask: Task<Void, Never>?

    enum BookSource: String, CaseIterable, Identifiable {
        case gutenberg = "Gutenberg"
        case internetArchive = "Internet Archive"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .gutenberg:
                "Free, public-domain titles from Project Gutenberg"
            case .internetArchive:
                "Open scans from Internet Archive. Lending-only items are left out."
            }
        }
    }

    /// One search hit from either source, flattened to what the row UI
    /// actually needs. Kept as a thin wrapper rather than two parallel
    /// result lists so the rest of the view doesn't need to branch on
    /// source at all.
    struct UnifiedResult: Identifiable {
        enum Backing {
            case gutenberg(GutenbergService.SearchResult)
            case internetArchive(InternetArchiveService.SearchResult)
        }

        let backing: Backing

        var id: String {
            switch backing {
            case .gutenberg(let result): "gutenberg-\(result.id)"
            case .internetArchive(let result): "ia-\(result.id)"
            }
        }

        var title: String {
            switch backing {
            case .gutenberg(let result): result.title
            case .internetArchive(let result): result.title
            }
        }

        var authorNames: String {
            switch backing {
            case .gutenberg(let result): result.authorNames
            case .internetArchive(let result): result.authorNames
            }
        }

        /// Gutendex tells us up front whether a book has an EPUB at all.
        /// Internet Archive's search index carries no such signal — every
        /// IA hit shows a "Get" button, and whether it's actually open is
        /// only known once the user taps it and the real metadata comes
        /// back (see InternetArchiveService.resolveDownload).
        var knownUnavailable: Bool {
            switch backing {
            case .gutenberg(let result): result.epubURL == nil
            case .internetArchive: false
            }
        }
    }

    enum DownloadState: Equatable {
        case downloading
        case done
        case failed
        case unavailable(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignTokens.hairline(colorScheme: colorScheme))
            content
        }
        .frame(width: 520, height: 600)
        .background(DesignTokens.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get Books")
                        .font(DesignTokens.serifFont(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(source.subtitle)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(TactileButtonStyle())
            }

            Picker("Source", selection: $source) {
                ForEach(BookSource.allCases) { candidate in
                    Text(candidate.rawValue).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search by title or author\u{2026}", text: $query)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.sansFont(size: 13))
                    .onSubmit { search(query) }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 7)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1)
            )
        }
        .padding(DesignTokens.Spacing.lg)
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results = []
                searchError = nil
                isSearching = false
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await performSearch(trimmed)
            }
        }
        .onChange(of: source) { _, _ in
            results = []
            downloadStates = [:]
            searchError = nil
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            search(trimmed)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchError {
            emptyState(icon: "exclamationmark.triangle", text: searchError)
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyState(
                icon: "text.book.closed",
                text: source == .gutenberg
                    ? "Search Project Gutenberg's 70,000+ free ebooks."
                    : "Search millions of scanned texts on the Internet Archive."
            )
        } else if results.isEmpty {
            emptyState(icon: "book.closed", text: "No results for \u{201c}\(query)\u{201d}.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { result in
                        resultRow(result)
                        Divider().overlay(DesignTokens.hairline(colorScheme: colorScheme))
                    }
                }
            }
        }
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(DesignTokens.sansFont(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }

    // MARK: - Result Row

    private func resultRow(_ result: UnifiedResult) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(DesignTokens.serifFont(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(result.authorNames.isEmpty ? "Unknown author" : result.authorNames)
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            downloadControl(for: result)
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private func downloadControl(for result: UnifiedResult) -> some View {
        switch downloadStates[result.id] {
        case .downloading:
            DownloadPill(kind: .working, action: {})
        case .done:
            DownloadPill(kind: .done, action: {})
        case .failed:
            DownloadPill(kind: .retry) { startDownload(result) }
        case .unavailable(let reason):
            Text(reason)
                .font(DesignTokens.sansFont(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
        case nil:
            if result.knownUnavailable {
                Text("No EPUB")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                DownloadPill(kind: .ready) { startDownload(result) }
            }
        }
    }

    // MARK: - Search

    @MainActor
    private func performSearch(_ trimmed: String) async {
        isSearching = true
        searchError = nil
        do {
            switch source {
            case .gutenberg:
                let found = try await GutenbergService.search(query: trimmed)
                guard !Task.isCancelled else { return }
                results = found.map { UnifiedResult(backing: .gutenberg($0)) }
            case .internetArchive:
                let found = try await InternetArchiveService.search(query: trimmed)
                guard !Task.isCancelled else { return }
                results = found.map { UnifiedResult(backing: .internetArchive($0)) }
            }
            isSearching = false
        } catch {
            guard !Task.isCancelled else { return }
            searchError = "Couldn't reach \(source.rawValue). Check your connection and try again."
            isSearching = false
        }
    }

    private func search(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { await performSearch(trimmed) }
    }

    // MARK: - Download

    private func startDownload(_ result: UnifiedResult) {
        downloadStates[result.id] = .downloading
        Task {
            do {
                let destination: URL
                switch result.backing {
                case .gutenberg(let source):
                    destination = try await GutenbergService.download(source)
                case .internetArchive(let source):
                    destination = try await InternetArchiveService.download(source)
                }
                downloadStates[result.id] = .done
                // Pass the file's own URL along so ContentView imports
                // just this one book instead of rescanning every watched
                // folder -- dropping it here would silently defeat that
                // optimization on every download.
                NotificationCenter.default.post(name: .stoaBooksDownloaded, object: destination)
            } catch InternetArchiveService.ServiceError.noOpenFileAvailable {
                downloadStates[result.id] = .unavailable("Lending only, can't be downloaded")
            } catch {
                downloadStates[result.id] = .failed
            }
        }
    }
}


// MARK: - Download pill

/// The button at the end of each Get Books row. Every state is the same size,
/// so rows line up and nothing shifts when a download starts or finishes.
private struct DownloadPill: View {
    enum Kind { case ready, working, done, retry }

    let kind: Kind
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private static let width: CGFloat = 112
    private static let height: CGFloat = 32

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                switch kind {
                case .ready:
                    Image(systemName: "arrow.down").font(.system(size: 11.5, weight: .bold))
                    Text("Download")
                case .working:
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Adding")
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 11.5, weight: .bold))
                    Text("Added")
                case .retry:
                    Image(systemName: "arrow.clockwise").font(.system(size: 11.5, weight: .bold))
                    Text("Try again")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: Self.width, height: Self.height)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(kind == .working || kind == .done)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: kind)
    }

    private var foreground: Color {
        switch kind {
        case .ready: DesignTokens.solidInk
        case .working: .secondary
        case .done: DesignTokens.accentInk
        case .retry: DesignTokens.accentSecondary
        }
    }

    private var fill: Color {
        switch kind {
        case .ready: DesignTokens.solidFill.opacity(hovering ? 0.88 : 1)
        case .working: Color.primary.opacity(0.06)
        case .done: DesignTokens.accent.opacity(0.14)
        case .retry: DesignTokens.accentSecondary.opacity(hovering ? 0.20 : 0.12)
        }
    }

    private var stroke: Color {
        switch kind {
        case .ready: .clear
        case .working: Color.primary.opacity(0.08)
        case .done: DesignTokens.accent.opacity(0.25)
        case .retry: DesignTokens.accentSecondary.opacity(0.35)
        }
    }
}
