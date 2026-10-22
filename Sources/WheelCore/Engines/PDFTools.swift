import AppKit
import CoreText
import PDFKit
import Quartz
import Vision

/// Page-level PDF operations behind the PDF edit tools. Every function returns a new document or
/// writes a new file; inputs are never modified.
public enum PDFTools {

    // MARK: Loading & saving

    /// Opens a PDF, unlocking it with `password` when given. Throws a clear error for locked files.
    public static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ActionError("Couldn't open \(url.lastPathComponent) as a PDF.") }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else {
                throw ActionError(password == nil
                    ? "\(url.lastPathComponent) is password-protected. Use Unlock first."
                    : "Wrong password for \(url.lastPathComponent).")
            }
        }
        return doc
    }

    public static func save(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ActionError("\(url.lastPathComponent) already exists.") }
        guard doc.write(to: url, withOptions: options) else {
            try? FileManager.default.removeItem(at: url)
            throw ActionError("Couldn't write \(url.lastPathComponent).")
        }
    }

    /// Writes `doc` beside `source` as "<name> <suffix>.pdf".
    @discardableResult
    public static func saveBeside(_ doc: PDFDocument, source: URL, suffix: String, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        let out = OutputPath.beside(source, suffix: suffix, ext: "pdf")
        try save(doc, to: out, options: options)
        return out
    }

    // MARK: Assembling pages

    /// One page of an assembled document: a copy of a source page (or a blank page) plus extra rotation.
    public struct PageItem: Hashable, Identifiable {
        public let id = UUID()
        public var source: Int?          // nil = blank page
        public var rotation: Int = 0     // extra degrees, multiple of 90

        public init(source: Int?, rotation: Int = 0) { self.source = source; self.rotation = rotation }
    }

    /// Builds a new document from `items`. Blank pages take the size of the first page.
    public static func assemble(_ doc: PDFDocument, _ items: [PageItem]) -> PDFDocument {
        let out = PDFDocument()
        let blankSize = doc.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
        for item in items {
            let page: PDFPage
            if let i = item.source, let src = doc.page(at: i), let copy = src.copy() as? PDFPage {
                page = copy
            } else {
                page = blankPage(size: blankSize)
            }
            if item.rotation % 360 != 0 { page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360 }
            out.insert(page, at: out.pageCount)
        }
        out.documentAttributes = doc.documentAttributes
        return out
    }

    public static func pages(_ doc: PDFDocument, keeping indices: [Int]) -> PDFDocument {
        assemble(doc, indices.filter { $0 >= 0 && $0 < doc.pageCount }.map { PageItem(source: $0) })
    }

    public static func pages(_ doc: PDFDocument, removing indices: Set<Int>) -> PDFDocument {
        pages(doc, keeping: (0..<doc.pageCount).filter { !indices.contains($0) })
    }

    public static func rotated(_ doc: PDFDocument, by degrees: Int, pages: Set<Int>? = nil) -> PDFDocument {
        assemble(doc, (0..<doc.pageCount).map { PageItem(source: $0, rotation: pages == nil || pages!.contains($0) ? degrees : 0) })
    }

    public static func reversed(_ doc: PDFDocument) -> PDFDocument {
        pages(doc, keeping: Array((0..<doc.pageCount).reversed()))
    }

    /// Chunks of `size` pages each (the last one may be shorter).
    public static func split(_ doc: PDFDocument, every size: Int) -> [(range: ClosedRange<Int>, doc: PDFDocument)] {
        let n = max(size, 1)
        return stride(from: 0, to: doc.pageCount, by: n).map { start in
            let range = start...min(start + n - 1, doc.pageCount - 1)
            return (range, pages(doc, keeping: Array(range)))
        }
    }

    /// Joins PDFs and images, in the given order. Images become one page each, sized to the image.
    public static func merge(_ urls: [URL]) throws -> PDFDocument {
        let out = PDFDocument()
        for url in urls {
            if FileKind.of(url) == .pdf {
                let doc = try open(url)
                for i in 0..<doc.pageCount {
                    if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
                }
            } else if FileKind.of(url) == .image {
                let img = try ImageEngine.load(url)
                guard let page = PDFPage(image: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))) else {
                    throw ActionError("Couldn't add \(url.lastPathComponent).")
                }
                out.insert(page, at: out.pageCount)
            } else {
                throw ActionError("\(url.lastPathComponent) isn't a PDF or image.")
            }
        }
        guard out.pageCount > 0 else { throw ActionError("Nothing to merge.") }
        return out
    }

    public static func removingAnnotations(_ doc: PDFDocument, keepLinks: Bool = true) -> PDFDocument {
        let out = assemble(doc, (0..<doc.pageCount).map { PageItem(source: $0) })
        for i in 0..<out.pageCount {
            guard let page = out.page(at: i) else { continue }
            for a in page.annotations where !(keepLinks && a.type == "Link") { page.removeAnnotation(a) }
        }
        return out
    }

    /// Parses "1-3, 5, 8-" (1-based, inclusive; open ends allowed) into 0-based indices.
    public static func parseRanges(_ text: String, pageCount: Int) -> [Int] {
        var result: [Int] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
            let bits = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if bits.count == 1, let n = Int(bits[0]) {
                result.append(n - 1)
            } else if bits.count == 2 {
                let a = Int(bits[0]) ?? 1, b = Int(bits[1]) ?? pageCount
                if a <= b { result += Array((a - 1)...(b - 1)) } else { result += Array(((b - 1)...(a - 1)).reversed()) }
            }
        }
        var seen = Set<Int>()
        return result.filter { $0 >= 0 && $0 < pageCount && seen.insert($0).inserted }
    }

    /// "1–3, 5" style label for a set of 0-based indices.
    public static func rangeLabel(_ indices: [Int]) -> String {
        let s = indices.sorted()
        var parts: [String] = []
        var i = 0
        while i < s.count {
            var j = i
            while j + 1 < s.count, s[j + 1] == s[j] + 1 { j += 1 }
            parts.append(i == j ? "\(s[i] + 1)" : "\(s[i] + 1)–\(s[j] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    private static func blankPage(size: CGSize) -> PDFPage {
        let img = NSImage(size: size, flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
        let page = PDFPage(image: img) ?? PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        return page
    }

    // MARK: Redrawing pages (stamps)

    /// Redraws every page into a new PDF (keeping text and vectors), calling `overlay` on top.
    /// The overlay draws in page space: origin bottom-left, size = the page as displayed (rotation applied).
    /// Annotations and form fields are not carried over; the visible result is burned in.
    public static func restamp(_ doc: PDFDocument, to url: URL,
                               overlay: (CGContext, CGRect, Int, Int) -> Void) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ActionError("Couldn't create PDF.") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let ref = page.pageRef else { continue }
            var rect = CGRect(origin: .zero, size: displayedSize(page))
            ctx.beginPage(mediaBox: &rect)
            ctx.saveGState()
            ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            ctx.clip(to: ref.getBoxRect(.cropBox))
            ctx.drawPDFPage(ref)
            ctx.restoreGState()
            ctx.saveGState()
            overlay(ctx, rect, i, doc.pageCount)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
    }

    /// Renders one page with an overlay into a bitmap at most `maxPixel` on its long side (for live previews).
    public static func preview(_ page: PDFPage, maxPixel: CGFloat, index: Int = 0, count: Int = 1,
                               overlay: ((CGContext, CGRect, Int, Int) -> Void)? = nil) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        let size = displayedSize(page)
        let s = maxPixel / max(size.width, size.height)
        guard let ctx = ImageEngine.bitmap(width: Int(size.width * s), height: Int(size.height * s)) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: s, y: s)
        let rect = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: ref.getBoxRect(.cropBox))
        ctx.drawPDFPage(ref)
        ctx.restoreGState()
        overlay?(ctx, rect, index, count)
        return ctx.makeImage()
    }

    /// Page size as shown on screen: crop box with rotation applied.
    public static func displayedSize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? b : CGSize(width: b.height, height: b.width)
    }

    /// Draws a string centred at `center`, rotated by `angle` degrees.
    static func drawText(_ text: String, in ctx: CGContext, center: CGPoint, size: CGFloat, color: NSColor,
                         angle: CGFloat = 0, weight: NSFont.Weight = .bold) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle * .pi / 180)
        ctx.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Watermark

    public struct WatermarkOptions: Equatable {
        public enum Layout: String, CaseIterable { case center, tiled }
        public var text = "CONFIDENTIAL"
        public var size: CGFloat = 64
        public var opacity: CGFloat = 0.18
        public var angle: CGFloat = 45
        public var color = NSColor.red
        public var layout = Layout.center
        public init() {}
    }

    public static func drawWatermark(_ o: WatermarkOptions, in ctx: CGContext, page rect: CGRect) {
        guard !o.text.isEmpty else { return }
        let color = o.color.withAlphaComponent(o.opacity)
        switch o.layout {
        case .center:
            drawText(o.text, in: ctx, center: CGPoint(x: rect.midX, y: rect.midY), size: o.size, color: color, angle: o.angle)
        case .tiled:
            let step = max(o.size * CGFloat(o.text.count) * 0.45, o.size * 3)
            var y = rect.minY - step
            var row = 0
            while y < rect.maxY + step {
                var x = rect.minX - step + (row.isMultiple(of: 2) ? 0 : step / 2)
                while x < rect.maxX + step {
                    drawText(o.text, in: ctx, center: CGPoint(x: x, y: y), size: o.size, color: color, angle: o.angle)
                    x += step
                }
                y += step * 0.6; row += 1
            }
        }
    }

    // MARK: Page numbers

    public struct PageNumberOptions: Equatable {
        public enum Position: String, CaseIterable {
            case bottomCenter, bottomRight, bottomLeft, topCenter, topRight, topLeft
        }
        public enum Format: String, CaseIterable { case plain, pageOf, dashed }
        public var position = Position.bottomCenter
        public var format = Format.plain
        public var start = 1
        public var size: CGFloat = 11
        public var margin: CGFloat = 28
        public var skipFirst = false
        public init() {}

        public func label(index: Int, count: Int) -> String {
            let n = start + index
            switch format {
            case .plain: return "\(n)"
            case .pageOf: return "Page \(n) of \(start + count - 1)"
            case .dashed: return "– \(n) –"
            }
        }
    }

    public static func drawPageNumber(_ o: PageNumberOptions, in ctx: CGContext, page rect: CGRect, index: Int, count: Int) {
        if o.skipFirst && index == 0 { return }
        let label = o.label(index: index, count: count)
        let x: CGFloat, y: CGFloat
        switch o.position {
        case .bottomCenter, .topCenter: x = rect.midX
        case .bottomLeft, .topLeft: x = rect.minX + o.margin + o.size * CGFloat(label.count) * 0.3
        case .bottomRight, .topRight: x = rect.maxX - o.margin - o.size * CGFloat(label.count) * 0.3
        }
        switch o.position {
        case .bottomCenter, .bottomLeft, .bottomRight: y = rect.minY + o.margin
        default: y = rect.maxY - o.margin
        }
        drawText(label, in: ctx, center: CGPoint(x: x, y: y), size: o.size, color: .black, weight: .regular)
    }

    // MARK: 2-up

    /// Two pages side by side on landscape sheets the size of the first page turned sideways.
    public static func twoUp(_ doc: PDFDocument, to url: URL) throws {
        guard let first = doc.page(at: 0) else { throw ActionError("The PDF has no pages.") }
        let p = displayedSize(first)
        var sheet = CGRect(x: 0, y: 0, width: max(p.width, p.height), height: min(p.width, p.height))
        guard let ctx = CGContext(url as CFURL, mediaBox: &sheet, nil) else { throw ActionError("Couldn't create PDF.") }
        let margin: CGFloat = 18
        let slotW = (sheet.width - margin * 3) / 2, slotH = sheet.height - margin * 2
        for start in stride(from: 0, to: doc.pageCount, by: 2) {
            ctx.beginPage(mediaBox: &sheet)
            for k in 0..<2 {
                guard let page = doc.page(at: start + k), let ref = page.pageRef else { continue }
                let slot = CGRect(x: margin + CGFloat(k) * (slotW + margin), y: margin, width: slotW, height: slotH)
                ctx.saveGState()
                ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: slot, rotate: 0, preserveAspectRatio: true))
                ctx.clip(to: ref.getBoxRect(.cropBox))
                ctx.drawPDFPage(ref)
                ctx.restoreGState()
            }
            ctx.endPage()
        }
        ctx.closePDF()
    }

    // MARK: Security

    public struct ProtectOptions {
        public var openPassword = ""          // needed to open; empty = anyone can open
        public var ownerPassword = ""         // needed to change permissions; defaults to a random one
        public var allowPrinting = true
        public var allowCopying = true
        public init() {}
    }

    public static func protect(_ doc: PDFDocument, source: URL, _ o: ProtectOptions) throws -> URL {
        guard !o.openPassword.isEmpty || !o.allowPrinting || !o.allowCopying else {
            throw ActionError("Set a password or restrict printing/copying.")
        }
        // PDFAccessPermissions is a plain enum in Swift, so combine the raw bit values.
        var perms = PDFAccessPermissions.allowsContentAccessibility.rawValue
        if o.allowPrinting { perms |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue }
        if o.allowCopying { perms |= PDFAccessPermissions.allowsContentCopying.rawValue }
        let owner = o.ownerPassword.isEmpty ? UUID().uuidString : o.ownerPassword
        var opts: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: owner, .accessPermissionsOption: perms]
        if !o.openPassword.isEmpty { opts[.userPasswordOption] = o.openPassword }
        return try saveBeside(doc, source: source, suffix: "Protected", options: opts)
    }

    /// Saves an unencrypted copy. `password` is only needed if the file asks for one to open.
    public static func unlock(_ url: URL, password: String?) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ActionError("Couldn't open \(url.lastPathComponent).") }
        guard doc.isEncrypted else { throw ActionError("\(url.lastPathComponent) isn't protected.") }
        if doc.isLocked {
            guard let password, !password.isEmpty, doc.unlock(withPassword: password) else {
                throw ActionError("Wrong password for \(url.lastPathComponent).")
            }
        }
        // Rebuild from the decrypted pages so no encryption dictionary is carried over.
        let clean = assemble(doc, (0..<doc.pageCount).map { PageItem(source: $0) })
        return try saveBeside(clean, source: url, suffix: "Unlocked")
    }

    /// True when opening needs a password (as opposed to only having restrictions).
    public static func needsPassword(_ url: URL) -> Bool { PDFDocument(url: url)?.isLocked ?? false }

    // MARK: Rasterizing

    /// Renders every page to an image page: removes hidden text, layers, forms and annotations.
    public static func flatten(_ doc: PDFDocument, to url: URL, dpi: CGFloat = 200, gray: Bool = false,
                               progress: ((Double) -> Void)? = nil) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ActionError("Couldn't create PDF.") }
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            var image = try PDFEngine.render(page: page, dpi: dpi)
            if gray { image = grayscale(image) ?? image }
            var rect = CGRect(origin: .zero, size: displayedSize(page))
            ctx.beginPage(mediaBox: &rect)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            ctx.endPage()
            progress?(Double(i + 1) / Double(doc.pageCount))
        }
        ctx.closePDF()
    }

    private static func grayscale(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Grayscale that keeps text and vectors, via the system "Gray Tone" Quartz filter.
    /// Falls back to rasterizing if the filter isn't available.
    public static func grayscale(_ doc: PDFDocument, to url: URL) throws {
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter")
        if FileManager.default.fileExists(atPath: filterURL.path), let filter = QuartzFilter(url: filterURL),
           doc.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) {
            return
        }
        try? FileManager.default.removeItem(at: url)
        try flatten(doc, to: url, gray: true)
    }

    // MARK: Trim margins

    /// Tightens each page's crop box to its visible content plus `padding` points.
    public static func trimmed(_ doc: PDFDocument, padding: CGFloat = 12) -> PDFDocument {
        let out = assemble(doc, (0..<doc.pageCount).map { PageItem(source: $0) })
        for i in 0..<out.pageCount {
            guard let page = out.page(at: i), let content = contentBounds(page) else { continue }
            let media = page.bounds(for: .mediaBox)
            page.setBounds(content.insetBy(dx: -padding, dy: -padding).intersection(media), for: .cropBox)
        }
        return out
    }

    /// Non-white area of a page in its media-box coordinates (unrotated), or nil for blank pages.
    static func contentBounds(_ page: PDFPage) -> CGRect? {
        guard let ref = page.pageRef else { return nil }
        let media = page.bounds(for: .mediaBox)
        let scale: CGFloat = 1.5
        let w = Int(media.width * scale), h = Int(media.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -media.minX, y: -media.minY)
        ctx.drawPDFPage(ref)
        let px = data.assumingMemoryBound(to: UInt8.self)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = px + y * w
            for x in 0..<w where row[x] < 245 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        // Bitmap rows run top-down in memory; convert back to PDF space (bottom-up).
        return CGRect(x: media.minX + CGFloat(minX) / scale, y: media.minY + CGFloat(h - 1 - maxY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    // MARK: OCR

    /// Adds an invisible, selectable text layer to pages that have no text (scans, photos).
    /// Pages that already contain text are copied unchanged. Recognition runs on-device (Vision).
    public static func makeSearchable(_ doc: PDFDocument, to url: URL, progress: ((Double) -> Void)? = nil) throws -> Int {
        var recognizedPages = 0
        try restampWithOCR(doc, to: url) { done in progress?(done) } counter: { recognizedPages += 1 }
        return recognizedPages
    }

    private static func restampWithOCR(_ doc: PDFDocument, to url: URL, progress: (Double) -> Void, counter: () -> Void) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ActionError("Couldn't create PDF.") }
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i), let ref = page.pageRef else { continue }
            var rect = CGRect(origin: .zero, size: displayedSize(page))
            ctx.beginPage(mediaBox: &rect)
            ctx.saveGState()
            ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            ctx.clip(to: ref.getBoxRect(.cropBox))
            ctx.drawPDFPage(ref)
            ctx.restoreGState()

            let hasText = !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasText {
                let image = try PDFEngine.render(page: page, dpi: 250)
                let lines = try recognize(image)
                if !lines.isEmpty { counter() }
                for line in lines { drawInvisible(line.text, in: ctx, box: line.box, page: rect) }
            }
            ctx.endPage()
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        ctx.closePDF()
    }

    struct RecognizedLine { let text: String; let box: CGRect } // box normalized, origin bottom-left

    static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return RecognizedLine(text: top.string, box: obs.boundingBox)
        }
    }

    /// Text that can be selected and searched but isn't visible, stretched over the recognized box.
    private static func drawInvisible(_ text: String, in ctx: CGContext, box: CGRect, page: CGRect) {
        let r = CGRect(x: page.minX + box.minX * page.width, y: page.minY + box.minY * page.height,
                       width: box.width * page.width, height: box.height * page.height)
        guard r.width > 1, r.height > 1 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, r.height * 0.85, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        guard width > 0 else { return }
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.15)
        ctx.scaleBy(x: r.width / CGFloat(width), y: 1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
