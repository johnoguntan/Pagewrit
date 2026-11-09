import Foundation
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Turns a MOBI / AZW / PRC book into a plain EPUB in the library's
/// Converted folder, so the normal EPUB reader (and the search indexer)
/// can use it. The original file is never touched.
enum KindleConverter {

    // MARK: Public API

    /// Reads title / author / cover without converting the whole book.
    /// Never throws for DRM or unsupported books: they still import, and the
    /// reader explains the problem when opened.
    static func inspect(url: URL) -> KindleInfo? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let file = try? KindleFile(data: data) else { return nil }
        return file.info
    }

    /// Converts `source` into an EPUB at `destination` (replacing any file there).
    @discardableResult
    static func convert(source: URL, destination: URL) throws -> KindleInfo {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let file = try KindleFile(data: data)
        let raw = try file.rawText()
        let book = try file.hasMobiHeader
            ? buildHTMLBook(raw: raw, file: file)
            : buildPlainTextBook(raw: raw, file: file)
        try writeEPUB(book, info: file.info, to: destination, identifier: source.lastPathComponent)
        return file.info
    }

    // MARK: Intermediate model

    struct Chapter {
        var fileName: String      // e.g. "Chapter-One.html"
        var title: String
        var html: String          // body content
    }

    struct ConvertedBook {
        var chapters: [Chapter]
        var images: [(name: String, data: Data)]
    }

    // MARK: MOBI (HTML) → chapters

    static func buildHTMLBook(raw: [UInt8], file: KindleFile) throws -> ConvertedBook {
        // 1. Insert an anchor at every byte offset that a `filepos` link points to.
        let offsets = filePositions(in: raw)
        let anchored = insertAnchors(into: raw, at: offsets)

        // 2. Decode to text.
        var html: String
        if file.textEncoding == .utf8 {
            html = String(decoding: anchored, as: UTF8.self)
        } else {
            html = String(bytes: anchored, encoding: .windowsCP1252)
                ?? String(bytes: anchored, encoding: .isoLatin1)
                ?? String(decoding: anchored, as: UTF8.self)
        }

        // 3. Keep only the body.
        html = bodyContent(of: html)

        // 4. Page breaks become chapter boundaries; other Kindle-only tags go.
        html = replace(html, pattern: "</?mbp:pagebreak[^>]*>", with: "\n<!--PAGEBREAK-->\n")
        html = replace(html, pattern: "</?mbp:[^>]*>", with: "")

        // 5. Images: recindex → images/imgN.ext
        let images = file.images()
        html = replace(html, pattern: "\\s(?:hi|lo)recindex\\s*=\\s*[\"']?\\d+[\"']?", with: "")
        html = replaceMatches(html, pattern: "<img\\b([^>]*?)\\srecindex\\s*=\\s*[\"']?0*(\\d+)[\"']?([^>]*)>") { ns, m in
            let before = ns.substring(with: m.range(at: 1))
            let number = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let after = ns.substring(with: m.range(at: 3))
            guard let image = images[number] else { return "" }
            return "<img\(before) src=\"images/img\(number).\(image.ext)\"\(after)>"
        }

        // 6. Internal links: filepos=N → href="#fileposN"
        html = replaceMatches(html, pattern: "filepos\\s*=\\s*[\"']?0*(\\d+)[\"']?") { ns, m in
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            return "href=\"#filepos\(n)\""
        }

        // 7. Split into chapters.
        var pieces: [String] = []
        var carry = ""
        for chunk in html.components(separatedBy: "<!--PAGEBREAK-->") {
            let combined = carry + chunk
            if hasContent(combined) {
                pieces.append(combined)
                carry = ""
            } else {
                carry = combined
            }
        }
        if !carry.isEmpty {
            if pieces.isEmpty { pieces = [carry] } else { pieces[pieces.count - 1] += carry }
        }
        guard !pieces.isEmpty else { throw KindleError.malformed("no readable text") }

        let fallbackTitle = file.info.title ?? "Book"
        var chapters: [Chapter] = []
        var used = Set<String>()
        for (index, piece) in pieces.enumerated() {
            let title = headingText(in: piece) ?? (pieces.count == 1 ? fallbackTitle : "Part \(index + 1)")
            var slug = slugify(title)
            if slug.isEmpty { slug = "Part-\(index + 1)" }
            var candidate = slug
            var n = 2
            while used.contains(candidate.lowercased()) { candidate = "\(slug)-\(n)"; n += 1 }
            used.insert(candidate.lowercased())
            chapters.append(Chapter(fileName: "\(candidate).html", title: title, html: piece))
        }

        // 8. Links that point into another chapter need that chapter's file name.
        var anchorFile: [Int: String] = [:]
        for chapter in chapters {
            forEachMatch(chapter.html, pattern: "id=\"filepos(\\d+)\"") { ns, m in
                if let n = Int(ns.substring(with: m.range(at: 1))) { anchorFile[n] = chapter.fileName }
            }
        }
        for i in chapters.indices {
            let own = chapters[i].fileName
            chapters[i].html = replaceMatches(chapters[i].html, pattern: "href=\"#filepos(\\d+)\"") { ns, m in
                let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
                if let target = anchorFile[n], target != own { return "href=\"\(target)#filepos\(n)\"" }
                return "href=\"#filepos\(n)\""
            }
        }

        let imageFiles = images.keys.sorted().compactMap { key -> (String, Data)? in
            guard let image = images[key] else { return nil }
            return ("img\(key).\(image.ext)", image.data)
        }
        return ConvertedBook(chapters: chapters, images: imageFiles.map { (name: $0.0, data: $0.1) })
    }

    // MARK: Bare PalmDOC text → one chapter

    static func buildPlainTextBook(raw: [UInt8], file: KindleFile) -> ConvertedBook {
        let text = String(bytes: raw, encoding: .windowsCP1252)
            ?? String(bytes: raw, encoding: .isoLatin1)
            ?? String(decoding: raw, as: UTF8.self)
        var paragraphs: [String] = []
        for block in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") {
            let line = block.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { paragraphs.append("<p>\(xmlEscape(line))</p>") }
        }
        let title = file.info.title ?? "Book"
        let chapter = Chapter(fileName: "\(slugify(title).isEmpty ? "Book" : slugify(title)).html",
                              title: title,
                              html: paragraphs.joined(separator: "\n"))
        return ConvertedBook(chapters: [chapter], images: [])
    }

    // MARK: Offsets and anchors

    /// Every byte offset referenced by a `filepos=` link.
    static func filePositions(in raw: [UInt8]) -> Set<Int> {
        let text = String(bytes: raw, encoding: .isoLatin1) ?? ""
        var result = Set<Int>()
        forEachMatch(text, pattern: "filepos\\s*=\\s*[\"']?0*(\\d+)") { ns, m in
            if let n = Int(ns.substring(with: m.range(at: 1))) { result.insert(n) }
        }
        return result
    }

    /// Splices `<a id="fileposN"></a>` into the bytes at each target offset,
    /// backing up to the start of a tag when the offset lands inside one.
    static func insertAnchors(into raw: [UInt8], at offsets: Set<Int>) -> [UInt8] {
        guard !offsets.isEmpty else { return raw }
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")
        var byPosition: [Int: [Int]] = [:]
        for target in offsets {
            var pos = min(max(target, 0), raw.count)
            var k = pos - 1
            while k >= 0 {
                if raw[k] == gt { break }
                if raw[k] == lt { pos = k; break }
                k -= 1
            }
            byPosition[pos, default: []].append(target)
        }
        var out = [UInt8]()
        out.reserveCapacity(raw.count + byPosition.count * 24)
        var last = 0
        for pos in byPosition.keys.sorted() {
            if pos > last { out.append(contentsOf: raw[last..<pos]) }
            for id in byPosition[pos]!.sorted() {
                out.append(contentsOf: Array("<a id=\"filepos\(id)\"></a>".utf8))
            }
            last = max(last, pos)
        }
        if last < raw.count { out.append(contentsOf: raw[last...]) }
        return out
    }

    // MARK: Text helpers

    static func bodyContent(of html: String) -> String {
        guard let open = html.range(of: "<body", options: .caseInsensitive),
              let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else { return html }
        let start = close.upperBound
        if let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards]), end.lowerBound >= start {
            return String(html[start..<end.lowerBound])
        }
        return String(html[start...])
    }

    static func hasContent(_ html: String) -> Bool {
        if html.range(of: "<img", options: .caseInsensitive) != nil { return true }
        let stripped = replace(html, pattern: "<[^>]*>", with: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !stripped.isEmpty
    }

    static func headingText(in html: String) -> String? {
        let regex = try? NSRegularExpression(pattern: "<h[1-3][^>]*>(.*?)</h[1-3]>",
                                             options: [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = html as NSString
        guard let m = regex?.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var text = replace(ns.substring(with: m.range(at: 1)), pattern: "<[^>]*>", with: "")
        text = decodeEntities(text)
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        return text.count > 60 ? String(text.prefix(60)) : text
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Letters and digits only, words joined by hyphens, so the reader's
    /// "file name as chapter title" fallback shows something readable.
    static func slugify(_ title: String) -> String {
        var out = ""
        var lastWasDash = true
        for scalar in title.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }

    // MARK: Regex helpers

    static func replace(_ s: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    static func replaceMatches(_ s: String, pattern: String,
                               transform: (NSString, NSTextCheckingResult) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += transform(ns, m)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func forEachMatch(_ s: String, pattern: String, _ body: (NSString, NSTextCheckingResult) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        let ns = s as NSString
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) { body(ns, m) }
    }

    // MARK: EPUB writer

    static func writeEPUB(_ book: ConvertedBook, info: KindleInfo, to destination: URL, identifier: String) throws {
        #if canImport(ZIPFoundation)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pagewrit-kindle-\(UUID().uuidString)", isDirectory: true)
        let oebps = work.appendingPathComponent("OEBPS", isDirectory: true)
        let imagesDir = oebps.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("META-INF", isDirectory: true),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }

        try write("application/epub+zip", work.appendingPathComponent("mimetype"))
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """, work.appendingPathComponent("META-INF/container.xml"))

        let title = info.title ?? "Untitled"
        for chapter in book.chapters {
            let page = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"/><title>\(xmlEscape(chapter.title))</title></head>
            <body>
            \(chapter.html)
            </body></html>
            """
            try write(page, oebps.appendingPathComponent(chapter.fileName))
        }
        for image in book.images {
            try image.data.write(to: imagesDir.appendingPathComponent(image.name))
        }

        var coverItem = ""
        var coverMeta = ""
        if let cover = info.coverData, let ext = KindleFile.imageExtension(cover) {
            try cover.write(to: imagesDir.appendingPathComponent("cover.\(ext)"))
            let mime = ext == "png" ? "image/png" : (ext == "gif" ? "image/gif" : "image/jpeg")
            coverItem = "<item id=\"cover-image\" href=\"images/cover.\(ext)\" media-type=\"\(mime)\" properties=\"cover-image\"/>"
            coverMeta = "<meta name=\"cover\" content=\"cover-image\"/>"
        }

        var manifest = "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n\(coverItem)\n"
        var spine = ""
        var navPoints = ""
        for (i, chapter) in book.chapters.enumerated() {
            manifest += "<item id=\"c\(i + 1)\" href=\"\(chapter.fileName)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i + 1)\"/>\n"
            navPoints += """
            <navPoint id="n\(i + 1)" playOrder="\(i + 1)"><navLabel><text>\(xmlEscape(chapter.title))</text></navLabel><content src="\(chapter.fileName)"/></navPoint>

            """
        }
        for image in book.images {
            let mime = image.name.hasSuffix(".png") ? "image/png" : (image.name.hasSuffix(".gif") ? "image/gif" : "image/jpeg")
            manifest += "<item id=\"\(image.name.replacingOccurrences(of: ".", with: "-"))\" href=\"images/\(image.name)\" media-type=\"\(mime)\"/>\n"
        }

        let bookID = "urn:pagewrit:\(xmlEscape(identifier))"
        let creator = info.author.map { "<dc:creator>\(xmlEscape($0))</dc:creator>" } ?? ""
        let publisher = info.publisher.map { "<dc:publisher>\(xmlEscape($0))</dc:publisher>" } ?? ""
        let language = xmlEscape(info.language ?? "en")
        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:title>\(xmlEscape(title))</dc:title>
        \(creator)
        \(publisher)
        <dc:language>\(language)</dc:language>
        <dc:identifier id="bookid">\(bookID)</dc:identifier>
        \(coverMeta)
        </metadata>
        <manifest>
        \(manifest)</manifest>
        <spine toc="ncx">
        \(spine)</spine>
        </package>
        """, oebps.appendingPathComponent("content.opf"))

        try write("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(bookID)"/></head>
        <docTitle><text>\(xmlEscape(title))</text></docTitle>
        <navMap>
        \(navPoints)</navMap>
        </ncx>
        """, oebps.appendingPathComponent("toc.ncx"))

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        try fm.zipItem(at: work, to: partial, shouldKeepParent: false)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        #else
        throw KindleError.malformed("zip support missing")
        #endif
    }
}
