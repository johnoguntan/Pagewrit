import AppKit

// MARK: - Model (all geometry in EMU; 12,700 EMU = 1 point)

enum SlideFill {
    case solid(NSColor)
    case gradient([NSColor], angle: CGFloat)
    case image(String)          // media path inside the package
}

struct SlideStroke {
    var color: NSColor
    var width: CGFloat          // EMU
    var dashed: Bool
}

enum PathCommand {
    case move(CGPoint), line(CGPoint), curve(CGPoint, CGPoint, CGPoint), close
}

enum SlideGeometry {
    case rect, roundRect, ellipse, triangle, diamond, line
    case path([PathCommand], CGSize)
}

struct TextRun {
    var text: String
    var size: CGFloat           // points
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var color: NSColor
    var font: String?
    var baseline: CGFloat = 0   // percent, + superscript
}

struct TextParagraph {
    var runs: [TextRun]
    var align: NSTextAlignment = .left
    var marL: CGFloat = 0       // EMU
    var indent: CGFloat = 0     // EMU
    var bullet: String?
    var spaceBefore: CGFloat = 0    // points
    var spaceAfter: CGFloat = 0
    var lineMultiple: CGFloat = 1
}

struct TextBody {
    enum Anchor { case top, middle, bottom }
    var paragraphs: [TextParagraph]
    var inset = NSEdgeInsets(top: 45720, left: 91440, bottom: 45720, right: 91440)   // EMU
    var anchor: Anchor = .top
    var wrap = true
    var shrinkToFit = false
    var fontScale: CGFloat = 1

    var isEmpty: Bool { paragraphs.allSatisfy { $0.runs.allSatisfy { $0.text.isEmpty } } }
    var plainText: String {
        paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
    }
}

struct SlideTransform2D {
    var frame: CGRect
    var rotation: CGFloat = 0   // degrees clockwise
    var flipH = false
    var flipV = false
}

struct SlideShape {
    var box: SlideTransform2D
    var geometry: SlideGeometry = .rect
    var fill: SlideFill?
    var stroke: SlideStroke?
    var text: TextBody?
}

struct SlidePicture {
    var box: SlideTransform2D
    var media: String
    var crop = NSEdgeInsets()   // fractions 0...1 of the source image
}

struct TableCell {
    var text: TextBody?
    var fill: SlideFill?
}

struct SlideTable {
    var frame: CGRect
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]
    var cells: [[TableCell]]
}

enum SlideElement {
    case shape(SlideShape)
    case picture(SlidePicture)
    case table(SlideTable)
    case unsupported(CGRect, String)
}

struct RenderSlide: Identifiable {
    let index: Int
    var background: SlideFill?
    var elements: [SlideElement]
    var notes: String
    var title: String?
    var hidden: Bool
    var id: Int { index }
    var number: Int { index + 1 }

    var unsupportedLabels: [String] {
        elements.compactMap { if case .unsupported(_, let l) = $0 { return l } else { return nil } }
    }

    /// Everything readable on the slide, for the outline.
    var text: String {
        var parts: [String] = []
        for el in elements {
            switch el {
            case .shape(let s): if let t = s.text, !t.isEmpty { parts.append(t.plainText) }
            case .table(let t):
                for row in t.cells { for c in row { if let b = c.text, !b.isEmpty { parts.append(b.plainText) } } }
            default: break
            }
        }
        return parts.joined(separator: "\n")
    }
}

/// A parsed deck, ready to draw. Immutable after loading.
final class SlideDeck: @unchecked Sendable {
    let size: CGSize                // EMU
    let slides: [RenderSlide]
    let media: [String: Data]
    let defaultBackground: NSColor
    private let imageCache = NSCache<NSString, NSImage>()

    init(size: CGSize, slides: [RenderSlide], media: [String: Data], defaultBackground: NSColor) {
        self.size = size
        self.slides = slides
        self.media = media
        self.defaultBackground = defaultBackground
    }

    var aspect: CGFloat { size.height > 0 ? size.width / size.height : 16.0 / 9.0 }

    /// Slides that appear in a slide show (hidden slides are skipped).
    var presentableIndices: [Int] { slides.filter { !$0.hidden }.map(\.index) }

    func image(for path: String) -> NSImage? {
        if let cached = imageCache.object(forKey: path as NSString) { return cached }
        guard let data = media[path], let img = NSImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: path as NSString)
        return img
    }
}

// MARK: - Parser

enum SlideDeckLoader {

    private struct Placeholder {
        var type: String?
        var idx: String?
        var rect: CGRect?
        var lstStyle: XNode?
        var bodyPr: XNode?
    }

    private struct MasterContext {
        var xml: XNode
        var colors: PPTXColorResolver
        var placeholders: [Placeholder]
        var txStyles: XNode?
    }

    private struct LayoutContext {
        var xml: XNode
        var placeholders: [Placeholder]
        var masterPath: String
    }

    /// Everything needed to parse one slide's shapes.
    private struct Context {
        var pkg: PPTXPackage
        var slidePath: String
        var rels: [String: PPTXPackage.Rel]
        var colors: PPTXColorResolver
        var layoutPlaceholders: [Placeholder]
        var masterPlaceholders: [Placeholder]
        var txStyles: XNode?
        var defaultTextStyle: XNode?
        var media: MediaBox
    }

    private final class MediaBox { var data: [String: Data] = [:] }

    private struct XForm {
        var ox: CGFloat = 0, oy: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1
        func apply(_ r: CGRect) -> CGRect {
            CGRect(x: ox + sx * r.minX, y: oy + sy * r.minY, width: sx * r.width, height: sy * r.height)
        }
        func child(off: CGPoint, ext: CGSize, chOff: CGPoint, chExt: CGSize) -> XForm {
            let kx = chExt.width != 0 ? ext.width / chExt.width : 1
            let ky = chExt.height != 0 ? ext.height / chExt.height : 1
            let nsx = sx * kx, nsy = sy * ky
            return XForm(ox: ox + sx * off.x - nsx * chOff.x, oy: oy + sy * off.y - nsy * chOff.y, sx: nsx, sy: nsy)
        }
    }

    // MARK: Entry point

    static func load(url: URL) -> SlideDeck? {
        guard let pkg = PPTXPackage(url: url),
              let pres = pkg.xml("ppt/presentation.xml") else { return nil }

        let sz = pres.child("p:sldSz")
        let size = CGSize(width: CGFloat(sz?.int("cx") ?? 9_144_000), height: CGFloat(sz?.int("cy") ?? 6_858_000))

        let presRels = pkg.rels(of: "ppt/presentation.xml")
        let slidePaths = pres.path("p:sldIdLst")?.all("p:sldId").compactMap { presRels[$0["r:id"] ?? ""]?.target } ?? []
        guard !slidePaths.isEmpty else { return nil }

        let defaultTextStyle = pres.child("p:defaultTextStyle")
        let media = MediaBox()
        var masters: [String: MasterContext] = [:]
        var layouts: [String: LayoutContext] = [:]
        var slides: [RenderSlide] = []
        var defaultBackground = NSColor.white

        for (i, slidePath) in slidePaths.enumerated() {
            guard let slideXML = pkg.xml(slidePath) else { continue }
            let rels = pkg.rels(of: slidePath)

            // Layout and master (cached across slides).
            let layoutPath = rels.values.first { $0.type == "slideLayout" }?.target
            var layout: LayoutContext?
            if let layoutPath {
                if let cached = layouts[layoutPath] { layout = cached }
                else if let xml = pkg.xml(layoutPath) {
                    let masterPath = pkg.rels(of: layoutPath).values.first { $0.type == "slideMaster" }?.target ?? ""
                    let ctx = LayoutContext(xml: xml, placeholders: placeholders(in: xml.path("p:cSld", "p:spTree")), masterPath: masterPath)
                    layouts[layoutPath] = ctx
                    layout = ctx
                }
            }
            var master: MasterContext?
            if let mp = layout?.masterPath, !mp.isEmpty {
                if let cached = masters[mp] { master = cached }
                else if let xml = pkg.xml(mp) {
                    let themePath = pkg.rels(of: mp).values.first { $0.type == "theme" }?.target
                    let theme = themePath.flatMap { pkg.xml($0) }.map(PPTXTheme.init(root:)) ?? PPTXTheme()
                    var cmap: [String: String] = [:]
                    if let m = xml.child("p:clrMap") { cmap = m.attrs }
                    let colors = PPTXColorResolver(theme: theme, colorMap: cmap)
                    let ctx = MasterContext(xml: xml, colors: colors,
                                            placeholders: placeholders(in: xml.path("p:cSld", "p:spTree")),
                                            txStyles: xml.child("p:txStyles"))
                    masters[mp] = ctx
                    master = ctx
                }
            }
            let colors = master?.colors ?? PPTXColorResolver(theme: PPTXTheme(), colorMap: [:])
            if i == 0 {
                if let bg = background(of: slideXML, layout: layout?.xml, master: master?.xml, colors: colors, rels: rels, pkg: pkg, media: media),
                   case .solid(let c) = bg { defaultBackground = c }
            }

            let ctx = Context(pkg: pkg, slidePath: slidePath, rels: rels, colors: colors,
                              layoutPlaceholders: layout?.placeholders ?? [],
                              masterPlaceholders: master?.placeholders ?? [],
                              txStyles: master?.txStyles, defaultTextStyle: defaultTextStyle, media: media)

            var title: String?
            let elements = parseTree(slideXML.path("p:cSld", "p:spTree"), XForm(), ctx, title: &title)
            let bg = background(of: slideXML, layout: layout?.xml, master: master?.xml, colors: colors, rels: rels, pkg: pkg, media: media)

            slides.append(RenderSlide(
                index: slides.count,
                background: bg,
                elements: elements,
                notes: notes(for: slidePath, pkg: pkg, rels: rels),
                title: title,
                hidden: slideXML["show"] == "0"))
        }

        guard !slides.isEmpty else { return nil }
        return SlideDeck(size: size, slides: slides, media: media.data, defaultBackground: defaultBackground)
    }

    // MARK: Placeholders

    private static func placeholders(in tree: XNode?) -> [Placeholder] {
        guard let tree else { return [] }
        var out: [Placeholder] = []
        for sp in tree.all("p:sp") {
            guard let ph = sp.path("p:nvSpPr", "p:nvPr", "p:ph") else { continue }
            var rect: CGRect?
            if let x = sp.path("p:spPr", "a:xfrm") { rect = frame(of: x)?.frame }
            out.append(Placeholder(type: ph["type"], idx: ph["idx"], rect: rect,
                                   lstStyle: sp.path("p:txBody", "a:lstStyle"),
                                   bodyPr: sp.path("p:txBody", "a:bodyPr")))
        }
        return out
    }

    private static func normalizedType(_ t: String?) -> String {
        switch t {
        case "title", "ctrTitle": return "title"
        case "dt", "ftr", "sldNum": return t!
        default: return "body"
        }
    }

    private static func match(_ ph: XNode, in list: [Placeholder]) -> Placeholder? {
        let idx = ph["idx"], type = ph["type"]
        if let idx, let m = list.first(where: { $0.idx == idx }) { return m }
        let norm = normalizedType(type)
        return list.first { normalizedType($0.type) == norm && (type == nil || $0.type == type || normalizedType($0.type) == norm) }
    }

    // MARK: Geometry helpers

    private static func frame(of xfrm: XNode) -> SlideTransform2D? {
        guard let off = xfrm.child("a:off"), let ext = xfrm.child("a:ext") else { return nil }
        let r = CGRect(x: CGFloat(off.double("x") ?? 0), y: CGFloat(off.double("y") ?? 0),
                       width: CGFloat(ext.double("cx") ?? 0), height: CGFloat(ext.double("cy") ?? 0))
        return SlideTransform2D(frame: r, rotation: CGFloat((xfrm.double("rot") ?? 0) / 60000),
                                flipH: xfrm["flipH"] == "1", flipV: xfrm["flipV"] == "1")
    }

    private static func place(_ t: SlideTransform2D, with x: XForm) -> SlideTransform2D {
        var out = t
        out.frame = x.apply(t.frame)
        return out
    }

    // MARK: Tree

    private static func parseTree(_ tree: XNode?, _ x: XForm, _ ctx: Context, title: inout String?) -> [SlideElement] {
        guard let tree else { return [] }
        var out: [SlideElement] = []
        for node in tree.children {
            switch node.name {
            case "p:sp":
                if let el = parseShape(node, x, ctx, title: &title) { out.append(el) }
            case "p:cxnSp":
                if let el = parseShape(node, x, ctx, title: &title, connector: true) { out.append(el) }
            case "p:pic":
                if let el = parsePicture(node, x, ctx) { out.append(el) }
            case "p:grpSp":
                guard let gx = node.path("p:grpSpPr", "a:xfrm"),
                      let off = gx.child("a:off"), let ext = gx.child("a:ext"),
                      let chOff = gx.child("a:chOff"), let chExt = gx.child("a:chExt") else {
                    out.append(contentsOf: parseTree(node, x, ctx, title: &title)); continue
                }
                let nx = x.child(
                    off: CGPoint(x: off.double("x") ?? 0, y: off.double("y") ?? 0),
                    ext: CGSize(width: ext.double("cx") ?? 0, height: ext.double("cy") ?? 0),
                    chOff: CGPoint(x: chOff.double("x") ?? 0, y: chOff.double("y") ?? 0),
                    chExt: CGSize(width: chExt.double("cx") ?? 0, height: chExt.double("cy") ?? 0))
                out.append(contentsOf: parseTree(node, nx, ctx, title: &title))
            case "p:graphicFrame":
                if let el = parseGraphicFrame(node, x, ctx) { out.append(el) }
            default:
                break
            }
        }
        return out
    }

    // MARK: Fills and strokes

    /// (specified, fill): `specified` is true when the properties say something
    /// about the fill at all, including an explicit noFill.
    private static func parseFill(_ props: XNode?, _ ctx: Context, phColor: NSColor? = nil) -> (Bool, SlideFill?) {
        guard let props else { return (false, nil) }
        for c in props.children {
            switch c.name {
            case "a:noFill": return (true, nil)
            case "a:solidFill":
                if let col = ctx.colors.color(inFill: c, placeholder: phColor) { return (true, .solid(col)) }
            case "a:gradFill":
                let stops = (c.child("a:gsLst")?.all("a:gs") ?? [])
                    .sorted { ($0.double("pos") ?? 0) < ($1.double("pos") ?? 0) }
                    .compactMap { ctx.colors.color(inFill: $0, placeholder: phColor) }
                if !stops.isEmpty {
                    let ang = CGFloat((c.child("a:lin")?.double("ang") ?? 5_400_000) / 60000)
                    return (true, .gradient(stops, angle: ang))
                }
            case "a:blipFill":
                if let rid = c.child("a:blip")?["r:embed"], let path = ctx.rels[rid]?.target {
                    loadMedia(path, ctx); return (true, .image(path))
                }
            default: break
            }
        }
        return (false, nil)
    }

    private static func loadMedia(_ path: String, _ ctx: Context) {
        if ctx.media.data[path] == nil, let d = ctx.pkg.data(path) { ctx.media.data[path] = d }
    }

    private static func parseStroke(_ spPr: XNode?, style: XNode?, _ ctx: Context) -> SlideStroke? {
        if let ln = spPr?.child("a:ln") {
            if ln.child("a:noFill") != nil { return nil }
            if let fill = ln.child("a:solidFill"), let c = ctx.colors.color(inFill: fill) {
                return SlideStroke(color: c, width: CGFloat(ln.double("w") ?? 9525),
                                   dashed: (ln.child("a:prstDash")?["val"] ?? "solid") != "solid")
            }
        }
        if let ref = style?.child("a:lnRef"), (ref.int("idx") ?? 0) > 0,
           let c = ctx.colors.color(inFill: ref) {
            let widths: [CGFloat] = [0, 9525, 25400, 38100]
            let idx = min(max(ref.int("idx") ?? 1, 0), 3)
            return SlideStroke(color: c, width: widths[idx], dashed: false)
        }
        return nil
    }

    // MARK: Shapes

    private static func parseShape(_ sp: XNode, _ x: XForm, _ ctx: Context,
                                   title: inout String?, connector: Bool = false) -> SlideElement? {
        let nvPr = connector ? sp.path("p:nvCxnSpPr", "p:nvPr") : sp.path("p:nvSpPr", "p:nvPr")
        let ph = nvPr?.child("p:ph")
        let spPr = sp.child("p:spPr")
        let style = sp.child("p:style")

        let layoutPH = ph.flatMap { match($0, in: ctx.layoutPlaceholders) }
        let masterPH = ph.flatMap { match($0, in: ctx.masterPlaceholders) }

        var box: SlideTransform2D?
        if let xf = spPr?.child("a:xfrm") { box = frame(of: xf).map { place($0, with: x) } }
        else if ph != nil, let r = layoutPH?.rect ?? masterPH?.rect {
            box = SlideTransform2D(frame: x.apply(r))
        }
        guard let box, box.frame.width >= 0, box.frame.height >= 0 else { return nil }

        // Geometry
        var geometry = SlideGeometry.rect
        if connector { geometry = .line }
        if let prst = spPr?.child("a:prstGeom")?["prst"] {
            switch prst {
            case "roundRect", "round1Rect", "round2SameRect": geometry = .roundRect
            case "ellipse": geometry = .ellipse
            case "triangle", "rtTriangle": geometry = .triangle
            case "diamond": geometry = .diamond
            case "line", "straightConnector1": geometry = .line
            default: geometry = .rect
            }
        } else if let cust = spPr?.child("a:custGeom"), let g = customGeometry(cust) {
            geometry = g
        }

        // Fill / stroke. Placeholders and text boxes default to no fill.
        let styleColor = style?.child("a:fillRef").flatMap { (ref: XNode) -> NSColor? in
            (ref.int("idx") ?? 0) > 0 ? ctx.colors.color(inFill: ref) : nil
        }
        let explicit = parseFill(spPr, ctx, phColor: styleColor)
        var fill: SlideFill? = explicit.1
        if !explicit.0, ph == nil, let c = styleColor,
           sp.path("p:nvSpPr", "p:cNvSpPr")?["txBox"] != "1" { fill = .solid(c) }
        let stroke = parseStroke(spPr, style: style, ctx)

        // Text
        var body: TextBody?
        if let tx = sp.child("p:txBody") {
            let kind = ph == nil ? "other" : (normalizedType(ph?["type"]) == "title" ? "title" : (normalizedType(ph?["type"]) == "body" ? "body" : "other"))
            var chain: [XNode] = []
            if let l = tx.child("a:lstStyle") { chain.append(l) }
            if let l = layoutPH?.lstStyle { chain.append(l) }
            if let l = masterPH?.lstStyle { chain.append(l) }
            switch kind {
            case "title": if let s = ctx.txStyles?.child("p:titleStyle") { chain.append(s) }
            case "body": if let s = ctx.txStyles?.child("p:bodyStyle") { chain.append(s) }
            default: if let s = ctx.txStyles?.child("p:otherStyle") { chain.append(s) }
            }
            if let d = ctx.defaultTextStyle { chain.append(d) }

            let fontRefColor = style?.child("a:fontRef").flatMap { ctx.colors.color(inFill: $0) }
            var bodyPrs: [XNode] = []
            if let b = tx.child("a:bodyPr") { bodyPrs.append(b) }
            if let b = layoutPH?.bodyPr { bodyPrs.append(b) }
            if let b = masterPH?.bodyPr { bodyPrs.append(b) }

            body = parseBody(tx, chain: chain, bodyPrs: bodyPrs, isTitle: kind == "title",
                             fallbackColor: fontRefColor, ctx)
            if kind == "title", title == nil, let t = body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                title = t.replacingOccurrences(of: "\n", with: " ")
            }
        }

        return .shape(SlideShape(box: box, geometry: geometry, fill: fill, stroke: stroke, text: body))
    }

    private static func customGeometry(_ cust: XNode) -> SlideGeometry? {
        guard let path = cust.path("a:pathLst", "a:path") else { return nil }
        let w = CGFloat(path.double("w") ?? 0), h = CGFloat(path.double("h") ?? 0)
        guard w > 0, h > 0 else { return nil }
        func pt(_ n: XNode?) -> CGPoint { CGPoint(x: n?.double("x") ?? 0, y: n?.double("y") ?? 0) }
        var cmds: [PathCommand] = []
        for c in path.children {
            switch c.name {
            case "a:moveTo": cmds.append(.move(pt(c.child("a:pt"))))
            case "a:lnTo": cmds.append(.line(pt(c.child("a:pt"))))
            case "a:cubicBezTo":
                let p = c.all("a:pt")
                if p.count == 3 { cmds.append(.curve(pt(p[0]), pt(p[1]), pt(p[2]))) }
            case "a:close": cmds.append(.close)
            default: break
            }
        }
        return cmds.isEmpty ? nil : .path(cmds, CGSize(width: w, height: h))
    }

    // MARK: Pictures

    private static func parsePicture(_ pic: XNode, _ x: XForm, _ ctx: Context) -> SlideElement? {
        guard let xf = pic.path("p:spPr", "a:xfrm"), let t = frame(of: xf),
              let blipFill = pic.child("p:blipFill"),
              let rid = blipFill.child("a:blip")?["r:embed"],
              let path = ctx.rels[rid]?.target else { return nil }
        loadMedia(path, ctx)
        var crop = NSEdgeInsets()
        if let s = blipFill.child("a:srcRect") {
            crop = NSEdgeInsets(top: CGFloat(s.double("t") ?? 0) / 100000, left: CGFloat(s.double("l") ?? 0) / 100000,
                                bottom: CGFloat(s.double("b") ?? 0) / 100000, right: CGFloat(s.double("r") ?? 0) / 100000)
        }
        return .picture(SlidePicture(box: place(t, with: x), media: path, crop: crop))
    }

    // MARK: Tables, charts and other frames

    private static func parseGraphicFrame(_ gf: XNode, _ x: XForm, _ ctx: Context) -> SlideElement? {
        guard let xf = gf.child("p:xfrm"), let t = frame(of: xf) else { return nil }
        let f = x.apply(t.frame)
        let data = gf.path("a:graphic", "a:graphicData")
        let uri = data?["uri"] ?? ""

        if let tbl = data?.child("a:tbl") {
            let cols = (tbl.child("a:tblGrid")?.all("a:gridCol") ?? []).map { CGFloat($0.double("w") ?? 0) * x.sx }
            var heights: [CGFloat] = []
            var cells: [[TableCell]] = []
            for tr in tbl.all("a:tr") {
                heights.append(CGFloat(tr.double("h") ?? 370840) * x.sy)
                var row: [TableCell] = []
                for tc in tr.all("a:tc") {
                    var chain: [XNode] = []
                    if let d = ctx.defaultTextStyle { chain.append(d) }
                    var body: TextBody?
                    if let tx = tc.child("a:txBody") {
                        body = parseBody(tx, chain: chain, bodyPrs: [], isTitle: false, fallbackColor: nil, ctx)
                        body?.inset = NSEdgeInsets(top: 45720, left: 91440, bottom: 45720, right: 91440)
                    }
                    row.append(TableCell(text: body, fill: parseFill(tc.child("a:tcPr"), ctx).1))
                }
                cells.append(row)
            }
            return .table(SlideTable(frame: f, columnWidths: cols, rowHeights: heights, cells: cells))
        }
        let label: String
        if uri.contains("chart") { label = "Chart" }
        else if uri.contains("diagram") { label = "SmartArt" }
        else if uri.contains("ole") || gf.descendants("p:oleObj").count > 0 { label = "Embedded object" }
        else { label = "Content" }
        return .unsupported(f, label)
    }

    // MARK: Background

    private static func background(of slide: XNode, layout: XNode?, master: XNode?, colors: PPTXColorResolver,
                                   rels: [String: PPTXPackage.Rel], pkg: PPTXPackage, media: MediaBox) -> SlideFill? {
        let dummy = Context(pkg: pkg, slidePath: "", rels: rels, colors: colors, layoutPlaceholders: [],
                            masterPlaceholders: [], txStyles: nil, defaultTextStyle: nil, media: media)
        for part in [slide, layout, master] {
            guard let bg = part?.path("p:cSld", "p:bg") else { continue }
            if let props = bg.child("p:bgPr") {
                let r = parseFill(props, dummy)
                if r.0 { return r.1 }
            } else if let ref = bg.child("p:bgRef"), let c = colors.color(inFill: ref) {
                return .solid(c)
            }
        }
        return nil
    }

    // MARK: Notes

    private static func notes(for slidePath: String, pkg: PPTXPackage, rels: [String: PPTXPackage.Rel]) -> String {
        guard let path = rels.values.first(where: { $0.type == "notesSlide" })?.target,
              let xml = pkg.xml(path), let tree = xml.path("p:cSld", "p:spTree") else { return "" }
        var lines: [String] = []
        for sp in tree.all("p:sp") {
            guard sp.path("p:nvSpPr", "p:nvPr", "p:ph")?["type"] == "body" else { continue }
            for p in sp.path("p:txBody")?.all("a:p") ?? [] {
                let line = p.descendants("a:t").map(\.text).joined()
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Text

    private static func parseBody(_ tx: XNode, chain: [XNode], bodyPrs: [XNode], isTitle: Bool,
                                  fallbackColor: NSColor?, _ ctx: Context) -> TextBody {
        func bodyAttr(_ key: String) -> String? {
            for b in bodyPrs { if let v = b[key] { return v } }
            return nil
        }
        var body = TextBody(paragraphs: [])
        body.inset = NSEdgeInsets(
            top: CGFloat(Double(bodyAttr("tIns") ?? "") ?? 45720), left: CGFloat(Double(bodyAttr("lIns") ?? "") ?? 91440),
            bottom: CGFloat(Double(bodyAttr("bIns") ?? "") ?? 45720), right: CGFloat(Double(bodyAttr("rIns") ?? "") ?? 91440))
        switch bodyAttr("anchor") {
        case "ctr": body.anchor = .middle
        case "b": body.anchor = .bottom
        default: body.anchor = .top
        }
        body.wrap = bodyAttr("wrap") != "none"
        for b in bodyPrs {
            if let fit = b.child("a:normAutofit") {
                body.shrinkToFit = true
                if let fs = fit.double("fontScale") { body.fontScale = CGFloat(fs / 100000) }
                break
            }
        }

        let theme = ctx.colors.theme
        let defaultColor = fallbackColor
            ?? theme.colors[ctx.colors.colorMap["tx1"] ?? "dk1"] ?? .black
        var autoNumbers: [Int: Int] = [:]

        for p in tx.all("a:p") {
            let pPr = p.child("a:pPr")
            let lvl = min(max(pPr?.int("lvl") ?? 0, 0), 8)
            let key = "a:lvl\(lvl + 1)pPr"

            func pAttr(_ name: String) -> String? {
                if let v = pPr?[name] { return v }
                for src in chain { if let v = src.child(key)?[name] { return v } }
                return nil
            }
            func pChild(_ name: String) -> XNode? {
                if let c = pPr?.child(name) { return c }
                for src in chain { if let c = src.child(key)?.child(name) { return c } }
                return nil
            }
            func defChild(_ name: String) -> XNode? {
                for src in chain { if let c = src.child(key)?.child("a:defRPr")?.child(name) { return c } }
                return nil
            }
            func defAttr(_ name: String) -> String? {
                for src in chain { if let v = src.child(key)?.child("a:defRPr")?[name] { return v } }
                return nil
            }

            var para = TextParagraph(runs: [])
            switch pAttr("algn") {
            case "ctr": para.align = .center
            case "r": para.align = .right
            case "just": para.align = .justified
            default: para.align = .left
            }
            para.marL = CGFloat(Double(pAttr("marL") ?? "") ?? 0)
            para.indent = CGFloat(Double(pAttr("indent") ?? "") ?? 0)
            if let pct = pChild("a:lnSpc")?.child("a:spcPct")?.double("val") { para.lineMultiple = CGFloat(pct / 100000) }
            if let pts = pChild("a:spcBef")?.child("a:spcPts")?.double("val") { para.spaceBefore = CGFloat(pts / 100) }
            if let pts = pChild("a:spcAft")?.child("a:spcPts")?.double("val") { para.spaceAfter = CGFloat(pts / 100) }

            // Bullet
            var bullet: String?
            let bu = pPr?.children.first { ["a:buNone", "a:buChar", "a:buAutoNum"].contains($0.name) }
                ?? chain.compactMap { $0.child(key)?.children.first { ["a:buNone", "a:buChar", "a:buAutoNum"].contains($0.name) } }.first
            if let bu {
                if bu.name == "a:buChar" { bullet = bu["char"] ?? "\u{2022}" }
                else if bu.name == "a:buAutoNum" {
                    let n = (autoNumbers[lvl] ?? 0) + 1
                    autoNumbers[lvl] = n
                    bullet = "\(n)."
                }
            }
            if bu?.name != "a:buAutoNum" { autoNumbers[lvl] = nil }
            if lvl < 8 { for deeper in (lvl + 1)...8 { autoNumbers[deeper] = nil } }
            para.bullet = bullet

            func makeRun(_ text: String, _ rPr: XNode?) -> TextRun {
                func attr(_ name: String) -> String? { rPr?[name] ?? defAttr(name) }
                let sizeHundredths = Double(attr("sz") ?? "") ?? 1800
                var color = defaultColor
                if let fill = rPr?.child("a:solidFill") ?? defChild("a:solidFill"),
                   let c = ctx.colors.color(inFill: fill) { color = c }
                var face = rPr?.child("a:latin")?["typeface"] ?? defChild("a:latin")?["typeface"]
                if face == "+mj-lt" { face = theme.majorFont } else if face == "+mn-lt" { face = theme.minorFont }
                if face == nil { face = isTitle ? theme.majorFont : theme.minorFont }
                return TextRun(text: text, size: CGFloat(sizeHundredths / 100),
                               bold: attr("b") == "1", italic: attr("i") == "1",
                               underline: (attr("u") ?? "none") != "none",
                               strike: (attr("strike") ?? "noStrike") != "noStrike",
                               color: color, font: face,
                               baseline: CGFloat(Double(attr("baseline") ?? "") ?? 0) / 1000)
            }

            for node in p.children {
                switch node.name {
                case "a:r", "a:fld":
                    let t = node.child("a:t")?.text ?? ""
                    para.runs.append(makeRun(t, node.child("a:rPr")))
                case "a:br":
                    para.runs.append(makeRun("\u{2028}", node.child("a:rPr")))
                default: break
                }
            }
            if para.runs.isEmpty {
                // Keep empty paragraphs' height using the end-of-paragraph size.
                para.runs.append(makeRun("", p.child("a:endParaRPr")))
            }
            body.paragraphs.append(para)
        }
        return body
    }
}
