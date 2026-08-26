import SwiftUI

@main
struct StoaApp: App {
    @StateObject private var scanner = ScannerService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
                .frame(minWidth: 720, minHeight: 480)
                .background(DesignTokens.background.ignoresSafeArea())
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environmentObject(scanner)
        }
    }
}
