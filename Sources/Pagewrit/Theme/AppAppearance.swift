import SwiftUI
import AppKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "pagewrit.appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        Self.refreshWindows()
    }

    /// macOS can leave toolbar buttons and the search box drawn in the old
    /// appearance after a switch (dark pills on a light window). Pushing the
    /// appearance to each window and redrawing its views, now and a moment
    /// later once the toolbar has rebuilt, clears it.
    static func refreshWindows() {
        func redraw() {
            for window in NSApp.windows {
                window.appearance = NSApp.appearance
                func walk(_ view: NSView) {
                    view.needsDisplay = true
                    view.subviews.forEach(walk)
                }
                if let root = window.contentView?.superview { walk(root) }
                window.toolbar?.items.compactMap(\.view).forEach(walk)
                window.invalidateShadow()
            }
        }
        redraw()
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { redraw() }
        }
    }

    static func applySaved() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? AppAppearance.system.rawValue
        (AppAppearance(rawValue: raw) ?? .system).apply()
    }
}

/// Keeps the window's drop shadow in sync with its content. Windows with
/// translucent toolbars and material backgrounds can leave a stale, flickering
/// shadow strip outside their edge; invalidating the shadow after layout
/// changes clears it.
struct WindowShadowFixer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []
        private var clickMonitor: Any?

        func attach(to window: NSWindow?) {
            // Each toolbar button carries its own word inside it; no extra caption below.
            // Only when it actually differs: re-setting it on every SwiftUI update
            // makes AppKit re-lay-out the toolbar, which made the whole window
            // jump in size and lag whenever a toolbar button was clicked.
            if let toolbar = window?.toolbar, toolbar.displayMode != .iconOnly {
                toolbar.displayMode = .iconOnly
            }
            Self.removeSearchFocusRing(in: window, retry: false)
            guard let window, window !== self.window else { return }
            self.window = window
            Self.removeSearchFocusRing(in: window)
            installClickAwayMonitor()
            tokens.forEach(NotificationCenter.default.removeObserver)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification
            ]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    window?.invalidateShadow()
                    Self.removeSearchFocusRing(in: window)
                }
            }
            window.invalidateShadow()
        }

        /// The toolbar's search box draws the system's blue focus ring around
        /// itself. Turn that off wherever the field lives in the window, and
        /// look again shortly after, because the toolbar builds it late and
        /// rebuilds it when the window changes width.
        static func removeSearchFocusRing(in window: NSWindow?, retry: Bool = true) {
            guard let window else { return }
            func walk(_ view: NSView) {
                if let field = view as? NSSearchField {
                    field.focusRingType = .none
                    field.cell?.focusRingType = .none
                }
                view.subviews.forEach(walk)
            }
            if let root = window.contentView?.superview { walk(root) }
            if let toolbarView = window.toolbar?.items.compactMap({ $0.view }) {
                toolbarView.forEach(walk)
            }
            guard retry else { return }
            for delay in [0.2, 0.8, 2.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                    removeSearchFocusRing(in: window, retry: false)
                }
            }
        }

        /// Clicking anywhere outside the search box lets go of it, like every
        /// Mac search field should. Without this the cursor stayed in the box
        /// until you clicked something in the sidebar.
        private func installClickAwayMonitor() {
            guard clickMonitor == nil else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      let field = editor.delegate as? NSSearchField else { return event }
                let point = field.convert(event.locationInWindow, from: nil)
                if !field.bounds.contains(point) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }
    }
}
