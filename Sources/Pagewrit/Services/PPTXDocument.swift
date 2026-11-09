import Foundation

#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// A PowerPoint (.pptx) deck read straight from its zip package — no Office
/// or Keynote needed. Gives Pagewrit the deck's title/author (for the
/// library), each slide's text (for the full-text index and the reader's
/// outline pane). Rendering the slides themselves is Quick Look's job; see
/// `PPTXReaderView`.
///
/// Only the modern XML format (.pptx) is supported. Legacy binary .ppt files
/// are not parsed.
struct PPTXDocument {

    struct Slide: Identifiable {
        let index: Int          // 0-based position in the deck
        let title: String?      // text of the title placeholder, if the slide has one
        let text: String        // all slide text, one paragraph per line (title included)
        var id: Int { index }
        var number: Int { index + 1 }
    }

    let title: String?
    let author: String?
    let slides: [Slide]

    /// Every slide's text joined for the search index.
    var plainText: String {
        slides.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    // MARK: - Loading

    /// Parses `url`. Returns nil if the file isn't a readable .pptx package.
    /// Safe to call off the main thread.
    static func load(from url: URL) -> PPTXDocument? {
        #if canImport(ZIPFoundation)
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return nil }

        func data(at path: String) -> Data? {
            guard let entry = archive[path], entry.uncompressedSize < 150_000_000 else { return nil }
            var out = Data()
            do {
                _ = try archive.extract(entry) { out.append($0) }
            } catch {
                return nil
            }
            return out
        }

        // A deck must have a presentation part; this also rejects random zips.
        guard let presentationXML = data(at: "ppt/presentation.xml") else { return nil }

        // Slide order: presentation.xml lists slide relationship ids in
        // order; the rels file maps each id to its slide part.
        let orderedRIds = ElementCollector.attributes(
            in: presentationXML, element: "p:sldId", attribute: "r:id")
        var targetsByRId: [String: String] = [:]
        if let relsXML = data(at: "ppt/_rels/presentation.xml.rels") {
            for rel in ElementCollector.attributeSets(in: relsXML, element: "Relationship") {
                if let id = rel["Id"], let target = rel["Target"] { targetsByRId[id] = target }
            }
        }

        var slidePaths: [String] = orderedRIds.compactMap { rid in
            guard let target = targetsByRId[rid] else { return nil }
            // Targets are relative to ppt/ ("slides/slide1.xml") or absolute ("/ppt/slides/slide1.xml").
            return target.hasPrefix("/") ? String(target.dropFirst()) : "ppt/" + target
        }
        if slidePaths.isEmpty {
            // Fallback for odd packages: numeric order of slideN.xml parts.
            slidePaths = archive
                .map(\.path)
                .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }

        var slides: [Slide] = []
        for path in slidePaths {
            guard let xml = data(at: path) else { continue }
            let parsed = SlideTextParser.parse(xml)
            slides.append(Slide(index: slides.count, title: parsed.title, text: parsed.text))
        }

        // Document properties.
        var docTitle: String?
        var docAuthor: String?
        if let core = data(at: "docProps/core.xml") {
            docTitle = ElementCollector.text(in: core, element: "dc:title")
            docAuthor = ElementCollector.text(in: core, element: "dc:creator")
        }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }

        return PPTXDocument(
            title: clean(docTitle) ?? clean(slides.first?.title),
            author: clean(docAuthor),
            slides: slides
        )
        #else
        return nil
        #endif
    }
}

// MARK: - XML helpers

/// Pulls simple facts out of an XML blob: attribute values of every matching
/// element, or the text of the first one.
private final class ElementCollector: NSObject, XMLParserDelegate {
    private let element: String
    private var attributeSets: [[String: String]] = []
    private var firstText: String?
    private var capturing = false
    private var buffer = ""

    private init(element: String) { self.element = element }

    static func attributeSets(in data: Data, element: String) -> [[String: String]] {
        let c = ElementCollector(element: element)
        c.run(data)
        return c.attributeSets
    }

    static func attributes(in data: Data, element: String, attribute: String) -> [String] {
        attributeSets(in: data, element: element).compactMap { $0[attribute] }
    }

    static func text(in data: Data, element: String) -> String? {
        let c = ElementCollector(element: element)
        c.run(data)
        return c.firstText
    }

    private func run(_ data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elementName == element else { return }
        attributeSets.append(attributeDict)
        if firstText == nil { capturing = true; buffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if capturing && elementName == element {
            firstText = buffer
            capturing = false
        }
    }
}

/// Reads one slide part: collects text runs (`a:t`), one line per paragraph
/// (`a:p`), and remembers which shape was the title placeholder.
private final class SlideTextParser: NSObject, XMLParserDelegate {
    private var lines: [String] = []
    private var titleLines: [String] = []

    private var inShape = false
    private var shapeIsTitle = false
    private var shapeLines: [String] = []
    private var paragraph = ""
    private var inRun = false

    static func parse(_ data: Data) -> (title: String?, text: String) {
        let p = SlideTextParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.shouldProcessNamespaces = false
        parser.parse()
        let title = p.titleLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, p.lines.joined(separator: "\n"))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "p:sp":
            inShape = true
            shapeIsTitle = false
            shapeLines = []
        case "p:ph":
            if inShape, let type = attributeDict["type"], type == "title" || type == "ctrTitle" {
                shapeIsTitle = true
            }
        case "a:p":
            paragraph = ""
        case "a:t":
            inRun = true
        case "a:br":
            paragraph += " "
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inRun { paragraph += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "a:t":
            inRun = false
        case "a:p":
            let line = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph = ""
            guard !line.isEmpty else { return }
            lines.append(line)
            if inShape { shapeLines.append(line) }
        case "p:sp":
            if shapeIsTitle { titleLines.append(contentsOf: shapeLines) }
            inShape = false
        default:
            break
        }
    }
}
