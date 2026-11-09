import AppKit

#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

// MARK: - Tiny XML tree

/// A minimal XML element tree. OOXML parts are small enough to hold in
/// memory, and a tree makes the inheritance lookups slide rendering needs
/// (slide → layout → master → theme) straightforward.
final class XNode {
    let name: String
    var attrs: [String: String]
    var children: [XNode] = []
    var text = ""

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    subscript(_ key: String) -> String? { attrs[key] }

    func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XNode] { children.filter { $0.name == name } }

    func path(_ names: String...) -> XNode? {
        var node: XNode? = self
        for n in names { node = node?.child(n) }
        return node
    }

    func int(_ key: String) -> Int? { attrs[key].flatMap { Int($0) } }
    func double(_ key: String) -> Double? { attrs[key].flatMap { Double($0) } }

    /// Every descendant (depth-first) with this name.
    func descendants(_ name: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private var root: XNode?
    private var stack: [XNode] = []

    static func parse(_ data: Data) -> XNode? {
        let b = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = b
        parser.shouldProcessNamespaces = false
        parser.parse()
        return b.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        // Pathologically deep XML would overflow the stack in the recursive
        // walkers, so stop parsing instead.
        if stack.count > 200 { parser.abortParsing(); return }
        let node = XNode(name: elementName, attrs: attributeDict)
        if let top = stack.last { top.children.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

// MARK: - Package

/// Read-only access to the parts of a .pptx zip, with relationship lookup.
final class PPTXPackage {
    struct Rel {
        let id: String
        let type: String      // last path component of the relationship type, e.g. "slideLayout"
        let target: String    // resolved path inside the package
    }

    #if canImport(ZIPFoundation)
    private let archive: Archive
    #endif
    private var xmlCache: [String: XNode] = [:]

    init?(url: URL) {
        #if canImport(ZIPFoundation)
        guard let a = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }
        archive = a
        #else
        return nil
        #endif
    }

    func data(_ path: String) -> Data? {
        #if canImport(ZIPFoundation)
        // A slide part is never legitimately this large; refuse a zip bomb.
        guard let entry = archive[path], entry.uncompressedSize < 150_000_000 else { return nil }
        var out = Data()
        do { _ = try archive.extract(entry) { out.append($0) } } catch { return nil }
        return out
        #else
        return nil
        #endif
    }

    func xml(_ path: String) -> XNode? {
        if let cached = xmlCache[path] { return cached }
        guard let d = data(path), let node = XMLTreeBuilder.parse(d) else { return nil }
        xmlCache[path] = node
        return node
    }

    /// Relationships declared by `part`, keyed by id.
    func rels(of part: String) -> [String: Rel] {
        let dir = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        let relsPath = (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
        guard let root = xml(relsPath) else { return [:] }
        var out: [String: Rel] = [:]
        for r in root.all("Relationship") {
            guard let id = r["Id"], let target = r["Target"], r["TargetMode"] != "External" else { continue }
            let type = (r["Type"] ?? "").split(separator: "/").last.map(String.init) ?? ""
            out[id] = Rel(id: id, type: type, target: Self.resolve(base: part, target: target))
        }
        return out
    }

    /// First relationship of a given type (e.g. the layout of a slide).
    func firstRel(of part: String, type: String) -> Rel? {
        rels(of: part).values.first { $0.type == type }
    }

    static func resolve(base part: String, target: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var comps = (part as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/").map(String.init) {
            if piece == ".." { _ = comps.popLast() }
            else if piece != "." { comps.append(piece) }
        }
        return comps.joined(separator: "/")
    }
}

// MARK: - Theme and colors

struct PPTXTheme {
    var colors: [String: NSColor] = [:]
    var majorFont: String?
    var minorFont: String?

    init() {}

    init(root: XNode) {
        if let scheme = root.path("a:themeElements", "a:clrScheme") {
            for entry in scheme.children {
                let key = entry.name.replacingOccurrences(of: "a:", with: "")
                if let c = entry.children.first {
                    if let v = c["val"], c.name == "a:srgbClr" { colors[key] = NSColor(pptxHex: v) }
                    else if let v = c["lastClr"] { colors[key] = NSColor(pptxHex: v) }
                }
            }
        }
        if let fonts = root.path("a:themeElements", "a:fontScheme") {
            majorFont = fonts.path("a:majorFont", "a:latin")?["typeface"]
            minorFont = fonts.path("a:minorFont", "a:latin")?["typeface"]
        }
    }
}

extension NSColor {
    convenience init(pptxHex hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// Resolves DrawingML color elements (srgbClr, schemeClr, ...) with their
/// luminance/tint/alpha modifiers against a theme and color map.
struct PPTXColorResolver {
    var theme: PPTXTheme
    var colorMap: [String: String]

    private static let presets: [String: String] = [
        "black": "000000", "white": "FFFFFF", "red": "FF0000", "green": "008000", "blue": "0000FF",
        "yellow": "FFFF00", "gray": "808080", "grey": "808080", "orange": "FFA500"
    ]

    /// `element` is the color element itself, e.g. an `a:schemeClr`.
    func color(_ element: XNode, placeholder: NSColor? = nil) -> NSColor? {
        var base: NSColor?
        switch element.name {
        case "a:srgbClr": base = element["val"].map(NSColor.init(pptxHex:))
        case "a:sysClr": base = (element["lastClr"] ?? element["val"]).map(NSColor.init(pptxHex:))
        case "a:prstClr": base = element["val"].flatMap { Self.presets[$0.lowercased()] }.map(NSColor.init(pptxHex:))
        case "a:schemeClr":
            guard let name = element["val"] else { return nil }
            if name == "phClr" { base = placeholder }
            else { base = theme.colors[colorMap[name] ?? name] }
        default: return nil
        }
        guard var c = base else { return nil }

        for mod in element.children {
            let val = (mod.double("val") ?? 100000) / 100000
            switch mod.name {
            case "a:lumMod": c = c.adjustingLuminance { $0 * val }
            case "a:lumOff": c = c.adjustingLuminance { $0 + val }
            case "a:tint": c = c.blended(withFraction: 1 - val, of: .white) ?? c
            case "a:shade": c = c.blended(withFraction: 1 - val, of: .black) ?? c
            case "a:alpha": c = c.withAlphaComponent(CGFloat(val))
            default: break
            }
        }
        return c
    }

    /// Color of a fill-like parent (`a:solidFill`, `a:ln`'s fill, ...): its first color child.
    func color(inFill fill: XNode, placeholder: NSColor? = nil) -> NSColor? {
        for c in fill.children {
            if let color = color(c, placeholder: placeholder) { return color }
        }
        return nil
    }
}

private extension NSColor {
    /// Applies `f` to HSL lightness.
    func adjustingLuminance(_ f: (CGFloat) -> CGFloat) -> NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return self }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let mx = max(r, g, b), mn = min(r, g, b)
        var l = (mx + mn) / 2
        var h: CGFloat = 0, s: CGFloat = 0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        l = min(max(f(l), 0), 1)
        func hue(_ p: CGFloat, _ q: CGFloat, _ tIn: CGFloat) -> CGFloat {
            var t = tIn
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if s == 0 { return NSColor(srgbRed: l, green: l, blue: l, alpha: rgb.alphaComponent) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return NSColor(srgbRed: hue(p, q, h + 1.0 / 3), green: hue(p, q, h), blue: hue(p, q, h - 1.0 / 3),
                       alpha: rgb.alphaComponent)
    }
}
