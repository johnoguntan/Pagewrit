import SwiftUI
import AppKit

// MARK: - ReaderPalette

/// One complete set of reading colors. Every reader surface (page, chrome,
/// PDF margin, EPUB CSS) is derived from a palette, so they can never drift
/// apart the way separate per-property switches did.
struct ReaderPalette {
    let isDark: Bool
    let backgroundHex: String
    let chromeHex: String
    let textHex: String
    let secondaryHex: String
    let linkHex: String
    let ruleHex: String

    var background: NSColor { NSColor(readerHex: backgroundHex) }
    var chrome: NSColor { NSColor(readerHex: chromeHex) }
    var text: NSColor { NSColor(readerHex: textHex) }
    var secondary: NSColor { NSColor(readerHex: secondaryHex) }
    var link: NSColor { NSColor(readerHex: linkHex) }
    var rule: NSColor { NSColor(readerHex: ruleHex) }

    /// Clean, near-neutral warm white. The default for light mode: high
    /// contrast (about 16:1) without the glare of pure white.
    static let paper = ReaderPalette(
        isDark: false,
        backgroundHex: "#FAF8F3", chromeHex: "#F1EEE6",
        textHex: "#1C1B19", secondaryHex: "#6B675F",
        linkHex: "#2D5A8A", ruleHex: "#DDD8CC"
    )

    /// Softer than Paper but still comfortably readable (about 11:1). The
    /// chrome is only a small step off the page, and links get their own
    /// warm brown so they are distinguishable from body text.
    static let sepia = ReaderPalette(
        isDark: false,
        backgroundHex: "#F3EAD7", chromeHex: "#EADFC8",
        textHex: "#34291B", secondaryHex: "#6E5F49",
        linkHex: "#8A4B14", ruleHex: "#D6C9AC"
    )

    static let night = ReaderPalette(
        isDark: true,
        backgroundHex: "#16161A", chromeHex: "#1F1F24",
        textHex: "#D8D6D0", secondaryHex: "#8F8D87",
        linkHex: "#8DB4E2", ruleHex: "#2E2E34"
    )
}

private extension NSColor {
    convenience init(readerHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
            .scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Typography

enum ReaderFace: String, CaseIterable, Identifiable {
    case serif, classic, sans

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "Serif"
        case .classic: "Classic"
        case .sans: "Sans"
        }
    }

    var cssFamily: String {
        switch self {
        case .serif: #""New York", "Iowan Old Style", Palatino, Georgia, serif"#
        case .classic: #"Georgia, "Times New Roman", serif"#
        case .sans: #"-apple-system, "SF Pro Text", system-ui, sans-serif"#
        }
    }
}

/// Everything about how the text itself is set, separate from color.
struct ReaderTypography: Equatable {
    var fontScale: Double = 1.0
    var face: ReaderFace = .serif
    var lineHeight: Double = 1.65
    /// Column width in em (about 65 characters at 34).
    var measure: Double = 34
    var justified: Bool = false
}

// MARK: - ReaderTheme

/// Reading-focused color theme shared by the EPUB and PDF readers.
///
/// `.system` is now "Auto": Paper when the Mac is in light mode, Night when
/// it is in dark mode. Previously it meant "whatever the publisher's CSS
/// says", which is why light mode looked unstyled and unreadable. The raw
/// value stays "system" so saved preferences keep working.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case sepia
    case night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Auto"
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .night: "Night"
        }
    }

    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .paper: "doc.text"
        case .sepia: "sun.max.fill"
        case .night: "moon.fill"
        }
    }

    func palette(for scheme: ColorScheme) -> ReaderPalette {
        switch self {
        case .paper: .paper
        case .sepia: .sepia
        case .night: .night
        case .system: scheme == .dark ? .night : .paper
        }
    }

    // MARK: - SwiftUI / AppKit colors
    //
    // These keep the old optional signatures so existing call sites
    // (`readerTheme.textColor ?? .primary`) still compile. They are never
    // nil now; `.system` returns dynamic colors that follow the appearance.

    private func nsColor(_ keyPath: KeyPath<ReaderPalette, NSColor>) -> NSColor {
        if self == .system {
            return NSColor(name: nil, dynamicProvider: { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return ReaderTheme.system.palette(for: dark ? .dark : .light)[keyPath: keyPath]
            })
        }
        return palette(for: .light)[keyPath: keyPath]
    }

    var backgroundColor: Color? { Color(nsColor: nsColor(\.background)) }
    var chromeColor: Color? { Color(nsColor: nsColor(\.chrome)) }
    var textColor: Color? { Color(nsColor: nsColor(\.text)) }
    var secondaryTextColor: Color? { Color(nsColor: nsColor(\.secondary)) }
    var pdfBackgroundNSColor: NSColor? { nsColor(\.background) }

    // MARK: - EPUB CSS

    /// The full reading stylesheet for a chapter.
    ///
    /// - Comfortable measure: text column capped at 34em (about 65 to 70
    ///   characters) and centered, instead of running edge to edge.
    /// - Type scale stays intact: only paragraph-level text is forced to the
    ///   base size, so headings, sup/sub and small print keep their ratios.
    ///   (The old rule flattened every element, h1 included, to one size.)
    /// - Colors are forced down the whole tree so a publisher's `color:#000`
    ///   can never end up invisible on the Night background.
    func epubCSS(scheme: ColorScheme, fontScale: Double) -> String {
        epubCSS(scheme: scheme, typography: ReaderTypography(fontScale: fontScale))
    }

    func epubCSS(scheme: ColorScheme, typography t: ReaderTypography) -> String {
        let p = palette(for: scheme)
        let px = (19.0 * t.fontScale * 100).rounded() / 100

        return #"""
        :root { color-scheme: \#(p.isDark ? "dark" : "light"); }
        html {
          background: \#(p.backgroundHex) !important;
          -webkit-text-size-adjust: none;
          scroll-padding-top: 24px;
        }
        body {
          background: \#(p.backgroundHex) !important;
          color: \#(p.textHex) !important;
          font-family: \#(t.face.cssFamily) !important;
          font-size: \#(px)px !important;
          line-height: \#(t.lineHeight) !important;
          max-width: \#(t.measure)em !important;
          margin: 0 auto !important;
          padding: 92px 32px 128px !important;
          text-align: \#(t.justified ? "justify" : "left");
          \#(t.justified ? "-webkit-hyphens: auto; hyphens: auto;" : "")
          overflow-wrap: break-word;
          -webkit-font-smoothing: antialiased;
        }
        body * {
          color: inherit !important;
          background-color: transparent !important;
          font-family: inherit !important;
          max-width: 100%;
        }
        p, li, dd, dt, blockquote {
          font-size: 1em !important;
          line-height: \#(t.lineHeight) !important;
        }
        p { margin: 0 0 0.85em !important; text-indent: 0 !important; }
        h1, h2, h3, h4, h5, h6 {
          line-height: 1.25 !important;
          font-weight: 600 !important;
          text-align: left !important;
          margin: 1.6em 0 0.6em !important;
        }
        h1 { font-size: 1.7em !important; }
        h2 { font-size: 1.4em !important; }
        h3 { font-size: 1.2em !important; }
        h4, h5, h6 { font-size: 1em !important; }
        sup, sub { font-size: 0.75em !important; line-height: 0 !important; }
        blockquote {
          margin: 1.2em 0 !important;
          padding-left: 1em !important;
          border-left: 3px solid \#(p.ruleHex) !important;
        }
        a, a * { color: \#(p.linkHex) !important; }
        a { text-decoration: underline; text-underline-offset: 0.15em; }
        pre, code, kbd, samp {
          font-family: ui-monospace, Menlo, monospace !important;
          font-size: 0.88em !important;
          white-space: pre-wrap;
        }
        img, svg, video { max-width: 100% !important; height: auto !important; }
        img { border-radius: 4px; }
        table { max-width: 100%; border-collapse: collapse; }
        td, th { border: 1px solid \#(p.ruleHex); padding: 0.3em 0.6em; }
        hr { border: 0 !important; border-top: 1px solid \#(p.ruleHex) !important; margin: 2em 0 !important; }
        ::selection { background: \#(p.linkHex)44; }

        #stoa-nav {
          display: flex; justify-content: space-between; align-items: center;
          margin-top: 3.5em; padding-top: 1.1em;
          border-top: 1px solid \#(p.ruleHex);
          font-family: -apple-system, system-ui, sans-serif !important;
          font-size: 0.75em;
        }
        #stoa-nav button {
          all: unset; cursor: pointer;
          color: \#(p.linkHex) !important;
          font-family: -apple-system, system-ui, sans-serif !important;
          padding: 0.5em 0.25em;
        }
        #stoa-nav button:hover { text-decoration: underline; }
        """#
    }
}


// MARK: - Window appearance

/// Makes the reader window's native controls match the reading theme.
/// Without this, a Paper page in a dark Mac gets white-on-white menus, segmented
/// pickers and popovers. Auto follows the system; every other theme pins the
/// window to light or dark to match its page.
struct ReaderWindowAppearance: NSViewRepresentable {
    let theme: ReaderTheme

    private var appearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .paper, .sepia: return NSAppearance(named: .aqua)
        case .night: return NSAppearance(named: .darkAqua)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.appearance = appearance }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let wanted = appearance
        DispatchQueue.main.async { view.window?.appearance = wanted }
    }
}


// MARK: - Native controls on reader colours

extension ReaderTheme {
    /// Light or dark, as the reader's own colours are, so native controls
    /// such as segmented pickers, switches and sliders match the panel.
    func controlScheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: return system
        case .paper, .sepia: return .light
        case .night: return .dark
        }
    }
}

extension View {
    /// For panels and popovers drawn in reader colours. A popover lives in its
    /// own window, which kept the old light or dark look after a theme change,
    /// leaving white labels on a light panel until it was reopened. This sets
    /// the look directly and redraws the controls the moment the theme changes.
    func readerControls(_ theme: ReaderTheme, system: ColorScheme) -> some View {
        let scheme = theme.controlScheme(system: system)
        return self
            .environment(\.colorScheme, scheme)
            .id("\(theme.rawValue)-\(scheme == .dark ? "dark" : "light")")
    }
}


// MARK: - The app's own light or dark look

/// Publishes Pagewrit's effective appearance (your Settings choice, or the
/// Mac's when that is System). Readers resolve "Auto" from this rather than
/// from their window, whose look the reader theme sets, so the page never
/// flips light or dark when something unrelated redraws.
@MainActor
final class AppearanceWatcher: ObservableObject {
    static let shared = AppearanceWatcher()

    @Published private(set) var scheme: ColorScheme
    private var observation: NSKeyValueObservation?

    private init() {
        scheme = Self.current()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                let now = AppearanceWatcher.current()
                if self?.scheme != now { self?.scheme = now }
            }
        }
    }

    static func current() -> ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
