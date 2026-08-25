import SwiftUI

@main
struct SamEbookLibraryApp: App {
    @StateObject private var scanner = ScannerService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(scanner)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        Settings {
            SettingsView()
                .environmentObject(scanner)
        }
    }
}
