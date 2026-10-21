// Renders Resources/AppIcon.icns: a glass wheel of slices on an orange squircle.
// Usage: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background (Apple's grid: 824/1024 body, centred)
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill(); bg.fill()
    ctx.restoreGState()
    bg.addClip()
    NSGradient(colors: [NSColor(srgbRed: 1, green: 0.70, blue: 0.28, alpha: 1),
                        NSColor(srgbRed: 1, green: 0.353, blue: 0.122, alpha: 1),
                        NSColor(srgbRed: 0.84, green: 0.20, blue: 0.42, alpha: 1)])!.draw(in: body, angle: -60)

    // Wheel: 6 rounded wedges around a hub; the top-right wedge is "hovered".
    let c = CGPoint(x: body.midX, y: body.midY)
    let outer = body.width * 0.36, inner = body.width * 0.17, gap = body.width * 0.022, corner = body.width * 0.03
    let disc = NSBezierPath(ovalIn: CGRect(x: c.x - outer - gap * 2, y: c.y - outer - gap * 2, width: (outer + gap * 2) * 2, height: (outer + gap * 2) * 2))
    NSColor.white.withAlphaComponent(0.22).setFill(); disc.fill()
    NSColor.white.withAlphaComponent(0.55).setStroke(); disc.lineWidth = s * 0.004; disc.stroke()

    let n = 6
    for i in 0..<n {
        let span = 2 * CGFloat.pi / CGFloat(n)
        let mid = CGFloat.pi / 2 - span * CGFloat(i)
        let path = CGMutablePath()
        let rIn = inner + corner, rOut = outer - corner, d = gap / 2 + corner
        let o0 = mid + span / 2 - asin(d / rOut), o1 = mid - span / 2 + asin(d / rOut)
        let i0 = mid + span / 2 - asin(d / rIn), i1 = mid - span / 2 + asin(d / rIn)
        path.addArc(center: c, radius: rOut, startAngle: o0, endAngle: o1, clockwise: true)
        path.addArc(center: c, radius: rIn, startAngle: i1, endAngle: i0, clockwise: false)
        path.closeSubpath()
        let rounded = path.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        ctx.addPath(path); ctx.addPath(rounded)
        let hot = i == 1
        ctx.setFillColor(hot ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.62).cgColor)
        ctx.fillPath(using: .winding)
    }
    // Hub
    let hub = NSBezierPath(ovalIn: CGRect(x: c.x - inner + gap, y: c.y - inner + gap, width: (inner - gap) * 2, height: (inner - gap) * 2))
    NSColor.white.withAlphaComponent(0.85).setFill(); hub.fill()
    let dot = NSBezierPath(ovalIn: CGRect(x: c.x - inner * 0.32, y: c.y - inner * 0.32, width: inner * 0.64, height: inner * 0.64))
    NSColor(srgbRed: 1, green: 0.353, blue: 0.122, alpha: 1).setFill(); dot.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try! render(512).write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
