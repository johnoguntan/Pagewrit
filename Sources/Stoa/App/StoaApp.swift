import SwiftUI
import CoreSpotlight

extension Notification.Name {
    /// Posted when the user taps a Stoa result in macOS Spotlight — carries
    /// the tapped book's contentHash as the notification's object.
    static let stoaOpenBookFromSpotlight = Notification.Name("stoaOpenBookFromSpotlight")

    /// Posted after GutenbergService finishes saving a downloaded EPUB to
    /// disk, carrying the file's URL as `object` — ContentView imports
    /// just that one file (see importSingleFile) rather than rescanning
    /// every watched folder for it.
    static let stoaBooksDownloaded = Notification.Name("stoaBooksDownloaded")

    /// Posted when something outside ContentView (Settings' Rescan button,
    /// or adding a new watched folder) wants a full rescan + import —
    /// ScannerService.scan() alone only refreshes the discovered-file list,
    /// it doesn't hash/classify/import anything into the library, so
    /// Settings needs a way to trigger the real pipeline that ContentView
    /// owns rather than duplicating it.
    static let stoaRequestFullRescan = Notification.Name("stoaRequestFullRescan")
}

/// Routes a Spotlight tap back into the running app. NSApplicationDelegate
/// is still the only way to receive continue-userActivity on macOS
/// SwiftUI-lifecycle apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        performFirstLaunchSetupIfNeeded()
    }

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

    /// Runs once, the very first time this installed copy of Stoa is
    /// launched: registers the app with Launch Services/Spotlight right
    /// away instead of waiting on background indexing, adds a Desktop
    /// shortcut, and pins the app to the Dock. This is what makes a plain
    /// drag-to-Applications install behave like a full installer without
    /// the person who installed it ever touching Terminal — the first
    /// double-click of the app itself does the rest.
    private func performFirstLaunchSetupIfNeeded() {
        let key = "com.thehappy.stoa.hasCompletedFirstLaunchSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let appURL = Bundle.main.bundleURL
        let appPath = appURL.path

        runProcess(
            "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
            args: ["-f", appPath]
        )
        runProcess("/usr/bin/mdimport", args: [appPath])

        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let linkURL = desktop.appendingPathComponent("Stoa")
            try? FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: appURL)
        }

        let dockEntry = "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key>"
            + "<string>file://\(appPath)/</string><key>_CFURLStringType</key><integer>15</integer>"
            + "</dict></dict></dict>"
        runProcess("/usr/bin/defaults", args: ["write", "com.apple.dock", "persistent-apps", "-array-add", dockEntry])
        runProcess("/usr/bin/killall", args: ["Dock"])

        UserDefaults.standard.set(true, forKey: key)
    }

    private func runProcess(_ launchPath: String, args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try? process.run()
        process.waitUntilExit()
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

        // A real, separate window for the reader — not a .sheet. Sheets are
        // docked to their parent window and can't be dragged or resized
        // independently, which doesn't suit long reading sessions where
        // people want to move the reader to another display, snap it
        // beside another app, or full-screen it on its own. Keyed by the
        // book's contentHash so macOS can restore/reuse a reader window
        // per book rather than stacking duplicates.
        WindowGroup(id: "reader", for: String.self) { $bookHash in
            ReaderWindowContent(bookHash: bookHash)
                .environmentObject(library)
                .frame(minWidth: 480, minHeight: 360)
                .background(DesignTokens.background.ignoresSafeArea())
        }
        .windowStyle(.automatic)
        .defaultSize(width: 900, height: 760)
        .commandsRemoved()
    }
}

/// Resolves a reader window's launch value (a book's contentHash) to the
/// live `Book` in the library. Looking it up rather than capturing the
/// `Book` value directly means the window stays correct if the book's
/// metadata changes while the window is open, and degrades gracefully if
/// the book was removed from the library while the window was open.
private struct ReaderWindowContent: View {
    let bookHash: String?
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if let bookHash, let book = library.books.first(where: { $0.contentHash == bookHash }) {
            BookReaderSheet(book: book)
                .environmentObject(library)
        } else {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "book.closed")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("This book is no longer in your library.")
                    .font(DesignTokens.sansFont(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.background.ignoresSafeArea())
        }
    }
}
