import Foundation
import Combine

/// Phase 1: walks the default folders (Documents, Desktop, Downloads) plus any
/// folders Sam manually adds, and finds every .epub/.pdf/.cbz file on disk.
///
/// This does NOT extract metadata yet (that's Phase 2's ImportPipeline) — its
/// only job is to prove we can reliably find her books, including tripping the
/// standard macOS "MyApp would like to access files in your X folder" prompts
/// the first time each protected folder is touched.
@MainActor
final class ScannerService: ObservableObject {

    @Published private(set) var discoveredFiles: [DiscoveredFile] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var lastScanError: String?
    @Published private(set) var extraFolders: [URL] = []

    private let fileManager = FileManager.default
    private let extraFoldersKey = "extraWatchedFolderPaths"

    /// Folders scanned automatically, always. Accessing these the first time
    /// is what triggers macOS's per-folder permission dialog for a
    /// non-sandboxed, notarized app — no extra code required for that part.
    var defaultFolders: [URL] {
        [
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true),
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
    }

    var allWatchedFolders: [URL] {
        defaultFolders + extraFolders
    }

    init() {
        loadExtraFolders()
    }

    // MARK: - Folder management

    func addFolder(_ url: URL) {
        guard !extraFolders.contains(url), !defaultFolders.contains(url) else { return }
        extraFolders.append(url)
        persistExtraFolders()
    }

    func removeExtraFolder(_ url: URL) {
        extraFolders.removeAll { $0 == url }
        persistExtraFolders()
    }

    private func loadExtraFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: extraFoldersKey) ?? []
        extraFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func persistExtraFolders() {
        let paths = extraFolders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: extraFoldersKey)
    }

    // MARK: - Scanning

    /// Walks all watched folders and republishes `discoveredFiles`.
    /// Safe to call repeatedly (e.g. a manual "Rescan" button).
    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        lastScanError = nil

        let folders = allWatchedFolders
        let results = await Task.detached(priority: .userInitiated) { [fileManager] () -> [DiscoveredFile] in
            var found: [DiscoveredFile] = []
            var seenPaths = Set<String>()

            for folder in folders {
                guard fileManager.fileExists(atPath: folder.path) else { continue }

                let enumerator = fileManager.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true } // keep walking past unreadable subfolders
                )

                guard let enumerator else { continue }

                // `for case ... in enumerator` (Sequence.makeIterator) is
                // flagged unavailable from async contexts under Swift 6
                // strict concurrency, since FileManager.DirectoryEnumerator
                // is an NSEnumerator bridge. Drive it directly via
                // nextObject() instead, which has no such restriction.
                while let fileURL = enumerator.nextObject() as? URL {
                    guard !seenPaths.contains(fileURL.path) else { continue }
                    guard let format = BookFormat(fileExtension: fileURL.pathExtension) else { continue }

                    let values = try? fileURL.resourceValues(forKeys: [
                        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
                    ])
                    guard values?.isRegularFile == true else { continue }

                    seenPaths.insert(fileURL.path)
                    found.append(
                        DiscoveredFile(
                            url: fileURL,
                            format: format,
                            sizeBytes: Int64(values?.fileSize ?? 0),
                            modifiedAt: values?.contentModificationDate
                        )
                    )
                }
            }

            return found.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
        }.value

        discoveredFiles = results
        lastScanDate = Date()
        isScanning = false
    }
}
