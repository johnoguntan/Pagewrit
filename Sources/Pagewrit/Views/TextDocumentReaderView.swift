import SwiftUI
import AppKit
import SwiftData

// MARK: - AppKit text view

/// Centers the text in a comfortable reading column however wide the window is.
private final class ColumnTextView: NSTextView {
    var measure: CGFloat = 700 {
        didSet { if oldValue != measure { updateInset(for: frame.width) } }
    }

    /// Called with the character index when the reader plainly clicks
    /// (no drag-selection) so a tapped highlight can open its note.
    var onPlainClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard index != NSNotFound else { return }
        onPlainClick?(index)
    }

    override func setFrameSize(_ newSize: NSSize) {
        updateInset(for: newSize.width)
        super.setFrameSize(newSize)
    }

    private func updateInset(for width: CGFloat) {
        let horizontal = max(28, (width - measure) / 2)
        let inset = NSSize(width: horizontal, height: 48)
        if textContainerInset != inset { textContainerInset = inset }
    }
}

/// Lets SwiftUI ask the underlying text view where the reader is.
final class ReaderTextHandle {
    fileprivate weak var textView: ColumnTextView?
    fileprivate weak var scrollView: NSScrollView?

    /// Character index at the top of the visible area (where read-aloud starts).
    func topCharacterIndex() -> Int {
        guard let tv = textView, let sv = scrollView else { return 0 }
        let point = NSPoint(x: tv.textContainerInset.width + 2, y: sv.contentView.bounds.minY + 24)
        return min(tv.characterIndexForInsertion(at: point), max(0, tv.string.utf16.count - 1))
    }

    /// Start of the selection if there is one, otherwise the top of the page.
    func startIndexForSpeech() -> Int {
        if let tv = textView, tv.selectedRange().length > 0 { return tv.selectedRange().location }
        return topCharacterIndex()
    }
}

private struct ColumnTextReader: NSViewRepresentable {
    let text: NSAttributedString
    let revision: Int
    let background: NSColor
    let measure: CGFloat
    let initialFraction: Double
    let highlight: NSRange?
    let handle: ReaderTextHandle
    let highlights: [Highlight]
    @Binding var request: TextHighlightRequest?
    let focus: TextFocusRequest?
    let onSelectionChange: (Bool) -> Void
    let onCreateHighlight: (NSRange, String, HighlightColor, Bool) -> Void
    let onTapHighlight: (PersistentIdentifier) -> Void
    let onScroll: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true

        let tv = ColumnTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticLinkDetectionEnabled = true
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        scroll.documentView = tv

        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observe(scroll: scroll, textView: tv, onScroll: onScroll)
        context.coordinator.observeSelection(of: tv)
        tv.onPlainClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleClick(at: index)
        }

        handle.textView = tv
        handle.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ColumnTextView else { return }
        let c = context.coordinator
        c.onScroll = onScroll
        c.onSelectionChange = onSelectionChange
        c.onTapHighlight = onTapHighlight
        tv.measure = measure
        tv.backgroundColor = background
        scroll.backgroundColor = background

        if context.coordinator.appliedRevision != revision {
            let keepFraction = context.coordinator.hasLoaded ? context.coordinator.lastFraction : initialFraction
            context.coordinator.appliedRevision = revision
            context.coordinator.suppressScroll = true
            tv.textStorage?.setAttributedString(text)
            DispatchQueue.main.async {
                context.coordinator.restore(fraction: keepFraction, in: scroll)
                context.coordinator.hasLoaded = true
                context.coordinator.suppressScroll = false
            }
        }

        c.syncHighlights(highlights, in: tv, revision: revision)

        if let focus, focus.id != c.lastFocusID {
            c.lastFocusID = focus.id
            if NSMaxRange(focus.range) <= (tv.string as NSString).length {
                tv.setSelectedRange(focus.range)
                tv.scrollRangeToVisible(focus.range)
                tv.showFindIndicator(for: focus.range)
            }
        }

        if let req = request, req.id != c.lastRequestID {
            c.lastRequestID = req.id
            let range = tv.selectedRange()
            let ns = tv.string as NSString
            if range.length > 0, NSMaxRange(range) <= ns.length {
                let quoted = ns.substring(with: range)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                if !quoted.isEmpty {
                    DispatchQueue.main.async { onCreateHighlight(range, quoted, req.color, req.wantsNote) }
                }
                tv.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            }
            DispatchQueue.main.async { request = nil }
        }

        if let range = highlight, range != context.coordinator.lastHighlight,
           NSMaxRange(range) <= (tv.string as NSString).length {
            context.coordinator.lastHighlight = range
            tv.setSelectedRange(range)
            tv.scrollRangeToVisible(range)
        } else if highlight == nil {
            context.coordinator.lastHighlight = nil
        }
    }

    final class Coordinator {
        var appliedRevision = -1
        var hasLoaded = false
        var suppressScroll = false
        var lastFraction: Double = 0
        var lastHighlight: NSRange?
        var onScroll: ((Double) -> Void)?
        var onSelectionChange: ((Bool) -> Void)?
        var onTapHighlight: ((PersistentIdentifier) -> Void)?
        var lastRequestID: UUID?
        var lastFocusID: UUID?
        private var token: NSObjectProtocol?
        private var selectionToken: NSObjectProtocol?

        // Saved highlights currently painted on the text.
        private var paintedSignature = ""
        private var painted: [(range: NSRange, id: PersistentIdentifier)] = []

        func observeSelection(of tv: NSTextView) {
            selectionToken = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: tv, queue: .main
            ) { [weak self, weak tv] _ in
                guard let self, let tv else { return }
                let has = tv.selectedRange().length > 0
                DispatchQueue.main.async { self.onSelectionChange?(has) }
            }
        }

        func handleClick(at index: Int) {
            guard let hit = painted.first(where: { NSLocationInRange(index, $0.range) }) else { return }
            onTapHighlight?(hit.id)
        }

        /// Paints highlights with temporary attributes, so the document text
        /// itself is never altered and re-rendering can't lose them.
        func syncHighlights(_ highlights: [Highlight], in tv: NSTextView, revision: Int) {
            guard let lm = tv.layoutManager else { return }
            let signature = "\(revision)|" + highlights.map {
                "\($0.persistentModelID.hashValue):\($0.rangeStart):\($0.rangeLength):\($0.colorRaw)"
            }.joined(separator: ",")
            guard signature != paintedSignature else { return }
            paintedSignature = signature

            let length = (tv.string as NSString).length
            for item in painted where NSMaxRange(item.range) <= length {
                lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: item.range)
            }
            painted = []
            for h in highlights {
                let range = NSRange(location: h.rangeStart, length: h.rangeLength)
                guard range.length > 0, NSMaxRange(range) <= length else { continue }
                lm.addTemporaryAttribute(
                    .backgroundColor,
                    value: h.color.nsColor.withAlphaComponent(0.55),
                    forCharacterRange: range
                )
                painted.append((range, h.persistentModelID))
            }
        }

        func observe(scroll: NSScrollView, textView: NSTextView, onScroll: @escaping (Double) -> Void) {
            self.onScroll = onScroll
            token = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self, weak scroll] _ in
                guard let self, let scroll, !self.suppressScroll else { return }
                let fraction = Self.fraction(of: scroll)
                self.lastFraction = fraction
                self.onScroll?(fraction)
            }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
            if let selectionToken { NotificationCenter.default.removeObserver(selectionToken) }
        }

        static func fraction(of scroll: NSScrollView) -> Double {
            guard let doc = scroll.documentView else { return 0 }
            let range = doc.frame.height - scroll.contentView.bounds.height
            guard range > 1 else { return 0 }
            return min(max(Double(scroll.contentView.bounds.minY / range), 0), 1)
        }

        func restore(fraction: Double, in scroll: NSScrollView) {
            guard let doc = scroll.documentView else { return }
            let range = max(0, doc.frame.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: range * fraction))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// MARK: - TextDocumentReaderView

/// Reader for Word documents, RTF, plain text and Markdown. Uses the same
/// themes as the other readers, with typeface, size and line-height controls,
/// find (⌘F), read-aloud with the spoken word highlighted, and saved progress.
struct TextDocumentReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    /// Pagewrit's own light or dark look, read straight from the app rather
    /// than this window, which the reader theme may have forced. "Auto"
    /// follows this, and it updates the instant the app look changes.
    @ObservedObject private var appearanceWatcher = AppearanceWatcher.shared
    private var colorScheme: ColorScheme { appearanceWatcher.scheme }
    @Environment(\.dismissWindow) private var dismissWindow
    @StateObject private var speech = SpeechController()

    @State private var loaded: TextDocumentLoader.Loaded?
    @State private var loadFailed = false
    @State private var rendered = NSAttributedString()
    @State private var revision = 0
    @State private var progress: Double = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var spokenRange: NSRange?
    @State private var handle = ReaderTextHandle()

    // Highlights & notes
    @State private var hasSelection = false
    @State private var highlightRequest: TextHighlightRequest?
    @State private var focusRequest: TextFocusRequest?
    @State private var showNotes = false
    @State private var showDisplay = false

    private static let defaultSize: Double = 17
    private static let defaultLineHeight: Double = 1.5
    private static let sizeRange: ClosedRange<Double> = 12...34

    private var readerTheme: ReaderTheme { ReaderTheme(rawValue: readerThemeRaw) ?? .system }

    private var isDefault: Bool {
        fontSize == Self.defaultSize && lineHeight == Self.defaultLineHeight
            && faceRaw == ReaderTextStyle.Face.serif.rawValue && readerTheme == .system
    }

    private func resetDisplay() {
        fontSize = Self.defaultSize
        lineHeight = Self.defaultLineHeight
        faceRaw = ReaderTextStyle.Face.serif.rawValue
        readerThemeRaw = ReaderTheme.system.rawValue
    }

    // MARK: Display panel

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Text size").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int(fontSize)) pt")
                        .font(DesignTokens.sansFont(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Button("Reset") { fontSize = Self.defaultSize }
                        .buttonStyle(.plain)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(accent)
                        .disabled(fontSize == Self.defaultSize)
                }
                HStack(spacing: 10) {
                    Text("A").font(.system(size: 12, design: .serif)).foregroundStyle(tint)
                        .accessibilityHidden(true)
                    Slider(value: $fontSize, in: Self.sizeRange, step: 1)
                        .tint(accent)
                        .accessibilityLabel("Text size")
                        .accessibilityValue("\(Int(fontSize)) points")
                    Text("A").font(.system(size: 22, design: .serif)).foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Theme").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                HStack(spacing: 14) {
                    ForEach(ReaderTheme.allCases) { theme in
                        ThemeSwatch(
                            theme: theme,
                            isSelected: theme == readerTheme,
                            systemScheme: colorScheme,
                            accent: accent,
                            label: textColor
                        ) { readerThemeRaw = theme.rawValue }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Typeface").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Typeface", selection: $faceRaw) {
                    ForEach(ReaderTextStyle.Face.allCases) { face in
                        Text(face.label).tag(face.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Line spacing").font(DesignTokens.sansFont(size: 12, weight: .semibold))
                Picker("Line spacing", selection: $lineHeight) {
                    Text("Compact").tag(1.25)
                    Text("Normal").tag(1.5)
                    Text("Relaxed").tag(1.8)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider().overlay(rule)

            Button(action: resetDisplay) {
                Label("Reset all to defaults", systemImage: "arrow.counterclockwise")
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(isDefault ? tint.opacity(0.6) : accent)
            }
            .buttonStyle(.plain)
            .disabled(isDefault)
            .help("Size 17, Normal spacing, Serif and the Auto theme")
        }
        .foregroundStyle(textColor)
        .padding(18)
        .frame(width: 320)
        .background(chrome)
    }
    @State private var selectedHighlightID: PersistentIdentifier?
    @State private var drawerTab: DrawerTab = .notes

    private enum DrawerTab: String, CaseIterable { case notes = "Notes", bookmarks = "Bookmarks" }

    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("pagewrit.text.face") private var faceRaw: String = ReaderTextStyle.Face.serif.rawValue
    @AppStorage("pagewrit.text.size") private var fontSize: Double = 17
    @AppStorage("pagewrit.text.lineHeight") private var lineHeight: Double = 1.5

    private var palette: ReaderPalette {
        (ReaderTheme(rawValue: readerThemeRaw) ?? .system).palette(for: colorScheme)
    }

    private var style: ReaderTextStyle {
        ReaderTextStyle(
            face: ReaderTextStyle.Face(rawValue: faceRaw) ?? .serif,
            size: CGFloat(fontSize),
            lineHeight: CGFloat(lineHeight),
            textColor: palette.text,
            secondaryColor: palette.secondary,
            linkColor: palette.link
        )
    }

    private var chrome: Color { Color(nsColor: palette.chrome) }
    private var textColor: Color { Color(nsColor: palette.text) }
    private var tint: Color { Color(nsColor: palette.secondary) }
    private var rule: Color { Color(nsColor: palette.rule) }
    private var accent: Color { Color(nsColor: palette.link) }

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbarFit { header }
            Rectangle().fill(rule).frame(height: 1)
            HStack(spacing: 0) {
                content
                    .overlay(alignment: .bottom) {
                        SelectionHighlightBar(
                            visible: hasSelection,
                            tint: tint, accent: accent, pageColor: Color(nsColor: palette.background)
                        ) { color, note in highlightRequest = TextHighlightRequest(color: color, wantsNote: note) }
                            .padding(.bottom, 18)
                    }
                if showNotes {
                    Rectangle().fill(rule).frame(width: 1)
                    notesDrawer
                }
            }
            Rectangle().fill(rule).frame(height: 1)
            footer
        }
        .frame(minWidth: 600, minHeight: 480)
        .background(ReaderWindowAppearance(theme: ReaderTheme(rawValue: readerThemeRaw) ?? .system))
        // Native controls (tab pickers, switches) follow the reader theme, not the Mac.
        .environment(\.colorScheme, (ReaderTheme(rawValue: readerThemeRaw) ?? .system).controlScheme(system: colorScheme))
        .background(Color(nsColor: palette.background).ignoresSafeArea())
        .onAppear {
            // Documents are usually work, not reading: no clock, and their
            // time does not count toward the daily goal.
            library.markOpened(book, countsTime: false)
            progress = book.readingProgress ?? 0
            load()
        }
        .onDisappear { speech.stop(); library.commitReading(countsTime: false) }
        .onAppear {
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { checkExternalJump() }
            }
        }
        .onChange(of: library.jumpRequest) { _, _ in checkExternalJump() }
        .onChange(of: faceRaw) { _, _ in restyle() }
        .onChange(of: fontSize) { _, _ in restyle() }
        .onChange(of: lineHeight) { _, _ in restyle() }
        .onChange(of: readerThemeRaw) { _, _ in restyle() }
        .onChange(of: colorScheme) { _, _ in restyle() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loadFailed {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(tint)
                Text("Couldn't open this document.")
                    .font(DesignTokens.sansFont(size: 14)).foregroundStyle(tint)
                Button("Open in Default App") { NSWorkspace.shared.open(book.sourceURL) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loaded == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ColumnTextReader(
                text: rendered,
                revision: revision,
                background: palette.background,
                measure: CGFloat(fontSize) * 40,
                initialFraction: book.readingProgress ?? 0,
                highlight: spokenRange,
                handle: handle,
                highlights: library.highlights(for: book).filter { $0.rangeLength > 0 },
                request: $highlightRequest,
                focus: focusRequest,
                onSelectionChange: { hasSelection = $0 },
                onCreateHighlight: { range, quoted, color, wantsNote in
                    createHighlight(range: range, text: quoted, color: color, wantsNote: wantsNote)
                },
                onTapHighlight: { id in
                    selectedHighlightID = id
                    showNotes = true
                },
                onScroll: { fraction in
                    progress = fraction
                    scheduleSave(fraction)
                }
            )
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(book.title)
                .font(DesignTokens.sansFont(size: 13, weight: .semibold))
                .foregroundStyle(textColor)
                .lineLimit(1)
            Spacer()

            Button { showDisplay.toggle() } label: {
                Label("Display", systemImage: "textformat.size")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(showDisplay ? accent : textColor)
            }
            .help("Text size, theme, typeface and spacing")
            .popover(isPresented: $showDisplay, arrowEdge: .bottom) {
                displayPanel
                    .background(ReaderWindowAppearance(theme: readerTheme))
                    .readerControls(readerTheme, system: colorScheme)
            }
            // Keyboard text size, without visible buttons.
            .background {
                Group {
                    Button("") { fontSize = max(Self.sizeRange.lowerBound, fontSize - 1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button("") { fontSize = min(Self.sizeRange.upperBound, fontSize + 1) }
                        .keyboardShortcut("=", modifiers: .command)
                    Button("") { fontSize = Self.defaultSize }
                        .keyboardShortcut("0", modifiers: .command)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }

            highlightMenu

            Button { toggleBookmark() } label: {
                Label("Bookmark", systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(isBookmarked ? accent : textColor)
            }
            .help(isBookmarked ? "Remove this bookmark" : "Bookmark where you are")
            .keyboardShortcut("d", modifiers: .command)

            Button {
                if showNotes && drawerTab == .notes { showNotes = false } else { drawerTab = .notes; showNotes = true }
            } label: {
                let count = library.highlightCount(forHash: book.contentHash)
                Label(count > 0 ? "Notes (\(count))" : "Notes", systemImage: "note.text")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(showNotes && drawerTab == .notes ? accent : textColor)
            }
            .help("Highlights and notes")

            Button(action: toggleSpeech) {
                Label(speech.isSpeaking ? (speech.isPaused ? "Resume" : "Pause") : "Listen",
                      systemImage: speech.isSpeaking ? (speech.isPaused ? "play.fill" : "pause.fill") : "speaker.wave.2")
                    .labelStyle(.titleAndIcon)
            }
            .help(speech.isSpeaking ? "Pause or resume read-aloud" : "Read aloud")

            if speech.isSpeaking {
                Button { speech.stop() } label: { Image(systemName: "stop.fill") }.help("Stop reading")
            }


            ReaderCloseButton(help: "Close this document (\u{2318}W)", tint: tint, rule: rule) { dismissWindow() }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(textColor)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: 48)
        .background(chrome)
    }

    private var footer: some View {
        HStack {
            ProgressView(value: min(max(progress, 0), 1))
                .progressViewStyle(.linear)
                .tint(Color(nsColor: palette.link))
            Text("\(Int((progress * 100).rounded()))%")
                .font(DesignTokens.sansFont(size: 11))
                .foregroundStyle(tint)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: 30)
        .background(chrome)
    }

    // MARK: Highlights & notes

    private var highlightMenu: some View {
        Menu {
            ForEach(HighlightColor.allCases) { color in
                Button {
                    highlightRequest = TextHighlightRequest(color: color, wantsNote: false)
                } label: {
                    Label {
                        Text(color.label)
                    } icon: {
                        Image(nsImage: color.dotImage)
                    }
                }
            }
            Divider()
            Button {
                highlightRequest = TextHighlightRequest(color: .yellow, wantsNote: true)
            } label: {
                Label("Highlight and add note", systemImage: "square.and.pencil")
            }
        } label: {
            Label("Highlight", systemImage: "highlighter").labelStyle(.titleAndIcon)
                .foregroundStyle(hasSelection ? accent : textColor.opacity(0.55))
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(loaded == nil || !hasSelection)
        .help(hasSelection ? "Highlight the selected text" : "Select some text first, then highlight it")
    }

    private var notesDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(DrawerTab.allCases, id: \.self) { tab in
                    Button { drawerTab = tab } label: {
                        Text(tab.rawValue)
                            .font(DesignTokens.sansFont(size: 12.5, weight: .semibold))
                            .foregroundStyle(drawerTab == tab ? accent : tint)
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(Capsule().fill(drawerTab == tab ? accent.opacity(0.16) : Color.clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { showNotes = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(tint)
                    .help("Hide this panel")
                    .accessibilityLabel("Hide this panel")
            }
            .padding(12)

            if drawerTab == .notes {
                HighlightsPanel(
                    highlights: library.highlights(for: book),
                    selectedID: selectedHighlightID,
                    textColor: textColor, tint: tint, accent: accent,
                    locationLabel: { highlight in
                        let total = max(1, rendered.length)
                        return "\(Int((Double(highlight.rangeStart) / Double(total) * 100).rounded()))% through"
                    },
                    onJump: { highlight in jump(to: highlight) },
                    onAddNote: { addNoteHere() }
                )
            } else {
                BookmarksPanel(
                    bookmarks: library.bookmarks(for: book),
                    textColor: textColor, tint: tint, accent: accent,
                    locationLabel: { "\(Int(($0.position * 100).rounded()))% through" },
                    onJump: { jump(toBookmark: $0) },
                    onRemove: { library.removeBookmark($0) },
                    onAdd: { toggleBookmark() },
                    isCurrentBookmarked: isBookmarked
                )
            }
        }
        .frame(width: 320)
        .background(chrome)
    }

    private func jump(to highlight: Highlight) {
        selectedHighlightID = highlight.persistentModelID
        focusRequest = TextFocusRequest(
            range: NSRange(location: highlight.rangeStart, length: max(1, highlight.rangeLength))
        )
    }

    // MARK: Notes and bookmarks at the current place

    private func addNoteHere() {
        let total = max(1, rendered.length)
        let start = min(total - 1, Int(progress * Double(total)))
        let created = library.addHighlight(
            bookHash: book.contentHash,
            pageIndex: 0,
            rangeStart: start, rangeLength: 0,
            position: progress,
            text: ""
        )
        selectedHighlightID = created.persistentModelID
    }

    private var currentBookmark: Bookmark? {
        library.bookmarks(for: book).first { abs($0.position - progress) < 0.01 }
    }

    private var isBookmarked: Bool { currentBookmark != nil }

    private func toggleBookmark() {
        if let existing = currentBookmark {
            library.removeBookmark(existing)
        } else {
            let pct = Int((progress * 100).rounded())
            library.addBookmark(for: book, position: progress, label: "\(pct)% through the document")
        }
        drawerTab = .bookmarks
        showNotes = true
    }

    private func jump(toBookmark bookmark: Bookmark) {
        let total = max(1, rendered.length)
        let start = min(total - 1, Int(bookmark.position * Double(total)))
        focusRequest = TextFocusRequest(range: NSRange(location: start, length: 1))
    }

    /// A highlight chosen in the library: open at that exact passage.
    private func checkExternalJump() {
        guard rendered.length > 0, let highlight = library.consumeJump(for: book.contentHash) else { return }
        jump(to: highlight)
    }

    private func createHighlight(range: NSRange, text: String, color: HighlightColor, wantsNote: Bool) {
        let total = max(1, rendered.length)
        let created = library.addHighlight(
            bookHash: book.contentHash,
            pageIndex: 0,
            rangeStart: range.location,
            rangeLength: range.length,
            position: Double(range.location) / Double(total),
            text: text,
            color: color
        )
        if wantsNote {
            selectedHighlightID = created.persistentModelID
            showNotes = true
        }
    }

    // MARK: Loading and styling

    private func load() {
        guard loaded == nil else { return }
        let url = book.sourceURL
        let format = book.format
        Task.detached(priority: .userInitiated) {
            let result = TextDocumentLoader.load(url: url, format: format)
            await MainActor.run {
                if let result {
                    loaded = result
                    restyle()
                } else {
                    loadFailed = true
                }
            }
        }
    }

    private func restyle() {
        guard let loaded else { return }
        if let rich = loaded.rich {
            rendered = RichDocumentStyler.restyle(rich, style: style)
        } else if let raw = loaded.rawText {
            rendered = loaded.isMarkdown
                ? MarkdownRenderer.render(raw, style: style)
                : plainText(raw)
        }
        revision += 1
        // Character offsets change when the text is re-rendered.
        spokenRange = nil
    }

    private func plainText(_ raw: String) -> NSAttributedString {
        let s = style
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        return NSAttributedString(string: text, attributes: [
            .font: s.font(),
            .foregroundColor: s.textColor,
            .paragraphStyle: s.paragraphStyle(spacingScale: 0.5)
        ])
    }

    // MARK: Progress

    private func scheduleSave(_ fraction: Double) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            library.updateProgress(for: book, progress: fraction)
        }
    }

    // MARK: Read aloud

    private func toggleSpeech() {
        if speech.isSpeaking {
            speech.togglePause()
            return
        }
        let text = rendered.string
        speech.onProgress = { location, length in
            spokenRange = NSRange(location: location, length: length)
        }
        speech.onFinish = { spokenRange = nil }
        speech.speak(text, from: handle.startIndexForSpeech())
    }
}


// MARK: - Highlight plumbing

struct TextHighlightRequest: Equatable {
    let id = UUID()
    let color: HighlightColor
    let wantsNote: Bool
}

/// Asks the text view to select and scroll to a saved highlight's range.
struct TextFocusRequest: Equatable {
    let id = UUID()
    let range: NSRange
}
