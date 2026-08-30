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
                "Open scans from Internet Archive \u{2014} lending-only items are filtered out"
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
            ProgressView()
                .controlSize(.small)
                .frame(width: 54)
        case .done:
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.accent)
        case .failed:
            Button {
                startDownload(result)
            } label: {
                Text("Retry")
                    .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(TactileButtonStyle())
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
                Button {
                    startDownload(result)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(DesignTokens.sansFont(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(DesignTokens.accent, in: Capsule())
                        .shadow(color: DesignTokens.accent.opacity(0.35), radius: 6, x: 0, y: 2)
                }
                .buttonStyle(TactileButtonStyle())
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
                switch result.backing {
                case .gutenberg(let source):
                    try await GutenbergService.download(source)
                case .internetArchive(let source):
                    try await InternetArchiveService.download(source)
                }
                downloadStates[result.id] = .done
                NotificationCenter.default.post(name: .stoaBooksDownloaded, object: nil)
            } catch InternetArchiveService.ServiceError.noOpenFileAvailable {
                downloadStates[result.id] = .unavailable("Lending only \u{2014} not downloadable")
            } catch {
                downloadStates[result.id] = .failed
            }
        }
    }
}
