import Foundation

/// Single source of truth for where Athenaeum's on-disk library extras —
/// cover images, cached full-text search index, and downloaded books —
/// live. Defaults to `~/Documents/AthenaeumLibrary`, but the user can point it
/// at any folder from Settings, typically one already synced by iCloud
/// Drive or Google Drive: Athenaeum doesn't integrate with either service
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

    /// The folder currently in use. Falls back to the default location if
    /// nothing's been chosen, or if a previously chosen folder can no
    /// longer be found (an external or not-yet-mounted cloud folder).
    static var folder: URL {
        if let path = UserDefaults.standard.string(forKey: defaultsKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        return defaultFolder
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AthenaeumLibrary", isDirectory: true)
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

        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: current.path) {
            let contents = try FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: nil)
            for item in contents {
                let destination = newFolder.appendingPathComponent(item.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: item, to: destination)
            }
        }

        UserDefaults.standard.set(newFolder.path, forKey: defaultsKey)
    }

    /// Points back at the default `~/Documents/AthenaeumLibrary` location.
    /// Does not move files back — the custom folder's contents are left
    /// in place, since the user may still want them there.
    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
