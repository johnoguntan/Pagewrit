import SwiftUI
import CoreSpotlight

extension Notification.Name {
    /// Posted when the user taps a Pagewrit result in macOS Spotlight — carries
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

    /// Posted by the folder watcher when new files appear. Same work as a full
    /// rescan, but done in the background with no scanning animation.
    static let stoaQuietRescan = Notification.Name("stoaQuietRescan")

    /// Posted by the Go menu. The object is a destination name such as
    /// "library" or "favorites"; ContentView switches the sidebar to it.
    static let pagewritGo = Notification.Name("pagewritGo")
}

/// Routes a Spotlight tap back into the running app. NSApplicationDelegate
/// is still the only way to receive continue-userActivity on macOS
/// SwiftUI-lifecycle apps.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.applySaved()
        EPUBContentRules.warmUp()
        CrashReporter.shared.start()

        // Closing the library window closes every open reader with it, so no
        // orphaned reading windows are left behind.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            guard let closing = note.object as? NSWindow, Self.isLibraryWindow(closing) else { return }
            for window in NSApp.windows where Self.isReaderWindow(window) && window.isVisible {
                window.close()
            }
        }
    }

    private static func isReaderWindow(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue ?? "").contains("reader")
    }

    /// The main window: a titled, resizable, ordinary window that is not a
    /// reader, panel, popover or sheet.
    private static func isLibraryWindow(_ window: NSWindow) -> Bool {
        !isReaderWindow(window)
            && !(window is NSPanel)
            && window.styleMask.contains(.titled)
            && window.sheetParent == nil
            && window.canBecomeMain
            && window.contentViewController != nil
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
}

@main
struct PagewritApp: App {
    @StateObject private var scanner = ScannerService()
    @StateObject private var library = LibraryStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // A single library window: choosing "Open With Pagewrit" in Finder while
        // the app is running reuses this window instead of opening another one.
        Window("Pagewrit", id: "main") {
            ContentView()
                .environmentObject(scanner)
                .environmentObject(library)
                .overlay { CelebrationOverlay() }
                .accessibilityRoot()
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
            CommandMenu("Go") {
                Button("All Books") { NotificationCenter.default.post(name: .pagewritGo, object: "library") }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Favorites") { NotificationCenter.default.post(name: .pagewritGo, object: "favorites") }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Needs Review") { NotificationCenter.default.post(name: .pagewritGo, object: "needsReview") }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Duplicates") { NotificationCenter.default.post(name: .pagewritGo, object: "duplicates") }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Highlights & Notes") { NotificationCenter.default.post(name: .pagewritGo, object: "highlighted") }
                    .keyboardShortcut("5", modifiers: .command)
                Button("Bookmarks") { NotificationCenter.default.post(name: .pagewritGo, object: "bookmarks") }
                    .keyboardShortcut("6", modifiers: .command)
                Button("Recycle Bin") { NotificationCenter.default.post(name: .pagewritGo, object: "recycleBin") }
                    .keyboardShortcut("7", modifiers: .command)
                Button("Invoices") { NotificationCenter.default.post(name: .pagewritGo, object: "invoices") }
                    .keyboardShortcut("8", modifiers: .command)
                Divider()
                Button("Rescan Folders") { NotificationCenter.default.post(name: .stoaRequestFullRescan, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                    .keyboardShortcut("/", modifiers: .command)
                Button("Welcome to Pagewrit") { library.showWelcome = true }
                if AppInfo.hasSupportContact {
                    Button("Report a Problem\u{2026}") { CrashReporter.shared.reportProblem() }
                    Button("Contact Support\u{2026}") { AppInfo.contactSupport() }
                }
                Button("Privacy\u{2026}") { library.showSettings = true }
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
            // No minimum here: each reader sets its own, and the window
            // takes it, so a window can never be narrower than its page.
            ReaderWindowContent(bookHash: bookHash)
                .environmentObject(library)
                .overlay { CelebrationOverlay() }
                .accessibilityRoot()
                .background(DesignTokens.background.ignoresSafeArea())
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 760)
        .commandsRemoved()

        Window("Keyboard Shortcuts", id: "shortcuts") {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

// MARK: - Keyboard shortcuts help

/// A quiet reference of every shortcut in the app: key caps on the right,
/// the action on the left, grouped by where you are.
struct KeyboardShortcutsView: View {
    private struct Entry: Identifiable { let id = UUID(); let action: String; let keys: [String] }
    private struct Group: Identifiable { let id = UUID(); let title: String; let entries: [Entry] }

    private static func e(_ action: String, _ keys: String...) -> Entry { Entry(action: action, keys: keys) }

    private let groups: [Group] = [
        Group(title: "Library", entries: [
            e("Search your library", "\u{2318}", "F"),
            e("All Books", "\u{2318}", "1"),
            e("Favorites", "\u{2318}", "2"),
            e("Needs Review", "\u{2318}", "3"),
            e("Duplicates", "\u{2318}", "4"),
            e("Highlights & Notes", "\u{2318}", "5"),
            e("Bookmarks", "\u{2318}", "6"),
            e("Recycle Bin", "\u{2318}", "7"),
            e("Invoices", "\u{2318}", "8"),
            e("Rescan folders", "\u{21E7}", "\u{2318}", "R"),
            e("Open the focused book or row", "Return"),
            e("Settings", "\u{2318}", ","),
            e("Keyboard Shortcuts", "\u{2318}", "/"),
        ]),
        Group(title: "Reading", entries: [
            e("Contents and pages", "\u{2318}", "L"),
            e("Search in book", "\u{2318}", "F"),
            e("Next or previous match", "\u{2318}", "G"),
            e("Next page", "\u{2318}", "\u{2192}"),
            e("Previous page", "\u{2318}", "\u{2190}"),
            e("Larger text or zoom in", "\u{2318}", "="),
            e("Smaller text or zoom out", "\u{2318}", "\u{2212}"),
            e("Reset size", "\u{2318}", "0"),
            e("Focus mode", "\u{21E7}", "\u{2318}", "F"),
            e("Bookmark this spot (text books)", "\u{2318}", "D"),
            e("Close the reader", "\u{2318}", "W"),
        ]),
        Group(title: "Ratings", entries: [
            e("Set a rating", "0", "to", "5"),
            e("Raise or lower a rating", "\u{2190}", "\u{2192}"),
        ]),
        Group(title: "Slides", entries: [
            e("Present", "\u{2325}", "\u{2318}", "Return"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Keyboard shortcuts")
                    .font(DesignTokens.serifFont(size: 28))
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title)
                            .font(DesignTokens.sansFont(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 4)
                        ForEach(group.entries) { entry in
                            HStack {
                                Text(entry.action)
                                    .font(DesignTokens.sansFont(size: 14))
                                Spacer(minLength: 24)
                                HStack(spacing: 4) {
                                    ForEach(Array(entry.keys.enumerated()), id: \.offset) { _, key in
                                        keycap(key)
                                    }
                                }
                            }
                            .padding(.vertical, 7)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(entry.action)
                            .accessibilityValue(entry.keys.joined(separator: " "))
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
            .padding(32)
        }
        .scrollIndicators(.hidden)
        .frame(width: 460, height: 620)
        .background(DesignTokens.background)
    }

    @ViewBuilder
    private func keycap(_ key: String) -> some View {
        if key == "to" {
            Text(key).font(DesignTokens.sansFont(size: 12)).foregroundStyle(.secondary)
        } else {
            Text(key)
                .font(DesignTokens.sansFont(size: 12, weight: .medium))
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, key.count > 1 ? 6 : 0)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
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
