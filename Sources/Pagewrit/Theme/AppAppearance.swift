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

        func attach(to window: NSWindow?) {
            // Each toolbar button carries its own word inside it; no extra caption below.
            // Only when it actually differs: re-setting it on every SwiftUI update
            // makes AppKit re-lay-out the toolbar, which made the whole window
            // jump in size and lag whenever a toolbar button was clicked.
            if let toolbar = window?.toolbar, toolbar.displayMode != .iconOnly {
                toolbar.displayMode = .iconOnly
            }
            guard let window, window !== self.window else { return }
            self.window = window
            tokens.forEach(NotificationCenter.default.removeObserver)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification
            ]
            tokens = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    window?.invalidateShadow()
                }
            }
            window.invalidateShadow()
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
