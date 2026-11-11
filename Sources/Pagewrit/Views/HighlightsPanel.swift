import SwiftUI
import SwiftData

/// The list of a book's highlights and notes, shared by every reader's
/// "Notes" drawer tab. It is format-agnostic: the reader supplies the
/// highlights, a label for where each one sits ("Page 12", "Chapter 3"),
/// and what to do when one is tapped.
struct HighlightsPanel: View {
    let highlights: [Highlight]
    let selectedID: PersistentIdentifier?
    let textColor: Color
    let tint: Color
    let accent: Color
    let locationLabel: (Highlight) -> String
    let onJump: (Highlight) -> Void
    /// Adds a note at the reader's current place, with no text selected.
    var onAddNote: (() -> Void)? = nil

    private var summary: String {
        let quotes = highlights.filter { !$0.text.isEmpty }.count
        let notes = highlights.filter { !$0.note.isEmpty }.count
        var parts: [String] = []
        if quotes > 0 { parts.append("\(quotes) \(quotes == 1 ? "highlight" : "highlights")") }
        if notes > 0 { parts.append("\(notes) \(notes == 1 ? "note" : "notes")") }
        return parts.isEmpty ? "Nothing yet" : parts.joined(separator: ", ")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(DesignTokens.sansFont(size: 12))
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if let onAddNote {
                Button(action: onAddNote) {
                    Label("New note", systemImage: "square.and.pencil")
                }
                .buttonStyle(.pw(.soft, size: .small))
                .help("Write a note at the place you are reading")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if highlights.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "highlighter")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(tint.opacity(0.7))
                    Text("Your highlights and notes live here")
                        .font(DesignTokens.sansFont(size: 13.5, weight: .medium))
                        .foregroundStyle(textColor)
                        .multilineTextAlignment(.center)
                    Text("Select some words in the book and choose a colour from the bar that appears. Or write a note about the page you are on.")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 26)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(highlights, id: \.persistentModelID) { highlight in
                                HighlightRow(
                                    highlight: highlight,
                                    isSelected: highlight.persistentModelID == selectedID,
                                    textColor: textColor, tint: tint, accent: accent,
                                    location: locationLabel(highlight),
                                    onJump: { onJump(highlight) }
                                )
                                .id(highlight.persistentModelID)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 14)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
}

/// One highlight or note: a stripe in its colour, the passage in the book's
/// own serif, your note beneath it, and where it sits in the book.
private struct HighlightRow: View {
    let highlight: Highlight
    let isSelected: Bool
    let textColor: Color
    let tint: Color
    let accent: Color
    let location: String
    let onJump: () -> Void

    @EnvironmentObject private var library: LibraryStore
    @State private var draft = ""
    @State private var editing = false
    @State private var expanded = false
    @State private var hovering = false
    @FocusState private var noteFocused: Bool

    private var isNoteOnly: Bool { highlight.text.isEmpty }
    private var stripe: Color { isNoteOnly ? accent : highlight.color.color }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(stripe)
                .frame(width: 3)
                .padding(.vertical, 12)
                .padding(.leading, 10)

            VStack(alignment: .leading, spacing: 9) {
                if isNoteOnly {
                    Label("Note", systemImage: "note.text")
                        .font(DesignTokens.sansFont(size: 11.5, weight: .medium))
                        .foregroundStyle(tint)
                } else {
                    Button(action: onJump) {
                        Text(highlight.text)
                            .font(DesignTokens.serifFont(size: 13.5, weight: .regular))
                            .foregroundStyle(textColor)
                            .lineSpacing(3)
                            .lineLimit(expanded ? nil : 4)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Go to this passage")
                    .accessibilityHint("Goes to this passage in the book")

                    if highlight.text.count > 220 {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                            .buttonStyle(.plain)
                            .font(DesignTokens.sansFont(size: 11.5, weight: .medium))
                            .foregroundStyle(accent)
                    }
                }

                if editing {
                    editor
                } else if !highlight.note.isEmpty {
                    Text(highlight.note)
                        .font(DesignTokens.sansFont(size: 12.5))
                        .foregroundStyle(textColor.opacity(0.9))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { startEditing() }
                        .help("Click to edit")
                }

                footer
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? accent.opacity(0.10) : tint.opacity(hovering ? 0.09 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? accent.opacity(0.45) : tint.opacity(0.10), lineWidth: isSelected ? 1 : 0.5)
        )
        .onHover { hovering = $0 }
        .onAppear {
            draft = highlight.note
            guard isNoteOnly && highlight.note.isEmpty else { return }
            if isSelected {
                // A brand new note opens ready to type.
                startEditing()
            } else {
                // A blank note left behind earlier: tidy it away.
                library.removeHighlight(highlight)
            }
        }
        // Closing the reader or switching tabs keeps what you typed.
        .onDisappear {
            guard editing else { return }
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != highlight.note {
                library.setHighlightNote(highlight, note: trimmed)
            }
        }
        .onChange(of: isSelected) { _, selected in
            if selected && highlight.note.isEmpty { startEditing() }
        }
        .accessibilityElement(children: .contain)
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField(isNoteOnly ? "Write your note" : "Add a note to this highlight", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DesignTokens.sansFont(size: 12.5))
                .foregroundStyle(textColor)
                .lineLimit(3...10)
                .focused($noteFocused)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(textColor.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(noteFocused ? accent.opacity(0.7) : tint.opacity(0.18),
                                      lineWidth: noteFocused ? 1.25 : 0.5)
                )
                .accessibilityLabel("Note")

            HStack(spacing: 6) {
                Text("\u{2318}\u{21A9} to save")
                    .font(DesignTokens.sansFont(size: 11))
                    .foregroundStyle(tint.opacity(0.8))
                Spacer()
                Button("Cancel") { cancel() }
                    .buttonStyle(.pw(.ghost, size: .small))
                Button("Save") { save() }
                    .buttonStyle(.pw(.primary, size: .small))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(location)
                .lineLimit(1)
            Text("\u{00B7}")
            Text(highlight.createdAt, format: .relative(presentation: .named))
                .lineLimit(1)
            Spacer(minLength: 6)

            if !editing && highlight.note.isEmpty && !isNoteOnly {
                Button { startEditing() } label: {
                    Label("Note", systemImage: "plus")
                }
                .buttonStyle(.pw(.ghost, size: .small))
                .help("Add a note to this highlight")
            }

            if !isNoteOnly {
                Menu {
                    ForEach(HighlightColor.allCases) { color in
                        Button {
                            library.setHighlightColor(highlight, color: color)
                        } label: {
                            Label { Text(color.label) } icon: { Image(nsImage: color.dotImage) }
                        }
                    }
                } label: {
                    Image(nsImage: highlight.color.dotImage)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Change colour")
                .accessibilityLabel("Colour, \(highlight.color.label)")
            }

            Button {
                editing = false
                library.removeHighlight(highlight)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0.55)
            .help(isNoteOnly ? "Delete note" : "Delete highlight")
            .accessibilityLabel(isNoteOnly ? "Delete note" : "Delete highlight")
        }
        .font(DesignTokens.sansFont(size: 11))
        .foregroundStyle(tint)
    }

    private func startEditing() {
        draft = highlight.note
        editing = true
        // Focus once the field exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { noteFocused = true }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if isNoteOnly && trimmed.isEmpty {
            // An empty note is not worth keeping.
            editing = false
            library.removeHighlight(highlight)
            return
        }
        if trimmed != highlight.note {
            library.setHighlightNote(highlight, note: trimmed)
        }
        editing = false
        noteFocused = false
    }

    private func cancel() {
        if isNoteOnly && highlight.note.isEmpty {
            editing = false
            library.removeHighlight(highlight)
            return
        }
        draft = highlight.note
        editing = false
        noteFocused = false
    }
}


// MARK: - Bookmarks

/// A book's bookmarks, for readers that keep them in a side drawer.
struct BookmarksPanel: View {
    let bookmarks: [Bookmark]
    let textColor: Color
    let tint: Color
    let accent: Color
    let locationLabel: (Bookmark) -> String
    let onJump: (Bookmark) -> Void
    let onRemove: (Bookmark) -> Void
    let onAdd: () -> Void
    let isCurrentBookmarked: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onAdd) {
                Label(isCurrentBookmarked ? "Remove bookmark here" : "Bookmark here",
                      systemImage: isCurrentBookmarked ? "bookmark.slash" : "bookmark")
            }
            .buttonStyle(.pw(.soft, size: .small, fullWidth: true))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if bookmarks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bookmark")
                        .font(.system(size: 26))
                        .foregroundStyle(tint.opacity(0.6))
                    Text("No bookmarks yet")
                        .font(DesignTokens.sansFont(size: 13, weight: .medium))
                        .foregroundStyle(textColor)
                    Text("Bookmark a place to come back to it later.")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(bookmarks, id: \.persistentModelID) { bookmark in
                            HStack(spacing: 8) {
                                Button { onJump(bookmark) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(bookmark.label)
                                            .font(DesignTokens.sansFont(size: 13, weight: .medium))
                                            .foregroundStyle(textColor)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Text(locationLabel(bookmark))
                                            .font(DesignTokens.sansFont(size: 11.5))
                                            .foregroundStyle(tint)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button { onRemove(bookmark) } label: {
                                    Image(systemName: "trash").font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(tint)
                                .help("Remove bookmark")
                                .accessibilityLabel("Remove bookmark")
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

// MARK: - Where a highlight sits

/// "Page 12", "Chapter 3" or "40% through the document", depending on the format.
func highlightLocationLabel(_ highlight: Highlight, book: Book) -> String {
    switch book.format {
    case .pdf:
        return "Page \(highlight.pageIndex + 1)"
    case .epub, .kindle:
        return "Chapter \(highlight.pageIndex + 1)"
    default:
        return "\(Int((highlight.position * 100).rounded()))% through the document"
    }
}

// MARK: - Highlights across the whole library

/// Every highlight and note, grouped by book. Choosing one opens the book
/// right at that passage: the right chapter or page, with the text selected.
struct HighlightsBrowser: View {
    let searchText: String

    @EnvironmentObject private var library: LibraryStore

    private struct BookGroup: Identifiable {
        let book: Book
        let items: [Highlight]
        var id: String { book.contentHash }
    }

    private var groups: [BookGroup] {
        let terms = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let byHash = Dictionary(library.books.map { ($0.contentHash, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: library.highlights, by: \.bookHash)
        var result: [BookGroup] = []
        for (hash, items) in grouped {
            guard let book = byHash[hash] else { continue }
            let title = book.title.lowercased()
            let matching = items.filter { item in
                terms.allSatisfy { term in
                    item.text.lowercased().contains(term)
                        || item.note.lowercased().contains(term)
                        || title.contains(term)
                }
            }
            guard !matching.isEmpty else { continue }
            let ordered = matching.sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
                return $0.rangeStart < $1.rangeStart
            }
            result.append(BookGroup(book: book, items: ordered))
        }
        return result.sorted {
            ($0.items.map(\.createdAt).max() ?? .distantPast) > ($1.items.map(\.createdAt).max() ?? .distantPast)
        }
    }

    var body: some View {
        let groups = self.groups
        let total = groups.reduce(0) { $0 + $1.items.count }

        return Group {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 46) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Highlights")
                                .font(DesignTokens.serifFont(size: 34, weight: .bold))
                                .tracking(-0.9)
                            Text("\(total) highlight\(total == 1 ? "" : "s") in \(groups.count) book\(groups.count == 1 ? "" : "s"). Choose one to open the book at that exact passage.")
                                .font(DesignTokens.sansFont(size: 13.5))
                                .foregroundStyle(.secondary)
                        }

                        ForEach(groups) { group in
                            BookSection(book: group.book, items: group.items)
                        }
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.top, 30)
                    .padding(.bottom, DesignTokens.Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(DesignTokens.background.ignoresSafeArea())
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "highlighter")
                .font(.system(size: 42))
                .foregroundStyle(DesignTokens.accent)
            Text(searchText.isEmpty ? "No highlights yet." : "No highlights match your search.")
                .font(DesignTokens.serifFont(size: 26, weight: .bold))
                .tracking(-0.5)
            Text("Select text in any book and choose Highlight. It collects here.")
                .font(DesignTokens.sansFont(size: 13.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private struct BookSection: View {
        let book: Book
        let items: [Highlight]

        var body: some View {
            HStack(alignment: .top, spacing: 24) {
                MattedCoverView(book: book, cornerRadius: 6, showBadge: false)
                    .frame(width: 76)
                    .coverShadow()

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(book.title)
                            .font(DesignTokens.serifFont(size: 21, weight: .bold))
                            .tracking(-0.3)
                            .lineLimit(2)
                        Text([book.displayAuthor, "\(items.count) highlight\(items.count == 1 ? "" : "s")"]
                            .compactMap { $0 }
                            .filter { !$0.isEmpty }
                            .joined(separator: ", "))
                            .font(DesignTokens.sansFont(size: 12.5))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.persistentModelID) { item in
                            QuoteRow(book: book, highlight: item)
                        }
                    }
                }
            }
        }
    }

    private struct QuoteRow: View {
        let book: Book
        let highlight: Highlight

        @EnvironmentObject private var library: LibraryStore
        @Environment(\.openWindow) private var openWindow
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovered = false

        private var marked: AttributedString {
            var text = AttributedString(highlight.text)
            text.backgroundColor = highlight.color.color.opacity(colorScheme == .dark ? 0.32 : 0.55)
            return text
        }

        var body: some View {
            Button {
                Haptics.tick()
                library.requestJump(to: highlight)
                openWindow(id: "reader", value: highlight.bookHash)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    if !highlight.text.isEmpty {
                        Text(marked)
                            .font(DesignTokens.serifFont(size: 16, weight: .regular))
                            .lineSpacing(4)
                            .lineLimit(7)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                    }

                    if !highlight.note.isEmpty {
                        Text(highlight.note)
                            .font(DesignTokens.sansFont(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 6) {
                        Text(highlightLocationLabel(highlight, book: book))
                            .font(DesignTokens.sansFont(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text("Open at this passage")
                            .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                            .foregroundStyle(DesignTokens.accentInk)
                            .opacity(hovered ? 1 : 0)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .contextMenu {
                Button("Copy quote") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(highlight.text, forType: .string)
                }
            }
        }
    }
}


// MARK: - Bookmarks across the whole library

/// Every bookmark, grouped by book. Choosing one opens the book there.
struct BookmarksBrowser: View {
    let searchText: String

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow

    private struct BookGroup: Identifiable {
        let book: Book
        let items: [Bookmark]
        var id: String { book.contentHash }
    }

    private var groups: [BookGroup] {
        let terms = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let byHash = Dictionary(library.books.map { ($0.contentHash, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: library.bookmarks, by: \.bookHash)
        var result: [BookGroup] = []
        for (hash, items) in grouped {
            guard let book = byHash[hash] else { continue }
            let title = book.title.lowercased()
            let matching = items.filter { item in
                terms.allSatisfy { title.contains($0) || item.label.lowercased().contains($0) }
            }
            guard !matching.isEmpty else { continue }
            result.append(BookGroup(book: book, items: matching.sorted { $0.position < $1.position }))
        }
        return result.sorted {
            ($0.items.map(\.createdAt).max() ?? .distantPast) > ($1.items.map(\.createdAt).max() ?? .distantPast)
        }
    }

    var body: some View {
        let groups = self.groups
        let total = groups.reduce(0) { $0 + $1.items.count }
        return Group {
            if groups.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 42))
                        .foregroundStyle(DesignTokens.accent)
                    Text(searchText.isEmpty ? "No bookmarks yet." : "No bookmarks match your search.")
                        .font(DesignTokens.serifFont(size: 26, weight: .bold))
                        .tracking(-0.5)
                    Text("Tap Bookmark while you read to save a place. It collects here.")
                        .font(DesignTokens.sansFont(size: 13.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Bookmarks")
                                .font(DesignTokens.serifFont(size: 34, weight: .bold))
                                .tracking(-0.9)
                            Text("\(total) saved place\(total == 1 ? "" : "s") in \(groups.count) book\(groups.count == 1 ? "" : "s"). Choose one to open the book there.")
                                .font(DesignTokens.sansFont(size: 13.5))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(groups) { group in
                            HStack(alignment: .top, spacing: 24) {
                                MattedCoverView(book: group.book, cornerRadius: 6, showBadge: false)
                                    .frame(width: 76)
                                    .coverShadow()
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(group.book.title)
                                        .font(DesignTokens.serifFont(size: 21, weight: .bold))
                                        .tracking(-0.3)
                                        .lineLimit(2)
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(group.items, id: \.persistentModelID) { item in
                                            row(item, book: group.book)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 780, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.top, 30)
                    .padding(.bottom, DesignTokens.Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(DesignTokens.background.ignoresSafeArea())
    }

    private func row(_ item: Bookmark, book: Book) -> some View {
        HStack(spacing: 10) {
            Button {
                Haptics.tick()
                library.updateProgress(for: book, progress: item.position)
                openWindow(id: "reader", value: book.contentHash)
            } label: {
                HStack {
                    Text(item.label)
                        .font(DesignTokens.sansFont(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int((item.position * 100).rounded()))% through")
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { library.removeBookmark(item) } label: { Image(systemName: "trash") }
                .buttonStyle(.pw(.ghost, size: .small))
                .help("Remove bookmark")
        }
    }
}
