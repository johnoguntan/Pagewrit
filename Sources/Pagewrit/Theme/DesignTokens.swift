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

    /// Soft cool teal, the one colour Pagewrit owns. Soft on purpose: used for
    /// fills and small signals (progress, selection, counts), never as a
    /// loud call-to-action.
    static let accent = Color(light: NSColor(red: 0.267, green: 0.553, blue: 0.639, alpha: 1),
                             dark: NSColor(red: 0.431, green: 0.690, blue: 0.769, alpha: 1))

    /// Pagewrit's teal at full depth, for solid controls with white text:
    /// primary buttons, chosen segments, switches, picked tiles. A deep,
    /// slightly inky teal reads richer than the soft accent and keeps white
    /// text crisp in both light and dark mode.
    static let accentFill = Color(light: NSColor(red: 0.106, green: 0.361, blue: 0.447, alpha: 1),
                                  dark: NSColor(red: 0.161, green: 0.431, blue: 0.525, alpha: 1))

    /// Solid buttons and chosen segments: near-white with dark text in dark
    /// mode, near-black with light text in light mode.
    static let solidFill = Color(light: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
                                 dark: NSColor(red: 0.93, green: 0.93, blue: 0.94, alpha: 1))
    static let solidInk = Color(light: NSColor(red: 1, green: 1, blue: 1, alpha: 1),
                                dark: NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))

    /// The same hue deepened so small text in it passes contrast on white.
    static let accentInk = Color(light: NSColor(red: 0.133, green: 0.345, blue: 0.431, alpha: 1),
                                dark: NSColor(red: 0.647, green: 0.827, blue: 0.890, alpha: 1))

    /// A soft coral (the bookmark ribbon on the icon) for the rare second signal.
    static let accentSecondary = Color(light: NSColor(red: 0.929, green: 0.482, blue: 0.396, alpha: 1),
                                      dark: NSColor(red: 0.953, green: 0.604, blue: 0.525, alpha: 1))

    /// Quiet cool-tinted canvas (light) and ink-blue near black (dark).
    /// Not cream: white surfaces and covers lift off it, and the blue
    /// reads cleaner against a cool ground.
    static let background = Color(light: NSColor(red: 0.918, green: 0.927, blue: 0.941, alpha: 1),
                                 dark: NSColor(red: 0.047, green: 0.051, blue: 0.063, alpha: 1))

    /// Cards and panels: a clear step above the canvas.
    static let surface = Color(light: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                              dark: NSColor(red: 0.094, green: 0.100, blue: 0.118, alpha: 1))

    /// Floating content: popovers, Settings groups.
    static let elevatedSurface = Color(light: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
                                      dark: NSColor(red: 0.133, green: 0.141, blue: 0.165, alpha: 1))

    /// Warm paper tone for the inset "page" inside a matted PDF cover.
    /// Same value in both schemes on purpose — it represents a physical page,
    /// not a UI surface, so it shouldn't invert with dark mode.
    static let paper = Color(light: NSColor(red: 0.937, green: 0.918, blue: 0.878, alpha: 1),
                            dark: NSColor(red: 0.937, green: 0.918, blue: 0.878, alpha: 1))

    // MARK: - Typography

    /// Bold system (SF Pro) style for section headers and book titles.
    /// This used to render as New York, Apple's serif — clean for a book's
    /// own page, but it read as a book/website font rather than native app
    /// chrome once it was on every title, header and label. One consistent
    /// SF Pro voice throughout instead.
    static func serifFont(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size * PWAccessibility.textScale, weight: softened(weight), design: .default)
    }

    /// Default sans for everything else. Regular weight for body text; the
    /// heaviest weight anywhere is semibold, so nothing shouts.
    static func sansFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * PWAccessibility.textScale, weight: softened(weight), design: .default)
    }

    /// Caps weight at semibold and treats medium as regular-plus, keeping the
    /// whole interface light and even.
    private static func softened(_ weight: Font.Weight) -> Font.Weight {
        switch weight {
        case .bold, .heavy, .black: return .semibold
        default: return weight
        }
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
        static let rowCornerRadius: CGFloat = 10
        static let iconLabelGap: CGFloat = 9

        /// Margin around the whole sidebar VStack (List(.sidebar) used to
        /// supply this implicitly; now explicit so it composes predictably
        /// with `contentInset` below).
        static let outerMargin: CGFloat = 8
        /// Padding between a selection pill's own edge and its icon/text —
        /// combined with `outerMargin`, this is what the app mark, section
        /// labels, and every row icon align to (8 + 8 = 16, i.e. Spacing.md).
        static let contentInset: CGFloat = 8

        /// App mark: 28x28 rounded square
        enum AppMark {
            static let size: CGFloat = 28
            static let cornerRadius: CGFloat = 10
            static let titleSize: CGFloat = 17
        }

        /// Section labels: 11pt, .semibold, positive tracking, .tertiary, uppercase
        enum SectionLabel {
            static let fontSize: CGFloat = 12
            static let tracking: CGFloat = 0
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
            static var fontSize: CGFloat { 13 }
            /// Reserves 2 lines' worth of height regardless of actual
            /// line count, so every row in the grid stays flush — a
            /// short 1-line title next to a wrapped 2-line title no
            /// longer staggers the row beneath it. Same discipline as
            /// the hero rail (DesignTokens.Hero.Title.blockHeight).
            static var blockHeight: CGFloat { 34 * PWAccessibility.textScale }
        }

        /// Secondary line: author when known, format otherwise. 12pt, .secondary
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

    /// No fixed height: the card sizes to its content (the cover image
    /// naturally drives it to ~200pt via coverWidth + paddingV). A fixed
    /// 148pt was squeezing eyebrow/title/meta/progress/button into a box
    /// with almost no room to breathe — the actual complaint that started
    /// this rework. Internal spacing is deliberately uneven (see Rhythm)
    /// rather than one repeated gap, so the block reads with real rhythm
    /// instead of mechanical uniformity.
    enum Hero {
        static let cornerRadius: CGFloat = 22
        static let coverWidth: CGFloat = 104
        static let glowOpacity: Double = 0.07

        /// Fixed width for a hero card in the horizontally scrolling row
        /// (Continue Reading, Recently Added, and room for more later) —
        /// a native "Up Next" style rail rather than one card that has to
        /// pick a single thing to show.
        static let cardWidth: CGFloat = 440

        /// Fixed card height. With several cards side by side in a row,
        /// letting each size to its own content (what an earlier pass
        /// did) meant a 1-line title card and a 2-line title card landed
        /// at different heights, and their Resume/Open buttons ended up
        /// at different Y positions — the row read as unaligned. A fixed
        /// height, combined with Title.blockHeight below and a Spacer
        /// pinning the button to the bottom, makes every card's eyebrow,
        /// title, and button line up across the whole row regardless of
        /// how much text any one card has.
        static let height: CGFloat = 236

        static let paddingH: CGFloat = 28
        static let paddingV: CGFloat = 28

        enum Eyebrow {
            static let fontSize: CGFloat = 11
            static let tracking: CGFloat = 0.6
        }

        enum Title {
            static let fontSize: CGFloat = 22
            static let tracking: CGFloat = -0.2
            /// Reserves 2 lines' worth of height regardless of actual
            /// line count, so whatever comes after the title (meta text,
            /// progress bar) starts at the same Y on every card.
            static let blockHeight: CGFloat = 56
        }

        enum Meta {
            static let fontSize: CGFloat = 13

            /// Reserves height for the tallest variant (the Continue
            /// Reading card's meta line + progress bar) so every card's
            /// meta block occupies the same space regardless of which
            /// kind it is — the button below it then sits a fixed
            /// Rhythm.beforeButton gap under that, instead of an elastic
            /// Spacer swallowing whatever's left and making the gap
            /// above the button different card to card.
            static let blockHeight: CGFloat = 30
        }

        enum Button {
            static let fontSize: CGFloat = 12
            static let paddingV: CGFloat = 7
            static let paddingH: CGFloat = 15
        }

        /// Uneven on purpose: tightest right under the title (eyebrow and
        /// title read as one thought), most generous just above the
        /// button (the one action on the card earns space of its own).
        enum Rhythm {
            static let afterEyebrow: CGFloat = 8
            static let afterTitle: CGFloat = 6
            static let beforeMeta: CGFloat = 10
            static let beforeButton: CGFloat = 18
        }
    }

    // MARK: - Format Badge (on cover, top-right)

    enum Badge {
        static let fontSize: CGFloat = 9
        static let tracking: CGFloat = 0.2
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
            static let fontSize: CGFloat = 22
            static let tracking: CGFloat = -0.2
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
            static let fontSize: CGFloat = 12
            static let tracking: CGFloat = 0
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
        static let gridScale: CGFloat = 1.0
        static let gridLiftY: CGFloat = -2
        static let buttonLiftY: CGFloat = -1
        static let gridSpringResponse: Double = 0.35
        static let buttonSpringResponse: Double = 0.20
        static let dampingFraction: Double = 1.0
    }

    // MARK: - Shadows (softer, more diffused)

    enum Shadow {
        /// Tight contact shadow on covers: unchanged
        static func tight(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Color.black.opacity(0.07), 1, 1)
        }

        /// Soft resting shadow under a cover.
        static func soft(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Color.black.opacity(colorScheme == .dark ? 0.38 : 0.10), 12, 6)
        }

        /// The same shadow when the pointer is over the cover: it rises.
        static func lifted(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Color.black.opacity(colorScheme == .dark ? 0.5 : 0.17), 22, 14)
        }

        /// Heavy shadow on detail cover: radius 40, y 30, opacity ~0.40
        static func heavy(colorScheme: ColorScheme) -> (color: Color, radius: CGFloat, y: CGFloat) {
            (Color.black.opacity(0.26), 34, 22)
        }
    }
}

// MARK: - Hairline & Format Color

extension DesignTokens {
    /// A border/divider color that's actually visible in both schemes.
    /// `.primary.opacity(0.07-0.08)` (the old approach) reads as pure black
    /// at ~8% in light mode — fine — but the same 8% of *white* in dark mode
    /// all but disappears against a near-black surface. This scales the
    /// opacity per scheme instead of using one flat value for both.
    static func hairline(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
    }

    /// A distinct, desaturated identity color per format — used sparingly
    /// (sidebar icons, format chips) as a spot of personality, not as a
    /// wash across large surfaces.
    static func formatColor(for format: BookFormat) -> Color {
        switch format {
        case .epub: Color(light: NSColor(red: 0.110, green: 0.490, blue: 0.510, alpha: 1),
                          dark: NSColor(red: 0.360, green: 0.730, blue: 0.740, alpha: 1))
        case .pdf: Color(light: NSColor(red: 0.660, green: 0.510, blue: 0.157, alpha: 1),
                         dark: NSColor(red: 0.851, green: 0.663, blue: 0.290, alpha: 1))
        case .cbz: Color(light: NSColor(red: 0.760, green: 0.290, blue: 0.360, alpha: 1),
                          dark: NSColor(red: 0.930, green: 0.490, blue: 0.540, alpha: 1))
        case .pptx: Color(light: NSColor(red: 0.769, green: 0.318, blue: 0.188, alpha: 1),
                          dark: NSColor(red: 0.929, green: 0.518, blue: 0.396, alpha: 1))
        case .docx: Color(light: NSColor(red: 0.200, green: 0.360, blue: 0.640, alpha: 1),
                          dark: NSColor(red: 0.450, green: 0.600, blue: 0.880, alpha: 1))
        case .text: Color(light: NSColor(red: 0.330, green: 0.510, blue: 0.400, alpha: 1),
                          dark: NSColor(red: 0.520, green: 0.720, blue: 0.590, alpha: 1))
        case .kindle: Color(light: NSColor(red: 0.560, green: 0.400, blue: 0.290, alpha: 1),
                          dark: NSColor(red: 0.780, green: 0.600, blue: 0.470, alpha: 1))
        }
    }
}

// MARK: - Color Convenience

extension DesignTokens {
    /// 8 muted gradient pairs, one per slot. Each book gets a stable slot
    /// derived from its filename hash so the grid looks varied but consistent.
    private static let placeholderColors: [Color] = [
        Color(red: 0.43, green: 0.55, blue: 0.67),  // dusty blue
        Color(red: 0.69, green: 0.50, blue: 0.40),  // warm clay
        Color(red: 0.45, green: 0.58, blue: 0.48),  // sage
        Color(red: 0.47, green: 0.50, blue: 0.55),  // slate
        Color(red: 0.55, green: 0.56, blue: 0.40),  // olive
        Color(red: 0.70, green: 0.46, blue: 0.48),  // muted rose
        Color(red: 0.38, green: 0.55, blue: 0.58),  // teal grey
        Color(red: 0.72, green: 0.60, blue: 0.38),  // ochre
    ]

    /// A stable flat colour for a file with no cover, from its path hash.
    /// Flat on purpose: gradients on every tile read as templated.
    static func placeholderGradient(for fileName: String) -> Color {
        var hash: UInt64 = 5381
        for byte in fileName.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return placeholderColors[Int(hash % UInt64(placeholderColors.count))]
    }
}

// MARK: - Touch and feel

enum Haptics {
    /// The small tick a trackpad gives when a control engages.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Pressing answers the hand: a light scale and a trackpad tick on press in.
private struct PressFeedback: ViewModifier {
    let pressed: Bool
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onChange(of: pressed) { _, isDown in
                if isDown { Haptics.tick() }
            }
    }
}

// MARK: - Buttons

/// The one strong action on a screen: solid ink (near black in light mode,
/// near white in dark). The accent is kept for small signals, not CTA pills.
struct InkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PWButtonBody(configuration: configuration, kind: .primary, size: .regular, fullWidth: false)
    }
}

/// A calm secondary action: hairline outline, no fill.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PWButtonBody(configuration: configuration, kind: .soft, size: .regular, fullWidth: false)
    }
}

// MARK: - Pagewrit buttons

/// One button family for the whole app: `.buttonStyle(.pw(.primary))`.
///
/// - primary:   the single main action on a screen (deep teal, solid)
/// - soft:      a friendly second action (teal tint)
/// - neutral:   a quiet action that still reads as a button
/// - danger:    a destructive action (red tint)
/// - dangerSolid: a destructive action that is the main choice
/// - ghost:     text only, with a tint on hover
enum PWButtonKind { case primary, soft, neutral, danger, dangerSolid, ghost }
enum PWButtonSize { case small, regular, large }

struct PWButtonStyle: ButtonStyle {
    var kind: PWButtonKind = .primary
    var size: PWButtonSize = .regular
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        PWButtonBody(configuration: configuration, kind: kind, size: size, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == PWButtonStyle {
    static func pw(_ kind: PWButtonKind = .primary, size: PWButtonSize = .regular, fullWidth: Bool = false) -> PWButtonStyle {
        PWButtonStyle(kind: kind, size: size, fullWidth: fullWidth)
    }
}

private struct PWButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: PWButtonKind
    let size: PWButtonSize
    let fullWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pagewritReduceMotion) private var reduceMotion
    @State private var hovering = false

    private static let red = Color(light: NSColor(red: 0.74, green: 0.16, blue: 0.16, alpha: 1),
                                   dark: NSColor(red: 1.0, green: 0.50, blue: 0.48, alpha: 1))

    /// The main action: a deep teal in light mode, a bright teal in dark mode,
    /// with text chosen for contrast against each.
    private static var primaryFill: Color { DesignTokens.solidFill }
    private static let primaryText = DesignTokens.solidInk

    // Sized like the system's own controls (small, regular, large) so the
    // buttons sit comfortably next to anything else macOS draws.
    private var height: CGFloat { size == .small ? 22 : (size == .regular ? 26 : 30) }
    private var padding: CGFloat { size == .small ? 10 : (size == .regular ? 13 : 16) }
    private var fontSize: CGFloat { 13 }
    private var radius: CGFloat { size == .small ? 5 : 6 }
    private var isMain: Bool { kind == .primary || kind == .dangerSolid }

    private var foreground: Color {
        switch kind {
        case .primary: return Self.primaryText
        case .soft, .neutral: return .primary
        case .ghost: return hovering ? .primary : .secondary
        case .danger: return Self.red
        case .dangerSolid: return .white
        }
    }

    /// Fills are tints of one ink, so every button reads as part of one family:
    /// solid for the main action, a gentle tint for the rest, nothing for text buttons.
    private var fill: Color {
        switch kind {
        case .primary: return Self.primaryFill.opacity(configuration.isPressed ? 0.78 : (hovering ? 0.90 : 1))
        case .soft, .neutral, .danger: return Color.primary.opacity(configuration.isPressed ? 0.20 : (hovering ? 0.15 : 0.10))
        case .dangerSolid: return Color(red: 0.74, green: 0.16, blue: 0.16).opacity(hovering ? 0.88 : 1)
        case .ghost: return Color.primary.opacity(hovering ? 0.07 : 0)
        }
    }

    private var edge: Color {
        switch kind {
        case .primary: return Color.white.opacity(colorScheme == .dark ? 0.16 : 0.22)
        case .dangerSolid: return Color.white.opacity(0.18)
        case .soft, .neutral, .danger: return Color.primary.opacity(0.07)
        default: return .clear
        }
    }

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .labelStyle(PWLabelStyle())
            .foregroundStyle(foreground)
            .padding(.horizontal, padding)
            .frame(height: height)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            // A hairline catches the light along the edge, like a native control.
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(edge, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(isMain || kind == .soft || kind == .neutral || kind == .danger ? 0.16 : 0), radius: 0.5, y: 0.5)
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            // Responds the instant it is pressed and springs back without overshoot.
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(reduceMotion ? .none : .spring(response: 0.22, dampingFraction: 1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .onChange(of: configuration.isPressed) { _, isDown in
                if isDown { Haptics.tick() }
            }
    }
}

/// Icon and title side by side, with an even gap.
private struct PWLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}


// MARK: - Scanning indicator

/// A small deck of pages that fans and shuffles while Pagewrit looks for new
/// files. Move the pointer over it and the pages tilt toward you; click and it
/// gives a little hop. Holds still when Reduce Motion is on.
struct ScanningIndicator: View {
    var label: String = "Looking for new books"
    var detail: String?
    /// One slim row with a small deck, for scans that run over a full library.
    var compact = false

    @Environment(\.pagewritReduceMotion) private var reduceMotion
    @State private var tilt: CGSize = .zero
    @State private var hop: Double = 0

    private var colors: [Color] {
        [DesignTokens.accent, DesignTokens.accentSecondary, DesignTokens.accent.opacity(0.5)]
    }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var compactBody: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        page(index: i, time: t)
                    }
                }
                .frame(width: 96, height: 64)
                .drawingGroup()
                .scaleEffect(0.42)
            }
            .frame(width: 44, height: 30)
            Text(detail.map { "\(label), \($0)" } ?? label)
                .font(DesignTokens.sansFont(size: 12.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(label), \($0)" } ?? label)
    }

    private var fullBody: some View {
        VStack(spacing: 10) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        page(index: i, time: t)
                    }
                }
                .frame(width: 96, height: 64)
                .rotation3DEffect(.degrees(Double(tilt.width) * 16), axis: (x: 0, y: 1, z: 0))
                .rotation3DEffect(.degrees(Double(-tilt.height) * 16), axis: (x: 1, y: 0, z: 0))
                .scaleEffect(1 + 0.14 * hop)
                .offset(y: -6 * hop)
            }
            .frame(width: 130, height: 84)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let x = max(-1, min(1, (point.x - 65) / 65))
                    let y = max(-1, min(1, (point.y - 42) / 42))
                    withAnimation(.smooth(duration: 0.2)) { tilt = CGSize(width: x, height: y) }
                case .ended:
                    withAnimation(.smooth(duration: 0.4)) { tilt = .zero }
                }
            }
            .onTapGesture {
                Haptics.tick()
                withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) { hop = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { hop = 0 }
                }
            }

            VStack(spacing: 2) {
                Text(label)
                    .font(DesignTokens.sansFont(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(DesignTokens.sansFont(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(label), \($0)" } ?? label)
    }

    private func page(index: Int, time: Double) -> some View {
        let phase = time * 1.7 + Double(index) * (2 * Double.pi / 3)
        let depth = (cos(phase) + 1) / 2
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(colors[index % colors.count])
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(.white.opacity(0.75)).frame(width: 16, height: 3)
                    Capsule().fill(.white.opacity(0.45)).frame(width: 22, height: 3)
                    Capsule().fill(.white.opacity(0.45)).frame(width: 12, height: 3)
                }
                .padding(7)
            }
            .frame(width: 36, height: 48)
            .shadow(color: .black.opacity(0.12 + 0.12 * depth), radius: 3 + 4 * depth, y: 2)
            .scaleEffect(0.86 + 0.14 * depth)
            .rotationEffect(.degrees(sin(phase) * 12))
            .offset(x: sin(phase) * 26, y: (1 - depth) * -4)
            .zIndex(depth)
    }
}


// MARK: - Accessibility preferences

/// Pagewrit's own accessibility settings, on top of the Mac's. Text size
/// scales every font that goes through DesignTokens; calm motion turns off the
/// dog's movement, confetti, hover lifts and slides even when the Mac's Reduce
/// Motion is off.
enum PWAccessibility {
    static let textScaleKey = "pagewrit.textScale"
    static let reduceMotionKey = "pagewrit.reduceMotion"

    enum TextSize: Double, CaseIterable, Identifiable {
        case standard = 1.0, large = 1.12, larger = 1.25
        var id: Double { rawValue }
        var label: String {
            switch self {
            case .standard: return "Standard"
            case .large: return "Large"
            case .larger: return "Larger"
            }
        }
    }

    static var textScale: CGFloat {
        let value = UserDefaults.standard.double(forKey: textScaleKey)
        return value > 0 ? CGFloat(min(max(value, 0.9), 1.4)) : 1
    }

    /// Either switch is enough: the Mac's Reduce Motion, or Pagewrit's own.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: reduceMotionKey)
    }

    /// Reads a line out to VoiceOver without moving focus.
    @MainActor
    static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

private struct PagewritReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when either the Mac or Pagewrit asks for calmer motion. Views read
    /// this instead of accessibilityReduceMotion.
    var pagewritReduceMotion: Bool {
        get { self[PagewritReduceMotionKey.self] }
        set { self[PagewritReduceMotionKey.self] = newValue }
    }
}

/// Put on each window's root: works out calm motion and redraws everything
/// at the new size the moment text size changes.
struct AccessibilityRoot: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(PWAccessibility.reduceMotionKey) private var appReduceMotion = false
    @AppStorage(PWAccessibility.textScaleKey) private var textScale: Double = 1

    func body(content: Content) -> some View {
        content
            .environment(\.pagewritReduceMotion, systemReduceMotion || appReduceMotion)
            .transaction { transaction in
                if appReduceMotion { transaction.animation = nil }
            }
            // The system's blue focus outline looks unfinished around our own
            // controls; every control already shows its own pressed and hover state.
            .focusEffectDisabled()
            .id(textScale)
    }
}

extension View {
    func accessibilityRoot() -> some View { modifier(AccessibilityRoot()) }
}

// MARK: - Segmented control

/// A segmented choice in Pagewrit's own teal, in place of the system's blue
/// one. The selected segment slides between options, the others light up on
/// hover, and the left and right arrow keys move the choice.
struct PWSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    var width: CGFloat? = nil

    @Namespace private var pill
    @State private var hovered: Int?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pagewritReduceMotion) private var reduceMotion

    private static var selectedFill: Color { DesignTokens.solidFill }

    private var selectedIndex: Int? { options.firstIndex { $0.value == selection } }

    private func choose(_ index: Int) {
        guard options.indices.contains(index), options[index].value != selection else { return }
        Haptics.tick()
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            selection = options[index].value
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let isSelected = selectedIndex == index
                Button { choose(index) } label: {
                    Text(options[index].label)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? DesignTokens.solidInk : Color.primary.opacity(hovered == index ? 0.95 : 0.75))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: width == nil ? nil : .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Self.selectedFill)
                                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.15), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else if hovered == index {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { choose((selectedIndex ?? 0) - 1); return .handled }
        .onKeyPress(.rightArrow) { choose((selectedIndex ?? -1) + 1); return .handled }
        .accessibilityElement(children: .contain)
    }
}


/// "1 book", "2 books": a count with the right word after it.
func countText(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (plural ?? singular + "s"))"
}


// MARK: - Cover shadow

/// A shadow that sits a cover on the page the way a real book rests on a
/// table: a tight dark line right under the edge, then a wide, faint fall-off.
/// One heavy blur looks like a grey smudge in light mode, so there are two,
/// and light mode uses less of both.
private struct CoverShadow: ViewModifier {
    var depth: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .shadow(color: .black.opacity(dark ? 0.55 : 0.16), radius: 1.5 * depth, x: 0, y: 1 * depth)
            .shadow(color: .black.opacity(dark ? 0.40 : 0.10), radius: 12 * depth, x: 0, y: 7 * depth)
    }
}

extension View {
    /// `depth` 1 is a list thumbnail; around 1.6 suits a large cover.
    func coverShadow(depth: CGFloat = 1) -> some View { modifier(CoverShadow(depth: depth)) }
}
