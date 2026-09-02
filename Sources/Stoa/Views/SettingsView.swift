import SwiftUI
import AppKit

/// Lets Sam add extra folders to scan beyond the defaults (Documents, Desktop,
/// Downloads), and remove ones she added before. Default folders are always
/// scanned and aren't listed as removable here.
///
/// Deliberately built closer to a native macOS "System Settings" inset list
/// than a dashboard: plain text section labels (no colored icon chips), thin
/// row dividers instead of separate floating cards, minimal shadow. The
/// earlier version leaned on the icon-chip + shadow-card pattern in every
/// section, which is what made it read as templated rather than native.
struct SettingsView: View {
    @EnvironmentObject private var scanner: ScannerService
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var relocateError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(DesignTokens.hairline(colorScheme: colorScheme))

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    group(label: "Always scanned") {
                        VStack(spacing: 0) {
                            ForEach(Array(scanner.defaultFolders.enumerated()), id: \.element) { index, folder in
                                if index > 0 { rowDivider }
                                folderRow(path: folder.path, removable: false, onRemove: {})
                            }
                        }
                    }

                    group(label: "Additional folders") {
                        VStack(spacing: 0) {
                            if scanner.extraFolders.isEmpty {
                                Text("No additional folders yet.")
                                    .font(DesignTokens.sansFont(size: 12.5))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 9)
                                    .padding(.horizontal, DesignTokens.Spacing.md)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(Array(scanner.extraFolders.enumerated()), id: \.element) { index, folder in
                                if index > 0 { rowDivider }
                                folderRow(path: folder.path, removable: true) {
                                    scanner.removeExtraFolder(folder)
                                }
                            }
                            rowDivider
                            addFolderRow
                        }
                    }

                    group(label: "Library") {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text("Rescan")
                                .font(DesignTokens.sansFont(size: 13))
                                .foregroundStyle(.primary)

                            Spacer()

                            if let lastScan = scanner.lastScanDate {
                                Text(lastScan.formatted(date: .abbreviated, time: .shortened))
                                    .font(DesignTokens.sansFont(size: 12))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Not scanned yet")
                                    .font(DesignTokens.sansFont(size: 12))
                                    .foregroundStyle(.tertiary)
                            }

                            rescanButton
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                    }

                    libraryLocationGroup

                    footer
                }
                .padding(.horizontal, DesignTokens.Spacing.xl)
                .padding(.top, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.xl)
            }
        }
        .frame(width: 480, height: 440)
        .background(DesignTokens.background.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(DesignTokens.serifFont(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, 14)
    }

    // MARK: - Group

    /// A plain, small-caps label above a single inset container — the
    /// native macOS System Settings shape, not a shadowed dashboard card.
    private func group<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(DesignTokens.sansFont(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(DesignTokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1)
            )
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(DesignTokens.hairline(colorScheme: colorScheme))
            .padding(.leading, DesignTokens.Spacing.md)
    }

    // MARK: - Folder Row

    private func folderRow(path: String, removable: Bool, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 15)

            Text(path)
                .font(DesignTokens.sansFont(size: 13))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if removable {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    private var addFolderRow: some View {
        Button(action: addFolder) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.accent)
                Text("Add Folder\u{2026}")
                    .font(DesignTokens.sansFont(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Buttons

    private var rescanButton: some View {
        Button {
            // Posts to ContentView rather than calling scanner.scan()
            // directly — scan() alone only refreshes the discovered-file
            // list, it never hashes/classifies/imports anything, so a
            // rescan triggered from here used to silently do nothing
            // useful: the file list would update but no new books would
            // ever reach the library grid.
            NotificationCenter.default.post(name: .stoaRequestFullRescan, object: nil)
        } label: {
            HStack(spacing: 5) {
                if scanner.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("Rescan")
                    .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .background(DesignTokens.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(scanner.isScanning)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Text("Stoa \u{00B7} 1.0.0")
                .font(DesignTokens.serifFont(size: 11, weight: .regular))
                .foregroundStyle(.quaternary)
            Spacer()
        }
        .padding(.top, DesignTokens.Spacing.xs)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"

        if panel.runModal() == .OK, let url = panel.url {
            scanner.addFolder(url)
            NotificationCenter.default.post(name: .stoaRequestFullRescan, object: nil)
        }
    }

    // MARK: - Library Location
    //
    // Where cover art, cached search text, and downloaded books live —
    // separate from the "watched folders" above, which are where Stoa
    // looks for books to import. Pointing this at an iCloud Drive or
    // Google Drive folder lets those extras sync across Macs the way the
    // original plan intended, without any account integration — Finder
    // is already watching that folder. The book list itself (titles,
    // tags, shelves, bookmarks, progress) isn't part of this folder and
    // stays on this Mac.

    private var libraryLocationGroup: some View {
        group(label: "Library Location") {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(library.libraryFolder.path)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, 9)
                .padding(.bottom, 6)

                Text("Cover art, cached search text, and downloaded books live here — point it at a synced folder to carry them across Macs. Your book list, tags, and progress stay on this Mac.")
                    .font(DesignTokens.sansFont(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.bottom, 9)

                if let relocateError {
                    Text(relocateError)
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.red)
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.bottom, 9)
                }

                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Choose Folder…") {
                        chooseLibraryFolder()
                    }
                    .font(DesignTokens.sansFont(size: 12.5))

                    if LibraryLocation.isCustom {
                        Button("Reset to Default") {
                            resetLibraryFolder()
                        }
                        .font(DesignTokens.sansFont(size: 12.5))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, 9)
            }
        }
    }

    private func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try library.relocateLibrary(to: url)
            relocateError = nil
        } catch {
            relocateError = "Couldn't move the library there: \(error.localizedDescription)"
        }
    }

    private func resetLibraryFolder() {
        do {
            try library.relocateLibrary(to: LibraryLocation.defaultFolder)
            LibraryLocation.resetToDefault()
            relocateError = nil
        } catch {
            relocateError = "Couldn't move the library back: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(ScannerService())
        .environmentObject(LibraryStore())
}
