import SwiftUI
import AppKit

/// Lets Sam add extra folders to scan beyond the defaults (Documents, Desktop,
/// Downloads), and remove ones she added before. Default folders are always
/// scanned and aren't listed as removable here.
///
/// Styled to match the rest of the app (DesignTokens) instead of the default
/// system Form look Phase 1 shipped with.
struct SettingsView: View {
    @EnvironmentObject private var scanner: ScannerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    section(title: "Always scanned") {
                        VStack(spacing: 1) {
                            ForEach(scanner.defaultFolders, id: \.self) { folder in
                                folderRow(path: folder.path, removable: false, onRemove: {})
                            }
                        }
                    }

                    section(title: "Additional folders") {
                        VStack(spacing: 1) {
                            if scanner.extraFolders.isEmpty {
                                Text("No additional folders added.")
                                    .font(DesignTokens.sansFont(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, DesignTokens.Spacing.xs)
                            }
                            ForEach(scanner.extraFolders, id: \.self) { folder in
                                folderRow(path: folder.path, removable: true) {
                                    scanner.removeExtraFolder(folder)
                                }
                            }
                        }

                        addFolderButton
                            .padding(.top, DesignTokens.Spacing.sm)
                    }

                    section(title: "Library") {
                        HStack {
                            rescanButton
                            Spacer()
                            if let lastScan = scanner.lastScanDate {
                                Text("Last scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                                    .font(DesignTokens.sansFont(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(DesignTokens.Spacing.xl)
            }
        }
        .frame(width: 480, height: 420)
        .background(DesignTokens.background.ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignTokens.accent)
            Text("Settings")
                .font(DesignTokens.serifFont(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(DesignTokens.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
    }

    // MARK: - Section

    /// 11pt tracked uppercase label above a grouped, hairline-separated card —
    /// same vocabulary as the sidebar's "WATCHED FOLDERS" / "FORMATS" labels.
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.sansFont(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(DesignTokens.Spacing.sm)
            .background(DesignTokens.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
    }

    // MARK: - Folder Row

    private func folderRow(path: String, removable: Bool, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            Text(path)
                .font(DesignTokens.sansFont(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    // MARK: - Buttons

    private var addFolderButton: some View {
        Button(action: addFolder) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("Add Folder\u{2026}")
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
            }
            .foregroundStyle(DesignTokens.accent)
        }
        .buttonStyle(.plain)
    }

    private var rescanButton: some View {
        Button {
            Task { await scanner.scan() }
        } label: {
            HStack(spacing: 6) {
                if scanner.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("Rescan now")
                    .font(DesignTokens.sansFont(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(DesignTokens.accent, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(scanner.isScanning)
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
