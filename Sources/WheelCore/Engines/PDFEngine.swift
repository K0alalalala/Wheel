import AppKit
import PDFKit

public enum PDFEngine {
    /// Renders a page to an opaque bitmap on white.
    public static func render(page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let ptSize = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let scale = dpi / 72
        let w = Int((ptSize.width * scale).rounded()), h = Int((ptSize.height * scale).rounded())
        guard let ctx = ImageEngine.bitmap(width: w, height: h) else { throw ActionError("Out of memory rendering page.") }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let img = ctx.makeImage() else { throw ActionError("Couldn't render page.") }
        return img
    }

    public static func text(of url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ActionError("Couldn't open \(url.lastPathComponent).") }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            parts.append(doc.page(at: i)?.string ?? "")
        }
        return parts.joined(separator: "\n\u{0C}\n")
    }

    public static func attributedText(of url: URL) throws -> NSAttributedString {
        guard let doc = PDFDocument(url: url) else { throw ActionError("Couldn't open \(url.lastPathComponent).") }
        let out = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.attributedString { out.append(s) }
            if i < doc.pageCount - 1 { out.append(NSAttributedString(string: "\n\n")) }
        }
        return out
    }
}
