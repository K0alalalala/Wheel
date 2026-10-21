import AppKit
import ImageIO
import XCTest
@testable import Wheel
@testable import WheelCore

final class EditTests: XCTestCase {
    func testCropUsesTopLeftPixels() throws {
        let f = try Fixtures()
        let img = try ImageEngine.load(try f.image("A.png", width: 400, height: 300))
        let cropped = try XCTUnwrap(ImageEngine.crop(img, to: CGRect(x: 10, y: 20, width: 100, height: 50)))
        XCTAssertEqual(cropped.size, CGSize(width: 100, height: 50))
    }

    func testBackgroundCanvasHonoursPaddingAndRatio() throws {
        let f = try Fixtures()
        let img = try ImageEngine.load(try f.image("A.png", width: 400, height: 300))
        var o = BackgroundOptions()
        o.padding = 50
        XCTAssertEqual(BackgroundRenderer.render(img, o)?.size, CGSize(width: 500, height: 400))
        o.aspect = .square
        XCTAssertEqual(BackgroundRenderer.render(img, o)?.size, CGSize(width: 500, height: 500))
        o.aspect = .wide
        let wide = try XCTUnwrap(BackgroundRenderer.render(img, o))
        XCTAssertEqual(Double(wide.width) / Double(wide.height), 16.0 / 9.0, accuracy: 0.01)
    }

    func testRedactionDestroysPixels() throws {
        let f = try Fixtures()
        let img = try ImageEngine.load(try f.image("A.png", width: 100, height: 100))
        let out = try XCTUnwrap(MarkRenderer.flatten(img, marks: [.redact(CGRect(x: 0, y: 0, width: 50, height: 50))]))
        // Top-left quadrant is black, bottom-right untouched.
        XCTAssertEqual(pixel(out, 10, 10), [0, 0, 0])
        XCTAssertNotEqual(pixel(out, 90, 90), [0, 0, 0])
    }

    func testAdjustRotatesAndKeepsSize() throws {
        let f = try Fixtures()
        let img = try ImageEngine.load(try f.image("A.png", width: 400, height: 300))
        var a = Adjustments()
        a.quarterTurns = 1
        XCTAssertEqual(a.apply(to: img)?.size, CGSize(width: 300, height: 400))
    }

    func testMetadataStripRemovesGPSAndKeepsOrientation() throws {
        let f = try Fixtures()
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera Co", kCGImagePropertyTIFFOrientation: 6],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:01:01 10:00:00"],
        ]
        let src = try f.image("Photo.jpg", format: .jpg, properties: props)
        XCTAssertTrue(MetadataEngine.hasPrivateMetadata(src))
        let out = try MetadataEngine.strip(src)
        XCTAssertEqual(out.lastPathComponent, "Photo No Metadata.jpg")
        XCTAssertFalse(MetadataEngine.hasPrivateMetadata(out))
        XCTAssertEqual(ImageEngine.pixelSize(out), ImageEngine.pixelSize(src), "orientation preserved")
    }

    func testCompressShrinksAndRenames() throws {
        let f = try Fixtures()
        let src = try f.image("Big.png", width: 1600, height: 1200)
        let data = try CompressEngine.compressImage(src, .init(format: nil, quality: 0.5, maxPixel: 800))
        XCTAssertEqual(CompressEngine.format(for: src, .init(format: nil, quality: 0.5, maxPixel: nil)), .jpg)
        let tmp = f.dir.appendingPathComponent("out.jpg")
        try data.write(to: tmp)
        XCTAssertEqual(ImageEngine.pixelSize(tmp), CGSize(width: 800, height: 600))
    }

    func testWheelHitTesting() {
        let g = WheelGeometry()
        let c = CGPoint(x: 150, y: 150)
        XCTAssertEqual(g.hit(c, center: c, count: 4), .hub)
        XCTAssertEqual(g.hit(CGPoint(x: 150, y: 50), center: c, count: 4), .slice(0))   // top
        XCTAssertEqual(g.hit(CGPoint(x: 250, y: 150), center: c, count: 4), .slice(1))  // right
        XCTAssertEqual(g.hit(CGPoint(x: 150, y: 250), center: c, count: 4), .slice(2))  // bottom
        XCTAssertEqual(g.hit(CGPoint(x: 50, y: 150), center: c, count: 4), .slice(3))   // left
        XCTAssertEqual(g.hit(CGPoint(x: 0, y: 0), center: c, count: 4), WheelGeometry.Hit.none)
    }

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let ctx = ImageEngine.bitmap(width: img.width, height: img.height)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * ctx.bytesPerRow + x * 4 // bitmap memory is top-down
        return [p[i], p[i + 1], p[i + 2]]
    }
}

final class StyleTests: XCTestCase {
    func testThemeRoundTripsAndToleratesJunk() throws {
        var s = StylePreset.neon.style
        s.size = 1.3
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(WheelStyle.self, from: data), s)

        // Unknown keys ignored, missing keys default, out-of-range values clamped.
        let junk = #"{"size": 99, "maxSlices": 1, "accent": "custom", "futureKey": true}"#
        let d = try JSONDecoder().decode(WheelStyle.self, from: Data(junk.utf8))
        XCTAssertEqual(d.size, 1.8)
        XCTAssertEqual(d.maxSlices, 3)
        XCTAssertEqual(d.accent, .custom)
        XCTAssertEqual(d.roundness, WheelStyle().roundness)
    }

    func testGeometryScalesAndRotates() {
        var s = WheelStyle()
        s.size = 1.5
        s.rotation = 90
        let g = WheelGeometry(style: s)
        XCTAssertEqual(g.outer, 195, accuracy: 0.01)
        let c = CGPoint(x: 300, y: 300)
        // With a 90° rotation, slice 0 sits at 3 o'clock.
        XCTAssertEqual(g.hit(CGPoint(x: 300 + 150, y: 300), center: c, count: 4), .slice(0))
        XCTAssertEqual(g.hit(CGPoint(x: 300, y: 300 - 150), center: c, count: 4), .slice(3))
    }

    func testExtremeShapesStillDrawEveryWedge() {
        var s = WheelStyle()
        s.roundness = 40; s.sliceGap = 16; s.hubRatio = 0.6; s.size = 0.6
        let g = WheelGeometry(style: s)
        for count in [3, 8, 10] {
            for i in 0..<count {
                let path = WedgeShape(index: i, count: count, geo: g).path(in: CGRect(x: 0, y: 0, width: g.diameter, height: g.diameter))
                XCTAssertFalse(path.isEmpty, "slice \(i)/\(count) vanished")
            }
        }
    }
}

final class CreditsTests: XCTestCase {
    func testCreditsGiveTheHumanTopBilling() {
        XCTAssertEqual(Credits.human, "K0alalalala")
        XCTAssertEqual(Credits.roles.first?.who, Credits.human)
        XCTAssertTrue(Credits.roles.contains { $0.who.hasPrefix("Claude") })
    }
}
