import SwiftUI

/// "Fix Metadata" sheet — search Open Library for a book whose title,
/// author, or cover is wrong (often because it was scanned from a bare
/// filename), pick the right catalog record, and apply its title, author,
/// and cover art to this book. Mirrors DownloadBooksView's search-sheet
/// shape (debounced search, per-row state) but resolves to a single
/// apply-and-dismiss action instead of a download.
struct MetadataLookupView: View {
    let book: Book

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var query: String
    @State private var results: [OpenLibraryService.SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var applyingID: String?

    init(book: Book) {
        self.book = book
        var seed = book.title
        if let author = book.author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            seed += " \(author)"
        }
        _query = State(initialValue: seed)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DesignTokens.hairline(colorScheme: colorScheme))
            content
        }
        .frame(width: 480, height: 560)
        .background(DesignTokens.background)
        .onAppear {
            search(query)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fix Metadata")
                        .font(DesignTokens.serifFont(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Search Open Library and apply the right title, author, and cover.")
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
            emptyState(icon: "text.book.closed", text: "Search Open Library's catalog by title or author.")
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

    private func resultRow(_ result: OpenLibraryService.SearchResult) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            coverThumbnail(result)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(DesignTokens.serifFont(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(rowSubtitle(result))
                    .font(DesignTokens.sansFont(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            if applyingID == result.id {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 54)
            } else {
                Button {
                    apply(result)
                } label: {
                    Text("Use This")
                        .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(DesignTokens.accent, in: Capsule())
                }
                .buttonStyle(TactileButtonStyle())
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private func coverThumbnail(_ result: OpenLibraryService.SearchResult) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(DesignTokens.surface)
            .frame(width: 32, height: 46)
            .overlay(
                Group {
                    if let url = result.thumbnailURL {
                        AsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.clear
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func rowSubtitle(_ result: OpenLibraryService.SearchResult) -> String {
        var parts: [String] = []
        if !result.authorText.isEmpty { parts.append(result.authorText) }
        if let year = result.firstPublishYear { parts.append(String(year)) }
        return parts.isEmpty ? "Unknown author" : parts.joined(separator: " \u{00b7} ")
    }

    // MARK: - Search

    @MainActor
    private func performSearch(_ trimmed: String) async {
        isSearching = true
        searchError = nil
        do {
            let found = try await OpenLibraryService.search(title: trimmed, author: nil)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        } catch {
            guard !Task.isCancelled else { return }
            searchError = "Couldn't reach Open Library. Check your connection and try again."
            isSearching = false
        }
    }

    private func search(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask = Task { await performSearch(trimmed) }
    }

    // MARK: - Apply

    private func apply(_ result: OpenLibraryService.SearchResult) {
        applyingID = result.id
        Task {
            let coverData = try? await OpenLibraryService.downloadCoverData(for: result)
            await MainActor.run {
                library.applyMetadata(
                    to: book,
                    title: result.title,
                    author: result.authorNames.isEmpty ? nil : result.authorText,
                    coverData: coverData
                )
                applyingID = nil
                dismiss()
            }
        }
    }
}
