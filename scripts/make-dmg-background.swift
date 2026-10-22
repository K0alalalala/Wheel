// Draws the installer window background: Resources/dmg-background.tiff (1x + 2x in one file).
// Usage: swift scripts/make-dmg-background.swift
// Layout must match make-dmg.sh: window 660×440, app icon at (170, 205), Applications at (490, 205).
import AppKit

let size = NSSize(width: 660, height: 440)
let orange = NSColor(srgbRed: 1, green: 0.353, blue: 0.122, alpha: 1)
let ink = NSColor(srgbRed: 0.13, green: 0.11, blue: 0.16, alpha: 1)

func draw(_ r: NSRect) {
    // Warm paper base so Finder's black icon labels stay readable.
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.985, blue: 0.965, alpha: 1),
                        NSColor(srgbRed: 1, green: 0.94, blue: 0.91, alpha: 1)])!.draw(in: r, angle: -90)

    // Soft brand glows in the corners.
    func glow(_ c: NSColor, _ center: NSPoint, _ radius: CGFloat) {
        NSGradient(colors: [c, c.withAlphaComponent(0)])!.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
    glow(NSColor(srgbRed: 1, green: 0.62, blue: 0.35, alpha: 0.35), NSPoint(x: 40, y: 440), 300)
    glow(NSColor(srgbRed: 0.6, green: 0.42, blue: 0.95, alpha: 0.22), NSPoint(x: 660, y: 0), 320)

    // A faint wheel watermark peeking in from the top right.
    let c = NSPoint(x: 600, y: 420)
    for (i, radius) in [CGFloat(150), 118].enumerated() {
        let ring = NSBezierPath()
        ring.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
        ring.lineWidth = i == 0 ? 22 : 2
        orange.withAlphaComponent(i == 0 ? 0.07 : 0.12).setStroke()
        ring.stroke()
    }
    for k in 0..<8 {
        let a = CGFloat(k) * .pi / 4 + .pi / 8
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + cos(a) * 70, y: c.y + sin(a) * 70))
        p.line(to: NSPoint(x: c.x + cos(a) * 160, y: c.y + sin(a) * 160))
        p.lineWidth = 3
        NSColor.white.withAlphaComponent(0.6).setStroke()
        p.stroke()
    }

    // Title and instruction.
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    func text(_ s: String, _ y: CGFloat, _ font: NSFont, _ color: NSColor, kern: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center, .kern: kern]
        (s as NSString).draw(in: NSRect(x: 0, y: y, width: size.width, height: font.pointSize * 1.5), withAttributes: attrs)
    }
    text("Wheel", 368, NSFont.systemFont(ofSize: 30, weight: .bold), ink, kern: -0.5)
    text("Drag Wheel into Applications to install", 344, NSFont.systemFont(ofSize: 14, weight: .medium), ink.withAlphaComponent(0.6))

    // Arrow from the app slot to Applications: a gentle arc with a rounded head.
    let from = NSPoint(x: 250, y: 238), to = NSPoint(x: 412, y: 238)
    let arc = NSBezierPath()
    arc.move(to: from)
    arc.curve(to: to, controlPoint1: NSPoint(x: 300, y: 278), controlPoint2: NSPoint(x: 362, y: 278))
    arc.lineWidth = 5
    arc.lineCapStyle = .round
    arc.setLineDash([0.1, 12], count: 2, phase: 0)
    orange.setStroke()
    arc.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: to.x - 16, y: to.y + 12))
    head.line(to: NSPoint(x: to.x + 3, y: to.y - 2))
    head.line(to: NSPoint(x: to.x - 18, y: to.y - 8))
    head.lineWidth = 5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    // Three little promises along the bottom.
    let chips = ["Free & open source", "Nothing leaves your Mac", "Apple Silicon + Intel"]
    let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    let widths = chips.map { ($0 as NSString).size(withAttributes: [.font: font]).width + 26 }
    var x = (size.width - widths.reduce(0, +) - CGFloat(chips.count - 1) * 10) / 2
    for (chip, w) in zip(chips, widths) {
        let rect = NSRect(x: x, y: 64, width: w, height: 24)
        NSColor.white.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        orange.withAlphaComponent(0.35).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 11.5, yRadius: 11.5)
        border.lineWidth = 1
        border.stroke()
        (chip as NSString).draw(at: NSPoint(x: rect.minX + 13, y: rect.minY + 4.5),
                                withAttributes: [.font: font, .foregroundColor: ink.withAlphaComponent(0.75)])
        x += w + 10
    }

    // The one thing people get stuck on.
    text("First launch: System Settings → Privacy & Security → Open Anyway", 30,
         NSFont.systemFont(ofSize: 11), ink.withAlphaComponent(0.45))
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size // points: Finder uses this to pick the right representation
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Resources/dmg-background.tiff")
let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)], using: .lzw, factor: 0)!
try! data.write(to: out)
try! render(scale: 2).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "dmg-background-preview.png"))
print("Wrote Resources/dmg-background.tiff")
