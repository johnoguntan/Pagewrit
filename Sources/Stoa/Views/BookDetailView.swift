import SwiftUI
import AppKit

// MARK: - BookDetailView

/// Two-column book detail: large cover on the left, metadata on the right.
/// Shows when a book is opened from the library grid.
struct BookDetailView: View {
    let file: DiscoveredFile
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xl) {
                coverSection
                metadataSection
            }
            .padding(DesignTokens.Spacing.xl)
        }
        .background(DesignTokens.background.ignoresSafeArea())
        .navigationTitle(file.url.deletingPathExtension().lastPathComponent)
    }

    // MARK: - Cover (left column)

    private var coverSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.Detail.coverCornerRadius)
                .fill(DesignTokens.coverGradient(for: file.format))
                .frame(width: DesignTokens.Detail.coverWidth)
                .aspectRatio(DesignTokens.Detail.coverAspectRatio, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Detail.coverCornerRadius)
                        .stroke(.primary.opacity(0.06), lineWidth: 0.5)
                )

            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: file.format.systemImage)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.white.opacity(0.9))

                Text(file.format.rawValue.uppercased())
                    .font(DesignTokens.sansFont(size: 14, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .shadow(
            color: DesignTokens.Shadow.heavy(colorScheme: colorScheme).color,
            radius: DesignTokens.Shadow.heavy(colorScheme: colorScheme).radius,
            x: 0,
            y: DesignTokens.Shadow.heavy(colorScheme: colorScheme).y
        )
        .fixedSize()
    }

    // MARK: - Metadata (right column)

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            // Title: 32pt serif .bold, tight tracking, .primary
            Text(file.url.deletingPathExtension().lastPathComponent)
                .font(DesignTokens.serifFont(
                    size: DesignTokens.Detail.Title.fontSize,
                    weight: .bold
                ))
                .tracking(DesignTokens.Detail.Title.tracking)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // Author: 16pt, .secondary
            Text("Unknown Author")
                .font(DesignTokens.sansFont(size: DesignTokens.Detail.Author.fontSize))
                .foregroundStyle(.secondary)

            tagPillsRow
            buttonsRow

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xxs)

            metadataGrid
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Tag Pills

    /// 12pt .semibold, .secondary, 6%-opacity black bg (8% dark),
    /// 4pt v / 10pt h padding, 8pt gaps, rounded capsule
    private var tagPillsRow: some View {
        HStack(spacing: DesignTokens.Detail.Tag.gap) {
            ForEach(["Fiction", "Science Fiction"], id: \.self) { tag in
                Text(tag)
                    .font(DesignTokens.sansFont(
                        size: DesignTokens.Detail.Tag.fontSize,
                        weight: .semibold
                    ))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Detail.Tag.paddingV)
                    .padding(.horizontal, DesignTokens.Detail.Tag.paddingH)
                    .background(
                        Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06),
                        in: Capsule()
                    )
            }
        }
    }

    // MARK: - Buttons

    private var buttonsRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Primary: accent bg, white text, 14pt .semibold
            Button {
                NSWorkspace.shared.open(file.url)
            } label: {
                Label("Open", systemImage: "book")
                    .font(DesignTokens.sansFont(
                        size: DesignTokens.Detail.PrimaryButton.fontSize,
                        weight: .semibold
                    ))
                    .foregroundStyle(.white)
                    .padding(.vertical, DesignTokens.Detail.PrimaryButton.paddingV)
                    .padding(.horizontal, DesignTokens.Detail.PrimaryButton.paddingH)
                    .background(DesignTokens.accent)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Detail.PrimaryButton.cornerRadius))
            }
            .buttonStyle(.plain)

            // Secondary: outlined, 1pt hairline, .secondary text
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(DesignTokens.sansFont(
                        size: DesignTokens.Detail.SecondaryButton.fontSize
                    ))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.Detail.SecondaryButton.paddingV)
                    .padding(.horizontal, DesignTokens.Detail.SecondaryButton.paddingH)
                    .background(.clear)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Detail.SecondaryButton.cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Detail.SecondaryButton.cornerRadius)
                            .stroke(.separator, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Metadata Grid (2x2)

    /// Labels: 11pt .semibold uppercase .tertiary + tracking.
    /// Values: 14pt .primary.
    private var metadataGrid: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxl) {
                metaItem(label: "FORMAT", value: file.format.rawValue.uppercased())
                metaItem(
                    label: "SIZE",
                    value: ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)
                )
            }

            HStack(alignment: .top, spacing: DesignTokens.Spacing.xxl) {
                metaItem(label: "LOCATION", value: file.url.deletingLastPathComponent().lastPathComponent)
                metaItem(
                    label: "MODIFIED",
                    value: file.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown"
                )
            }

            progressRow()
        }
    }

    private func metaItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(label)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaLabel.fontSize,
                    weight: .semibold
                ))
                .tracking(DesignTokens.Detail.MetaLabel.tracking)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            Text(value)
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaValue.fontSize
                ))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    // MARK: - Progress Row

    /// 3pt tall rounded bar: track at 8% black opacity, fill in accent color
    private func progressRow() -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("PROGRESS")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaLabel.fontSize,
                    weight: .semibold
                ))
                .tracking(DesignTokens.Detail.MetaLabel.tracking)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(DesignTokens.Detail.ProgressBar.trackOpacity))
                        .frame(height: DesignTokens.Detail.ProgressBar.height)

                    // 0% fill — will show real progress when available
                    Capsule()
                        .fill(DesignTokens.accent)
                        .frame(width: 0, height: DesignTokens.Detail.ProgressBar.height)
                }
            }
            .frame(height: DesignTokens.Detail.ProgressBar.height)

            Text("Not started")
                .font(DesignTokens.sansFont(
                    size: DesignTokens.Detail.MetaValue.fontSize
                ))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BookDetailView(
            file: DiscoveredFile(
                url: URL(fileURLWithPath: "/Users/test/Book.epub"),
                format: .epub,
                sizeBytes: 2_500_000,
                modifiedAt: Date()
            )
        )
    }
}
