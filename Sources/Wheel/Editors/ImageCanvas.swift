import AppKit
import WheelCore
import SwiftUI

/// Maps between the fitted on-screen image rect and image pixels (top-left origin).
struct ImageMapper {
    let imageSize: CGSize
    let rect: CGRect

    var scale: CGFloat { rect.width / max(imageSize.width, 1) }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / scale, y: (p.y - rect.minY) / scale)
    }
    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x * scale, y: rect.minY + p.y * scale)
    }
    func toView(_ r: CGRect) -> CGRect {
        CGRect(origin: toView(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale))
    }
    func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imageSize.width), y: min(max(p.y, 0), imageSize.height))
    }
}

/// Shows an image fitted to the available space, with an overlay that gets a mapper.
struct ImageCanvas<Overlay: View>: View {
    let image: NSImage
    let pixelSize: CGSize
    var padding: CGFloat = 12
    @ViewBuilder let overlay: (ImageMapper) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let mapper = Self.fit(pixelSize, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: padding, dy: padding))
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: mapper.rect.width, height: mapper.rect.height)
                    .offset(x: mapper.rect.minX, y: mapper.rect.minY)
                overlay(mapper)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    static func fit(_ size: CGSize, in bounds: CGRect) -> ImageMapper {
        let s = min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1))
        let w = size.width * s, h = size.height * s
        return ImageMapper(imageSize: size, rect: CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h))
    }
}

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

extension CGImage {
    var size: CGSize { CGSize(width: width, height: height) }

    /// Downscaled copy for fast previews.
    func preview(maxPixel: CGFloat) -> CGImage {
        let s = min(1, maxPixel / CGFloat(max(width, height)))
        guard s < 1, let ctx = ImageEngine.bitmap(width: Int(CGFloat(width) * s), height: Int(CGFloat(height) * s)) else { return self }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        return ctx.makeImage() ?? self
    }
}

/// A drawable mark in image pixel coordinates (top-left origin). Shared by Annotate and Redact.
enum Mark {
    case stroke([CGPoint], NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case box(CGRect, NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)
    case redact(CGRect)
}

enum MarkRenderer {
    /// Draws the image and its marks into a new flat bitmap. No layers survive.
    static func flatten(_ image: CGImage, marks: [Mark]) -> CGImage? {
        guard let ctx = ImageEngine.bitmap(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for m in marks { draw(m, in: ctx) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func draw(_ mark: Mark, in ctx: CGContext) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch mark {
        case let .stroke(points, color, width):
            guard let first = points.first else { return }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.beginPath()
            ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            if points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            ctx.strokePath()
        case let .arrow(a, b, color, width):
            ctx.setStrokeColor(color.cgColor)
            ctx.setFillColor(color.cgColor)
            ctx.setLineWidth(width)
            let angle = atan2(b.y - a.y, b.x - a.x)
            let head = max(width * 4, 12)
            let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
            ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
            ctx.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
            ctx.closePath(); ctx.fillPath()
        case let .box(rect, color, width):
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.stroke(rect)
        case let .text(string, point, color, size):
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
            (string as NSString).draw(at: point, withAttributes: attrs)
        case let .redact(rect):
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(rect.integral)
        }
    }
}

/// Draws marks in view space for live preview.
struct MarksOverlay: View {
    let marks: [Mark]
    let mapper: ImageMapper

    var body: some View {
        Canvas { ctx, _ in
            ctx.withCGContext { cg in
                cg.translateBy(x: mapper.rect.minX, y: mapper.rect.minY)
                cg.scaleBy(x: mapper.scale, y: mapper.scale)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                for m in marks { MarkRenderer.draw(m, in: cg) }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        .allowsHitTesting(false)
    }
}

/// Loads the source image for an editor, with a small preview copy.
struct LoadedImage {
    let url: URL
    let full: CGImage
    let preview: NSImage

    init(_ url: URL) throws {
        self.url = url
        full = try ImageEngine.load(url)
        preview = NSImage(cgImage: full.preview(maxPixel: 1400))
    }
}

/// Footer with Reset on the left and the primary action on the right.
struct EditorFooter: View {
    var resetTitle = "Reset"
    let primaryTitle: String
    var primaryEnabled = true
    var busy = false
    let onReset: (() -> Void)?
    let onPrimary: () -> Void

    var body: some View {
        HStack {
            if let onReset { Button(resetTitle, action: onReset).buttonStyle(SubtleButtonStyle()) }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(AccentButtonStyle(enabled: primaryEnabled && !busy))
                .disabled(!primaryEnabled || busy)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// Saves a rendered image next to the source off the main thread.
func saveEdited(_ image: CGImage, source: URL, suffix: String, format: ImageFormat? = nil) async throws -> URL {
    let fmt = format ?? ImageEngine.editOutputFormat(for: source)
    let quality = Settings.shared.quality
    return try await Task.detached(priority: .userInitiated) {
        let out = OutputPath.beside(source, suffix: suffix, ext: fmt.ext)
        try ImageEngine.write(image, to: out, format: fmt, quality: max(quality, 0.9))
        return out
    }.value
}
