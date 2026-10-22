import AppKit
import PDFKit

public enum PDFEngine {
    /// Renders a page to an opaque bitmap on white, as it appears on screen (crop box, rotation applied).
    public static func render(page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let ptSize = PDFTools.displayedSize(page)
        let scale = dpi / 72
        let w = Int((ptSize.width * scale).rounded()), h = Int((ptSize.height * scale).rounded())
        guard let ctx = ImageEngine.bitmap(width: w, height: h) else { throw ActionError("Out of memory rendering page.") }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        if let ref = page.pageRef {
            // getDrawingTransform only scales down, so draw at 72 dpi into a scaled context.
            ctx.scaleBy(x: scale, y: scale)
            let unscaled = CGRect(origin: .zero, size: ptSize)
            ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: unscaled, rotate: 0, preserveAspectRatio: true))
            ctx.clip(to: ref.getBoxRect(.cropBox))
            ctx.drawPDFPage(ref)
        } else {
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: ctx)
        }
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
