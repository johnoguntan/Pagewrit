import SwiftUI

/// "Get Books" sheet — search and download free, public-domain titles from
/// Project Gutenberg straight into the library. Debounces as you type,
/// shows per-row download state, and posts .stoaBooksDownloaded so
/// ContentView rescans once a file lands on disk.
struct DownloadBooksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var results: [GutenbergService.SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var downloadStates: [Int: DownloadState] = [:]
    @State private var searchTask: Task<Void, Never>?

    enum DownloadState: Equatable {
        case downloading
        case done
        case failed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignTokens.hairline(colorScheme: colorScheme))
            content
        }
        .frame(width: 520, height: 560)
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
                    Text("Free, public-domain titles from Project Gutenberg")
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
            emptyState(icon: "text.book.closed", text: "Search Project Gutenberg's 70,000+ free ebooks.")
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

    private func resultRow(_ result: GutenbergService.SearchResult) -> some View {
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
    private func downloadControl(for result: GutenbergService.SearchResult) -> some View {
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
        case nil:
            if result.epubURL != nil {
                Button {
                    startDownload(result)
                } label: {
                    Text("Get")
                        .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(DesignTokens.accent, in: Capsule())
                }
                .buttonStyle(TactileButtonStyle())
            } else {
                Text("No EPUB")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Search

    @MainActor
    private func performSearch(_ trimmed: String) async {
        isSearching = true
        searchError = nil
        do {
            let found = try await GutenbergService.search(query: trimmed)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        } catch {
            guard !Task.isCancelled else { return }
            searchError = "Couldn't reach Project Gutenberg. Check your connection and try again."
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

    private func startDownload(_ result: GutenbergService.SearchResult) {
        downloadStates[result.id] = .downloading
        Task {
            do {
                let fileURL = try await GutenbergService.download(result)
                downloadStates[result.id] = .done
                // Carries the downloaded file's URL so ContentView can
                // import just this one file instead of rescanning every
                // watched folder for one new arrival.
                NotificationCenter.default.post(name: .stoaBooksDownloaded, object: fileURL)
            } catch {
                downloadStates[result.id] = .failed
            }
        }
    }
}
