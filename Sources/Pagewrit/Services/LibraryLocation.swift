import Foundation

/// Single source of truth for where Pagewrit's on-disk library extras —
/// cover images, cached full-text search index, and downloaded books —
/// live. Defaults to `~/Documents/StoaLibrary`, but the user can point it
/// at any folder from Settings, typically one already synced by iCloud
/// Drive or Google Drive: Pagewrit doesn't integrate with either service
/// directly, it just relies on Finder already watching that folder, per
/// the original plan.
///
/// This deliberately does NOT cover the SwiftData store itself (titles,
/// tags, shelves, bookmarks, reading progress) — that database is
/// managed by SwiftData in its own app-support location regardless of
/// this setting, so moving this folder syncs the regenerable extras and
/// any newly downloaded books, not the reading list itself.
enum LibraryLocation {
    private static let defaultsKey = "stoa.libraryFolderPath"
    /// Under the App Sandbox a folder the person picked is only reachable
    /// through a security-scoped bookmark, so the custom location is stored
    /// as one (the path key above stays as the "is custom" marker).
    private static let bookmarkKey = "pagewrit.libraryFolderBookmark"
    private static var scoped: URL?

    private static func resolvedCustomFolder() -> URL? {
        if let scoped { return scoped }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        scoped = url
        return url
    }

    /// The folder currently in use. Falls back to the default location if
    /// nothing's been chosen, or if a previously chosen folder can no
    /// longer be found (an external or not-yet-mounted cloud folder).
    static var folder: URL {
        if UserDefaults.standard.string(forKey: defaultsKey) != nil,
           let url = resolvedCustomFolder() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return defaultFolder
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StoaLibrary", isDirectory: true)
    }

    /// True once the user has pointed the library somewhere other than the default.
    static var isCustom: Bool {
        UserDefaults.standard.string(forKey: defaultsKey) != nil
    }

    /// Moves everything under the current folder (Covers, SearchIndex,
    /// Downloads) into `newFolder`, then records `newFolder` as the chosen
    /// location. Safe to call while the app is running: none of these
    /// subfolders are held open by a persistent file handle, unlike the
    /// SwiftData store, which this deliberately leaves untouched.
    static func relocate(to newFolder: URL) throws {
        let current = folder
        guard current.standardizedFileURL != newFolder.standardizedFileURL else { return }

        // Moving a folder into itself would fail halfway and leave a mess.
        let from = current.standardizedFileURL.path + "/"
        guard !newFolder.standardizedFileURL.path.hasPrefix(from) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }

        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: current.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            for item in contents {
                try mergeMove(item, into: newFolder.appendingPathComponent(item.lastPathComponent))
            }
        }

        // Remember the new folder across launches (sandbox bookmark).
        let data = try newFolder.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        UserDefaults.standard.set(newFolder.path, forKey: defaultsKey)
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        _ = resolvedCustomFolder()
    }

    /// Moves `item` to `destination` without ever deleting what is already
    /// there: folders are merged, and a file that already exists at the
    /// destination is left untouched (the old copy stays where it was).
    private static func mergeMove(_ item: URL, into destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            try fm.moveItem(at: item, to: destination)
            return
        }
        var itemIsDir: ObjCBool = false, destIsDir: ObjCBool = false
        fm.fileExists(atPath: item.path, isDirectory: &itemIsDir)
        fm.fileExists(atPath: destination.path, isDirectory: &destIsDir)
        guard itemIsDir.boolValue, destIsDir.boolValue else { return }
        for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
            try mergeMove(child, into: destination.appendingPathComponent(child.lastPathComponent))
        }
    }

    /// Points back at the default `~/Documents/StoaLibrary` location.
    /// Does not move files back — the custom folder's contents are left
    /// in place, since the user may still want them there.
    static func resetToDefault() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
