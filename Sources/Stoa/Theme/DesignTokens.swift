import SwiftUI
import AppKit

// MARK: - Color + Light/Dark convenience

extension Color {
    /// Create a color that adapts between light and dark mode using NSColor.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }))
    }
}

// MARK: - Design Tokens

/// Single source of truth for every visual value in the app.
/// All spacing follows a 4/8pt rhythm: 4, 8, 12, 16, 20, 24, 32.
enum DesignTokens {

    // MARK: - Colors

    /// Deep royal indigo-violet, adapting for light/dark — richer and more
    /// saturated than the original periwinkle accent, reads as a deliberate
    /// jewel tone rather than a default "blue".
    static let accent = Color(light: NSColor(red: 0.278, green: 0.278, blue: 0.784, alpha: 1),
                             dark: NSColor(red: 0.541, green: 0.541, blue: 0.996, alpha: 1))

    /// A warmer secondary accent (muted amber) reserved for small moments
    /// that shouldn't compete with the primary accent — currently unused,
    /// available for a future "favorite"/highlight affordance.
    static let accentSecondary = Color(light: NSColor(red: 0.729, green: 0.541, blue: 0.204, alpha: 1),
                                      dark: NSColor(red: 0.847, green: 0.663, blue: 0.361, alpha: 1))

    /// Soft warm ivory / warm charcoal. Main window and detail content background.
    static let background = Color(light: NSColor(red: 0.973, green: 0.965, blue: 0.949, alpha: 1),
                                 dark: NSColor(red: 0.110, green: 0.106, blue: 0.098, alpha: 1))

    /// Slightly lighter warm surface. Sidebar panel and card/surface backgrounds.
    static let surface = Color(light: NSColor(red: 0.984, green: 0.976, blue: 0.961, alpha: 1),
                              dark: NSColor(red: 0.129, green: 0.122, blue: 0.114, alpha: 1))

    /// Warm paper tone for the inset "page" inside a matted PDF cover.
    /// Same value in both schemes on purpose — it represents a physical page,
    /// not a UI surface, so it shouldn't invert with dark mode.
    static let paper = Color(light: NSColor(red: 0.937, green: 0.918, blue: 0.878, alpha: 1),
                            dark: NSColor(red: 0.937, green: 0.918, blue: 0.878, alpha: 1))

    // MARK: - Typography

    /// Serif design for section headers and book titles (renders as New York on macOS).
    static func serifFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Default sans design for everything else.
    static func sansFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    // MARK: - Spacing (4/8pt grid)

    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Sidebar

    enum Sidebar {
        static let width: CGFloat = 232
        static let rowHeight: CGFloat = 30
        static let rowPaddingV: CGFloat = 6
        static let rowPaddingH: CGFloat = 8
        static let rowCornerRadius: CGFloat = 10
        static let iconLabelGap: CGFloat = 9

        /// App mark: 28x28 rounded square
        enum AppMark {
            static let size: CGFloat = 28
            static let cornerRadius: CGFloat = 10
            static let titleSize: CGFloat = 17
        }

        /// Section labels: 11pt, .semibold, positive tracking, .tertiary, uppercase
        enum SectionLabel {
            static let fontSize: CGFloat = 11
            static let tracking: CGFloat = 0.2
        }

        /// Row label font size
        static let fontSize: CGFloat = 13
    }

    // MARK: - Library Grid

    enum Grid {
        static let columnMinimum: CGFloat = 150
        static let spacing: CGFloat = 24

        enum Cover {
            static let aspectRatio: CGFloat = 2.0 / 3.0
            static let cornerRadius: CGFloat = 10
        }

        /// Title: 13pt serif .semibold, .primary, 2-line max
        enum Title {
            static let fontSize: CGFloat = 13
        }

        /// Author: 12pt, .secondary
        enum Author {
            static let fontSize: CGFloat = 12
        }
    }

    // MARK: - Matted PDF Cover (mat + inset paper page)

    enum Mat {
        /// Inset paper rect as a fraction of the outer mat's size.
        static let paperWidthFraction: CGFloat = 0.78
        static let paperHeightFraction: CGFloat = 0.84
        static let paperCornerRadius: CGFloat = 5
        /// Skeleton placeholder bars shown on the paper while a thumbnail loads.
        static let skeletonBarOpacity: Double = 0.22
        static let skeletonTitleBarOpacity: Double = 0.5
    }

    // MARK: - Hero (Recently Added / Continue Reading band)

    enum Hero {
        static let height: CGFloat = 148
        static let cornerRadius: CGFloat = 18
        static let coverWidth: CGFloat = 96
        static let glowOpacity: Double = 0.14

        enum Eyebrow {
            static let fontSize: CGFloat = 11
            static let tracking: CGFloat = 0.5
        }

        enum Title {
            static let fontSize: CGFloat = 30
            static let tracking: CGFloat = -0.4
        }

        enum Meta {
            static let fontSize: CGFloat = 13
        }

        enum Button {
            static let fontSize: CGFloat = 13
            static let paddingV: CGFloat = 9
            static let paddingH: CGFloat = 18
            static let cornerRadius: CGFloat = 9
        }
    }

    // MARK: - Format Badge (on cover, top-right)

    enum Badge {
        static let fontSize: CGFloat = 9
        static let tracking: CGFloat = 0.5
        static let paddingV: CGFloat = 2
        static let paddingH: CGFloat = 6
        static let cornerRadius: CGFloat = 4
    }

    // MARK: - Section Headers

    enum SectionHeader {
        static let fontSize: CGFloat = 26
        static let tracking: CGFloat = -0.5

        /// Trailing count label: 13pt .tertiary
        enum Count {
            static let fontSize: CGFloat = 13
        }
    }

    // MARK: - Book Detail

    enum Detail {
        static let coverWidth: CGFloat = 220
        static let coverAspectRatio: CGFloat = 2.0 / 3.0
        static let coverCornerRadius: CGFloat = 14

        enum Title {
            static let fontSize: CGFloat = 32
            static let tracking: CGFloat = -0.5
        }

        enum Author {
            static let fontSize: CGFloat = 16
        }

        enum Tag {
            static let fontSize: CGFloat = 12
            static let paddingV: CGFloat = 4
            static let paddingH: CGFloat = 10
            static let gap: CGFloat = 8
            static let cornerRadius: CGFloat = 12
        }

        enum PrimaryButton {
            static let fontSize: CGFloat = 14
            static let paddingV: CGFloat = 10
            static let paddingH: CGFloat = 22
            static let cornerRadius: CGFloat = 10
        }

        enum SecondaryButton {
            static let fontSize: CGFloat = 14
            static let paddingV: CGFloat = 10
            static let paddingH: CGFloat = 22
            static let cornerRadius: CGFloat = 10
        }

        /// Metadata grid labels: 11pt .semibold uppercase .tertiary + tracking
        enum MetaLabel {
            static let fontSize: CGFloat = 11
            static let tracking: CGFloat = 0.5
        }

        /// Metadata grid values: 14pt .primary
        enum MetaValue {
            static let fontSize: CGFloat = 14
        }

        /// Progress bar
        enum ProgressBar {
            static let height: CGFloat = 3
            static let cornerRadius: CGFloat = 1.5
            static let trackOpacity: Double = 0.08
        }
    }

    // MARK: - Hover Animation

    enum Hover {
        static let gridScale: CGFloat = 1.015
        static let gridLiftY: CGFloat = -3
        static let buttonLiftY: CGFloat = -1
        static let gridSpringResponse: Double = 0.35
        static let buttonSpringResponse: Double = 0.20
        static let dampingFraction: Double = 1.0
    }

    // MARK: - Shadows (softer, more diffused)

    enum Shadow {
        /// Tight contact shadow on covers: unchanged
        static func tight(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Color.black.opacity(0.10), 1, 1)
        }

        /// Soft lifted shadow: radius 18, y 14, opacity ~0.22 light / ~0.45 dark
        static func soft(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            let opacity = colorScheme == .dark ? 0.45 : 0.22
            return (Color.black.opacity(opacity), 18, 14)
        }

        /// Heavy shadow on detail cover: radius 40, y 30, opacity ~0.40
        static func heavy(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Color.black.opacity(0.40), 40, 30)
        }
    }
}

// MARK: - Color Convenience

extension DesignTokens {
    /// 8 muted gradient pairs, one per slot. Each book gets a stable slot
    /// derived from its filename hash so the grid looks varied but consistent.
    private static let placeholderGradients: [(top: Color, bottom: Color)] = [
        // Dusty blue
        (Color(red: 0.55, green: 0.63, blue: 0.73), Color(red: 0.42, green: 0.52, blue: 0.65)),
        // Warm clay
        (Color(red: 0.72, green: 0.55, blue: 0.45), Color(red: 0.62, green: 0.43, blue: 0.35)),
        // Sage
        (Color(red: 0.52, green: 0.62, blue: 0.52), Color(red: 0.40, green: 0.52, blue: 0.42)),
        // Plum
        (Color(red: 0.58, green: 0.44, blue: 0.58), Color(red: 0.46, green: 0.34, blue: 0.48)),
        // Slate
        (Color(red: 0.50, green: 0.52, blue: 0.56), Color(red: 0.38, green: 0.40, blue: 0.44)),
        // Olive
        (Color(red: 0.54, green: 0.56, blue: 0.42), Color(red: 0.42, green: 0.44, blue: 0.32)),
        // Muted rose
        (Color(red: 0.68, green: 0.50, blue: 0.52), Color(red: 0.56, green: 0.38, blue: 0.42)),
        // Steel
        (Color(red: 0.46, green: 0.52, blue: 0.58), Color(red: 0.34, green: 0.40, blue: 0.48)),
    ]

    /// A stable placeholder gradient for a given file, derived from its name hash.
    static func placeholderGradient(for fileName: String) -> LinearGradient {
        let index = abs(fileName.hashValue) % placeholderGradients.count
        let pair = placeholderGradients[index]
        return LinearGradient(
            colors: [pair.top, pair.bottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Legacy: format-specific gradient (kept for BookDetailView fallback).
    static func coverGradient(for format: BookFormat) -> LinearGradient {
        switch format {
        case .epub:
            return LinearGradient(
                colors: [Color.blue.opacity(0.75), Color.teal.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .pdf:
            return LinearGradient(
                colors: [Color.red.opacity(0.75), Color.orange.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .cbz:
            return LinearGradient(
                colors: [Color.purple.opacity(0.75), Color.pink.opacity(0.85)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}
