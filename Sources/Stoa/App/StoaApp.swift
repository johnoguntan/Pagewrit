import SwiftUI
import CoreSpotlight

extension Notification.Name {
    /// Posted when the user taps a Stoa result in macOS Spotlight — carries
    /// the tapped book's contentHash as the notification's object.
    static let stoaOpenBookFromSpotlight = Notification.Name("stoaOpenBookFromSpotlight")
}

/// Routes a Spotlight tap back into the running app. NSApplicationDelegate
/// is still the only way to receive continue-userActivity on macOS
/// SwiftUI-lifecycle apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let hash = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        else {
            return false
        }
        NotificationCenter.default.post(name: .stoaOpenBookFromSpotlight, object: hash)
        return true
    }
}

@main
struct StoaApp: App {
    @StateObject private var scanner = ScannerService()
    @StateObject private var library = LibraryStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
                .environmentObject(library)
                .frame(minWidth: 720, minHeight: 480)
                .background(DesignTokens.background.ignoresSafeArea())
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
            // Settings lives inside the main window (sidebar gear button, or
            // Cmd+,) rather than as a separate macOS Settings window — the
            // native Settings scene is intentionally not used here.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    library.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
