import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Tabbed settings: a slim sidebar on the left (General, Library, Reading,
/// About) and a scrolling detail pane on the right. Every control writes
/// straight to its stored value, so there is no Save button.
struct SettingsView: View {
    @EnvironmentObject private var scanner: ScannerService
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppAppearance.storageKey) private var appearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("pagewrit.showDog") private var showDog = true
    @AppStorage(PWAccessibility.textScaleKey) private var textScale: Double = 1
    @AppStorage(PWAccessibility.reduceMotionKey) private var calmMotion = false
    @AppStorage(Wellbeing.breakEveryKey) private var breakEvery = 0
    @AppStorage(Wellbeing.quietDaysKey) private var quietDaysRaw = ""
    @AppStorage(Wellbeing.quietStartKey) private var quietStart = 22 * 60
    @AppStorage(Wellbeing.quietEndKey) private var quietEnd = 7 * 60
    @AppStorage(Wellbeing.easyReadingKey) private var easyReading = false
    @AppStorage("pagewrit.text.size") private var documentTextSize: Double = 17
    @ObservedObject private var readingClock = ReadingTracker.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(DogPet.nameKey) private var dogName = ""
    @AppStorage("pagewrit.hasMetDog") private var hasMetDog = false
    @AppStorage("pagewrit.celebrationSound") private var celebrationSound = true
    @AppStorage("stoa.gridDensity") private var gridDensityRaw: String = GridDensity.comfortable.rawValue
    @AppStorage("stoa.hasSeenOnboarding") private var hasSeenOnboarding = false

    @AppStorage("stoa.readerTheme") private var readerThemeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("stoa.epubFace") private var faceRaw: String = ReaderFace.serif.rawValue
    @AppStorage("stoa.epubFontScale") private var fontScale: Double = 1.0
    @AppStorage("stoa.epubLineHeight") private var lineHeight: Double = 1.65
    @AppStorage("stoa.epubJustify") private var justify: Bool = false
    @AppStorage("stoa.pdfLayout") private var pdfLayoutRaw: String = PDFPageLayout.scroll.rawValue
    @AppStorage("stoa.pdfPageTint") private var pdfTintRaw: String = "original"
    @AppStorage("stoa.cbzFit") private var cbzFitRaw: String = CBZFitMode.page.rawValue
    @AppStorage("stoa.cbzSpread") private var cbzSpread: Bool = false
    @AppStorage("stoa.cbzRightToLeft") private var cbzRTL: Bool = false

    // Remembered, so a change that redraws the window (like text size) keeps your place.
    @AppStorage("pagewrit.settingsTab") private var tab: SettingsTab = .general
    @State private var relocateError: String?
    @AppStorage(ScannerService.downloadCloudKey) private var downloadCloud = true
    @State private var backupMessage: String?
    @State private var backupFailed = false
    @State private var pendingRestoreURL: URL?
    @AppStorage(LibraryStore.autoBackupKey) private var autoBackup = true
    @State private var confirmReset = false

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general, library, reading, wellbeing, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .library: "Library"
            case .reading: "Reading"
            case .wellbeing: "Wellbeing"
            case .about: "About & Privacy"
            }
        }

        var icon: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .library: "books.vertical"
            case .reading: "book"
            case .wellbeing: "heart"
            case .about: "hand.raised"
            }
        }

        var subtitle: String {
            switch self {
            case .general: "How Pagewrit looks and feels."
            case .library: "Where your books come from and live."
            case .reading: "Make every reader comfortable for your eyes."
            case .wellbeing: "Rest your eyes, keep quiet hours, and read in comfort."
            case .about: "Privacy, help and version details."
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(DesignTokens.hairline(colorScheme: colorScheme))
            VStack(spacing: 0) {
                detailHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        switch tab {
                        case .general: generalTab
                        case .library: libraryTab
                        case .reading: readingTab
                        case .wellbeing: wellbeingTab
                        case .about: aboutTab
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.top, 8)
                    .padding(.bottom, DesignTokens.Spacing.xxl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 640, idealWidth: 880, maxWidth: 880, minHeight: 440, idealHeight: 640, maxHeight: 640)
        // Switches and sliders in Pagewrit's teal, not the system blue.
        .tint(DesignTokens.accent)
        .background(DesignTokens.background.ignoresSafeArea())
    }

    /// Settings opens over the library window, not as a sheet, so closing
    /// means clearing the flag; dismiss() covers any other presentation.
    private func close() {
        if library.showSettings {
            library.showSettings = false
        } else {
            dismiss()
        }
    }

    // MARK: - Chrome

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image("PagewritMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Settings")
                    .font(DesignTokens.serifFont(size: 20, weight: .bold))
                    .tracking(-0.3)
            }
            .padding(.horizontal, 10)
            .padding(.top, 26)
            .padding(.bottom, 22)

            ForEach(SettingsTab.allCases) { item in
                let selected = tab == item
                Button { tab = item } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selected ? DesignTokens.accentInk : Color.secondary)
                            .frame(width: 20)
                        Text(item.title)
                            .font(DesignTokens.sansFont(size: 13.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? DesignTokens.accent.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 3) {
                Text("\(AppInfo.name) \(AppInfo.version)")
                    .font(DesignTokens.sansFont(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Image(systemName: "heart.fill").font(.system(size: 9))
                    Text("Built with love")
                }
                .font(DesignTokens.sansFont(size: 11.5))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 14)
        .frame(width: 236)
        .background(DesignTokens.surface)
    }

    private var detailHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(tab.title)
                    .font(DesignTokens.serifFont(size: 32, weight: .bold))
                    .tracking(-0.8)
                Text(tab.subtitle)
                    .font(DesignTokens.sansFont(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { close() } label: {
                Text("Done")
                    .frame(minWidth: 58)
            }
            .buttonStyle(.pw(.primary, size: .regular))
            .help("Close settings (Esc)")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: - General

    private var generalTab: some View {
        Group {
            group(label: "Appearance", footnote: "System follows your Mac's light or dark setting.") {
                HStack(spacing: 12) {
                    ForEach(AppAppearance.allCases) { option in
                        appearanceCard(option)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }

            group(label: "Cover size", footnote: "How big book covers appear in your library.") {
                HStack(spacing: 12) {
                    ForEach(GridDensity.allCases) { density in
                        densityCard(density)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }

            group(label: "Accessibility", footnote: "Every button, cover and list in Pagewrit has a VoiceOver label. On a book cover, the VoiceOver actions menu also offers Show details and Favourite. Readers use their own text size in Display.") {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow("Text size", detail: "Makes the words in the library, sidebar and panels bigger.") {
                        PWSegmented(selection: $textScale,
                                    options: PWAccessibility.TextSize.allCases.map { ($0.label, $0.rawValue) })
                            .accessibilityLabel("Text size")
                    }
                    rowDivider
                    settingRow("Calm motion", detail: "Turns off the dog's movement, confetti, hover lifts and slides. Your Mac's Reduce Motion setting does this too.") {
                        Toggle("", isOn: $calmMotion).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Calm motion")
                    }
                    rowDivider
                    settingRow("Keyboard", detail: "Everything works from the keyboard. Tab moves between controls when Keyboard navigation is on in System Settings.") {
                        Button("Show Shortcuts") { openWindow(id: "shortcuts") }
                            .buttonStyle(.pw(.neutral, size: .regular))
                    }
                }
            }

            group(label: "Library dog", footnote: "The dog who lives in your sidebar.") {
                settingRow("Show the dog") {
                    Toggle("", isOn: $showDog).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Show the dog")
                }
                settingRow("Name", detail: "He answers to it in the sidebar.") {
                    TextField("No name yet", text: $dogName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onChange(of: dogName) { _, new in
                            if new.count > 24 { dogName = String(new.prefix(24)) }
                        }
                }
                settingRow("Celebration sound", detail: "A soft chime when you reach your goal or finish a book.") {
                    Toggle("", isOn: $celebrationSound).labelsHidden().toggleStyle(.switch)
                        .accessibilityLabel("Celebration sound")
                }
                settingRow("Introduce him again", detail: "Shows the meet the dog screen next time you open Pagewrit.") {
                    Button("Reset") { hasMetDog = false }
                        .buttonStyle(.pw(.neutral, size: .regular))
                }
            }

            group(label: "Welcome") {
                settingRow("Show the welcome tour again", detail: "Replays the intro on next launch.") {
                    Button("Reset") { hasSeenOnboarding = false }
                        .buttonStyle(.pw(.neutral, size: .regular))
                }
            }
        }
    }

    private func densityCard(_ density: GridDensity) -> some View {
        let selected = gridDensityRaw == density.rawValue
        let columns: Int
        switch density {
        case .compact: columns = 5
        case .comfortable: columns = 4
        case .large: columns = 3
        }
        return Button { gridDensityRaw = density.rawValue } label: {
            VStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(DesignTokens.accent.opacity(0.35 + 0.1 * Double(i % 3)))
                            .aspectRatio(0.68, contentMode: .fit)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .frame(height: 76)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? DesignTokens.accent : Color.clear, lineWidth: 2.5)
                )
                Text(density.displayName)
                    .font(DesignTokens.sansFont(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DesignTokens.accent : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func appearanceCard(_ option: AppAppearance) -> some View {
        let selected = appearanceRaw == option.rawValue
        return Button { appearanceRaw = option.rawValue } label: {
            VStack(spacing: 8) {
                appearancePreview(option)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selected ? DesignTokens.accent : DesignTokens.hairline(colorScheme: colorScheme),
                                    lineWidth: selected ? 2.5 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white, DesignTokens.accent)
                                .padding(6)
                        }
                    }
                Text(option.label)
                    .font(DesignTokens.sansFont(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DesignTokens.accent : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onChange(of: appearanceRaw) { _, new in
            (AppAppearance(rawValue: new) ?? .system).apply()
        }
    }

    @ViewBuilder
    private func appearancePreview(_ option: AppAppearance) -> some View {
        switch option {
        case .light: miniWindow(dark: false)
        case .dark: miniWindow(dark: true)
        case .system:
            HStack(spacing: 0) {
                miniWindow(dark: false)
                miniWindow(dark: true)
            }
        }
    }

    private func miniWindow(dark: Bool) -> some View {
        let bg = dark ? Color(white: 0.10) : Color(white: 0.97)
        let bar = dark ? Color(white: 0.20) : Color(white: 0.88)
        let ink = dark ? Color(white: 0.55) : Color(white: 0.6)
        return ZStack(alignment: .topLeading) {
            bg
            HStack(alignment: .top, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(bar).frame(width: 14)
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(DesignTokens.accent).frame(width: 26, height: 5)
                    RoundedRectangle(cornerRadius: 2).fill(ink).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(ink.opacity(0.6)).frame(width: 34, height: 4)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Library

    private var libraryTab: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(library.books.count) books from \(scanner.allWatchedFolders.count) folders")
                    .font(DesignTokens.serifFont(size: 24, weight: .bold))
                    .tracking(-0.4)
                HStack(spacing: 14) {
                    Text(scanner.lastScanDate.map { "Last scanned \($0.formatted(.relative(presentation: .named)))" } ?? "Not scanned yet")
                        .font(DesignTokens.sansFont(size: 13))
                        .foregroundStyle(.secondary)
                    rescanButton
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)

            group(label: "Watched folders") {
                VStack(spacing: 0) {
                    ForEach(Array(scanner.defaultFolders.enumerated()), id: \.element) { index, folder in
                        if index > 0 { rowDivider }
                        folderRow(url: folder, removable: false)
                    }
                    ForEach(Array(scanner.extraFolders.enumerated()), id: \.element) { index, folder in
                        if index > 0 || !scanner.defaultFolders.isEmpty { rowDivider }
                        folderRow(url: folder, removable: true)
                    }
                    if !scanner.allWatchedFolders.isEmpty { rowDivider }
                    addFolderRow
                }
            }

            group(label: "Cloud", footnote: "Books in iCloud Drive work straight away. For Google Drive, install the free Google Drive for desktop app first, then add your My Drive or a folder inside it. Pagewrit reads the copies on your Mac and never signs in to your accounts.") {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow("iCloud Drive", detail: "Add your whole iCloud Drive or just a Books folder in it.") {
                        Button {
                            if scanner.addCloudFolder(.iCloudDrive) { Task { await scanner.scan() } }
                        } label: {
                            Label("Add iCloud Drive\u{2026}", systemImage: "icloud")
                        }
                        .buttonStyle(.pw(.neutral, size: .regular))
                    }
                    rowDivider
                    settingRow("Google Drive", detail: "Uses the Google Drive for desktop app on this Mac.") {
                        HStack(spacing: 8) {
                            textLink("Get the app") {
                                if let url = URL(string: "https://www.google.com/drive/download/") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            Button {
                                if scanner.addCloudFolder(.googleDrive) { Task { await scanner.scan() } }
                            } label: {
                                Label("Add Google Drive\u{2026}", systemImage: "cloud")
                            }
                            .buttonStyle(.pw(.neutral, size: .regular))
                        }
                    }
                    rowDivider
                    settingRow("Download cloud books", detail: cloudDetail) {
                        Toggle("", isOn: $downloadCloud).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Download cloud books")
                    }
                }
            }

            group(label: "Storage") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(library.libraryFolder.path)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(library.libraryFolder.path)
                    if let relocateError {
                        Text(relocateError)
                            .font(DesignTokens.sansFont(size: 11.5))
                            .foregroundStyle(.red)
                    }
                    HStack(spacing: 14) {
                        textLink("Change\u{2026}") { chooseLibraryFolder() }
                        textLink("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([library.libraryFolder])
                        }
                        if LibraryLocation.isCustom {
                            textLink("Reset") { resetLibraryFolder() }
                        }
                        Spacer(minLength: 0)
                    }
                    Text("Covers, search text and downloads. Book list, tags and progress stay on this Mac.")
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, DesignTokens.Spacing.md)
            }

            group(label: "Backup", footnote: "A backup holds your ratings, favourites, tags, shelves, series, progress, highlights, notes, bookmarks, chosen covers and settings. Your book files stay where they are. Restoring adds to what you have and never deletes anything.") {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow("Back up now", detail: "Save a backup file anywhere you like, such as iCloud Drive or a USB drive.") {
                        Button("Back Up\u{2026}") { backUpNow() }
                            .buttonStyle(.pw(.primary, size: .regular))
                    }
                    rowDivider
                    settingRow("Restore", detail: "Bring back everything from a backup file. Books not on this Mac yet get their details as soon as they are found.") {
                        Button("Restore\u{2026}") { chooseBackupToRestore() }
                            .buttonStyle(.pw(.neutral, size: .regular))
                    }
                    rowDivider
                    settingRow("Weekly backup", detail: weeklyDetail) {
                        Toggle("", isOn: $autoBackup).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Weekly backup")
                    }
                    if let backupMessage {
                        HStack(spacing: 8) {
                            Image(systemName: backupFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(backupFailed ? DesignTokens.accentSecondary : DesignTokens.accent)
                            Text(backupMessage)
                                .font(DesignTokens.sansFont(size: 12.5))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.md)
                        .padding(.vertical, 10)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .alert("Restore this backup?", isPresented: Binding(
                get: { pendingRestoreURL != nil },
                set: { if !$0 { pendingRestoreURL = nil } }
            )) {
                Button("Restore") {
                    if let url = pendingRestoreURL { restore(from: url) }
                    pendingRestoreURL = nil
                }
                Button("Cancel", role: .cancel) { pendingRestoreURL = nil }
            } message: {
                Text("Details from the backup are added to your library. Nothing you have now is removed.")
            }
        }
    }

    private var weeklyDetail: String {
        var text = "Keeps the five newest copies in your library folder."
        if let last = library.lastAutoBackup {
            text += " Last one \(last.formatted(.relative(presentation: .named)))."
        }
        return text
    }

    private func backUpNow() {
        let panel = NSSavePanel()
        panel.title = "Back Up Pagewrit"
        panel.nameFieldStringValue = LibraryStore.suggestedBackupName()
        panel.allowedContentTypes = [UTType(filenameExtension: LibraryStore.backupExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.writeBackup(to: url)
            backupFailed = false
            backupMessage = "Backed up \(library.books.count) books to \(url.lastPathComponent)."
            Haptics.tick()
        } catch {
            backupFailed = true
            backupMessage = "Could not save the backup. \(error.localizedDescription)"
        }
    }

    private func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Pagewrit Backup"
        panel.allowedContentTypes = [UTType(filenameExtension: LibraryStore.backupExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.directoryURL = library.backupsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingRestoreURL = url
    }

    private func restore(from url: URL) {
        do {
            let result = try library.restoreBackup(from: url)
            backupFailed = false
            var parts = ["Restored details for \(result.matched) \(result.matched == 1 ? "book" : "books")"]
            if result.highlights > 0 { parts.append("\(result.highlights) highlights") }
            if result.bookmarks > 0 { parts.append("\(result.bookmarks) bookmarks") }
            var text = parts.joined(separator: ", ") + "."
            if result.waiting > 0 {
                text += " \(result.waiting) more will be filled in when those files are found."
            }
            backupMessage = text
            Haptics.tick()
        } catch {
            backupFailed = true
            backupMessage = error.localizedDescription
        }
    }

    private func textLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
                .foregroundStyle(DesignTokens.accent)
        }
        .buttonStyle(.plain)
    }

    private var cloudDetail: String {
        var text = "Books stored only in the cloud are downloaded so you can read them offline. Files over 250 MB wait until you open them."
        if scanner.cloudDownloadsWaiting > 0 {
            text += " \(scanner.cloudDownloadsWaiting) still downloading."
        }
        return text
    }

    private func folderRow(url: URL, removable: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: ScannerService.icon(for: url))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(ScannerService.displayName(for: url))
                .font(DesignTokens.sansFont(size: 13, weight: .medium))
            Text(ScannerService.locationText(for: url))
                .font(DesignTokens.sansFont(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            if removable {
                Button { scanner.removeExtraFolder(url) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Stop watching this folder")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    private var addFolderRow: some View {
        Button(action: addFolder) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignTokens.accent)
                    .frame(width: 18)
                Text("Add Folder\u{2026}")
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.accent)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var rescanButton: some View {
        Button {
            NotificationCenter.default.post(name: .stoaRequestFullRescan, object: nil)
        } label: {
            HStack(spacing: 6) {
                if scanner.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(scanner.isScanning ? "Scanning\u{2026}" : "Rescan")
                    .font(DesignTokens.sansFont(size: 12.5, weight: .medium))
            }
            .foregroundStyle(DesignTokens.accent)
        }
        .buttonStyle(.plain)
        .disabled(scanner.isScanning)
    }

    // MARK: - Reading

    private var readingPreview: some View {
        let theme = ReaderTheme(rawValue: readerThemeRaw) ?? .system
        let palette = theme.palette(for: colorScheme)
        let face = ReaderFace(rawValue: faceRaw) ?? .serif
        let design: Font.Design = face == .sans ? .default : .serif
        let size = 15 * fontScale
        return VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(DesignTokens.sansFont(size: 11.5, weight: .medium))
                .foregroundStyle(Color(nsColor: palette.secondary))
            Text("Chapter One")
                .font(.system(size: size * 1.35, weight: .bold, design: design))
            Text("It was a bright, cold day in April, and the clocks were striking thirteen. A good book is a quiet room you can walk into any time you like.")
                .font(.system(size: size, design: design))
                .lineSpacing(max(0, (lineHeight - 1.2) * size))
        }
        .foregroundStyle(Color(nsColor: palette.text))
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.background), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignTokens.hairline(colorScheme: colorScheme), lineWidth: 1)
        )
    }

    private var readingTab: some View {
        Group {
            readingPreview

            group(label: "All readers") {
                settingRow("Background", detail: "Auto follows the app appearance.") {
                    PWSegmented(selection: $readerThemeRaw,
                                options: ReaderTheme.allCases.map { ($0.label, $0.rawValue) }, width: 280)
                        .accessibilityLabel("Background")
                }
            }

            group(label: "Books (EPUB)") {
                VStack(spacing: 0) {
                    settingRow("Typeface") {
                        PWSegmented(selection: $faceRaw,
                                    options: ReaderFace.allCases.map { ($0.label, $0.rawValue) }, width: 280)
                            .accessibilityLabel("Typeface")
                    }
                    rowDivider
                    settingRow("Text size", detail: "\(Int((fontScale * 100).rounded()))%") {
                        Slider(value: $fontScale, in: 0.7...1.8, step: 0.05)
                            .frame(width: 200)
                    }
                    rowDivider
                    settingRow("Line spacing", detail: String(format: "%.2f", lineHeight)) {
                        Slider(value: $lineHeight, in: 1.3...2.0, step: 0.05)
                            .frame(width: 200)
                    }
                    rowDivider
                    settingRow("Justify text") {
                        Toggle("", isOn: $justify).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Justify text")
                    }
                }
            }

            group(label: "Documents (PDF)") {
                VStack(spacing: 0) {
                    settingRow("Page layout") {
                        PWSegmented(selection: $pdfLayoutRaw,
                                    options: PDFPageLayout.allCases.map { ($0.label, $0.rawValue) }, width: 280)
                            .accessibilityLabel("Page layout")
                    }
                    rowDivider
                    settingRow("Page colour", detail: "Original leaves the PDF untouched.") {
                        PWSegmented(selection: $pdfTintRaw,
                                    options: [("Original", "original"), ("Sepia", "sepia"), ("Inverted", "invert")],
                                    width: 280)
                            .accessibilityLabel("Page colour")
                    }
                }
            }

            group(label: "Comics (CBZ)") {
                VStack(spacing: 0) {
                    settingRow("Fit") {
                        PWSegmented(selection: $cbzFitRaw,
                                    options: CBZFitMode.allCases.map { ($0.label, $0.rawValue) }, width: 280)
                            .accessibilityLabel("Fit")
                    }
                    rowDivider
                    settingRow("Two-page spread") {
                        Toggle("", isOn: $cbzSpread).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Two-page spread")
                    }
                    rowDivider
                    settingRow("Right-to-left (manga)") {
                        Toggle("", isOn: $cbzRTL).labelsHidden().toggleStyle(.switch)
                            .accessibilityLabel("Right-to-left (manga)")
                    }
                }
            }

            HStack {
                Spacer()
                Button { confirmReset = true } label: {
                    Label("Restore reading defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.pw(.ghost, size: .regular))
            }
            .confirmationDialog("Restore reading defaults?", isPresented: $confirmReset) {
                Button("Restore", role: .destructive) { resetReadingDefaults() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Resets reader theme, typeface, sizes, PDF and comic options. Your books and progress are not affected.")
            }
        }
    }

    private func resetReadingDefaults() {
        readerThemeRaw = ReaderTheme.system.rawValue
        faceRaw = ReaderFace.serif.rawValue
        fontScale = 1.0
        lineHeight = 1.65
        justify = false
        pdfLayoutRaw = PDFPageLayout.scroll.rawValue
        pdfTintRaw = "original"
        cbzFitRaw = CBZFitMode.page.rawValue
        cbzSpread = false
        cbzRTL = false
    }

    // MARK: - About

    private var aboutTab: some View {
        Group {
            group(label: "Privacy") {
                Text(AppInfo.privacySummary)
                    .font(DesignTokens.sansFont(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DesignTokens.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            group(label: "Help") {
                VStack(spacing: 0) {
                    if AppInfo.hasSupportContact {
                        linkRow("Contact support", icon: "envelope") { AppInfo.contactSupport() }
                        rowDivider
                    }
                    linkRow("Copy diagnostic info", icon: "doc.on.doc") { AppInfo.copyDiagnostics() }
                }
            }

            group(label: "Version") {
                settingRow("\(AppInfo.name)", detail: AppInfo.diagnostics) { EmptyView() }
            }
        }
    }

    private func linkRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: icon)
                    .foregroundStyle(DesignTokens.accent)
                    .frame(width: 20)
                Text(title)
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Building blocks

    private func group<Content: View>(
        label: String,
        footnote: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(DesignTokens.sansFont(size: 15, weight: .semibold))
                .padding(.leading, DesignTokens.Spacing.md)
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let footnote {
                Text(footnote)
                    .font(DesignTokens.sansFont(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, DesignTokens.Spacing.md)
            }
        }
    }

    private func settingRow<Trailing: View>(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(DesignTokens.sansFont(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, DesignTokens.Spacing.md)
    }

    private var rowDivider: some View {
        Divider()
            .overlay(DesignTokens.hairline(colorScheme: colorScheme))
            .padding(.leading, DesignTokens.Spacing.md)
    }

    // MARK: - Actions

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


// MARK: - Wellbeing

extension SettingsView {
    private static let breakChoices = [0, 20, 30, 45, 60, 90]
    private static let dayLetters: [(day: Int, letter: String, name: String)] = [
        (1, "S", "Sunday"), (2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"),
        (5, "T", "Thursday"), (6, "F", "Friday"), (7, "S", "Saturday")
    ]

    var wellbeingTab: some View {
        Group {
            group(label: "Time and focus") {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow("Break reminders", detail: "A calm card after a stretch of reading, reminding you to rest your eyes. Stepping away resets it.") {
                        Picker("Break reminders", selection: $breakEvery) {
                            ForEach(Self.breakChoices, id: \.self) { minutes in
                                Text(minutes == 0 ? "Off" : "Every \(readingMinutesText(minutes, short: true))").tag(minutes)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    rowDivider
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Quiet hours")
                                .font(DesignTokens.sansFont(size: 13, weight: .medium))
                            Text("On the days you pick, Pagewrit goes quiet between these times: no sounds or nudges, and one gentle reminder to wind down if you are still reading.")
                                .font(DesignTokens.sansFont(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            ForEach(Self.dayLetters, id: \.day) { entry in
                                dayButton(entry.day, letter: entry.letter, name: entry.name)
                            }
                            Spacer(minLength: 12)
                            DatePicker("From", selection: minutesBinding($quietStart), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .accessibilityLabel("Quiet hours start")
                                .disabled(quietDaysRaw.isEmpty)
                            Text("to")
                                .font(DesignTokens.sansFont(size: 12.5))
                                .foregroundStyle(.secondary)
                            DatePicker("To", selection: minutesBinding($quietEnd), displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .accessibilityLabel("Quiet hours end")
                                .disabled(quietDaysRaw.isEmpty)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                }
            }

            group(label: "Comfort", footnote: "Easy reading is a good place to start if small text or busy screens are tiring. Change any part of it later in General and Reading.") {
                VStack(alignment: .leading, spacing: 0) {
                    settingRow("Easy reading", detail: "Bigger words everywhere, larger text and roomier lines in books, and calm motion with nothing sliding around.") {
                        Toggle("", isOn: Binding(
                            get: { easyReading },
                            set: { applyEasyReading($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Easy reading")
                    }
                    rowDivider
                    settingRow("Warmer screen at night", detail: "Your Mac can shift its colours warmer in the evening, which is gentler on the eyes. macOS calls this Night Shift.") {
                        Button("Open Night Shift") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.pw(.neutral, size: .regular))
                    }
                    rowDivider
                    settingRow("Listen instead", detail: "Any book can be read aloud. Choose Listen at the top of the reader, and select a sentence first to start from there.") {
                        EmptyView()
                    }
                }
            }

            group(label: "Reflect", footnote: "All of this stays on this Mac.") {
                HStack(spacing: 10) {
                    statTile(readingMinutesText(Int(readingClock.weekSeconds / 60), short: true), "this week")
                    statTile(readingMinutesText(Int(readingClock.weekSeconds / 60 / 7), short: true), "a day on average")
                    statTile("\(readingClock.longestStreak) \(readingClock.longestStreak == 1 ? "day" : "days")", "longest streak")
                    statTile("\(readingClock.daysRead)", readingClock.daysRead == 1 ? "day of reading" : "days of reading")
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, 6)
            }
        }
    }

    private func dayButton(_ day: Int, letter: String, name: String) -> some View {
        let on = quietDaysRaw.contains(String(day))
        return Button {
            var days = Set(quietDaysRaw.map(String.init))
            if on { days.remove(String(day)) } else { days.insert(String(day)) }
            quietDaysRaw = days.sorted().joined()
            Haptics.tick()
        } label: {
            Text(letter)
                .font(DesignTokens.sansFont(size: 12.5, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                .frame(width: 30, height: 30)
                .background(Circle().fill(on ? DesignTokens.accent : Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(DesignTokens.serifFont(size: 18, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(DesignTokens.sansFont(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }

    /// Minutes after midnight, shown in a time picker.
    private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minutes.wrappedValue / 60,
                                      minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let cal = Calendar.current
                minutes.wrappedValue = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
            }
        )
    }

    /// One switch for people who find small text and motion tiring.
    private func applyEasyReading(_ on: Bool) {
        easyReading = on
        textScale = on ? PWAccessibility.TextSize.larger.rawValue : PWAccessibility.TextSize.standard.rawValue
        calmMotion = on
        fontScale = on ? 1.3 : 1.0
        lineHeight = on ? 1.9 : 1.65
        documentTextSize = on ? 21 : 17
    }
}
