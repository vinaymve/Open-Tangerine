import AppKit
import Foundation
import PDFKit

@main struct DocumentTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("OpenTangerine-documents-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func url(_ name: String) -> URL { root.appendingPathComponent(name) }
        func convert(_ source: URL, _ from: FileFormat, _ to: FileFormat, _ name: String) async throws -> URL {
            let output = url(name)
            try await Engines.convert(ConversionRequest(source: source, sourceFormat: from, target: to, destination: output, progress: { _ in }))
            return output
        }
        let text = "Open Tangerine document test\nCafé & <content>\n\nSecond paragraph."
        try text.write(to: url("input.txt"), atomically: true, encoding: .utf8)
        let pdf = try await convert(url("input.txt"), .txt, .pdf, "text.pdf")
        precondition(PDFDocument(url: pdf)!.string!.contains("Open Tangerine"))
        for target: FileFormat in [.png, .jpg, .srt, .vtt] {
            let out = try await convert(url("input.txt"), .txt, target, "text.\(target.fileExtension)")
            if target == .png || target == .jpg { precondition(try! ImageIOBridge.load(out).width == 1275) }
            else { precondition(try! String(contentsOf: out, encoding: .utf8).contains("Second paragraph")) }
            print("PASS TXT -> \(target)")
        }
        for target: FileFormat in [.png, .jpg, .txt, .docx] {
            let out = try await convert(pdf, .pdf, target, "pdf.\(target.fileExtension)")
            switch target {
            case .png, .jpg: precondition(try! ImageIOBridge.load(out).width == 2550)
            case .txt: precondition(try! String(contentsOf: out, encoding: .utf8).contains("Open Tangerine"))
            case .docx:
                let result = try await Shell.run("/usr/bin/unzip", ["-p", out.path, "word/document.xml"])
                precondition(result.succeeded && result.stdout.contains("Open Tangerine") && result.stdout.contains("&amp;"))
            default: break
            }
            print("PASS PDF -> \(target)")
        }
        let second = url("second.pdf")
        try TextRenderer.writePDF("Second page marker", to: second)
        let merged = url("merged.pdf")
        try PDFOps.merge([pdf, second], to: merged)
        let mergedDoc = try PDFOps.document(merged)
        precondition(mergedDoc.pageCount == 2 && mergedDoc.page(at: 1)!.string!.contains("Second page"))
        for mode: PDFOps.SplitMode in [.everyPage, .everyN, .ranges] {
            let outputs = try PDFOps.split(merged, mode: mode, every: 2, ranges: "2", into: url("split-\(mode.rawValue)"))
            precondition(outputs.count == (mode == .everyPage ? 2 : 1))
            precondition(try! PDFOps.document(outputs[0]).pageCount == (mode == .everyN ? 2 : 1))
            print("PASS PDF split \(mode)")
        }
        try PDFOps.assemble(pages: [PDFPageRef(sourceIndex: 1, rotation: 90, sourceURL: merged), PDFPageRef(sourceIndex: 0, rotation: 0, sourceURL: merged)], to: url("reordered.pdf"))
        let reordered = try PDFOps.document(url("reordered.pdf"))
        precondition(reordered.page(at: 0)!.rotation == 90 && reordered.page(at: 0)!.string!.contains("Second page"))
        for strong in [false, true] {
            let out = url("compressed-\(strong).pdf")
            try PDFOps.compress(merged, strong: strong, to: out)
            precondition(try! PDFOps.document(out).pageCount == 2)
            print("PASS PDF compression strong=\(strong), preserves page count (size reduction not guaranteed)")
        }
        let imagePDF = url("images.pdf")
        try PDFOps.fromImages([url("text.png"), url("text.jpg")], to: imagePDF, progress: { _ in })
        precondition(try! PDFOps.document(imagePDF).pageCount == 2)
        let multiImages = try await convert(merged, .pdf, .png, "pages.png")
        let pages = try fm.contentsOfDirectory(at: multiImages, includingPropertiesForKeys: nil)
        precondition(pages.count == 2)
        for page in pages { precondition(try! ImageIOBridge.load(page).width == 2550) }
        let scanDOCX = try await convert(imagePDF, .pdf, .docx, "scanned.docx")
        let listing = try await Shell.run("/usr/bin/unzip", ["-l", scanDOCX.path])
        precondition(listing.stdout.contains("image1.png") && listing.stdout.contains("image2.png"))
        do { _ = try await convert(imagePDF, .pdf, .txt, "scan.txt"); fatalError("Empty scanned text reported as success") } catch { }
        let protected = url("protected.pdf")
        precondition(mergedDoc.write(to: protected, withOptions: [.userPasswordOption: "test-password", .ownerPasswordOption: "owner-password"]))
        do { _ = try await convert(protected, .pdf, .png, "locked.png"); fatalError("Locked PDF accepted") } catch { }
        let mixed = url("mixed.pdf")
        try PDFOps.merge([imagePDF, pdf], to: mixed)
        let mixedDocx = try await convert(mixed, .pdf, .docx, "mixed.docx")
        let mixedXML = try await Shell.run("/usr/bin/unzip", ["-p", mixedDocx.path, "word/document.xml"])
        precondition(mixedXML.stdout.range(of: "<w:drawing>")!.lowerBound < mixedXML.stdout.range(of: "Open Tangerine")!.lowerBound)
        precondition(mixedXML.stdout.contains("w:type=\"page\""))
        print("PASS mixed scanned/text PDF -> DOCX preserves page order and breaks")
        print("PASS PDF merge/reorder/rotate, images-to-PDF, multipage export, scanned DOCX, scanned/locked rejection")
        let srt = "1\n00:00:01,250 --> 00:00:03,000\nHello <i>world</i>\n\n2\n00:00:04,000 --> 00:00:05,000\nSecond cue\n"
        try srt.write(to: url("captions.srt"), atomically: true, encoding: .utf8)
        let vtt = try await convert(url("captions.srt"), .srt, .vtt, "captions.vtt")
        let roundtrip = try await convert(vtt, .vtt, .srt, "roundtrip.srt")
        let cues = SubtitleParser.parse(try String(contentsOf: roundtrip, encoding: .utf8), hint: .srt)
        precondition(cues.count == 2 && cues[0].start == 1.25 && cues[1].end == 5)
        for (source, format) in [(url("captions.srt"), FileFormat.srt), (vtt, .vtt)] {
            let out = try await convert(source, format, .txt, "\(format).txt")
            precondition(try! String(contentsOf: out, encoding: .utf8).contains("Hello world"))
        }
        precondition(SubtitleParser.format(59.9999, separator: ",") == "00:01:00,000")
        precondition(SubtitleParser.parseTimestamp("nan") == nil)
        print("PASS SRT/VTT round trip + both TXT exports; millisecond carry and invalid timestamp")
        try await markdownTests(root: root, convert: convert)
        try await docxTests(root: root, convert: convert)
    }

    /// Draws positioned lines with named fonts, which survive PDFKit text extraction.
    static func structuredPDF(_ pages: [[(x: CGFloat, y: CGFloat, runs: [(String, String, CGFloat)])]], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in pages {
            context.beginPDFPage(nil)
            for line in page {
                let text = NSMutableAttributedString()
                for (string, font, size) in line.runs {
                    text.append(NSAttributedString(string: string, attributes: [.font: NSFont(name: font, size: size)!]))
                }
                context.textPosition = CGPoint(x: line.x, y: line.y)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor static func markdownTests(root: URL, convert: (URL, FileFormat, FileFormat, String) async throws -> URL) async throws {
        let regular = "Helvetica", bold = "Helvetica-Bold", italic = "Helvetica-Oblique", mono = "Courier"
        func plain(_ x: CGFloat, _ y: CGFloat, _ text: String) -> (x: CGFloat, y: CGFloat, runs: [(String, String, CGFloat)]) {
            (x, y, [(text, regular, 11)])
        }
        let draft = root.appendingPathComponent("structured-draft.pdf")
        structuredPDF([[
            (72, 740, [("Quarterly Report", bold, 24)]),
            (72, 704, [("Overview", bold, 16)]),
            (72, 680, [("This report covers ", regular, 11), ("bold", bold, 11), (" and ", regular, 11), ("italic", italic, 11), (" text with a conver-", regular, 11)]),
            plain(72, 666, "sion that wraps onto a second line."),
            plain(72, 640, "Prices use 5*3 and file_name values."),
            plain(72, 614, "• First item"),
            plain(72, 600, "• Second item"),
            plain(90, 586, "◦ Nested item"),
            plain(72, 560, "1. Step one"),
            plain(72, 546, "2. Step two"),
            (72, 520, [("let x = 1", mono, 11)]),
            (72, 506, [("print(x)", mono, 11)]),
            plain(72, 480, "Visit Open Tangerine for details."),
            plain(72, 454, "# not a heading"),
            plain(72, 428, "This sentence continues on the"),
            plain(300, 40, "1"),
        ], [
            plain(72, 740, "next page as well."),
        ]], to: draft)
        let document = PDFDocument(url: draft)!
        let target = document.findString("Open Tangerine", withOptions: []).first!
        let link = PDFAnnotation(bounds: target.bounds(for: document.page(at: 0)!), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/open-tangerine")
        document.page(at: 0)!.addAnnotation(link)
        let source = root.appendingPathComponent("structured.pdf")
        precondition(document.write(to: source))

        let output = try await convert(source, .pdf, .md, "structured.md")
        precondition(output.pathExtension == "md")
        let markdown = try String(contentsOf: output, encoding: .utf8)
        let expected = """
        # Quarterly Report

        ## Overview

        This report covers **bold** and *italic* text with a conversion that wraps onto a second line.

        Prices use 5\\*3 and file\\_name values.

        - First item
        - Second item
            - Nested item
        1. Step one
        2. Step two

        ```
        let x = 1
        print(x)
        ```

        Visit [Open Tangerine](https://example.com/open-tangerine) for details.

        \\# not a heading

        This sentence continues on the next page as well.

        """
        if markdown != expected {
            FileHandle.standardError.write(Data("Expected:\n\(expected)\nActual:\n\(markdown)\n".utf8))
            fatalError("PDF -> Markdown structure mismatch")
        }
        print("PASS PDF -> Markdown headings, emphasis, hyphenation, escaping, lists, code, links, page numbers, page continuation")

        let scanned = root.appendingPathComponent("images.pdf")
        do { _ = try await convert(scanned, .pdf, .md, "scan.md"); fatalError("Empty scanned Markdown reported as success") } catch { }
        let mixed = try await convert(root.appendingPathComponent("mixed.pdf"), .pdf, .md, "mixed.md")
        let mixedText = try String(contentsOf: mixed, encoding: .utf8)
        precondition(mixedText.contains("<!-- Page 1 has no selectable text") && mixedText.contains("Open Tangerine document test"))
        print("PASS PDF -> Markdown rejects scanned-only PDFs and notes scanned pages in mixed PDFs")

        let notes = root.appendingPathComponent("notes.md")
        try "# Notes\n\nPlain **markdown** input.".write(to: notes, atomically: true, encoding: .utf8)
        let notesPDF = try await convert(notes, .md, .pdf, "notes.pdf")
        precondition(PDFDocument(url: notesPDF)!.string!.contains("Plain"))
        print("PASS Markdown input still converts to PDF")
    }

    /// Writes a minimal .docx package from WordprocessingML parts.
    static func docx(_ parts: [String: String], to url: URL) async throws {
        let folder = url.deletingPathExtension().appendingPathExtension("parts")
        for (path, content) in parts {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
        try await ZipTool.zip(directory: folder, to: url)
    }

    @MainActor static func docxTests(root: URL, convert: (URL, FileFormat, FileFormat, String) async throws -> URL) async throws {
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:mc=\"http://schemas.openxmlformats.org/markup-compatibility/2006\""
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func p(_ style: String? = nil, num: (Int, Int)? = nil, _ runs: String) -> String {
            var props = style.map { "<w:pStyle w:val=\"\($0)\"/>" } ?? ""
            if let num { props += "<w:numPr><w:ilvl w:val=\"\(num.1)\"/><w:numId w:val=\"\(num.0)\"/></w:numPr>" }
            return "<w:p><w:pPr>\(props)<w:rPr><w:b/></w:rPr></w:pPr>\(runs)</w:p>"
        }
        func r(_ text: String, _ props: String = "") -> String {
            "<w:r><w:rPr>\(props)</w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
        }
        let body = [
            p("Title", r("Quarterly Report")),
            p("Heading1", r("Overview")),
            p(nil, r("Plain ") + r("bold", "<w:b/>") + r(" and ") + r("italic", "<w:i/>") + r(" with ") + r("code()", "<w:rFonts w:ascii=\"Courier New\"/>")
                + r(" and a_b *stars*") + r("hidden", "<w:vanish/>") + "<w:del><w:r><w:delText>gone</w:delText></w:r></w:del>"
                + "<w:r><w:tab/><w:t>tabbed</w:t></w:r>"),
            p(nil, r("Visit ") + "<w:hyperlink r:id=\"rIdLink\">" + r("our site", "<w:rStyle w:val=\"Hyperlink\"/>") + "</w:hyperlink>"
                + r(", ") + "<w:hyperlink r:id=\"rIdBad\">" + r("unsafe") + "</w:hyperlink>"
                + r(" or ") + "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r><w:r><w:instrText> HYPERLINK \"mailto:hi@example.com\" </w:instrText></w:r><w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
                + r("mail us") + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>" + r(".")),
            p(nil, r("Line one") + "<w:r><w:br/></w:r>" + r("# not a heading")),
            p(nil, r("1. Not a list")),
            p("Heading2", r("1. Lists")),
            p(nil, num: (1, 0), r("First bullet")),
            p(nil, num: (1, 1), r("Nested ") + r("bullet", "<w:b/>")),
            p(nil, num: (1, 0), r("Second bullet")),
            p(nil, num: (2, 0), r("Step one")),
            p(nil, num: (2, 0), r("Step two")),
            p(nil, num: (2, 1), r("Sub step")),
            p(nil, num: (2, 0), r("Step three")),
            p("Quote", r("A wise quote")),
            p("CodeBlock", r("let x = 1")),
            p("CodeBlock", ""),
            p("CodeBlock", r("print(x) // **raw**")),
            "<w:tbl><w:tr><w:tc><w:p>" + r("Name") + "</w:p></w:tc><w:tc><w:p>" + r("Qty | Unit") + "</w:p></w:tc></w:tr>"
                + "<w:tr><w:tc><w:p>" + r("Apples", "<w:b/>") + "</w:p></w:tc><w:tc><w:p>" + r("3") + "</w:p><w:p>" + r("kg") + "</w:p></w:tc></w:tr>"
                + "<w:tr><w:tc><w:tcPr><w:gridSpan w:val=\"2\"/></w:tcPr><w:p>" + r("Total") + "</w:p></w:tc></w:tr></w:tbl>",
            p(nil, "<w:r><w:drawing><wp:inline><wp:docPr id=\"1\" name=\"Picture 1\" descr=\"Sales chart\"/><a:blip xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" r:embed=\"rIdImg\"/></wp:inline></w:drawing></w:r>"),
            p(nil, "<w:r><w:pict><v:rect xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\" o:hr=\"t\"/></w:pict></w:r>"),
            p(nil, "<w:r><w:drawing><wp:anchor><wp:docPr id=\"2\" name=\"Shape 2\"/></wp:anchor></w:drawing></w:r>"),
            p(nil, "<mc:AlternateContent><mc:Choice Requires=\"wps\">" + r("Shown once") + "</mc:Choice><mc:Fallback>" + r("Shown once") + "</mc:Fallback></mc:AlternateContent>"),
            "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>",
            p("Heading1", r("Appendix")),
            p(nil, r("Last page.")),
        ].joined()
        let parts = [
            "[Content_Types].xml": "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            "word/_rels/document.xml.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdS\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/><Relationship Id=\"rIdN\" Type=\"\(rel)/numbering\" Target=\"numbering.xml\"/><Relationship Id=\"rIdLink\" Type=\"\(rel)/hyperlink\" Target=\"https://example.com/a(b)\" TargetMode=\"External\"/><Relationship Id=\"rIdBad\" Type=\"\(rel)/hyperlink\" Target=\"file:///etc/passwd\" TargetMode=\"External\"/></Relationships>",
            "word/styles.xml": "<?xml version=\"1.0\"?><w:styles \(w)><w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault></w:docDefaults>"
                + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>"
                + "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:rPr><w:sz w:val=\"56\"/></w:rPr></w:style>"
                + "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/></w:rPr></w:style>"
                + "<w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Heading1\"/><w:pPr><w:outlineLvl w:val=\"1\"/></w:pPr></w:style>"
                + "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:rPr><w:i/></w:rPr></w:style>"
                + "<w:style w:type=\"paragraph\" w:styleId=\"CodeBlock\"><w:name w:val=\"Code Block\"/></w:style>"
                + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/></w:style></w:styles>",
            "word/numbering.xml": "<?xml version=\"1.0\"?><w:numbering \(w)>"
                + "<w:abstractNum w:abstractNumId=\"10\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"bullet\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum>"
                + "<w:abstractNum w:abstractNumId=\"20\"><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:start w:val=\"1\"/><w:numFmt w:val=\"lowerLetter\"/></w:lvl></w:abstractNum>"
                + "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"10\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"20\"/></w:num></w:numbering>",
            "word/document.xml": "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(w)><w:body>\(body)<w:sectPr/></w:body></w:document>",
        ]
        let source = root.appendingPathComponent("report.docx")
        try await docx(parts, to: source)
        let markdown = try String(contentsOf: try await convert(source, .docx, .md, "report.md"), encoding: .utf8)
        let expected = """
        # Quarterly Report

        # Overview

        Plain **bold** and *italic* with `code()` and a\\_b \\*stars\\* tabbed

        Visit [our site](https://example.com/a%28b%29), unsafe or [mail us](mailto:hi@example.com).

        Line one\\
        \\# not a heading

        1\\. Not a list

        ## 1. Lists

        - First bullet
            - Nested **bullet**
        - Second bullet

        1. Step one
        2. Step two
            1. Sub step
        3. Step three

        > *A wise quote*

        ```
        let x = 1

        print(x) // **raw**
        ```

        | Name | Qty \\| Unit |
        | --- | --- |
        | **Apples** | 3<br>kg |
        | Total |   |

        <!-- Image: Sales chart (images are not exported to Markdown) -->

        ---

        Shown once

        # Appendix

        Last page.

        """
        if markdown != expected {
            FileHandle.standardError.write(Data("--- expected\n\(expected)\n--- actual\n\(markdown)".utf8))
            fatalError("DOCX -> Markdown structure mismatch")
        }
        print("PASS DOCX -> Markdown headings, emphasis, code, links, breaks, lists, quotes, code blocks, tables, images, hidden/deleted text")

        let pdf = try await convert(source, .docx, .pdf, "report.pdf")
        let document = PDFDocument(url: pdf)!
        precondition(document.pageCount == 2, "page break should start page 2, got \(document.pageCount)")
        precondition(document.page(at: 0)!.string!.contains("Quarterly Report") && document.page(at: 1)!.string!.contains("Appendix"))
        print("PASS DOCX -> PDF keeps text and page breaks")

        // A document saved by TextEdit has no heading styles; size marks the heading.
        let plain = NSMutableAttributedString(string: "Trip Notes\n", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 24)!])
        let long = Array(repeating: "Body text that is long enough to wrap across several lines on the page.", count: 400).joined(separator: " ")
        plain.append(NSAttributedString(string: "Packed bags.\n\(long)\n", attributes: [.font: NSFont(name: "Helvetica", size: 12)!]))
        let textEdit = root.appendingPathComponent("textedit.docx")
        try plain.data(from: NSRange(location: 0, length: plain.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: textEdit)
        let textEditMarkdown = try String(contentsOf: try await convert(textEdit, .docx, .md, "textedit.md"), encoding: .utf8)
        precondition(textEditMarkdown.hasPrefix("# Trip Notes\n\nPacked bags.\n\nBody text"), textEditMarkdown)
        let longPDF = PDFDocument(url: try await convert(textEdit, .docx, .pdf, "textedit.pdf"))!
        precondition(longPDF.pageCount > 1 && longPDF.string!.contains("Trip Notes"))
        print("PASS DOCX from TextEdit -> Markdown size headings and multi-page PDF")

        let broken = root.appendingPathComponent("broken.docx")
        try Data("not a zip".utf8).write(to: broken)
        for target: FileFormat in [.md, .pdf] {
            do { _ = try await convert(broken, .docx, target, "broken.\(target.fileExtension)"); fatalError("Broken DOCX reported as success") } catch { }
        }
        print("PASS DOCX rejects files that are not Word documents")
    }
}
