import SwiftUI
import AppKit

// MARK: - BookDetailView

/// Two-column book detail: large cover on the left, metadata on the right.
/// Now accepts a `Book` (persisted via SwiftData) instead of a raw `DiscoveredFile`.
struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var newTagText = ""
    @State private var showReader = false
    @State private var showDeleteConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xl) {
                coverSection
                metadataSection
            }
            .padding(DesignTokens.Spacing.xl)
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .navigationTitle(book.title)
        .sheet(isPresented: $showReader) {
            readerSheet
        }
        .confirmationDialog(
            "Delete \u{201c}\(book.title)\u{201d}?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) {
                library.deleteFile(for: book)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the file itself to the Trash, not just Stoa's library entry. This can't be undone from inside Stoa.")
        }
    }

    // MARK: - In-App Reader

    private var readerSheet: some View {
        BookReaderSheet(book: book)
            .environmentObject(library)
    }

    // MARK: - Cover (left column)

    private var coverSection: some View {
        MattedCoverView(book: book, cornerRadius: DesignTokens.Detail.coverCornerRadius, showBadge: false)
            .frame(width: DesignTokens.Detail.coverWidth)
            .shadow(
                color: DesignTokens.Shadow.heavy(colorScheme: colorScheme).color,
                radius: DesignTokens.Shadow.heavy(colorScheme: colorScheme).radius,
                x: 0,
                y: DesignTokens.Shadow.heavy(colorScheme: colorScheme).y
            )
            .fixedSize()
    }

    // MARK: - Metadata (right column)

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(book.title)
                .font(DesignTokens.serifFont(
                    size: DesignTokens.Detail.Title.fontSize,
                    weight: .bold
                ))
                .tracking(DesignTokens.Detail.Title.tracking)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(DesignTokens.sansFont(size: DesignTokens.Detail.Author.fontSize))
                    .foregroundStyle(.secondary)
            }

            tagSection
            buttonsRow

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xxs)

            metadataGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tags (real, from Book.tags)

    private var tagSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Detail.Tag.gap) {
                ForEach(book.tags, id: \.self) { tag in
                    tagPill(tag)
                }
            }

            HStack(spacing: DesignTokens.Spacing.xs) {
                TextField("Add tag\u{2026}", text: $newTagText)
                    .textFieldStyle(.plain)
                    .font(DesignTokens.sansFont(
                        size: DesignTokens.Detail.Tag.fontSize,
                        weight: .medium
                    ))
                    .frame(maxWidth: 100)
                    .onSubmit {
                        addTag()
                    }

                if !newTagText.isEmpty {
                    Button {
                        addTag()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(DesignTokens.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.Tag.fontSize,
                    weight: .semibold
                ))
                .foregroundStyle(.secondary)

            Button {
                removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, DesignTokens.Detail.Tag.paddingV)
        .padding(.horizontal, DesignTokens.Detail.Tag.paddingH)
        .background(
            Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06),
            in: Capsule()
        )
    }

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !book.tags.contains(trimmed) else { return }
        library.updateTags(for: book, tags: book.tags + [trimmed])
        newTagText = ""
    }

    private func removeTag(_ tag: String) {
        library.updateTags(for: book, tags: book.tags.filter { $0 != tag })
    }

    // MARK: - Buttons

    private var buttonsRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button {
                if book.format == .pdf || book.format == .cbz || book.format == .epub {
                    showReader = true
                } else {
                    NSWorkspace.shared.open(book.sourceURL)
                }
            } label: {
                Label(
                    book.format == .pdf || book.format == .cbz || book.format == .epub ? "Read" : "Open",
                    systemImage: book.format == .pdf || book.format == .cbz || book.format == .epub ? "book.fill" : "book"
                )
                    .font(DesignTokens.sansFont(
                        size: DesignTokens.Detail.PrimaryButton.fontSize,
                        weight: .semibold
                    ))
                    .foregroundStyle(.white)
                    .padding(.vertical, DesignTokens.Detail.PrimaryButton.paddingV)
                    .padding(.horizontal, DesignTokens.Detail.PrimaryButton.paddingH)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Detail.PrimaryButton.cornerRadius))
            }
            .buttonStyle(.plain)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(DesignTokens.sansFont(
                        size: DesignTokens.Detail.SecondaryButton.fontSize
                    ))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Detail.SecondaryButton.paddingV)
                    .padding(.horizontal, DesignTokens.Detail.SecondaryButton.paddingH)
                    .background(.clear)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Detail.SecondaryButton.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Detail.SecondaryButton.cornerRadius)
                            .stroke(.separator, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(DesignTokens.Detail.SecondaryButton.paddingV)
            }
            .buttonStyle(.plain)
            .help("Delete file\u{2026}")
        }
    }

    // MARK: - Metadata Grid (2x2)

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxl) {
                metaItem(label: "FORMAT", value: book.format.rawValue.uppercased())
                metaItem(
                    label: "SIZE",
                    value: ByteCountFormatter.string(fromByteCount: book.sizeBytes, countStyle: .file)
                )
            }

            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxl) {
                metaItem(label: "SOURCE", value: book.sourceURL.deletingLastPathComponent().lastPathComponent)
                metaItem(
                    label: "ADDED",
                    value: book.addedAt.formatted(date: .abbreviated, time: .omitted)
                )
            }

            progressRow()
        }
    }

    private func metaItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(label)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaLabel.fontSize,
                    weight: .semibold
                ))
                .tracking(DesignTokens.Detail.MetaLabel.tracking)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Text(value)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaValue.fontSize
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Progress Row

    private func progressRow() -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("PROGRESS")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaLabel.fontSize,
                    weight: .semibold
                ))
                .tracking(DesignTokens.Detail.MetaLabel.tracking)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(DesignTokens.Detail.ProgressBar.trackOpacity))
                        .frame(height: DesignTokens.Detail.ProgressBar.height)

                    let progress = book.readingProgress ?? 0
                    Capsule()
                        .fill(DesignTokens.accent)
                        .frame(
                            width: geo.size.width * progress,
                            height: DesignTokens.Detail.ProgressBar.height
                        )
                }
            }
            .frame(height: DesignTokens.Detail.ProgressBar.height)

            Text(progressText)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaValue.fontSize
                ))
                .foregroundStyle(.secondary)
        }
    }

    private var progressText: String {
        guard let progress = book.readingProgress else { return "Not started" }
        return "\(Int(progress * 100))% complete"
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BookDetailView(book: Book(
            title: "Sample Book",
            author: "Author Name",
            format: .pdf,
            sourceURL: URL(fileURLWithPath: "/Users/test/Book.pdf")
        ))
        .environmentObject(LibraryStore())
    }
}
