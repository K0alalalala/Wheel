import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Operations that turn several files into one.
public enum CombineEngine {

    // MARK: Combine into PDF

    public enum PageSize: String, CaseIterable, Codable {
        case original, letter, a4
        public var title: String { self == .original ? "Original" : self == .letter ? "Letter" : "A4" }
        var size: CGSize? {
            switch self {
            case .original: return nil
            case .letter: return CGSize(width: 612, height: 792)
            case .a4: return CGSize(width: 595, height: 842)
            }
        }
    }

    public static func canCombineIntoPDF(_ url: URL) -> Bool { [.pdf, .image, .document].contains(FileKind.of(url)) }

    /// PDFs (all pages), images (one page each) and documents (typeset) into one PDF, in the given order.
    /// With a page size, images are fitted onto pages of that size (landscape for wide images).
    public static func pdf(from urls: [URL], pageSize: PageSize = .original,
                           progress: ((Double) -> Void)? = nil) async throws -> PDFDocument {
        let out = PDFDocument()
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            switch FileKind.of(url) {
            case .pdf:
                let doc = try PDFTools.open(url)
                for p in 0..<doc.pageCount {
                    if let page = doc.page(at: p)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
                }
            case .image:
                out.insert(try imagePage(url, pageSize: pageSize.size), at: out.pageCount)
            case .document:
                let doc = try await typeset(url)
                for p in 0..<doc.pageCount {
                    if let page = doc.page(at: p)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
                }
            default:
                throw ActionError("\(url.lastPathComponent) can't go into a PDF.")
            }
            progress?(Double(i + 1) / Double(urls.count))
        }
        guard out.pageCount > 0 else { throw ActionError("Nothing to combine.") }
        return out
    }

    private static func imagePage(_ url: URL, pageSize: CGSize?) throws -> PDFPage {
        let img = try ImageEngine.load(url)
        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        guard var size = pageSize else {
            guard let page = PDFPage(image: ns) else { throw ActionError("Couldn't add \(url.lastPathComponent).") }
            return page
        }
        if img.width > img.height { size = CGSize(width: size.height, height: size.width) }
        let box = CGRect(origin: .zero, size: size)
        guard let page = PDFPage(image: ns, options: [.mediaBox: NSValue(rect: box), .upscaleIfSmaller: true]) else {
            throw ActionError("Couldn't add \(url.lastPathComponent).")
        }
        return page
    }

    /// Text documents become Letter pages via the same typesetter as Convert → PDF.
    @MainActor
    private static func typeset(_ url: URL) async throws -> PDFDocument {
        let text = try await DocumentEngine.read(url)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try DocumentEngine.writePDF(text, to: tmp)
        guard let doc = PDFDocument(url: tmp) else { throw ActionError("Couldn't typeset \(url.lastPathComponent).") }
        // Detach pages from the temp file before it's deleted.
        guard let data = doc.dataRepresentation(), let copy = PDFDocument(data: data) else { return doc }
        return copy
    }

    // MARK: Stitch images

    public enum StitchLayout: String, CaseIterable, Codable { case vertical, horizontal, grid }

    public struct StitchOptions: Equatable {
        public var layout = StitchLayout.vertical
        public var columns = 2
        public var spacing: CGFloat = 0          // px between images
        public var background = NSColor.white
        public var matchSizes = true              // scale to a common width (vertical) / height (horizontal) / cell (grid)
        public init() {}
    }

    /// Joins images into one. Never upscales beyond the largest input, and caps at 16k px per side.
    public static func stitch(_ images: [CGImage], _ o: StitchOptions) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let gap = max(0, o.spacing)
        var placed: [(CGImage, CGRect)] = []
        var canvas = CGSize.zero

        switch o.layout {
        case .vertical:
            let width = CGFloat(images.map(\.width).max()!)
            var y: CGFloat = 0
            for img in images {
                let s = o.matchSizes ? width / CGFloat(img.width) : 1
                let size = CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
                placed.append((img, CGRect(x: (width - size.width) / 2, y: y, width: size.width, height: size.height)))
                y += size.height + gap
            }
            canvas = CGSize(width: width, height: y - gap)
        case .horizontal:
            let height = CGFloat(images.map(\.height).max()!)
            var x: CGFloat = 0
            for img in images {
                let s = o.matchSizes ? height / CGFloat(img.height) : 1
                let size = CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
                placed.append((img, CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)))
                x += size.width + gap
            }
            canvas = CGSize(width: x - gap, height: height)
        case .grid:
            let cols = min(max(o.columns, 1), images.count)
            let rows = Int((Double(images.count) / Double(cols)).rounded(.up))
            let cell = CGSize(width: CGFloat(images.map(\.width).max()!), height: CGFloat(images.map(\.height).max()!))
            for (i, img) in images.enumerated() {
                let r = i / cols, c = i % cols
                let frame = CGRect(x: CGFloat(c) * (cell.width + gap), y: CGFloat(r) * (cell.height + gap), width: cell.width, height: cell.height)
                let s = o.matchSizes ? min(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height)) : 1
                let size = CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
                placed.append((img, CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)))
            }
            canvas = CGSize(width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * gap,
                            height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap)
        }

        let limit: CGFloat = 16_000
        let k = min(1, limit / max(canvas.width, canvas.height))
        guard let ctx = ImageEngine.bitmap(width: Int((canvas.width * k).rounded()), height: Int((canvas.height * k).rounded())) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(o.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        // Layout above is top-down; CoreGraphics is bottom-up.
        for (img, r) in placed {
            let flipped = CGRect(x: r.minX * k, y: (canvas.height - r.maxY) * k, width: r.width * k, height: r.height * k)
            ctx.draw(img, in: flipped)
        }
        return ctx.makeImage()
    }

    // MARK: Animated GIF

    public struct GIFOptions: Equatable {
        public var frameDelay = 0.5        // seconds per frame
        public var maxSize = 800           // px, long side
        public var loop = true
        public var boomerang = false       // play forward then backward
        public init() {}
    }

    /// Frames are fitted onto one canvas (the first image's aspect) so sizes can differ.
    public static func gif(_ images: [CGImage], _ o: GIFOptions, to url: URL) throws {
        guard let first = images.first else { throw ActionError("No images.") }
        var frames = images
        if o.boomerang, images.count > 2 { frames += images.dropFirst().dropLast().reversed() }
        let s = min(1, CGFloat(o.maxSize) / CGFloat(max(first.width, first.height)))
        let w = Int(CGFloat(first.width) * s), h = Int(CGFloat(first.height) * s)

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw ActionError("Couldn't create GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: o.loop ? 0 : 1]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: o.frameDelay,
                                                          kCGImagePropertyGIFUnclampedDelayTime: o.frameDelay]] as CFDictionary
        for img in frames {
            guard let ctx = ImageEngine.bitmap(width: w, height: h) else { continue }
            ctx.interpolationQuality = .high
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let fit = min(CGFloat(w) / CGFloat(img.width), CGFloat(h) / CGFloat(img.height))
            let fw = CGFloat(img.width) * fit, fh = CGFloat(img.height) * fit
            ctx.draw(img, in: CGRect(x: (CGFloat(w) - fw) / 2, y: (CGFloat(h) - fh) / 2, width: fw, height: fh))
            if let frame = ctx.makeImage() { CGImageDestinationAddImage(dest, frame, frameProps) }
        }
        guard CGImageDestinationFinalize(dest) else { throw ActionError("Couldn't write GIF.") }
    }

    // MARK: Join audio/video

    /// Plays clips back to back in one file: MP4 if any clip has video, otherwise M4A.
    public static func join(_ urls: [URL], name: String, progress: @escaping ProgressHandler) async throws -> URL {
        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        var hasVideo = false
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            if try await !asset.loadTracks(withMediaType: .video).isEmpty { hasVideo = true }
            do {
                try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: cursor)
            } catch {
                throw ActionError("Couldn't add \(url.lastPathComponent): \(error.localizedDescription)")
            }
            cursor = cursor + duration
        }
        let ext = hasVideo ? "mp4" : "m4a"
        let out = OutputPath.unique(in: urls[0].deletingLastPathComponent(),
                                    base: name.isEmpty ? "Joined" : ArchiveEngine.sanitized(name), ext: ext)
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: hasVideo ? AVAssetExportPresetHighestQuality : AVAssetExportPresetAppleM4A) else {
            throw ActionError("These clips can't be exported together.")
        }
        session.outputURL = out
        session.outputFileType = hasVideo ? .mp4 : .m4a
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poll.cancel() }
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        if session.status == .cancelled { try? FileManager.default.removeItem(at: out); throw CancellationError() }
        if let error = session.error { try? FileManager.default.removeItem(at: out); throw ActionError(error.localizedDescription) }
        return out
    }
}
