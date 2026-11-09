import SwiftUI
import Quartz
import UniformTypeIdentifiers

// MARK: - Quick Look host (full-fidelity fallback)

/// macOS's own Office previewer. It draws everything exactly as Office does
/// (charts, SmartArt, fonts), but cannot jump to a slide or give thumbnails,
/// so it backs the "Preview" mode and decks Pagewrit can't parse.
private struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL)?.absoluteURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Void) {
        // QLPreviewView.close() aborts the app if the view is torn down before
        // Quick Look finished starting it (which happens when a reader opens
        // and closes quickly). Releasing the item is the safe cleanup.
        view.previewItem = nil
    }
}

// MARK: - PPTXReaderView

/// Reader for PowerPoint decks: slide thumbnails, the current slide at full
/// size, speaker notes, slide text search, a slide show with presenter view
/// (Pro), and PDF / image export (Pro).
struct PPTXReaderView: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore
    /// Pagewrit's own light or dark look, read straight from the app rather
    /// than this window, which the reader theme may have forced. "Auto"
    /// follows this, and it updates the instant the app look changes.
    @ObservedObject private var appearanceWatcher = AppearanceWatcher.shared
    private var colorScheme: ColorScheme { appearanceWatcher.scheme }
    @Environment(\.dismissWindow) private var dismissWindow

    private enum LoadState { case loading, ready, failed }
    private enum Mode: String, CaseIterable { case slides = "Slides", preview = "Preview" }
    private enum Pane: String, CaseIterable { case notes = "Notes", text = "Text" }

    @State private var deck: SlideDeck?
    @State private var state: LoadState = .loading
    @State private var selected = 0
    @State private var mode: Mode = .slides
    @State private var pane: Pane? = .notes
    @State private var query = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var proFeature: ProFeature?
    @State private var exportMessage: String?
    @FocusState private var focused: Bool

    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue
    private var palette: ReaderPalette {
        (ReaderTheme(rawValue: readerThemeRaw) ?? .system).palette(for: colorScheme)
    }
    private var chrome: Color { Color(nsColor: palette.chrome) }
    private var textColor: Color { Color(nsColor: palette.text) }
    private var tint: Color { Color(nsColor: palette.secondary) }
    private var rule: Color { Color(nsColor: palette.rule) }
    private var accent: Color { Color(nsColor: palette.link) }

    private var slideCount: Int { deck?.slides.count ?? 0 }
    private var currentSlide: RenderSlide? { deck?.slides.indices.contains(selected) == true ? deck?.slides[selected] : nil }

    var body: some View {
        VStack(spacing: 0) {
            ReaderToolbarFit { header }
            Rectangle().fill(rule).frame(height: 1)
            content
            if state == .ready && mode == .slides {
                Rectangle().fill(rule).frame(height: 1)
                footer
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(ReaderWindowAppearance(theme: ReaderTheme(rawValue: readerThemeRaw) ?? .system))
        // Native controls (tab pickers, switches) follow the reader theme, not the Mac.
        .environment(\.colorScheme, (ReaderTheme(rawValue: readerThemeRaw) ?? .system).controlScheme(system: colorScheme))
        .background(Color(nsColor: palette.background).ignoresSafeArea())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.upArrow) { go(-1); return .handled }
        .onKeyPress(.pageUp) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.downArrow) { go(1); return .handled }
        .onKeyPress(.pageDown) { go(1); return .handled }
        .onKeyPress(.space) { go(1); return .handled }
        .onKeyPress(.home) { select(0); return .handled }
        .onKeyPress(.end) { select(slideCount - 1); return .handled }
        .onAppear {
            library.markOpened(book)
            focused = true
            loadDeck()
        }
        .onDisappear { library.commitReading() }
        .onChange(of: selected) { _, new in scheduleSave(new) }
        .alert(item: Binding(get: { proFeature.map { ProAlert(feature: $0) } }, set: { _ in proFeature = nil })) { alert in
            Alert(title: Text("\(alert.feature.title) is a Pagewrit Pro feature"),
                  message: Text("Pro isn't available yet. It's coming soon."),
                  dismissButton: .default(Text("OK")))
        }
        .alert("Export", isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })) {
            Button("OK") { exportMessage = nil }
        } message: { Text(exportMessage ?? "") }
    }

    private struct ProAlert: Identifiable { let feature: ProFeature; var id: String { feature.rawValue } }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(DesignTokens.sansFont(size: 13, weight: .semibold))
                    .foregroundStyle(textColor).lineLimit(1)
                if slideCount > 0 {
                    Text("\(slideCount) slide\(slideCount == 1 ? "" : "s")")
                        .font(DesignTokens.sansFont(size: 11)).foregroundStyle(tint)
                }
            }
            Spacer()

            if state == .ready {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 150).labelsHidden()
                .help("Slides: thumbnails, notes and presenting. Preview: exact Office rendering.")

                if mode == .slides {
                    Menu {
                        Button("Notes") { pane = pane == .notes ? nil : .notes }
                        Button("Slide text") { pane = pane == .text ? nil : .text }
                        if pane != nil { Divider(); Button("Hide side panel") { pane = nil } }
                    } label: { Label("Panel", systemImage: "sidebar.right").foregroundStyle(textColor) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                    Menu {
                        Button("PDF\u{2026}") { gated(.slideExport, exportPDF) }
                        Button("Images (PNG)\u{2026}") { gated(.slideExport, exportImages) }
                    } label: { Label("Export", systemImage: "square.and.arrow.up").foregroundStyle(textColor) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()

                    Button { gated(.presenterMode, present) } label: {
                        Label("Present", systemImage: "play.rectangle.fill")
                    }
                    .buttonStyle(.pw(.primary, size: .small))
                    .keyboardShortcut(.return, modifiers: [.command, .option])
                    .help("Start the slide show (\u{2325}\u{2318}\u{21A9})")
                }
            }

            Button { NSWorkspace.shared.open(book.sourceURL) } label: {
                Label("Open in App", systemImage: "arrow.up.forward.app").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless).help("Open in PowerPoint or Keynote")

            ReadingTimerPill(tint: tint, accent: accent)

            ReaderCloseButton(help: "Close this deck (\u{2318}W)", tint: tint, rule: rule) { dismissWindow() }
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: 52)
        .background(chrome)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView("Reading slides\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            VStack(spacing: 0) {
                notice("Pagewrit couldn't read this deck's slides, so it's shown in Preview.")
                QuickLookPreview(url: book.sourceURL)
            }
        case .ready:
            if mode == .preview {
                QuickLookPreview(url: book.sourceURL)
            } else {
                HStack(spacing: 0) {
                    thumbnails.frame(width: 188)
                    Rectangle().fill(rule).frame(width: 1)
                    stage
                    if let pane {
                        Rectangle().fill(rule).frame(width: 1)
                        sidePanel(pane).frame(width: 300)
                    }
                }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.sansFont(size: 12))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.sm)
            .background(chrome)
    }

    // MARK: Thumbnails

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(deck?.slides ?? []) { slide in
                        thumb(slide).id(slide.index)
                    }
                }
                .padding(10)
            }
            .onChange(of: selected) { _, new in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .background(chrome.opacity(0.6))
    }

    private func thumb(_ slide: RenderSlide) -> some View {
        let isSelected = slide.index == selected
        return HStack(alignment: .top, spacing: 6) {
            Text("\(slide.number)")
                .font(DesignTokens.sansFont(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? accent : tint)
                .frame(width: 16, alignment: .trailing)
            if let deck {
                SlideImageView(deck: deck, index: slide.index, pixelWidth: 360)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(isSelected ? accent : rule, lineWidth: isSelected ? 2 : 1))
                    .opacity(slide.hidden ? 0.4 : 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { select(slide.index) }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            Color(nsColor: palette.background)
            if let deck, currentSlide != nil {
                SlideImageView(deck: deck, index: selected, pixelWidth: 2000)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                    .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button { go(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(selected == 0)
            Text("Slide \(selected + 1) of \(slideCount)")
                .font(DesignTokens.sansFont(size: 12)).monospacedDigit()
                .frame(minWidth: 100)
            Button { go(1) } label: { Image(systemName: "chevron.right") }
                .disabled(selected + 1 >= slideCount)
            if let title = currentSlide?.title {
                Text(title).font(DesignTokens.sansFont(size: 12)).foregroundStyle(tint).lineLimit(1)
            }
            Spacer()
            if let labels = currentSlide?.unsupportedLabels, !labels.isEmpty {
                Button { mode = .preview } label: {
                    Label("\(Set(labels).sorted().joined(separator: ", ")) \u{2014} view in Preview", systemImage: "exclamationmark.triangle")
                        .font(DesignTokens.sansFont(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Pagewrit can't draw this part of the slide. Preview shows it exactly.")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(textColor)
        .padding(.horizontal, DesignTokens.Spacing.md)
        .frame(height: 36)
        .background(chrome)
    }

    // MARK: Side panel

    @ViewBuilder
    private func sidePanel(_ pane: Pane) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { pane }, set: { self.pane = $0 })) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            Rectangle().fill(rule).frame(height: 1)

            switch pane {
            case .notes:
                ScrollView {
                    let notes = currentSlide?.notes ?? ""
                    Text(notes.isEmpty ? "No speaker notes on this slide." : notes)
                        .font(DesignTokens.sansFont(size: 13))
                        .foregroundStyle(notes.isEmpty ? tint : textColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .text:
                TextField("Search slides", text: $query)
                    .textFieldStyle(.roundedBorder).padding(10)
                let hits = matchingSlides
                if hits.isEmpty {
                    Text(query.isEmpty ? "No text found in this deck." : "No slides match.")
                        .font(DesignTokens.sansFont(size: 12)).foregroundStyle(tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(hits) { slide in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Slide \(slide.number)")
                                        .font(DesignTokens.sansFont(size: 10, weight: .bold))
                                        .foregroundStyle(slide.index == selected ? accent : tint)
                                    Text(slide.text.isEmpty ? "(no text)" : slide.text)
                                        .font(DesignTokens.sansFont(size: 12))
                                        .foregroundStyle(textColor).lineLimit(6)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .contentShape(Rectangle())
                                .onTapGesture { select(slide.index) }
                                Rectangle().fill(rule).frame(height: 1)
                            }
                        }
                    }
                }
            }
        }
        .background(chrome)
    }

    private var matchingSlides: [RenderSlide] {
        guard let deck else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return deck.slides }
        return deck.slides.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.notes.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Navigation and progress

    private func go(_ delta: Int) { select(selected + delta) }

    private func select(_ index: Int) {
        guard slideCount > 0 else { return }
        selected = min(max(index, 0), slideCount - 1)
    }

    private func scheduleSave(_ index: Int) {
        guard slideCount > 1 else { return }
        let fraction = Double(index) / Double(slideCount - 1)
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            library.updateProgress(for: book, progress: fraction)
        }
    }

    private func loadDeck() {
        let url = book.sourceURL
        let saved = book.readingProgress
        Task.detached(priority: .userInitiated) {
            let result = SlideDeckLoader.load(url: url)
            await MainActor.run {
                if let result {
                    deck = result
                    if let saved, result.slides.count > 1 {
                        selected = min(max(Int((saved * Double(result.slides.count - 1)).rounded()), 0), result.slides.count - 1)
                    }
                    state = .ready
                    // A deck made only of things Pagewrit can't draw reads better in Preview.
                    if result.slides.allSatisfy({ $0.elements.isEmpty }) { mode = .preview }
                } else {
                    state = .failed
                }
            }
        }
    }

    // MARK: Pro features

    private func gated(_ feature: ProFeature, _ action: () -> Void) {
        if Entitlements.isUnlocked(feature) { action() } else { proFeature = feature }
    }

    private func present() {
        guard let deck else { return }
        let controller = PresenterController.shared
        controller.onEnd = { last in
            selected = last
            focused = true
        }
        controller.start(deck: deck, from: selected, title: book.title)
    }

    private func exportPDF() {
        guard let deck else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = book.title + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let data = SlideRenderer.pdfData(deck: deck)
            let ok = data.flatMap { try? $0.write(to: url) } != nil
            await MainActor.run {
                exportMessage = ok ? "Saved \(url.lastPathComponent)." : "The PDF couldn't be saved."
            }
        }
    }

    private func exportImages() {
        guard let deck else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the slide images."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let base = book.title
        Task.detached(priority: .userInitiated) {
            var written = 0
            for slide in deck.slides {
                let img = SlideRenderer.image(deck: deck, index: slide.index, pixelWidth: 1920)
                guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = String(format: "%@ %02d.png", base, slide.number)
                if (try? png.write(to: folder.appendingPathComponent(name))) != nil { written += 1 }
            }
            let savedCount = written
            await MainActor.run {
                exportMessage = "Saved \(savedCount) of \(deck.slides.count) slide images."
            }
        }
    }
}
