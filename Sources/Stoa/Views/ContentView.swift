import SwiftUI
import Foundation

// MARK: - ContentView

/// Library grid view with warm, luxurious palette and serif-accented typography.
/// All values sourced from DesignTokens.
struct ContentView: View {
    @EnvironmentObject private var scanner: ScannerService
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""
    @State private var selectedFileID: String?

    // MARK: - Computed data

    /// Files scoped by the sidebar selection (a format, a watched folder, or
    /// "All Books" when nil), then further narrowed by the search field.
    private var filteredFiles: [DiscoveredFile] {
        var files = scanner.discoveredFiles

        if let selectedFileID {
            if let format = BookFormat(rawValue: selectedFileID) {
                // A "Formats" row was picked.
                files = files.filter { $0.format == format }
            } else {
                // A "Watched Folders" row was picked — its tag is the folder's
                // path. Match files that live inside that folder (recursively).
                let folderPath = selectedFileID.hasSuffix("/") ? selectedFileID : selectedFileID + "/"
                files = files.filter { $0.url.path.hasPrefix(folderPath) }
            }
        }

        guard !searchText.isEmpty else { return files }
        return files.filter {
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var booksByFormat: [(title: String, files: [DiscoveredFile])] {
        let grouped = Dictionary(grouping: filteredFiles) { $0.format }
        return BookFormat.allCases.compactMap { format in
            guard let files = grouped[format], !files.isEmpty else { return nil }
            return (format.sectionTitle, files)
        }
    }

    /// Most recently modified file across the whole library, for the hero band.
    /// Independent of search/filter — this is a "welcome back" spotlight, not
    /// a search result.
    private var mostRecentFile: DiscoveredFile? {
        scanner.discoveredFiles.max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
    }

    // MARK: - Grid layout

    private let columns = [
        GridItem(
            .adaptive(minimum: DesignTokens.Grid.columnMinimum),
            spacing: DesignTokens.Grid.spacing
        )
    ]

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .navigationTitle("Library")
        .navigationDestination(for: DiscoveredFile.self) { file in
            BookDetailView(file: file)
        }
        .searchable(text: $searchText, prompt: "Search books")
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
        .tint(DesignTokens.accent)
        .background(DesignTokens.background.ignoresSafeArea())
        .task {
            if scanner.discoveredFiles.isEmpty {
                await scanner.scan()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedFileID) {
            // App mark + Library row
            Section {
                sidebarRow(
                    title: "All Books",
                    icon: "books.vertical",
                    isSelected: selectedFileID == nil
                )
                .tag(nil as String?)
            }

            Section(header: sidebarSectionLabel("WATCHED FOLDERS")) {
                ForEach(scanner.allWatchedFolders, id: \.self) { folder in
                    sidebarRow(
                        title: folder.lastPathComponent,
                        icon: "folder",
                        isSelected: selectedFileID == folder.path
                    )
                    .tag(folder.path)
                }
            }

            Section(header: sidebarSectionLabel("FORMATS")) {
                ForEach(BookFormat.allCases, id: \.self) { format in
                    sidebarRow(
                        title: format.sectionTitle,
                        icon: format.systemImage,
                        isSelected: selectedFileID == format.rawValue
                    )
                    .tag(format.rawValue)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DesignTokens.surface.ignoresSafeArea())
        .safeAreaInset(edge: .top) {
            sidebarAppMark
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.xxs)
        }
        .frame(width: DesignTokens.Sidebar.width)
    }

    // MARK: - Sidebar App Mark

    /// 28x28 rounded-square filled with accent, containing a book SF Symbol,
    /// next to "Stoa" in serif at ~17pt semibold.
    private var sidebarAppMark: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(
                    width: DesignTokens.Sidebar.AppMark.size,
                    height: DesignTokens.Sidebar.AppMark.size
                )
                .background(DesignTokens.accent)
                .clipShape(RoundedRectangle(
                    cornerRadius: DesignTokens.Sidebar.AppMark.cornerRadius
                ))

            Text("Stoa")
                .font(DesignTokens.serifFont(
                    size: DesignTokens.Sidebar.AppMark.titleSize,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)

            Spacer()
        }
    }

    // MARK: - Sidebar Row

    private func sidebarRow(title: String, icon: String, isSelected: Bool) -> some View {
        HStack(spacing: DesignTokens.Sidebar.iconLabelGap) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.Sidebar.fontSize, weight: .medium))
                .frame(width: 16)
            Text(title)
                .font(.system(size: DesignTokens.Sidebar.fontSize))
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundColor(isSelected ? DesignTokens.accent : .primary)
            Spacer()
        }
        .padding(.vertical, DesignTokens.Sidebar.rowPaddingV)
        .padding(.horizontal, DesignTokens.Sidebar.rowPaddingH)
        .background(
            isSelected
                ? DesignTokens.accent.opacity(0.12)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowCornerRadius))
    }

    // MARK: - Sidebar Section Label

    /// 11pt, .semibold, positive tracking, .tertiary, uppercase
    private func sidebarSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(DesignTokens.sansFont(
                size: DesignTokens.Sidebar.SectionLabel.fontSize,
                weight: .semibold
            ))
            .tracking(DesignTokens.Sidebar.SectionLabel.tracking)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    // MARK: - Detail Content

    private var detailContent: some View {
        VStack(spacing: 0) {
            if scanner.isScanning {
                ProgressView("Scanning\u{2026}")
                    .padding(.vertical, DesignTokens.Spacing.lg)
            }

            if let error = scanner.lastScanError {
                Text(error)
                    .foregroundStyle(.red)
                    .padding(.vertical, DesignTokens.Spacing.lg)
            }

            if filteredFiles.isEmpty && !scanner.isScanning {
                emptyState
            } else {
                ScrollView {
                    if searchText.isEmpty, let mostRecent = mostRecentFile {
                        HeroBand(file: mostRecent)
                            .padding(.horizontal, DesignTokens.Spacing.xl)
                            .padding(.top, DesignTokens.Spacing.lg)
                    }

                    LazyVGrid(columns: columns, spacing: DesignTokens.Grid.spacing) {
                        ForEach(booksByFormat, id: \.title) { section in
                            Section {
                                ForEach(section.files) { file in
                                    NavigationLink(value: file) {
                                        BookCoverTile(file: file)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } header: {
                                sectionHeader(
                                    section.title,
                                    count: section.files.count
                                )
                            }
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                    .padding(.top, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.xxl)
                }
            }
        }
    }

    // MARK: - Section Header

    /// 26pt serif .bold, tight tracking, .primary, trailing count in 13pt .tertiary
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(title)
                .font(DesignTokens.serifFont(
                    size: DesignTokens.SectionHeader.fontSize,
                    weight: .bold
                ))
                .tracking(DesignTokens.SectionHeader.tracking)
                .foregroundStyle(.primary)

            Text("\(count)")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.SectionHeader.Count.fontSize
                ))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(.top, DesignTokens.Spacing.lg)
        .padding(.bottom, DesignTokens.Spacing.xxs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)

            Text("No Books Found")
                .font(DesignTokens.serifFont(size: 20, weight: .semibold))

            Text("Click Rescan to search your Documents, Desktop, and Downloads folders.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - HeroBand

/// Full-width spotlight above the grid: the single "recently added" book, big.
/// Once Phase 3 adds reading-progress tracking this becomes a "Continue
/// Reading" variant (progress bar + Resume) for the last-opened book instead
/// of the last-added one — same shape, different data source.
struct HeroBand: View {
    let file: DiscoveredFile
    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        file.url.deletingPathExtension().lastPathComponent
    }

    private var relativeAdded: String {
        guard let date = file.modifiedAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius)
                .fill(DesignTokens.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius)
                        .stroke(.primary.opacity(0.08), lineWidth: 1)
                )

            // The one "wow" moment on this screen — a single soft accent glow.
            // Deliberately not repeated anywhere else on the page.
            RadialGradient(
                colors: [DesignTokens.accent.opacity(DesignTokens.Hero.glowOpacity), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 340
            )
            .allowsHitTesting(false)

            HStack(alignment: .center, spacing: DesignTokens.Spacing.xl) {
                MattedCoverView(file: file, cornerRadius: 10)
                    .frame(width: DesignTokens.Hero.coverWidth)
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.5 : 0.25),
                        radius: 16, x: 0, y: 10
                    )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recently added")
                        .font(DesignTokens.sansFont(
                            size: DesignTokens.Hero.Eyebrow.fontSize,
                            weight: .semibold
                        ))
                        .tracking(DesignTokens.Hero.Eyebrow.tracking)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)

                    Text(title)
                        .font(DesignTokens.serifFont(
                            size: DesignTokens.Hero.Title.fontSize,
                            weight: .semibold
                        ))
                        .tracking(DesignTokens.Hero.Title.tracking)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text("\(file.format.rawValue.uppercased()) \u{00b7} \(relativeAdded)")
                        .font(DesignTokens.sansFont(size: DesignTokens.Hero.Meta.fontSize))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, DesignTokens.Spacing.xs)

                    Button {
                        NSWorkspace.shared.open(file.url)
                    } label: {
                        Text("Open")
                            .font(DesignTokens.sansFont(
                                size: DesignTokens.Hero.Button.fontSize,
                                weight: .semibold
                            ))
                            .foregroundStyle(.white)
                            .padding(.vertical, DesignTokens.Hero.Button.paddingV)
                            .padding(.horizontal, DesignTokens.Hero.Button.paddingH)
                            .background(
                                DesignTokens.accent,
                                in: RoundedRectangle(cornerRadius: DesignTokens.Hero.Button.cornerRadius)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: DesignTokens.Hero.height)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Hero.cornerRadius))
    }
}

// MARK: - BookCoverTile

/// Single cover-art tile in the library grid.
struct BookCoverTile: View {
    let file: DiscoveredFile
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var title: String {
        file.url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            MattedCoverView(file: file)
                .shadow(
                    color: DesignTokens.Shadow.tight(colorScheme: colorScheme).color,
                    radius: DesignTokens.Shadow.tight(colorScheme: colorScheme).radius,
                    x: 0,
                    y: DesignTokens.Shadow.tight(colorScheme: colorScheme).y
                )
                .shadow(
                    color: DesignTokens.Shadow.soft(colorScheme: colorScheme).color,
                    radius: DesignTokens.Shadow.soft(colorScheme: colorScheme).radius,
                    x: 0,
                    y: DesignTokens.Shadow.soft(colorScheme: colorScheme).y
                )

            // Title: 13pt serif .semibold, .primary, 2-line max
            Text(title)
                .font(DesignTokens.serifFont(
                    size: DesignTokens.Grid.Title.fontSize,
                    weight: .semibold
                ))
                .foregroundStyle(.primary)
                .lineLimit(2)

            // Format: 12pt, .secondary
            Text(file.format.rawValue.uppercased())
                .font(DesignTokens.sansFont(size: DesignTokens.Grid.Author.fontSize))
                .foregroundStyle(.secondary)
        }
        .offset(y: isHovered ? DesignTokens.Hover.gridLiftY : 0)
        .scaleEffect(isHovered ? DesignTokens.Hover.gridScale : 1.0)
        .animation(
            .spring(
                response: DesignTokens.Hover.gridSpringResponse,
                dampingFraction: DesignTokens.Hover.dampingFraction
            ),
            value: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                NSWorkspace.shared.open(file.url)
            } label: {
                Label("Open", systemImage: "doc.text")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [file.url]
                )
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    file.url.path,
                    forType: .string
                )
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }
        }
    }
}

// MARK: - MattedCoverView

/// The cover treatment shared by the grid and the hero band.
///
/// PDFs render "matted": a per-book hashed gradient mat (same hash as the
/// old placeholder gradient, so it stays visually consistent) with a warm
/// paper-toned page inset in the center. The real PDF thumbnail, once
/// loaded, fills that inset page — not the whole card — so even a plain
/// business-document PDF reads as a book on a shelf instead of a raw page
/// scan. While the thumbnail loads (or if it fails) the page shows a few
/// skeleton line-bars standing in for text.
///
/// EPUB/CBZ don't have real cover-art extraction yet (Phase 2), so they
/// keep the old full-bleed gradient + monogram placeholder. Once Phase 2
/// lands real EPUB/CBZ cover art, that art is designed cover art and should
/// render full-bleed here too — only a raw PDF page gets matted.
struct MattedCoverView: View {
    let file: DiscoveredFile
    var cornerRadius: CGFloat = DesignTokens.Grid.Cover.cornerRadius
    var showBadge: Bool = true

    @State private var thumbnail: NSImage?
    @State private var thumbnailLoaded = false

    private var title: String {
        file.url.deletingPathExtension().lastPathComponent
    }

    private var monogram: String {
        String(title.prefix(1)).uppercased()
    }

    var body: some View {
        ZStack {
            if file.format == .pdf {
                mattedPDF
            } else {
                fullBleedPlaceholder
            }

            if showBadge {
                formatBadge
                    .padding(DesignTokens.Spacing.xs)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .aspectRatio(DesignTokens.Grid.Cover.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .onAppear {
            loadThumbnail()
        }
    }

    // MARK: - Matted PDF

    private var mattedPDF: some View {
        ZStack {
            DesignTokens.placeholderGradient(for: file.url.lastPathComponent)

            GeometryReader { geo in
                let paperSize = CGSize(
                    width: geo.size.width * DesignTokens.Mat.paperWidthFraction,
                    height: geo.size.height * DesignTokens.Mat.paperHeightFraction
                )

                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius)
                        .fill(DesignTokens.paper)
                        .frame(width: paperSize.width, height: paperSize.height)
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)

                    if let thumbnail, thumbnailLoaded {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: paperSize.width, height: paperSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius))
                    } else {
                        skeletonLines
                            .frame(width: paperSize.width, height: paperSize.height)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Mat.paperCornerRadius))
                    }
                }
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }

    /// A few rounded bars standing in for text while the real thumbnail loads.
    private var skeletonLines: some View {
        VStack(alignment: .leading, spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonTitleBarOpacity))
                .frame(width: 34, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonBarOpacity))
                .frame(height: 2.5)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonBarOpacity))
                .frame(width: 46, height: 2.5)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(DesignTokens.Mat.skeletonBarOpacity))
                .frame(height: 2.5)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Full-bleed placeholder (EPUB / CBZ)

    /// Muted gradient (varied per book) with a large serif monogram.
    private var fullBleedPlaceholder: some View {
        ZStack {
            DesignTokens.placeholderGradient(for: file.url.lastPathComponent)

            Text(monogram)
                .font(DesignTokens.serifFont(size: 48, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .aspectRatio(DesignTokens.Grid.Cover.aspectRatio, contentMode: .fill)
    }

    // MARK: - Format Badge

    private var formatBadge: some View {
        Text(file.format.rawValue.uppercased())
            .font(DesignTokens.sansFont(
                size: DesignTokens.Badge.fontSize,
                weight: .bold
            ))
            .tracking(DesignTokens.Badge.tracking)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.vertical, DesignTokens.Badge.paddingV)
            .padding(.horizontal, DesignTokens.Badge.paddingH)
            .background(
                .black.opacity(0.22),
                in: RoundedRectangle(cornerRadius: DesignTokens.Badge.cornerRadius)
            )
    }

    // MARK: - Thumbnail Loading

    private func loadThumbnail() {
        // Only PDFs have a real-thumbnail source today (EPUB/CBZ need their
        // own extractors, added in Phase 2).
        guard file.format == .pdf else { return }

        CoverThumbnailCache.shared.loadThumbnail(for: file.url) { image in
            if let image {
                withAnimation(.easeIn(duration: 0.25)) {
                    thumbnail = image
                    thumbnailLoaded = true
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ScannerService())
}
