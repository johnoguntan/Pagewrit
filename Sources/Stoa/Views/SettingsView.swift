import SwiftUI
import AppKit

/// Lets Sam add extra folders to scan beyond the defaults (Documents, Desktop,
/// Downloads), and remove ones she added before. Default folders are always
/// scanned and aren't listed as removable here.
///
/// Styled to match the rest of the app (DesignTokens): elevated cards on a
/// near-black surface, icon-accented section headers, real (not
/// imperceptible) elevation contrast — see DesignTokens.elevatedSurface.
struct SettingsView: View {
    @EnvironmentObject private var scanner: ScannerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                section(title: "Always scanned", icon: "checkmark.circle.fill", tint: DesignTokens.accent) {
                    VStack(spacing: 2) {
                        ForEach(scanner.defaultFolders, id: \.self) { folder in
                            folderRow(path: folder.path, removable: false, onRemove: {})
                        }
                    }
                }

                section(title: "Additional folders", icon: "folder.badge.plus", tint: DesignTokens.formatColor(for: .cbz)) {
                    VStack(spacing: 2) {
                        if scanner.extraFolders.isEmpty {
                            Text("No additional folders yet — add one below to widen the scan.")
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

                section(title: "Library", icon: "arrow.triangle.2.circlepath", tint: DesignTokens.formatColor(for: .epub)) {
                    HStack {
                        rescanButton
                        Spacer()
                        if let lastScan = scanner.lastScanDate {
                            Text("Last scanned \(lastScan.formatted(date: .abbreviated, time: .shortened))")
                                .font(DesignTokens.sansFont(size: 12))
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Not scanned yet")
                                .font(DesignTokens.sansFont(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(DesignTokens.Spacing.xl)
        }
        .frame(width: 520, height: 460)
        .background(DesignTokens.background.ignoresSafeArea())
    }

    // MARK: - Section

    /// Icon-accented label above a grouped, elevated card. The icon chip
    /// gives each section a small, distinct identity at a glance instead of
    /// three visually-identical gray blocks.
    private func section<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20, height: 20)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

                Text(title)
                    .font(DesignTokens.sansFont(size: 12, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1)
            )
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.30 : 0.04),
                radius: 14, x: 0, y: 4
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
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
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
