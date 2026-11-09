import AppKit

/// Draws parsed slides with Core Graphics / AppKit text. Used for the
/// reader, thumbnails, the presenter, and PDF/PNG export, so every surface
/// shows the same picture.
///
/// Supported: backgrounds (solid, gradient, image), shapes (rectangles,
/// rounded rectangles, ellipses, triangles, diamonds, lines, freeform
/// paths), pictures with cropping, text with theme fonts/colors/bullets and
/// shrink-to-fit, groups, rotation and flips, and basic tables.
/// Not drawn: charts, SmartArt, embedded objects, video, animations and
/// transitions (charts and SmartArt show a labelled placeholder).
enum SlideRenderer {

    // MARK: Entry points

    /// A bitmap of one slide, `pixelWidth` pixels wide.
    static func image(deck: SlideDeck, index: Int, pixelWidth: CGFloat) -> NSImage {
        let width = max(1, pixelWidth.rounded())
        let height = max(1, (width / deck.aspect).rounded())
        guard deck.slides.indices.contains(index),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gc = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        drawFlipped(on: gc.cgContext, height: height) {
            draw(deck: deck, slide: deck.slides[index], in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        return img
    }

    /// A PDF with one page per slide (hidden slides included only if asked).
    static func pdfData(deck: SlideDeck, includeHidden: Bool = false) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        // Slide size in points.
        var box = CGRect(x: 0, y: 0, width: deck.size.width / 12700, height: deck.size.height / 12700)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for slide in deck.slides where includeHidden || !slide.hidden {
            ctx.beginPDFPage(nil)
            drawFlipped(on: ctx, height: box.height) { draw(deck: deck, slide: slide, in: box) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    private static func drawFlipped(on cg: CGContext, height: CGFloat, _ body: () -> Void) {
        cg.saveGState()
        cg.translateBy(x: 0, y: height)
        cg.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body()
        NSGraphicsContext.current = previous
        cg.restoreGState()
    }

    // MARK: Slide

    /// Draws into `rect` of a flipped (top-left origin) graphics context.
    static func draw(deck: SlideDeck, slide: RenderSlide, in rect: CGRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let scale = rect.width / deck.size.width          // EMU → drawing units
        cg.saveGState()
        cg.clip(to: rect)
        cg.translateBy(x: rect.minX, y: rect.minY)

        // Background
        let bgRect = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        if let bg = slide.background {
            fill(bg, path: NSBezierPath(rect: bgRect), deck: deck, in: bgRect)
        } else {
            deck.defaultBackground.setFill()
            NSBezierPath(rect: bgRect).fill()
        }

        for element in slide.elements {
            switch element {
            case .shape(let s): drawShape(s, deck: deck, scale: scale)
            case .picture(let p): drawPicture(p, deck: deck, scale: scale)
            case .table(let t): drawTable(t, deck: deck, scale: scale)
            case .unsupported(let frame, let label): drawPlaceholder(frame, label: label, scale: scale)
            }
        }
        cg.restoreGState()
    }

    // MARK: Transform helper

    private static func withTransform(_ box: SlideTransform2D, scale: CGFloat, _ body: (CGRect) -> Void) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let f = CGRect(x: box.frame.minX * scale, y: box.frame.minY * scale,
                       width: box.frame.width * scale, height: box.frame.height * scale)
        cg.saveGState()
        if box.rotation != 0 || box.flipH || box.flipV {
            cg.translateBy(x: f.midX, y: f.midY)
            if box.rotation != 0 { cg.rotate(by: box.rotation * .pi / 180) }
            cg.scaleBy(x: box.flipH ? -1 : 1, y: box.flipV ? -1 : 1)
            cg.translateBy(x: -f.midX, y: -f.midY)
        }
        body(f)
        cg.restoreGState()
    }

    // MARK: Shapes

    private static func drawShape(_ s: SlideShape, deck: SlideDeck, scale: CGFloat) {
        withTransform(s.box, scale: scale) { f in
            let path = bezier(for: s.geometry, in: f)
            if let fillSpec = s.fill, !isLine(s.geometry) { fill(fillSpec, path: path, deck: deck, in: f) }
            if let stroke = s.stroke {
                stroke.color.setStroke()
                path.lineWidth = max(0.5, stroke.width * scale)
                if stroke.dashed { path.setLineDash([path.lineWidth * 3, path.lineWidth * 2], count: 2, phase: 0) }
                path.stroke()
            }
            if let text = s.text, !text.isEmpty {
                drawText(text, in: f, scale: scale)
            }
        }
    }

    private static func isLine(_ g: SlideGeometry) -> Bool {
        if case .line = g { return true }
        return false
    }

    private static func bezier(for geometry: SlideGeometry, in f: CGRect) -> NSBezierPath {
        switch geometry {
        case .rect:
            return NSBezierPath(rect: f)
        case .roundRect:
            let r = min(f.width, f.height) * 0.1667
            return NSBezierPath(roundedRect: f, xRadius: r, yRadius: r)
        case .ellipse:
            return NSBezierPath(ovalIn: f)
        case .triangle:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: f.midX, y: f.minY))
            p.line(to: CGPoint(x: f.maxX, y: f.maxY))
            p.line(to: CGPoint(x: f.minX, y: f.maxY))
            p.close()
            return p
        case .diamond:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: f.midX, y: f.minY))
            p.line(to: CGPoint(x: f.maxX, y: f.midY))
            p.line(to: CGPoint(x: f.midX, y: f.maxY))
            p.line(to: CGPoint(x: f.minX, y: f.midY))
            p.close()
            return p
        case .line:
            let p = NSBezierPath()
            p.move(to: CGPoint(x: f.minX, y: f.minY))
            p.line(to: CGPoint(x: f.maxX, y: f.maxY))
            return p
        case .path(let cmds, let size):
            let p = NSBezierPath()
            func map(_ pt: CGPoint) -> CGPoint {
                CGPoint(x: f.minX + pt.x / size.width * f.width, y: f.minY + pt.y / size.height * f.height)
            }
            for c in cmds {
                switch c {
                case .move(let a): p.move(to: map(a))
                case .line(let a): p.line(to: map(a))
                case .curve(let a, let b, let c2): p.curve(to: map(c2), controlPoint1: map(a), controlPoint2: map(b))
                case .close: p.close()
                }
            }
            return p
        }
    }

    private static func fill(_ spec: SlideFill, path: NSBezierPath, deck: SlideDeck, in f: CGRect) {
        switch spec {
        case .solid(let c):
            c.setFill()
            path.fill()
        case .gradient(let colors, let angle):
            if colors.count >= 2, let g = NSGradient(colors: colors) {
                // OOXML angles run clockwise from the x axis; the context is flipped.
                g.draw(in: path, angle: -angle)
            } else if let c = colors.first {
                c.setFill(); path.fill()
            }
        case .image(let key):
            guard let img = deck.image(for: key), let cg = NSGraphicsContext.current?.cgContext else { return }
            cg.saveGState()
            path.addClip()
            img.draw(in: f, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            cg.restoreGState()
        }
    }

    // MARK: Pictures

    private static func drawPicture(_ p: SlidePicture, deck: SlideDeck, scale: CGFloat) {
        guard let img = deck.image(for: p.media) else { return }
        withTransform(p.box, scale: scale) { f in
            let w = img.size.width, h = img.size.height
            let src = CGRect(x: p.crop.left * w, y: p.crop.bottom * h,
                             width: w * (1 - p.crop.left - p.crop.right),
                             height: h * (1 - p.crop.top - p.crop.bottom))
            img.draw(in: f, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }

    // MARK: Placeholder for unsupported content

    private static func drawPlaceholder(_ frame: CGRect, label: String, scale: CGFloat) {
        let f = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        NSColor.gray.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: f).fill()
        let p = NSBezierPath(rect: f.insetBy(dx: 0.5, dy: 0.5))
        NSColor.gray.withAlphaComponent(0.5).setStroke()
        p.lineWidth = 1
        p.setLineDash([4, 3], count: 2, phase: 0)
        p.stroke()
        let size = max(10, min(f.width, f.height) * 0.12)
        let text = NSAttributedString(string: "\(label) \u{2014} open Preview to see it", attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.gray])
        let b = text.boundingRect(with: CGSize(width: f.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        text.draw(with: CGRect(x: f.minX, y: f.midY - b.height / 2, width: f.width, height: b.height),
                  options: [.usesLineFragmentOrigin])
    }

    // MARK: Tables

    private static func drawTable(_ t: SlideTable, deck: SlideDeck, scale: CGFloat) {
        var y = t.frame.minY * scale
        for (r, row) in t.cells.enumerated() {
            let rh = (r < t.rowHeights.count ? t.rowHeights[r] : 370_840) * scale
            var x = t.frame.minX * scale
            for (c, cell) in row.enumerated() {
                let cw = (c < t.columnWidths.count ? t.columnWidths[c] : t.frame.width / CGFloat(max(1, row.count))) * scale
                let rect = CGRect(x: x, y: y, width: cw, height: rh)
                if let fillSpec = cell.fill { fill(fillSpec, path: NSBezierPath(rect: rect), deck: deck, in: rect) }
                NSColor.gray.withAlphaComponent(0.55).setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 0.75
                border.stroke()
                if let text = cell.text, !text.isEmpty { drawText(text, in: rect, scale: scale) }
                x += cw
            }
            y += rh
        }
    }

    // MARK: Text

    private static func attributed(_ body: TextBody, scale: CGFloat, fit: CGFloat) -> NSAttributedString {
        let ptToUnit = scale * 12700            // 1 pt of slide space in drawing units
        let out = NSMutableAttributedString()
        for (i, p) in body.paragraphs.enumerated() {
            let style = NSMutableParagraphStyle()
            style.alignment = p.align
            style.lineHeightMultiple = max(0.5, p.lineMultiple)
            style.paragraphSpacingBefore = p.spaceBefore * ptToUnit * fit
            style.paragraphSpacing = p.spaceAfter * ptToUnit * fit
            let left = p.marL * scale
            style.headIndent = left
            style.firstLineHeadIndent = max(0, left + p.indent * scale)
            if p.bullet != nil {
                style.tabStops = [NSTextTab(textAlignment: .left, location: max(left, style.firstLineHeadIndent + 12))]
                style.defaultTabInterval = max(12, left)
            }
            style.lineBreakMode = body.wrap ? .byWordWrapping : .byClipping

            let para = NSMutableAttributedString()
            if let bullet = p.bullet, let first = p.runs.first, !p.runs.allSatisfy({ $0.text.isEmpty }) {
                para.append(NSAttributedString(string: bullet + "\t", attributes: attributes(for: first, ptToUnit: ptToUnit, fit: fit)))
            }
            for run in p.runs {
                para.append(NSAttributedString(string: run.text, attributes: attributes(for: run, ptToUnit: ptToUnit, fit: fit)))
            }
            if i < body.paragraphs.count - 1 { para.append(NSAttributedString(string: "\n")) }
            para.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: para.length))
            out.append(para)
        }
        return out
    }

    private static func attributes(for run: TextRun, ptToUnit: CGFloat, fit: CGFloat) -> [NSAttributedString.Key: Any] {
        let size = max(1, run.size * ptToUnit * fit * (run.baseline != 0 ? 0.65 : 1))
        var font = NSFont(name: run.font ?? "", size: size) ?? NSFont.systemFont(ofSize: size)
        if run.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: run.color]
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if run.baseline != 0 { attrs[.baselineOffset] = size * run.baseline / 100 * 1.5 }
        return attrs
    }

    private static func drawText(_ body: TextBody, in frame: CGRect, scale: CGFloat) {
        let area = CGRect(
            x: frame.minX + body.inset.left * scale, y: frame.minY + body.inset.top * scale,
            width: frame.width - (body.inset.left + body.inset.right) * scale,
            height: frame.height - (body.inset.top + body.inset.bottom) * scale)
        guard area.width > 1, area.height > 1 else { return }
        let drawWidth = body.wrap ? area.width : 10_000

        var fit = body.shrinkToFit ? body.fontScale : 1
        var text = attributed(body, scale: scale, fit: fit)
        var height = text.boundingRect(with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height
        if body.shrinkToFit {
            var guardCount = 0
            while height > area.height, fit > 0.3, guardCount < 14 {
                fit -= 0.05; guardCount += 1
                text = attributed(body, scale: scale, fit: fit)
                height = text.boundingRect(with: CGSize(width: drawWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin]).height
            }
        }

        var y = area.minY
        switch body.anchor {
        case .top: break
        case .middle: y += (area.height - height) / 2
        case .bottom: y += area.height - height
        }
        let target = CGRect(x: area.minX, y: y, width: drawWidth, height: max(height, 1))
        text.draw(with: target, options: [.usesLineFragmentOrigin])
    }
}
