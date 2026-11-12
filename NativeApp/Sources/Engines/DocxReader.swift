import AppKit
import Foundation

/// Reads Word (.docx) documents for conversion to Markdown and PDF.
///
/// Markdown is built from the WordprocessingML itself: paragraph styles give headings,
/// quotes and code; numbering definitions give bullet and numbered lists; run properties
/// give bold, italic and monospace spans; relationships give web links; tables become
/// GitHub-style tables. Documents written without heading styles fall back to font size.
/// Images, footnotes, comments, headers and footers are not exported to Markdown.
enum DocxReader {
    static let notWordMessage = "This file is not a readable Word (.docx) document."

    // MARK: - Package

    /// Extracts the package into a temporary folder for the duration of `body`.
    static func withPackage<T>(_ url: URL, _ body: (URL) throws -> T) async throws -> T {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("opentangerine-docx-read-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        do { try await ZipTool.unzip(url, into: folder) } catch { throw OpenTangerineError.invalidInput(notWordMessage) }
        return try body(folder)
    }

    struct Relationship { var type: String; var target: String; var external: Bool }

    static func relationships(_ url: URL) -> [String: Relationship] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let handler = RelationshipsHandler()
        handler.parse(data)
        return handler.relationships
    }

    /// Resolves a relationship target relative to the part that owns it, refusing paths outside the package.
    static func resolve(_ target: String, from part: URL, root: URL) -> URL? {
        let base = target.hasPrefix("/") ? root : part.deletingLastPathComponent()
        let resolved = base.appendingPathComponent(target.hasPrefix("/") ? String(target.dropFirst()) : target).standardizedFileURL
        guard resolved.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return resolved
    }

    static func mainDocument(in root: URL) throws -> URL {
        let packageRels = relationships(root.appendingPathComponent("_rels/.rels"))
        if let rel = packageRels.values.first(where: { $0.type.hasSuffix("/officeDocument") }),
           let url = resolve(rel.target, from: root.appendingPathComponent("_rels/.rels").deletingLastPathComponent(), root: root),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let fallback = root.appendingPathComponent("word/document.xml")
        guard FileManager.default.fileExists(atPath: fallback.path) else { throw OpenTangerineError.invalidInput(notWordMessage) }
        return fallback
    }

    // MARK: - Markdown

    static func markdown(_ url: URL, progress: (Double) -> Void = { _ in }) async throws -> String {
        try await withPackage(url) { root in
            let document = try mainDocument(in: root)
            let partRelsURL = document.deletingLastPathComponent()
                .appendingPathComponent("_rels/\(document.lastPathComponent).rels")
            let rels = relationships(partRelsURL)
            func part(_ suffix: String) -> URL? {
                guard let rel = rels.values.first(where: { $0.type.hasSuffix(suffix) && !$0.external }) else { return nil }
                return resolve(rel.target, from: document, root: root)
            }
            let styles = StylesHandler()
            if let stylesURL = part("/styles"), let data = try? Data(contentsOf: stylesURL) { styles.parse(data) }
            let numbering = NumberingHandler()
            if let numberingURL = part("/numbering"), let data = try? Data(contentsOf: numberingURL) { numbering.parse(data) }
            progress(0.2)

            guard let data = try? Data(contentsOf: document) else { throw OpenTangerineError.invalidInput(notWordMessage) }
            var links: [String: URL] = [:]
            for (id, rel) in rels where rel.type.hasSuffix("/hyperlink") && rel.external {
                if let link = safeLink(rel.target) { links[id] = link }
            }
            let body = DocumentHandler(links: links)
            guard body.parse(data) else { throw OpenTangerineError.invalidInput(notWordMessage) }
            progress(0.7)
            let builder = MarkdownBuilder(styles: styles, numbering: numbering)
            return PDFMarkdown.render(blocks: builder.blocks(body.items))
        }
    }

    /// Only web and mail links are kept, matching PDF → Markdown.
    static func safeLink(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    // MARK: - Document model

    struct RunProps {
        var bold: Bool?
        var italic: Bool?
        var mono: Bool?
        var size: CGFloat?
    }

    struct Run {
        var text: String
        var props: RunProps
        var characterStyle: String?
        var link: URL?
    }

    struct Paragraph {
        var styleId: String?
        var numId: String?
        var level: Int?
        var outlineLevel: Int?
        var runs: [Run] = []
        var images: [String] = []
        var rules = 0
        var text: String { runs.map(\.text).joined() }
    }

    final class Cell { var paragraphs: [Paragraph] = [] }
    final class Table { var rows: [[Cell]] = [] }

    enum Item {
        case paragraph(Paragraph)
        case table(Table)
    }

    /// Marks a hard line break inside a paragraph until the Markdown is rendered.
    static let lineBreak = "\u{2028}"

    static func isMonospace(_ font: String) -> Bool {
        let name = font.lowercased()
        return ["courier", "menlo", "monaco", "consolas", "mono", "inconsolata", "fira code", "source code"].contains { name.contains($0) }
    }

    static func flag(_ attributes: [String: String]) -> Bool {
        guard let value = attribute(attributes, "val")?.lowercased() else { return true }
        return !["0", "false", "off", "none"].contains(value)
    }

    static func attribute(_ attributes: [String: String], _ name: String) -> String? {
        if let value = attributes[name] { return value }
        return attributes.first { key, _ in key.hasSuffix(":" + name) }?.value
    }

    static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }
}

// MARK: - XML handlers

private class LocalNameParser: NSObject, XMLParserDelegate {
    var path: [String] = []

    @discardableResult
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        return parser.parse()
    }

    func start(_ name: String, _ attributes: [String: String]) {}
    func end(_ name: String) {}
    func text(_ string: String) {}

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = DocxReader.localName(elementName)
        start(name, attributeDict)
        path.append(name)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        path.removeLast()
        end(DocxReader.localName(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text(string) }

    var parent: String? { path.last }
    var grandparent: String? { path.count >= 2 ? path[path.count - 2] : nil }
}

private final class RelationshipsHandler: LocalNameParser {
    var relationships: [String: DocxReader.Relationship] = [:]

    override func start(_ name: String, _ attributes: [String: String]) {
        guard name == "Relationship", let id = attributes["Id"], let type = attributes["Type"], let target = attributes["Target"] else { return }
        relationships[id] = .init(type: type, target: target, external: attributes["TargetMode"]?.lowercased() == "external")
    }
}

private final class StylesHandler: LocalNameParser {
    struct Style {
        var name = ""
        var basedOn: String?
        var outlineLevel: Int?
        var numId: String?
        var level: Int?
        var props = DocxReader.RunProps()
        var isDefault = false
        var type = ""
    }

    var styles: [String: Style] = [:]
    var defaults = DocxReader.RunProps()
    private var current: Style?
    private var currentId: String?
    private var inDefaults = false

    override func start(_ name: String, _ attributes: [String: String]) {
        let attr = { DocxReader.attribute(attributes, $0) }
        switch name {
        case "rPrDefault": inDefaults = true
        case "style":
            currentId = attr("styleId")
            current = Style(isDefault: DocxReader.flag(["val": attr("default") ?? "0"]), type: attr("type") ?? "")
        case "name": if parent == "style" { current?.name = attr("val") ?? "" }
        case "basedOn": if parent == "style" { current?.basedOn = attr("val") }
        case "outlineLvl": if parent == "pPr", let value = attr("val").flatMap(Int.init) { current?.outlineLevel = value }
        case "numId": if grandparent == "pPr" { current?.numId = attr("val") }
        case "ilvl": if grandparent == "pPr" { current?.level = attr("val").flatMap(Int.init) }
        case "b", "i", "rFonts", "sz":
            guard parent == "rPr" else { return }
            var props = inDefaults && current == nil ? defaults : (current?.props ?? DocxReader.RunProps())
            switch name {
            case "b": props.bold = DocxReader.flag(attributes)
            case "i": props.italic = DocxReader.flag(attributes)
            case "rFonts": if let font = attr("ascii") ?? attr("hAnsi") { props.mono = DocxReader.isMonospace(font) }
            default: if let size = attr("val").flatMap(Double.init) { props.size = CGFloat(size) / 2 }
            }
            if inDefaults && current == nil { defaults = props } else { current?.props = props }
        default: break
        }
    }

    override func end(_ name: String) {
        if name == "rPrDefault" { inDefaults = false }
        if name == "style", let id = currentId, let style = current { styles[id] = style; current = nil; currentId = nil }
    }

    /// Walks the `basedOn` chain from the style outwards.
    func chain(_ id: String?) -> [Style] {
        var result: [Style] = []
        var next = id
        while let key = next, let style = styles[key], result.count < 12 {
            result.append(style)
            next = style.basedOn
        }
        return result
    }

    var defaultParagraphStyle: String? {
        styles.first { $0.value.isDefault && $0.value.type == "paragraph" }?.key
    }
}

private final class NumberingHandler: LocalNameParser {
    struct Level { var format = "decimal"; var start = 1 }

    private(set) var abstracts: [String: [Int: Level]] = [:]
    private(set) var nums: [String: (abstract: String, starts: [Int: Int])] = [:]
    private var abstractId: String?
    private var level: Int?
    private var numId: String?
    private var overrideLevel: Int?

    override func start(_ name: String, _ attributes: [String: String]) {
        let attr = { DocxReader.attribute(attributes, $0) }
        switch name {
        case "abstractNum": abstractId = attr("abstractNumId"); abstracts[abstractId ?? ""] = [:]
        case "lvl":
            if parent == "abstractNum", let id = abstractId, let ilvl = attr("ilvl").flatMap(Int.init) {
                level = ilvl
                abstracts[id]?[ilvl] = Level()
            }
        case "numFmt": if parent == "lvl", let id = abstractId, let ilvl = level { abstracts[id]?[ilvl]?.format = attr("val") ?? "decimal" }
        case "start": if parent == "lvl", let id = abstractId, let ilvl = level { abstracts[id]?[ilvl]?.start = attr("val").flatMap(Int.init) ?? 1 }
        case "num": numId = attr("numId"); if let id = numId { nums[id] = ("", [:]) }
        case "abstractNumId": if parent == "num", let id = numId { nums[id]?.abstract = attr("val") ?? "" }
        case "lvlOverride": overrideLevel = attr("ilvl").flatMap(Int.init)
        case "startOverride":
            if let id = numId, let ilvl = overrideLevel, let value = attr("val").flatMap(Int.init) { nums[id]?.starts[ilvl] = value }
        default: break
        }
    }

    override func end(_ name: String) {
        switch name {
        case "abstractNum": abstractId = nil
        case "lvl": level = nil
        case "num": numId = nil
        case "lvlOverride": overrideLevel = nil
        default: break
        }
    }

    func level(numId: String, ilvl: Int) -> Level? {
        guard let num = nums[numId], var level = abstracts[num.abstract]?[ilvl] else { return nil }
        if let start = num.starts[ilvl] { level.start = start }
        return level
    }
}

private final class DocumentHandler: LocalNameParser {
    let links: [String: URL]
    var items: [DocxReader.Item] = []

    private var paragraphs: [DocxReader.Paragraph] = []
    /// Paragraphs found inside text boxes, emitted after the paragraph that anchors them.
    private var deferred: [[DocxReader.Paragraph]] = []
    private var tables: [DocxReader.Table] = []
    private var props = DocxReader.RunProps()
    private var characterStyle: String?
    private var hidden = false
    private var text = ""
    private var inText = false
    private var hyperlinks: [URL?] = []
    private var fields: [(instruction: String, link: URL?, inResult: Bool)] = []
    private var inInstruction = false
    private var skipDepth = 0
    private var imageAlt = ""
    private var hasImage = false
    private var isRule = false

    init(links: [String: URL]) { self.links = links }

    private var link: URL? {
        if let link = hyperlinks.last(where: { $0 != nil }) { return link }
        return fields.last(where: { $0.inResult && $0.link != nil })?.link
    }

    private func append(_ string: String) {
        guard !paragraphs.isEmpty, !hidden, !string.isEmpty else { return }
        if fields.contains(where: { !$0.inResult }) { return }
        paragraphs[paragraphs.count - 1].runs.append(.init(text: string, props: props, characterStyle: characterStyle, link: link))
    }

    override func start(_ name: String, _ attributes: [String: String]) {
        if skipDepth > 0 || name == "Fallback" { skipDepth += 1; return }
        let attr = { DocxReader.attribute(attributes, $0) }
        switch name {
        case "p":
            paragraphs.append(.init())
            deferred.append([])
        case "pStyle": if parent == "pPr", !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].styleId = attr("val") }
        case "numId": if grandparent == "pPr", !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].numId = attr("val") }
        case "ilvl": if grandparent == "pPr", !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].level = attr("val").flatMap(Int.init) }
        case "outlineLvl": if parent == "pPr", !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].outlineLevel = attr("val").flatMap(Int.init) }
        case "r":
            props = .init(); characterStyle = nil; hidden = false
        case "rStyle": if parent == "rPr", grandparent == "r" { characterStyle = attr("val") }
        case "b": if parent == "rPr", grandparent == "r" { props.bold = DocxReader.flag(attributes) }
        case "i": if parent == "rPr", grandparent == "r" { props.italic = DocxReader.flag(attributes) }
        case "vanish": if parent == "rPr", grandparent == "r" { hidden = DocxReader.flag(attributes) }
        case "sz": if parent == "rPr", grandparent == "r", let size = attr("val").flatMap(Double.init) { props.size = CGFloat(size) / 2 }
        case "rFonts":
            if parent == "rPr", grandparent == "r", let font = attr("ascii") ?? attr("hAnsi") { props.mono = DocxReader.isMonospace(font) }
        case "t": inText = true; text = ""
        case "instrText": inInstruction = true
        case "tab": if parent == "r" { append(" ") }
        case "br", "cr":
            if parent == "r", attr("type") == nil || attr("type") == "textWrapping" { append(DocxReader.lineBreak) }
        case "noBreakHyphen": append("-")
        case "hyperlink":
            hyperlinks.append(attr("id").flatMap { links[$0] })
        case "fldSimple":
            fields.append((attr("instr") ?? "", Self.fieldLink(attr("instr") ?? ""), true))
        case "fldChar":
            switch attr("fldCharType") {
            case "begin": fields.append(("", nil, false))
            case "separate":
                if !fields.isEmpty {
                    fields[fields.count - 1].inResult = true
                    fields[fields.count - 1].link = Self.fieldLink(fields[fields.count - 1].instruction)
                }
            case "end": if !fields.isEmpty { fields.removeLast() }
            default: break
            }
        case "drawing", "pict": imageAlt = ""; hasImage = false; isRule = false
        case "blip", "imagedata": hasImage = true
        case "rect": if DocxReader.attribute(attributes, "hr").map({ DocxReader.flag(["val": $0]) }) == true { isRule = true }
        case "shape": if imageAlt.isEmpty { imageAlt = attr("alt") ?? "" }
        case "docPr":
            imageAlt = attr("descr").flatMap { $0.isEmpty ? nil : $0 } ?? attr("title").flatMap { $0.isEmpty ? nil : $0 } ?? attr("name") ?? ""
        case "tbl": tables.append(.init()); cellIndexes.append(0)
        case "tr": tables.last?.rows.append([])
        case "tc":
            if let table = tables.last, !table.rows.isEmpty {
                table.rows[table.rows.count - 1].append(.init())
                cellIndexes[cellIndexes.count - 1] = table.rows[table.rows.count - 1].count - 1
            }
        case "gridSpan":
            if let table = tables.last, let count = attr("val").flatMap(Int.init), count > 1, !table.rows.isEmpty {
                for _ in 1..<min(count, 64) { table.rows[table.rows.count - 1].append(.init()) }
            }
        default: break
        }
    }

    override func text(_ string: String) {
        guard skipDepth == 0 else { return }
        if inText { text += string }
        if inInstruction, !fields.isEmpty { fields[fields.count - 1].instruction += string }
    }

    override func end(_ name: String) {
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "t": inText = false; append(text); text = ""
        case "instrText": inInstruction = false
        case "hyperlink": if !hyperlinks.isEmpty { hyperlinks.removeLast() }
        case "fldSimple": if !fields.isEmpty { fields.removeLast() }
        case "drawing", "pict":
            guard !paragraphs.isEmpty else { return }
            if isRule { paragraphs[paragraphs.count - 1].rules += 1 }
            else if hasImage { paragraphs[paragraphs.count - 1].images.append(imageAlt) }
        case "p":
            guard let paragraph = paragraphs.popLast(), let inner = deferred.popLast() else { return }
            if !paragraphs.isEmpty {
                // A text-box paragraph inside another paragraph.
                deferred[deferred.count - 1].append(paragraph)
                deferred[deferred.count - 1] += inner
            } else {
                emit([paragraph] + inner)
            }
        case "tbl":
            guard let table = tables.popLast() else { return }
            cellIndexes.removeLast()
            if tables.isEmpty {
                items.append(.table(table))
            } else {
                // Nested tables are flattened into the enclosing cell.
                let rows = table.rows.map { row in row.flatMap(\.paragraphs) }.flatMap { $0 }
                emit(rows)
            }
        default: break
        }
    }

    private func emit(_ list: [DocxReader.Paragraph]) {
        if let table = tables.last, let index = cellIndexes.last, let row = table.rows.last, row.indices.contains(index) {
            // gridSpan placeholders follow the cell, so its content goes to the recorded cell index.
            row[index].paragraphs += list
        } else {
            items += list.map { .paragraph($0) }
        }
    }

    /// For each open table, the index of the cell being filled in its current row.
    private var cellIndexes: [Int] = []

    static func fieldLink(_ instruction: String) -> URL? {
        let trimmed = instruction.trimmingCharacters(in: .whitespaces)
        guard trimmed.uppercased().hasPrefix("HYPERLINK") else { return nil }
        guard let open = trimmed.firstIndex(of: "\""),
              let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return DocxReader.safeLink(String(trimmed[trimmed.index(after: open)..<close]))
    }
}

// MARK: - Markdown builder

private struct MarkdownBuilder {
    let styles: StylesHandler
    let numbering: NumberingHandler

    typealias Block = PDFMarkdown.Block

    func blocks(_ items: [DocxReader.Item]) -> [Block] {
        let body = bodySize(items)
        var blocks: [Block] = []
        var counters: [String: [Int: Int]] = [:]
        var blankAfterCode = 0
        var lastWasList = false
        var lastListId: String?
        for item in items {
            switch item {
            case .table(let table):
                if let rendered = render(table) { blocks.append(.note(rendered)) }
                blankAfterCode = 0
                lastWasList = false
            case .paragraph(let paragraph):
                let styleChain = styles.chain(paragraph.styleId ?? styles.defaultParagraphStyle)
                let runs = markdownRuns(paragraph, styleChain: styleChain)
                let plain = runs.map(\.text).joined()
                let hasText = !plain.replacingOccurrences(of: DocxReader.lineBreak, with: "").trimmingCharacters(in: .whitespaces).isEmpty
                let images = paragraph.images.map { alt in
                    "<!-- Image\(alt.isEmpty ? "" : ": " + alt.replacingOccurrences(of: "--", with: "–")) (images are not exported to Markdown) -->"
                } + Array(repeating: "---", count: paragraph.rules)
                guard hasText else {
                    if case .code = blocks.last { blankAfterCode += 1 }
                    blocks += images.map { .note($0) }
                    if !images.isEmpty { blankAfterCode = 0; lastWasList = false }
                    continue
                }
                let styleName = styleChain.first?.name.lowercased() ?? ""
                if isCode(styleName: styleName, runs: runs) {
                    let lines = plain.components(separatedBy: DocxReader.lineBreak)
                    if case .code(var existing)? = blocks.last {
                        existing += Array(repeating: "", count: blankAfterCode) + lines
                        blocks[blocks.count - 1] = .code(existing)
                    } else {
                        blocks.append(.code(lines))
                    }
                } else if let level = headingLevel(paragraph, styleChain: styleChain, runs: runs, body: body) {
                    let text = PDFMarkdown.inline(runs, styled: false).replacingOccurrences(of: DocxReader.lineBreak, with: " ")
                        // A trailing "#" would be read as the heading's closing sequence.
                        .replacingOccurrences(of: #"#$"#, with: "\\#", options: .regularExpression)
                    blocks.append(.note(String(repeating: "#", count: level) + " " + text))
                } else if let list = listInfo(paragraph, styleChain: styleChain, counters: &counters) {
                    let indent = String(repeating: "    ", count: list.level + 1)
                    let line = String(repeating: "    ", count: list.level) + (list.ordered ?? "-") + " " + inline(runs, continuation: indent)
                    if lastWasList, lastListId == list.id || list.level > 0, case .note(let previous)? = blocks.last {
                        blocks[blocks.count - 1] = .note(previous + "\n" + line)
                    } else {
                        blocks.append(.note(line))
                    }
                    lastWasList = images.isEmpty
                    if list.level == 0 { lastListId = list.id }
                    blocks += images.map { .note($0) }
                    blankAfterCode = 0
                    continue
                } else if styleName.contains("quote") {
                    let text = inline(runs, continuation: "> ")
                    blocks.append(.note("> " + text))
                } else {
                    blocks.append(.note(inline(runs, continuation: "")))
                }
                blocks += images.map { .note($0) }
                blankAfterCode = 0
                lastWasList = false
            }
        }
        return blocks
    }

    /// Inline Markdown with hard line breaks; each continuation line keeps the block's indent or prefix.
    private func inline(_ runs: [PDFMarkdown.Run], continuation: String) -> String {
        let rendered = PDFMarkdown.inline(runs, styled: true)
        let lines = rendered.components(separatedBy: DocxReader.lineBreak).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first else { return "" }
        let escapedFirst = PDFMarkdown.escapeLineStart(first)
        let rest = lines.dropFirst().map { continuation + PDFMarkdown.escapeLineStart($0) }
        return ([escapedFirst] + rest).joined(separator: "\\\n")
    }

    private func markdownRuns(_ paragraph: DocxReader.Paragraph, styleChain: [StylesHandler.Style]) -> [PDFMarkdown.Run] {
        paragraph.runs.map { run in
            let props = effective(run, styleChain: styleChain)
            let style = PDFMarkdown.Style(bold: props.bold ?? false, italic: props.italic ?? false, mono: props.mono ?? false)
            return PDFMarkdown.Run(text: run.text, style: style, size: props.size ?? 11, link: run.link)
        }
    }

    private func effective(_ run: DocxReader.Run, styleChain: [StylesHandler.Style]) -> DocxReader.RunProps {
        var props = run.props
        for style in styles.chain(run.characterStyle) + styleChain + [StylesHandler.Style(props: styles.defaults)] {
            if props.bold == nil { props.bold = style.props.bold }
            if props.italic == nil { props.italic = style.props.italic }
            if props.mono == nil { props.mono = style.props.mono }
            if props.size == nil { props.size = style.props.size }
        }
        return props
    }

    private func isCode(styleName: String, runs: [PDFMarkdown.Run]) -> Bool {
        if ["code", "source", "preformatted", "html pre", "plain text"].contains(where: { styleName.contains($0) }) { return true }
        let visible = runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.text != DocxReader.lineBreak }
        return !visible.isEmpty && visible.allSatisfy(\.style.mono)
    }

    private func headingLevel(_ paragraph: DocxReader.Paragraph, styleChain: [StylesHandler.Style], runs: [PDFMarkdown.Run], body: CGFloat) -> Int? {
        for style in styleChain {
            let name = style.name.lowercased()
            if name == "title" { return 1 }
            if name.hasPrefix("heading"), let level = Int(name.dropFirst("heading".count).trimmingCharacters(in: .whitespaces)) {
                return min(max(level, 1), 6)
            }
        }
        if let outline = paragraph.outlineLevel ?? styleChain.lazy.compactMap(\.outlineLevel).first, (0...5).contains(outline) {
            return outline + 1
        }
        // Documents without heading styles (for example from TextEdit): short, larger-than-body lines.
        let visible = runs.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let text = visible.map(\.text).joined().trimmingCharacters(in: .whitespaces)
        guard !visible.isEmpty, text.count <= 120, !text.hasSuffix("."), paragraph.numId == nil else { return nil }
        let smallest = visible.map(\.size).min() ?? body
        if smallest >= body * 1.8 { return 1 }
        if smallest >= body * 1.4 { return 2 }
        if smallest >= body * 1.15 { return 3 }
        return nil
    }

    private func listInfo(_ paragraph: DocxReader.Paragraph, styleChain: [StylesHandler.Style], counters: inout [String: [Int: Int]]) -> (id: String, ordered: String?, level: Int)? {
        guard let numId = paragraph.numId ?? styleChain.lazy.compactMap(\.numId).first, numId != "0" else { return nil }
        let ilvl = min(max(paragraph.level ?? styleChain.lazy.compactMap(\.level).first ?? 0, 0), 8)
        let level = numbering.level(numId: numId, ilvl: ilvl) ?? .init(format: "bullet", start: 1)
        if level.format == "none" { return nil }
        var levels = counters[numId] ?? [:]
        for deeper in levels.keys where deeper > ilvl { levels[deeper] = nil }
        if level.format == "bullet" {
            counters[numId] = levels
            return (numId, nil, ilvl)
        }
        let number = (levels[ilvl] ?? level.start - 1) + 1
        levels[ilvl] = number
        counters[numId] = levels
        return (numId, "\(number).", ilvl)
    }

    /// The most common run size, weighted by characters.
    private func bodySize(_ items: [DocxReader.Item]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for case .paragraph(let paragraph) in items {
            let chain = styles.chain(paragraph.styleId ?? styles.defaultParagraphStyle)
            for run in markdownRuns(paragraph, styleChain: chain) { weights[run.size, default: 0] += run.text.count }
        }
        return weights.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 11
    }

    private func render(_ table: DocxReader.Table) -> String? {
        let rows: [[String]] = table.rows.map { row in
            row.map { cell in
                cell.paragraphs.map { paragraph in
                    let chain = styles.chain(paragraph.styleId ?? styles.defaultParagraphStyle)
                    return PDFMarkdown.inline(markdownRuns(paragraph, styleChain: chain), styled: true)
                        .replacingOccurrences(of: DocxReader.lineBreak, with: "<br>")
                }
                .filter { !$0.isEmpty }
                .joined(separator: "<br>")
                .replacingOccurrences(of: "|", with: "\\|")
            }
        }.filter { !$0.isEmpty }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0, rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }
        let padded = rows.map { $0 + Array(repeating: "", count: columns - $0.count) }
        func line(_ cells: [String]) -> String { "| " + cells.map { $0.isEmpty ? " " : $0 }.joined(separator: " | ") + " |" }
        var lines = [line(padded[0]), "|" + Array(repeating: " --- |", count: columns).joined()]
        lines += padded.dropFirst().map(line)
        return lines.joined(separator: "\n")
    }
}

// MARK: - PDF

extension DocxReader {
    /// Lays out the document with the system Word importer and writes one PDF page per text container.
    /// Page breaks in the document start a new page. Headers, footers and footnotes are not drawn.
    static func writePDF(_ source: URL, to destination: URL, progress: (Double) -> Void = { _ in }) throws {
        var attributes: NSDictionary?
        let imported: NSAttributedString
        do {
            imported = try NSAttributedString(url: source, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                              documentAttributes: &attributes)
        } catch {
            throw OpenTangerineError.invalidInput(notWordMessage)
        }
        let info = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        var pageSize = (info[.paperSize] as? NSValue)?.sizeValue ?? CGSize(width: 612, height: 792)
        if pageSize.width < 72 || pageSize.height < 72 { pageSize = CGSize(width: 612, height: 792) }
        func margin(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat {
            let value = (info[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72
            return min(max(value, 0), min(pageSize.width, pageSize.height) / 4)
        }
        let left = margin(.leftMargin), right = margin(.rightMargin), top = margin(.topMargin), bottom = margin(.bottomMargin)
        let content = CGSize(width: pageSize.width - left - right, height: pageSize.height - top - bottom)

        let text = NSMutableAttributedString(attributedString: imported)
        let whole = NSRange(location: 0, length: text.length)
        // Unstyled text would otherwise draw in the appearance's text colour (white in Dark Mode).
        text.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }
        // An attachment taller or wider than the page would never fit in a container.
        text.enumerateAttribute(.attachment, in: whole) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var size = attachment.bounds.size
            if size == .zero { size = attachment.image?.size ?? attachment.attachmentCell?.cellSize() ?? .zero }
            guard size.width > 0, size.height > 0 else { return }
            let scale = min(content.width / size.width, content.height * 0.95 / size.height, 1)
            if scale < 1 { attachment.bounds = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale) }
        }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        let glyphCount = layout.numberOfGlyphs
        var laidOut = 0
        var stalled = 0
        repeat {
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            let end = NSMaxRange(range)
            stalled = end <= laidOut && range.length == 0 ? stalled + 1 : 0
            laidOut = max(laidOut, end)
            if glyphCount > 0 { progress(Double(laidOut) / Double(glyphCount) * 0.5) }
        } while laidOut < glyphCount && stalled < 3 && containers.count < 10_000
        while containers.count > 1, stalled > 0, layout.glyphRange(for: containers[containers.count - 1]).length == 0 {
            layout.removeTextContainer(at: containers.count - 1)
            containers.removeLast()
            stalled -= 1
        }

        guard let consumer = CGDataConsumer(url: destination as CFURL) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw OpenTangerineError.encodeFailed(destination.lastPathComponent) }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        for (index, container) in containers.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let range = layout.glyphRange(for: container)
            let origin = NSPoint(x: left, y: top)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
            progress(0.5 + Double(index + 1) / Double(containers.count) * 0.5)
        }
        context.closePDF()
    }
}
