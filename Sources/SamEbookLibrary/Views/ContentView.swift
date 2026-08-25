import SwiftUI

/// Phase 1 UI: just proves the scan works. Shows every discovered file as a
/// flat list with its format and folder. Phase 2 replaces this with the real
/// cover-grid library view once files are imported with metadata.
struct ContentView: View {
    @EnvironmentObject private var scanner: ScannerService
    @State private var searchText = ""

    private var filteredFiles: [DiscoveredFile] {
        guard !searchText.isEmpty else { return scanner.discoveredFiles }
        return scanner.discoveredFiles.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Watched Folders") {
                    ForEach(scanner.allWatchedFolders, id: \.self) { folder in
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .lineLimit(1)
                    }
                }
            }
            .navigationTitle("Sam's Library")
        } detail: {
            VStack(spacing: 0) {
                if scanner.isScanning {
                    ProgressView("Scanning…")
                        .padding()
                }

                if let error = scanner.lastScanError {
                    Text(error)
                        .foregroundStyle(.red)
                        .padding()
                }

                if filteredFiles.isEmpty && !scanner.isScanning {
                    ContentUnavailableView(
                        "No Books Found Yet",
                        systemImage: "books.vertical",
                        description: Text("Click Rescan to search your Documents, Desktop, and Downloads folders for EPUB, PDF, and CBZ files.")
                    )
                } else {
                    List(filteredFiles) { file in
                        HStack {
                            Image(systemName: icon(for: file.format))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(file.url.lastPathComponent)
                                    .font(.body)
                                Text(file.url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(file.format.rawValue.uppercased())
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search books")
                }
            }
            .navigationTitle("Library (\(filteredFiles.count))")
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { await scanner.scan() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(scanner.isScanning)
                }
            }
        }
        .task {
            if scanner.discoveredFiles.isEmpty {
                await scanner.scan()
            }
        }
    }

    private func icon(for format: BookFormat) -> String {
        switch format {
        case .epub: return "book"
        case .pdf: return "doc.richtext"
        case .cbz: return "photo.on.rectangle"
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ScannerService())
}
