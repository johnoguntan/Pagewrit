import AppKit

/// How reflowable documents (Word, RTF, plain text, Markdown) are drawn:
/// one set of typography settings shared by all of them, derived from the
/// reader theme so they match the EPUB and PDF readers.
struct ReaderTextStyle: Equatable {
    enum Face: String, CaseIterable, Identifiable {
        case serif, sans, mono
        var id: String { rawValue }
        var label: String {
            switch self {
            case .serif: "Serif"
            case .sans: "Sans"
            case .mono: "Mono"
            }
        }
    }

    var face: Face = .serif
    var size: CGFloat = 17
    var lineHeight: CGFloat = 1.5
    var textColor: NSColor = .labelColor
    var secondaryColor: NSColor = .secondaryLabelColor
    var linkColor: NSColor = .linkColor

    func font(size: CGFloat? = nil, bold: Bool = false, italic: Bool = false, forceMono: Bool = false) -> NSFont {
        let pt = size ?? self.size
        let base = NSFont.systemFont(ofSize: pt, weight: bold ? .bold : .regular)
        var descriptor = base.fontDescriptor
        if forceMono || face == .mono {
            descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        } else if face == .serif {
            descriptor = descriptor.withDesign(.serif) ?? descriptor
        }
        if italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }
        return NSFont(descriptor: descriptor, size: pt) ?? base
    }

    func paragraphStyle(headIndent: CGFloat = 0, firstLineIndent: CGFloat? = nil,
                        spacingScale: CGFloat = 0.6) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeight
        p.paragraphSpacing = size * spacingScale
        p.headIndent = headIndent
        p.firstLineHeadIndent = firstLineIndent ?? headIndent
        return p
    }
}

// MARK: - Markdown

/// A small, dependency-free Markdown renderer: headings, paragraphs, bullet
/// and numbered lists, block quotes, code blocks, rules, and inline bold,
/// italic, code, strikethrough and links. It is for reading notes and
/// documents, not a full CommonMark implementation (no tables or images).
enum MarkdownRenderer {

    static func render(_ source: String, style: ReaderTextStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var paragraph: [String] = []
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ")
            paragraph.removeAll()
            append(inline(text, style: style), to: out, paragraph: style.paragraphStyle())
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                inCode.toggle()
                continue
            }
            if inCode {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: style.font(size: style.size * 0.88, forceMono: true),
                    .foregroundColor: style.textColor,
                    .backgroundColor: style.secondaryColor.withAlphaComponent(0.12),
                    .paragraphStyle: style.paragraphStyle(headIndent: 12, spacingScale: 0.05)
                ]
                out.append(NSAttributedString(string: line + "\n", attributes: attrs))
                continue
            }
            if trimmed.isEmpty { flushParagraph(); continue }

            if let (level, text) = heading(trimmed) {
                flushParagraph()
                let scales: [CGFloat] = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0]
                let size = style.size * scales[min(level, 6) - 1]
                var attrs = baseAttributes(style, size: size, bold: true)
                attrs[.paragraphStyle] = style.paragraphStyle(spacingScale: 0.5)
                let heading = NSMutableAttributedString(attributedString: inline(text, style: style, size: size, bold: true))
                heading.addAttributes([.paragraphStyle: attrs[.paragraphStyle] as Any], range: NSRange(location: 0, length: heading.length))
                heading.append(NSAttributedString(string: "\n"))
                out.append(heading)
                continue
            }
            if isRule(trimmed) {
                flushParagraph()
                out.append(NSAttributedString(string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", attributes: [
                    .font: style.font(), .foregroundColor: style.secondaryColor,
                    .paragraphStyle: style.paragraphStyle()
                ]))
                continue
            }
            if let (depth, marker, text) = listItem(line) {
                flushParagraph()
                let indent = style.size * 1.4 * CGFloat(depth + 1)
                let item = NSMutableAttributedString(string: marker + "\u{2009}\u{2009}", attributes: baseAttributes(style))
                item.append(inline(text, style: style))
                let ps = style.paragraphStyle(headIndent: indent, firstLineIndent: indent - style.size * 1.1, spacingScale: 0.25)
                append(item, to: out, paragraph: ps)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == ">" })).trimmingCharacters(in: .whitespaces)
                let quote = NSMutableAttributedString(attributedString: inline(text, style: style, italic: true))
                quote.addAttribute(.foregroundColor, value: style.secondaryColor, range: NSRange(location: 0, length: quote.length))
                append(quote, to: out, paragraph: style.paragraphStyle(headIndent: style.size * 1.2))
                continue
            }
            paragraph.append(trimmed)
        }
        flushParagraph()
        return out
    }

    // MARK: Helpers

    private static func append(_ text: NSAttributedString, to out: NSMutableAttributedString, paragraph: NSParagraphStyle) {
        let m = NSMutableAttributedString(attributedString: text)
        m.append(NSAttributedString(string: "\n"))
        m.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: m.length))
        out.append(m)
    }

    private static func baseAttributes(_ style: ReaderTextStyle, size: CGFloat? = nil, bold: Bool = false) -> [NSAttributedString.Key: Any] {
        [.font: style.font(size: size, bold: bold), .foregroundColor: style.textColor]
    }

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = Set(line.filter { !$0.isWhitespace })
        return line.count >= 3 && chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    /// (nesting depth, bullet or "1." marker, text)
    private static func listItem(_ line: String) -> (Int, String, String)? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let rest = line.dropFirst(leading)
        let depth = leading / 2
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (depth, "\u{2022}", rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix(while: { $0.isNumber })
        if !digits.isEmpty {
            let after = rest.dropFirst(digits.count)
            if let sep = after.first, sep == "." || sep == ")", after.dropFirst().first == " " {
                return (depth, "\(digits).", after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func inline(_ text: String, style: ReaderTextStyle, size: CGFloat? = nil,
                       bold: Bool = false, italic: Bool = false) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [
                .font: style.font(size: size, bold: bold, italic: italic), .foregroundColor: style.textColor])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let isCode = intent.contains(.code)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: style.font(size: isCode ? (size ?? style.size) * 0.9 : size,
                                  bold: bold || intent.contains(.stronglyEmphasized),
                                  italic: italic || intent.contains(.emphasized),
                                  forceMono: isCode),
                .foregroundColor: style.textColor
            ]
            if isCode { attrs[.backgroundColor] = style.secondaryColor.withAlphaComponent(0.12) }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link {
                attrs[.link] = link
                attrs[.foregroundColor] = style.linkColor
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

// MARK: - Rich documents (Word, RTF, ODT)

enum RichDocumentStyler {
    /// Re-skins an imported document with the reader's typography while
    /// keeping its structure: headings stay bigger than body text, bold and
    /// italic survive, images and links are untouched.
    static func restyle(_ source: NSAttributedString, style: ReaderTextStyle) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: m.length)
        guard full.length > 0 else { return m }

        // Body size = the font size covering the most characters.
        var counts: [CGFloat: Int] = [:]
        m.enumerateAttribute(.font, in: full) { value, range, _ in
            if let f = value as? NSFont { counts[f.pointSize, default: 0] += range.length }
        }
        let body = counts.max(by: { $0.value < $1.value })?.key ?? 12

        m.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let f = value as? NSFont else {
                m.addAttribute(.font, value: style.font(), range: range)
                return
            }
            let traits = f.fontDescriptor.symbolicTraits
            let size = max(8, f.pointSize / body * style.size)
            m.addAttribute(.font, value: style.font(
                size: size,
                bold: traits.contains(.bold),
                italic: traits.contains(.italic),
                forceMono: traits.contains(.monoSpace)), range: range)
        }

        m.enumerateAttribute(.link, in: full) { value, range, _ in
            m.addAttribute(.foregroundColor, value: value == nil ? style.textColor : style.linkColor, range: range)
        }

        m.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let p = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            p.lineHeightMultiple = style.lineHeight
            p.paragraphSpacing = max(p.paragraphSpacing, style.size * 0.5)
            m.addAttribute(.paragraphStyle, value: p, range: range)
        }
        return m
    }
}
