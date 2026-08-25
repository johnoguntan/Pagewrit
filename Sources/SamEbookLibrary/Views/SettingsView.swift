import SwiftUI
import AppKit

/// Lets Sam add extra folders to scan beyond the defaults (Documents, Desktop,
/// Downloads), and remove ones she added before. Default folders are always
/// scanned and aren't listed as removable here.
struct SettingsView: View {
    @EnvironmentObject private var scanner: ScannerService

    var body: some View {
        Form {
            Section("Always Scanned") {
                ForEach(scanner.defaultFolders, id: \.self) { folder in
                    Text(folder.path)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Additional Folders") {
                if scanner.extraFolders.isEmpty {
                    Text("No additional folders added.")
                        .foregroundStyle(.secondary)
                }
                ForEach(scanner.extraFolders, id: \.self) { folder in
                    HStack {
                        Text(folder.path)
                        Spacer()
                        Button(role: .destructive) {
                            scanner.removeExtraFolder(folder)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Folder…") {
                    addFolder()
                }
            }

            Section {
                Button("Rescan Now") {
                    Task { await scanner.scan() }
                }
                if let lastScan = scanner.lastScanDate {
                    Text("Last scanned: \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"

        if panel.runModal() == .OK, let url = panel.url {
            scanner.addFolder(url)
            Task { await scanner.scan() }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ScannerService())
}
