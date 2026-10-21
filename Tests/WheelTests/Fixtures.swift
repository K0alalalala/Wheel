import AppKit
import ImageIO
import XCTest
@testable import WheelCore

/// Creates throwaway input files in a fresh temp folder.
final class Fixtures {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("WheelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func image(_ name: String, width: Int = 400, height: Int = 300, format: ImageFormat = .png,
               properties: [CFString: Any]? = nil) throws -> URL {
        let ctx = ImageEngine.bitmap(width: width, height: height)!
        ctx.setFillColor(NSColor.systemOrange.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let url = dir.appendingPathComponent(name)
        try ImageEngine.encode(ctx.makeImage()!, format: format, properties: properties).write(to: url)
        return url
    }

    func pdf(_ name: String, pages: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for i in 1...pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ("Hello page \(i)" as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    func text(_ name: String, _ contents: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func files() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
    }
}
