import SwiftUI
import AppKit

/// A borderless window that can take keyboard focus, used for the audience screen.
final class PresenterWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Runs a slide show: a full-screen audience window, plus (when a second
/// display is connected) a presenter console on the main display with the
/// current slide, the next slide, speaker notes and a timer. With one
/// display, press N to overlay notes and the timer on the show.
///
/// Keys: → ↓ Space Return PageDown = next · ← ↑ Delete PageUp = back ·
/// Home / End · B = black screen · N = notes overlay · Esc = end.
@MainActor
final class PresenterController: ObservableObject {
    static let shared = PresenterController()

    @Published private(set) var position = 0
    @Published var blackout = false
    @Published var showHUD = false
    @Published private(set) var isPresenting = false

    private(set) var deck: SlideDeck?
    private(set) var order: [Int] = []
    private(set) var startedAt = Date()
    var onEnd: ((Int) -> Void)?

    private var audience: PresenterWindow?
    private var console: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var monitor: Any?
    private var savedOptions: NSApplication.PresentationOptions = []
    private var changedPresentation = false

    private init() {}

    var count: Int { order.count }
    var currentSlideIndex: Int { order.indices.contains(position) ? order[position] : 0 }
    var nextSlideIndex: Int? { position + 1 < order.count ? order[position + 1] : nil }
    var currentSlide: RenderSlide? { deck?.slides[safe: currentSlideIndex] }
    var currentNotes: String { currentSlide?.notes ?? "" }

    // MARK: Start / end

    func start(deck: SlideDeck, from slideIndex: Int, title: String) {
        guard !isPresenting else { return }
        let order = deck.presentableIndices
        guard !order.isEmpty else { return }
        self.deck = deck
        self.order = order
        position = order.firstIndex(where: { $0 >= slideIndex }) ?? 0
        startedAt = Date()
        blackout = false
        showHUD = false
        isPresenting = true

        let screens = NSScreen.screens
        let main = NSScreen.main ?? screens[0]
        let multiple = screens.count > 1
        let audienceScreen = multiple ? (screens.first { $0 != main } ?? main) : main

        let win = PresenterWindow(contentRect: audienceScreen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false, screen: audienceScreen)
        // Floating, not screen-saver: the Dock and menu bar stay reachable, and the
        // show steps aside when the user switches apps (Cmd-Tab).
        win.level = .floating
        win.hidesOnDeactivate = true
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: AudienceView(controller: self, singleScreen: !multiple))
        win.setFrame(audienceScreen.frame, display: true)
        win.makeKeyAndOrderFront(nil)
        audience = win

        if multiple {
            let c = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            c.title = "Presenter View \u{2014} \(title)"
            c.isReleasedWhenClosed = false
            c.contentView = NSHostingView(rootView: PresenterConsoleView(controller: self))
            c.setFrame(NSRect(x: main.frame.midX - 590, y: main.frame.midY - 360, width: 1180, height: 720), display: true)
            c.makeKeyAndOrderFront(nil)
            console = c
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: c, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func end() {
        guard isPresenting else { return }
        isPresenting = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        audience?.orderOut(nil)
        audience = nil
        console?.orderOut(nil)
        console = nil
        if changedPresentation { NSApp.presentationOptions = savedOptions }
        changedPresentation = false
        savedOptions = []
        let last = currentSlideIndex
        onEnd?(last)
    }

    // MARK: Navigation

    func next() { if position + 1 < order.count { position += 1; blackout = false } }
    func previous() { if position > 0 { position -= 1; blackout = false } }
    func first() { position = 0 }
    func last() { position = max(0, order.count - 1) }

    private func handle(_ event: NSEvent) -> Bool {
        guard isPresenting else { return false }
        switch event.keyCode {
        case 124, 125, 49, 36, 121: next()
        case 123, 126, 51, 116: previous()
        case 115: first()
        case 119: last()
        case 53: end()
        case 11: blackout.toggle()
        case 45: showHUD.toggle()
        default: return false
        }
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Audience

struct AudienceView: View {
    @ObservedObject var controller: PresenterController
    let singleScreen: Bool

    @State private var barVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !controller.blackout, let deck = controller.deck {
                    SlideImageView(deck: deck, index: controller.currentSlideIndex,
                                   pixelWidth: min(3840, max(1280, geo.size.width * 2)))
                }
                if singleScreen && controller.showHUD {
                    VStack {
                        Spacer()
                        PresenterHUD(controller: controller)
                            .padding(.bottom, 96)
                            .padding(24)
                    }
                }
                if singleScreen {
                    controls
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { controller.next() }
        }
        .ignoresSafeArea()
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onAppear { reveal() }
    }

    /// Always-available exit in the corner, plus a bar that appears when the
    /// pointer moves and fades after a few quiet seconds.
    private var controls: some View {
        ZStack {
            VStack {
                HStack {
                    Spacer()
                    Button { controller.end() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            Text("End show").font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                        .foregroundStyle(.white.opacity(barVisible ? 0.95 : 0.4))
                    }
                    .buttonStyle(.plain)
                    .help("End the slide show (Esc)")
                }
                Spacer()
            }
            .padding(20)

            VStack {
                Spacer()
                HStack(spacing: 4) {
                    barButton("chevron.left", help: "Previous slide", disabled: controller.position == 0) { controller.previous() }
                    Text("\(controller.position + 1) of \(controller.count)")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .frame(minWidth: 64)
                    barButton("chevron.right", help: "Next slide", disabled: controller.position + 1 >= controller.count) { controller.next() }
                    Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 6)
                    barButton("text.alignleft", help: "Speaker notes (N)") { controller.showHUD.toggle() }
                    barButton(controller.blackout ? "rectangle" : "rectangle.fill", help: "Black screen (B)") { controller.blackout.toggle() }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .padding(.bottom, 28)
                .opacity(barVisible ? 1 : 0)
                .onHover { inside in
                    if inside { hideTask?.cancel(); barVisible = true } else { reveal() }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: barVisible)
    }

    private func barButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.3 : 1)
        .disabled(disabled)
        .help(help)
    }

    private func reveal() {
        barVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            barVisible = false
        }
    }
}

struct PresenterHUD: View {
    @ObservedObject var controller: PresenterController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Slide \(controller.position + 1) of \(controller.count)")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(formatElapsed(ctx.date.timeIntervalSince(controller.startedAt))).monospacedDigit()
                }
            }
            .font(.system(size: 14, weight: .semibold))
            Text(controller.currentNotes.isEmpty ? "No speaker notes for this slide." : controller.currentNotes)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(8)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 900)
    }
}

// MARK: - Presenter console

struct PresenterConsoleView: View {
    @ObservedObject var controller: PresenterController
    @State private var notesSize: Double = 22

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 12) {
                if let deck = controller.deck {
                    SlideImageView(deck: deck, index: controller.currentSlideIndex, pixelWidth: 1600)
                        .shadow(radius: 6)
                }
                HStack(spacing: 12) {
                    Button { controller.previous() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(controller.position == 0)
                    Text("Slide \(controller.position + 1) of \(controller.count)")
                        .monospacedDigit().frame(minWidth: 110)
                    Button { controller.next() } label: { Label("Next", systemImage: "chevron.right") }
                        .disabled(controller.position + 1 >= controller.count)
                    Spacer()
                    Button { controller.blackout.toggle() } label: {
                        Label(controller.blackout ? "Show Slide" : "Black Screen", systemImage: "rectangle.fill")
                    }
                    Button(role: .destructive) { controller.end() } label: { Label("End Show", systemImage: "xmark.circle") }
                }
            }
            .frame(minWidth: 520)

            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    HStack {
                        Image(systemName: "timer")
                        Text(formatElapsed(ctx.date.timeIntervalSince(controller.startedAt)))
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    }
                }
                Text("NEXT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                if let deck = controller.deck, let next = controller.nextSlideIndex {
                    SlideImageView(deck: deck, index: next, pixelWidth: 640).shadow(radius: 3)
                } else {
                    Text("End of show").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Text("NOTES").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { notesSize = max(12, notesSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { notesSize = min(48, notesSize + 2) } label: { Image(systemName: "textformat.size.larger") }
                }
                .buttonStyle(.borderless)
                ScrollView {
                    Text(controller.currentNotes.isEmpty ? "No speaker notes for this slide." : controller.currentNotes)
                        .font(.system(size: notesSize))
                        .foregroundStyle(controller.currentNotes.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(width: 340)
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 600)
    }
}
