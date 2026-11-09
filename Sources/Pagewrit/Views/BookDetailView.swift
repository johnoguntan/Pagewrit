import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - BookDetailView

/// Two-column book detail: large cover on the left, metadata on the right.
/// Now accepts a `Book` (persisted via SwiftData) instead of a raw `DiscoveredFile`.
struct BookDetailView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var newTagText = ""
    @State private var newShelfText = ""
    @State private var showDeleteConfirmation = false
    @State private var showMetadataLookup = false
    @Environment(\.dismiss) private var dismiss
    @State private var paneWidth: CGFloat = 900
    @State private var isScannedPDF = false
    @ObservedObject private var ocr = OCRManager.shared

    /// Below this width the cover and metadata can't sit side by side without
    /// squeezing the buttons and title, so they stack instead.
    private var isCompact: Bool { paneWidth < 780 }

    var body: some View {
        ScrollView {
            Group {
                if isCompact {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                        coverSection
                        metadataSection
                    }
                } else {
                    HStack(alignment: .top, spacing: DesignTokens.Spacing.xl) {
                        coverSection
                        metadataSection
                    }
                }
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { paneWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in paneWidth = width }
            }
        )
        .background(DesignTokens.background.ignoresSafeArea())
        .navigationTitle(book.title)
        .task(id: book.contentHash) {
            guard book.format == .pdf, !library.hasSearchableCopy(book) else { isScannedPDF = false; return }
            let url = book.sourceURL
            isScannedPDF = await Task.detached(priority: .utility) { OCRService.isScanned(url: url) }.value
        }
        .onChange(of: ocr.jobs[book.contentHash]?.done ?? false) { _, done in
            if done { isScannedPDF = false }
        }
        .sheet(isPresented: $showMetadataLookup) {
            MetadataLookupView(book: book)
                .environmentObject(library)
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
            Text("This moves the file itself to the Trash, not just Pagewrit's library entry. This can't be undone from inside Pagewrit.")
        }
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
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(DesignTokens.sansFont(size: DesignTokens.Detail.Author.fontSize))
                    .foregroundStyle(.secondary)
            }

            readingSection
            tagSection
            shelfSection
            buttonsRow

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xxs)

            metadataGrid

            notesSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Status, rating and series

    @State private var seriesDraft = ""
    @State private var seriesNumberDraft = ""

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Picker("Status", selection: Binding(
                    get: { book.status },
                    set: { library.setStatus(book, status: $0) }
                )) {
                    ForEach(ReadingStatus.allCases) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                VStack(alignment: .leading, spacing: 2) {
                    Text("YOUR RATING")
                        .font(DesignTokens.sansFont(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    DogRating(rating: book.rating, size: 20) { value in
                        library.setRating(book, rating: value)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("SERIES")
                    .font(DesignTokens.sansFont(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                TextField("Series name", text: $seriesDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit(saveSeries)
                Text("#").foregroundStyle(.secondary)
                TextField("Book #", text: $seriesNumberDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onSubmit(saveSeries)
                if seriesDraft != (book.seriesName ?? "")
                    || seriesNumberDraft != Self.formatIndex(book.seriesIndex) {
                    Button("Save", action: saveSeries)
                        .buttonStyle(.borderless)
                }
            }
            .onAppear {
                seriesDraft = book.seriesName ?? ""
                seriesNumberDraft = Self.formatIndex(book.seriesIndex)
            }
        }
    }

    private static func formatIndex(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func saveSeries() {
        let number = Double(seriesNumberDraft.trimmingCharacters(in: .whitespaces))
        library.setSeries(book, name: seriesDraft, index: number)
        seriesDraft = book.seriesName ?? ""
        seriesNumberDraft = Self.formatIndex(book.seriesIndex)
    }

    // MARK: - Highlights & notes

    private var notesSection: some View {
        let items = library.highlights(for: book)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Text(items.isEmpty ? "Highlights and notes" : "Highlights and notes (\(items.count))")
                    .font(DesignTokens.sansFont(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !items.isEmpty {
                    Button("Copy as Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            MarkdownExporter.exportNotes(for: book, highlights: items),
                            forType: .string
                        )
                    }
                    Button("Export\u{2026}") { exportNotes(items) }
                }
            }
            .buttonStyle(.borderless)
            .font(DesignTokens.sansFont(size: 12))

            if items.isEmpty {
                Text("Open the book, select some text and choose Highlight. Your highlights and notes will collect here.")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items, id: \.persistentModelID) { item in
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.color.color)
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                library.requestJump(to: item)
                                openWindow(id: "reader", value: book.contentHash)
                            } label: {
                                Text(item.text.isEmpty ? "Note" : item.text)
                                    .font(DesignTokens.serifFont(size: 14, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Open the book at this passage")
                            Text(highlightLocationLabel(item, book: book))
                                .font(DesignTokens.sansFont(size: 11))
                                .foregroundStyle(.secondary)
                            if !item.note.isEmpty {
                                Text(item.note)
                                    .font(DesignTokens.sansFont(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }

    private func exportNotes(_ items: [Highlight]) {
        let markdown = MarkdownExporter.exportNotes(for: book, highlights: items)
        let panel = NSSavePanel()
        panel.title = "Export Highlights and Notes"
        panel.nameFieldStringValue = book.title.replacingOccurrences(of: "/", with: "-") + " \u{2014} notes"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tags (real, from Book.tags)

    private var tagSection: some View {
        chipEditor(
            title: "TAGS",
            icon: nil,
            items: book.tags,
            placeholder: "Add tag",
            text: $newTagText,
            onAdd: addTag,
            onRemove: removeTag
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

    // MARK: - Shelves (real, from Book.shelfNames)
    //
    // Same shape as tags, but a distinct field and sidebar section so a user
    // can browse "just what's on my Currently Reading shelf" without it
    // mixing with freeform tags.

    private var shelfSection: some View {
        chipEditor(
            title: "SHELVES",
            icon: "books.vertical",
            items: book.shelfNames,
            placeholder: "Add to shelf",
            text: $newShelfText,
            onAdd: addShelf,
            onRemove: removeShelf
        )
    }

    // MARK: - Shared chip editor

    /// A labelled row of removable pills that wraps onto extra lines, ending
    /// in an obviously-editable "+ Add" field.
    private func chipEditor(
        title: String,
        icon: String?,
        items: [String],
        placeholder: String,
        text: Binding<String>,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaLabel.fontSize,
                    weight: .semibold
                ))
                .tracking(DesignTokens.Detail.MetaLabel.tracking)
                .foregroundStyle(.tertiary)

            FlowLayout(spacing: DesignTokens.Detail.Tag.gap) {
                ForEach(items, id: \.self) { item in
                    pill(item, icon: icon) { onRemove(item) }
                }

                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField(placeholder, text: text)
                        .textFieldStyle(.plain)
                        .font(DesignTokens.sansFont(
                            size: DesignTokens.Detail.Tag.fontSize,
                            weight: .medium
                        ))
                        .frame(width: 96)
                        .onSubmit(onAdd)

                    if !text.wrappedValue.isEmpty {
                        Button(action: onAdd) {
                            Image(systemName: "return")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignTokens.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Add")
                        .accessibilityLabel("Add")
                    }
                }
                .padding(.vertical, DesignTokens.Detail.Tag.paddingV)
                .padding(.horizontal, DesignTokens.Detail.Tag.paddingH)
                .overlay(
                    Capsule().strokeBorder(
                        Color.primary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                    )
                )
            }
        }
    }

    private func pill(_ label: String, icon: String?, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(label)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.Tag.fontSize,
                    weight: .semibold
                ))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
            .accessibilityLabel("Remove")
        }
        .padding(.vertical, DesignTokens.Detail.Tag.paddingV)
        .padding(.horizontal, DesignTokens.Detail.Tag.paddingH)
        .background(Color.primary.opacity(0.10), in: Capsule())
    }

    private func addShelf() {
        let trimmed = newShelfText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !book.shelfNames.contains(trimmed) else { return }
        library.updateShelves(for: book, shelves: book.shelfNames + [trimmed])
        newShelfText = ""
    }

    private func removeShelf(_ shelf: String) {
        library.updateShelves(for: book, shelves: book.shelfNames.filter { $0 != shelf })
    }

    // MARK: - Buttons

    private var canReadInApp: Bool {
        true
    }

    private var readButton: some View {
        Button {
            if canReadInApp {
                openWindow(id: "reader", value: book.contentHash)
            } else {
                NSWorkspace.shared.open(book.sourceURL)
            }
        } label: {
            Label(canReadInApp ? "Read" : "Open", systemImage: canReadInApp ? "book.fill" : "book")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.PrimaryButton.fontSize,
                    weight: .semibold
                ))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, DesignTokens.Detail.PrimaryButton.paddingV)
                .padding(.horizontal, DesignTokens.Detail.PrimaryButton.paddingH)
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Detail.PrimaryButton.cornerRadius))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(DesignTokens.sansFont(size: DesignTokens.Detail.SecondaryButton.fontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, DesignTokens.Detail.SecondaryButton.paddingV)
                .padding(.horizontal, 16)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Detail.SecondaryButton.cornerRadius)
                        .stroke(.separator, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var deleteButton: some View {
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
        .accessibilityLabel("Delete file\u{2026}")
    }

    /// One row when there's room; otherwise Read + delete on top and the
    /// secondary actions underneath (labels never wrap or shrink).
    private var buttonsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                readButton
                secondaryButton("Show in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
                }
                secondaryButton("Fix Metadata", icon: "pencil.and.list.clipboard") {
                    showMetadataLookup = true
                }
                ocrButton
                Spacer(minLength: 0)
                deleteButton
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    readButton
                    Spacer(minLength: 0)
                    deleteButton
                }
                HStack(spacing: DesignTokens.Spacing.sm) {
                    secondaryButton("Show in Finder", icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([book.sourceURL])
                    }
                    secondaryButton("Fix Metadata", icon: "pencil.and.list.clipboard") {
                        showMetadataLookup = true
                    }
                    ocrButton
                }
            }
        }
    }

    /// Offered for scanned PDFs: reads the page images and makes the book searchable.
    @ViewBuilder
    private var ocrButton: some View {
        if ocr.isRunning(book.contentHash) {
            secondaryButton("Making searchable\u{2026} \(Int((ocr.jobs[book.contentHash]?.progress ?? 0) * 100))%", icon: "text.viewfinder") {
                ocr.cancel(book.contentHash)
            }
        } else if isScannedPDF && Entitlements.isUnlocked(.ocr) {
            secondaryButton("Make Searchable", icon: "text.viewfinder") {
                ocr.start(book: book, library: library)
            }
        }
    }

    // MARK: - Metadata Grid (2x2)

    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxl) {
                metaItem(label: "Format", value: book.format.label)
                metaItem(
                    label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: book.sizeBytes, countStyle: .file)
                )
            }

            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxl) {
                metaItem(label: "Source", value: book.sourceURL.deletingLastPathComponent().lastPathComponent)
                metaItem(
                    label: "Added",
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
            Text("Progress")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaLabel.fontSize,
                    weight: .semibold
                ))
                .tracking(DesignTokens.Detail.MetaLabel.tracking)
                .foregroundStyle(.tertiary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.14))
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

// MARK: - FlowLayout

/// Left-to-right layout that wraps onto new lines, used for tag and shelf pills.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
