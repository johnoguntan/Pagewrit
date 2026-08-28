import SwiftUI

@main
struct StoaApp: App {
    @StateObject private var scanner = ScannerService()
    @StateObject private var library = LibraryStore()

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
