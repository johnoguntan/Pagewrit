import Foundation
import Combine

/// Phase 1: walks the folders the person chose (sandbox bookmarks), and finds every book, document and deck on disk.
///
/// This does NOT extract metadata yet (that's Phase 2's ImportPipeline) — its
/// only job is to find the books in the folders the person picked.
@MainActor
final class ScannerService: ObservableObject {

    @Published private(set) var discoveredFiles: [DiscoveredFile] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastScanDate: Date?
    @Published private(set) var lastScanError: String?
    @Published private(set) var extraFolders: [URL] = []
    /// Books in iCloud Drive or Google Drive that are not on this Mac yet.
    /// Pagewrit asks for them to download and adds them once they arrive.
    @Published private(set) var cloudDownloadsWaiting = 0

    private let fileManager = FileManager.default

    /// Folders never worth scanning for books.
    nonisolated static let ignoredFolders: Set<String> = [
        "node_modules", "Pods", "DerivedData", "build", ".build", "vendor", "site-packages"
    ]
    /// Text and Word files smaller than this are notes and stubs, not reading.
    nonisolated static let minimumReadableBytes: Int64 = 4_000
    nonisolated static let boilerplateNames: Set<String> = [
        "readme", "license", "licence", "changelog", "contributing", "notice", "authors",
        "todo", "requirements", "code_of_conduct", "security", "copying", "third_party_notices"
    ]
    private let bookmarksKey = "pagewrit.watchedFolderBookmarks"
    nonisolated static let downloadCloudKey = "pagewrit.downloadCloudBooks"
    /// Bigger cloud files wait until you open them.
    nonisolated static let maxAutoDownloadBytes: Int64 = 250_000_000
    private var cloudRecheck: Task<Void, Never>?

    /// While cloud books are downloading, look again every minute so they
    /// join the library soon after they land.
    private func scheduleCloudRecheck() {
        guard cloudRecheck == nil else { return }
        cloudRecheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            self?.cloudRecheck = nil
            NotificationCenter.default.post(name: .stoaQuietRescan, object: nil)
        }
    }

    /// Under the App Sandbox nothing is readable until the person picks it,
    /// so there are no automatic folders any more: every watched folder is
    /// one they chose, remembered as a security-scoped bookmark. Kept as an
    /// (empty) property so callers that list "built-in" folders still compile.
    var defaultFolders: [URL] { [] }

    var allWatchedFolders: [URL] {
        defaultFolders + extraFolders
    }

    /// Folders whose security scope is currently open. Access is held for
    /// the life of the app so readers and the importer can open any book
    /// inside a watched folder later, not just during a scan.
    private var accessed: [URL] = []

    /// Watches the folders for new files and asks for a rescan when things settle.
    private var watcher: FolderWatcher?
    private var watchedPaths: [String] = []

    private func ensureWatching() {
        let paths = allWatchedFolders.map { $0.standardizedFileURL.path }
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        if watcher == nil {
            watcher = FolderWatcher {
                NotificationCenter.default.post(name: .stoaQuietRescan, object: nil)
            }
        }
        watcher?.watch(allWatchedFolders)
    }

    /// Bookmarks that could not be resolved right now (volume offline); kept so they are not lost.
    private var unresolvedBookmarks: [Data] = []

    init() {
        loadExtraFolders()
    }

    // MARK: - Folder management

    func addFolder(_ url: URL) {
        let std = url.standardizedFileURL
        guard !extraFolders.contains(where: { $0.standardizedFileURL == std }) else { return }
        guard let data = try? std.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return }
        if std.startAccessingSecurityScopedResource() { accessed.append(std) }
        extraFolders.append(std)
        var all = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        all.append(data)
        UserDefaults.standard.set(all, forKey: bookmarksKey)
    }

    func removeExtraFolder(_ url: URL) {
        let std = url.standardizedFileURL
        if let i = accessed.firstIndex(of: std) {
            accessed[i].stopAccessingSecurityScopedResource()
            accessed.remove(at: i)
        }
        extraFolders.removeAll { $0.standardizedFileURL == std }
        persistExtraFolders()
    }

    private func loadExtraFolders() {
        let stored = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] ?? []
        var urls: [URL] = []
        var anyStale = false
        var unresolved: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                // An unplugged drive or unavailable volume: keep the bookmark so
                // the folder comes back when it does, instead of forgetting it.
                unresolved.append(data)
                continue
            }
            if stale { anyStale = true }
            if url.startAccessingSecurityScopedResource() { accessed.append(url) }
            urls.append(url)
        }
        extraFolders = urls
        unresolvedBookmarks = unresolved
        if anyStale { persistExtraFolders() }
    }

    /// Rewrites the stored bookmarks from the current list (also refreshes
    /// any that went stale).
    private func persistExtraFolders() {
        let data = extraFolders.compactMap {
            try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(data + unresolvedBookmarks, forKey: bookmarksKey)
    }

    // MARK: - Scanning

    /// Walks all watched folders and republishes `discoveredFiles`.
    /// Safe to call repeatedly (e.g. a manual "Rescan" button).
    func scan() async {
        guard !isScanning else { return }
        ensureWatching()
        isScanning = true
        lastScanError = nil

        let folders = allWatchedFolders
        let downloadCloud = UserDefaults.standard.object(forKey: Self.downloadCloudKey) as? Bool ?? true
        let scanned = await Task.detached(priority: .userInitiated) { [fileManager] () -> (files: [DiscoveredFile], waiting: Int) in
            var found: [DiscoveredFile] = []
            var seenPaths = Set<String>()
            var waiting = 0

            for folder in folders {
                guard fileManager.fileExists(atPath: folder.path) else { continue }

                let enumerator = fileManager.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
                                                 .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
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
                    // Office leaves "~$deck.pptx" lock files next to open documents.
                    guard !fileURL.lastPathComponent.hasPrefix("~$") else { continue }
                    // Skip build and dependency folders so READMEs and notes inside
                    // projects never end up in a reading library.
                    guard !fileURL.pathComponents.contains(where: ScannerService.ignoredFolders.contains) else { continue }

                    let values = try? fileURL.resourceValues(forKeys: [
                        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
                        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
                    ])
                    guard values?.isRegularFile == true else { continue }

                    // iCloud Drive and Google Drive keep some files only in the
                    // cloud. Reading one would stall the scan while it downloads,
                    // so ask for it now and pick it up on a later scan.
                    if values?.isUbiquitousItem == true,
                       let status = values?.ubiquitousItemDownloadingStatus,
                       status != .current, status != .downloaded {
                        waiting += 1
                        if downloadCloud, Int64(values?.fileSize ?? 0) < ScannerService.maxAutoDownloadBytes {
                            try? fileManager.startDownloadingUbiquitousItem(at: fileURL)
                        }
                        continue
                    }

                    // Text and Word files are everywhere on a Mac; only keep ones that
                    // look like something to read, not READMEs, licenses or stubs.
                    if format == .text || format == .docx {
                        let size = Int64(values?.fileSize ?? 0)
                        let base = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                        guard size >= ScannerService.minimumReadableBytes,
                              !ScannerService.boilerplateNames.contains(base) else { continue }
                    }

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

            let sorted = found.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
            return (sorted, waiting)
        }.value

        discoveredFiles = scanned.files
        cloudDownloadsWaiting = scanned.waiting
        if scanned.waiting > 0 { scheduleCloudRecheck() }
        lastScanDate = Date()
        isScanning = false
    }
}

import AppKit

extension ScannerService {
    /// Asks the person which folders hold their books. Under the App Sandbox
    /// this is the only way Pagewrit can read them. Returns true if any
    /// folder was added.
    @discardableResult
    func chooseFolders() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.title = "Choose your book folders"
        panel.message = "Pagewrit will look for books, documents and presentations in the folders you pick."
        panel.prompt = "Add Folders"
        panel.directoryURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Documents", isDirectory: true)
        guard panel.runModal() == .OK else { return false }
        for url in panel.urls { addFolder(url) }
        return !panel.urls.isEmpty
    }
}

extension ScannerService {
    /// The sandbox can't read Documents, Desktop or Downloads on its own, so
    /// this walks through them one at a time. Each panel opens already on
    /// the right folder; the person only has to press Return. Skipping one
    /// just leaves it out.
    @discardableResult
    func chooseStandardFolders() -> Bool {
        let home = "/Users/\(NSUserName())"
        var added = false
        for name in ["Documents", "Desktop", "Downloads"] {
            let url = URL(fileURLWithPath: "\(home)/\(name)", isDirectory: true)
            if allWatchedFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { continue }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = url
            panel.title = "Allow access to \(name)"
            panel.message = "Click Allow Access so Pagewrit can find the books in your \(name) folder."
            panel.prompt = "Allow Access"
            if panel.runModal() == .OK, let picked = panel.url {
                addFolder(picked)
                added = true
            }
        }
        return added
    }
}


// MARK: - Cloud folders

extension ScannerService {
    enum CloudService {
        case iCloudDrive, googleDrive

        var name: String {
            switch self {
            case .iCloudDrive: return "iCloud Drive"
            case .googleDrive: return "Google Drive"
            }
        }
    }

    /// Your real home folder (not the app's sandbox container).
    private static var realHome: String { "/Users/\(NSUserName())" }

    /// Where each service keeps its files on a Mac. Google Drive needs the
    /// Google Drive for desktop app, which puts "My Drive" under CloudStorage.
    private static func startFolder(for service: CloudService) -> URL {
        switch service {
        case .iCloudDrive:
            return URL(fileURLWithPath: "\(realHome)/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        case .googleDrive:
            return URL(fileURLWithPath: "\(realHome)/Library/CloudStorage", isDirectory: true)
        }
    }

    /// Opens the folder picker already inside iCloud Drive or Google Drive.
    /// You can add the whole drive or just a "Books" folder inside it.
    @discardableResult
    func addCloudFolder(_ service: CloudService) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.startFolder(for: service)
        panel.title = "Add books from \(service.name)"
        switch service {
        case .iCloudDrive:
            panel.message = "Choose iCloud Drive, or a folder inside it such as Books. Pagewrit downloads the books it finds so you can read them offline."
        case .googleDrive:
            panel.message = "Open your Google Drive (GoogleDrive-your@email), then My Drive, and choose it or a folder inside it. This needs the free Google Drive for desktop app."
        }
        panel.prompt = "Add \(service.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        addFolder(url)
        return true
    }

    /// A friendly name for a watched folder: "iCloud Drive" instead of
    /// com~apple~CloudDocs, "Google Drive" instead of My Drive.
    nonisolated static func displayName(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasSuffix("/com~apple~CloudDocs") { return "iCloud Drive" }
        if path.contains("/Library/CloudStorage/GoogleDrive-"),
           url.lastPathComponent == "My Drive" || url.deletingLastPathComponent().lastPathComponent.hasPrefix("GoogleDrive-") {
            return "Google Drive"
        }
        return url.lastPathComponent
    }

    /// A symbol that says where a watched folder lives.
    nonisolated static func icon(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/") { return "icloud" }
        if path.contains("/Library/CloudStorage/") { return "cloud" }
        return "folder"
    }

    /// Where it is, for a second line: "iCloud Drive", "Google Drive" or the parent path.
    nonisolated static func locationText(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.contains("/Library/Mobile Documents/") { return "iCloud Drive" }
        if path.contains("/Library/CloudStorage/GoogleDrive-") { return "Google Drive" }
        if path.contains("/Library/CloudStorage/") { return "Cloud storage" }
        return url.deletingLastPathComponent().path
    }
}
