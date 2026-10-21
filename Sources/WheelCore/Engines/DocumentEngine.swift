import AppKit
import CoreText

/// Document formats the Convert wheel can produce from documents and PDFs.
public enum DocFormat: String, CaseIterable {
    case pdf, docx, txt, rtf, html

    public var title: String { rawValue.uppercased() }

    public static func of(_ url: URL) -> DocFormat? {
        switch url.pathExtension.lowercased() {
        case "htm": return .html
        case let e: return DocFormat(rawValue: e)
        }
    }
}

/// Native document conversion through NSAttributedString (reads/writes DOCX, RTF, HTML, TXT)
/// and CoreText for paginated PDF output. pandoc is used for Markdown when installed.
public enum DocumentEngine {
    public static let pageSize = CGSize(width: 612, height: 792) // US Letter
    public static let margin: CGFloat = 54

    public static func read(_ url: URL) async throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try PDFEngine.attributedText(of: url)
        case "md", "markdown":
            let text = try String(contentsOf: url, encoding: .utf8)
            if let pandoc = ExternalTools.pandoc {
                let html = try await ExternalTools.run(pandoc, ["-f", "gfm", "-t", "html", "-s", url.path])
                if let s = attributed(html: Data(html.utf8)) { return s }
            }
            let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            let a = try AttributedString(markdown: text, options: opts)
            return styled(NSAttributedString(a))
        case "txt":
            return styled(NSAttributedString(string: try String(contentsOf: url, encoding: .utf8)))
        default:
            var attrs: NSDictionary? = nil
            do {
                return try NSAttributedString(url: url, options: [:], documentAttributes: &attrs)
            } catch {
                throw ActionError("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private static func attributed(html: Data) -> NSAttributedString? {
        try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html,
                                                       .characterEncoding: String.Encoding.utf8.rawValue],
                                documentAttributes: nil)
    }

    /// Plain text gets a readable default font instead of 12pt Helvetica.
    private static func styled(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { m.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: range) }
        }
        m.addAttribute(.foregroundColor, value: NSColor.black, range: full)
        return m
    }

    public static func write(_ text: NSAttributedString, as format: DocFormat, to url: URL) throws {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .txt:
            try text.string.write(to: url, atomically: true, encoding: .utf8)
        case .pdf:
            try writePDF(text, to: url)
        case .docx, .rtf, .html:
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : format == .rtf ? .rtf : .html
            let data = try text.data(from: range, documentAttributes: [.documentType: type])
            try data.write(to: url, options: .withoutOverwriting)
        }
    }

    /// Lays text out across Letter pages with CoreText.
    public static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ActionError("Couldn't create PDF.") }
        let setter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        let frameRect = box.insetBy(dx: margin, dy: margin)
        var location = 0
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            if visible.length == 0 { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }
}
