import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Output image formats the Convert wheel knows about, in wheel order.
public enum ImageFormat: String, CaseIterable, Codable {
    case png, jpg, webp, heic, tiff, bmp, avif, gif

    public var ext: String { rawValue }
    public var title: String { rawValue.uppercased() }

    public var utType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .avif: return UTType("public.avif") ?? .image
        case .gif: return .gif
        }
    }

    public var supportsQuality: Bool { [.jpg, .heic, .avif, .webp].contains(self) }
    public var supportsAlpha: Bool { [.png, .tiff, .heic, .avif, .webp, .gif].contains(self) }

    public static func of(_ url: URL) -> ImageFormat? {
        let ext = url.pathExtension.lowercased()
        if ext == "jpeg" { return .jpg }
        if ext == "tif" { return .tiff }
        if ext == "heif" { return .heic }
        return ImageFormat(rawValue: ext)
    }

    /// True when ImageIO can write this format directly.
    public var writableByImageIO: Bool {
        let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return ids.contains(utType.identifier)
    }
}

public enum ImageEngine {
    public static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Loads an image file with its EXIF orientation applied. PDFs render page 1.
    public static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        if FileKind.of(url) == .pdf {
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { throw ActionError("Couldn't open \(url.lastPathComponent).") }
            return try PDFEngine.render(page: page, dpi: 200)
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ActionError("Couldn't read \(url.lastPathComponent) as an image.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(w, h, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ActionError("Couldn't decode \(url.lastPathComponent).")
        }
        return img
    }

    public static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? Int,
              var h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
        return CGSize(width: w, height: h)
    }

    /// Image properties (EXIF, GPS, TIFF...) of the first frame.
    public static func properties(_ url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return props
    }

    /// Encodes `image` to `format`. `quality` is 0...1 for lossy formats.
    public static func encode(_ image: CGImage, format: ImageFormat, quality: Double = 0.85, properties: [CFString: Any]? = nil) throws -> Data {
        if format == .webp && !format.writableByImageIO {
            return try ExternalTools.encodeWebP(image, quality: quality)
        }
        var img = image
        if !format.supportsAlpha { img = flattened(image, background: .white) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw ActionError("This Mac can't write \(format.title).")
        }
        var opts: [CFString: Any] = properties ?? [:]
        if format.supportsQuality { opts[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ActionError("Couldn't encode \(format.title).") }
        return data as Data
    }

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double = 0.85) throws {
        let data = try encode(image, format: format, quality: quality)
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// Writes a one-page-per-image PDF, each page sized to its image at 72 dpi.
    public static func writePDF(_ images: [CGImage], to url: URL) throws {
        guard let first = images.first else { return }
        var box = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ActionError("Couldn't create PDF.") }
        for img in images {
            var pageBox = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            let info = [kCGPDFContextMediaBox: Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.draw(img, in: pageBox)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    public static func flattened(_ image: CGImage, background: NSColor) -> CGImage {
        guard let ctx = bitmap(width: image.width, height: image.height) else { return image }
        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    public static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Crops using a rect in top-left-origin pixel coordinates.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        image.cropping(to: rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }

    /// The format edits are saved in: the source's own format when we can write it, otherwise PNG.
    public static func editOutputFormat(for source: URL) -> ImageFormat {
        if let f = ImageFormat.of(source), f != .gif, f.writableByImageIO || (f == .webp && ExternalTools.cwebp != nil) { return f }
        return .png
    }
}
