import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import WheelCore
@testable import Wheel

final class CombineEngineTests: XCTestCase {
    private func listing(_ archive: URL, tool: String, args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args + [archive.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func testZipAndTarIncludeFilesAndFoldersWithoutClutter() async throws {
        let f = try Fixtures()
        let pdf = try f.pdf("Report.pdf", pages: 1)
        let img = try f.image("Photo.png")
        let folder = f.dir.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: folder.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)

        let zip = try await ArchiveEngine.archive([pdf, img, folder], name: "Bundle", format: .zip)
        XCTAssertEqual(zip.lastPathComponent, "Bundle.zip")
        let zl = try listing(zip, tool: "/usr/bin/unzip", args: ["-Z1"])
        XCTAssertTrue(zl.contains("Report.pdf") && zl.contains("Photo.png") && zl.contains("Assets/notes.txt"), zl)
        XCTAssertFalse(zl.contains(".DS_Store"), zl)

        let again = try await ArchiveEngine.archive([pdf, img], name: "Bundle", format: .zip)
        XCTAssertEqual(again.lastPathComponent, "Bundle 2.zip", "never overwrites")

        let tgz = try await ArchiveEngine.archive([pdf, folder], name: "../evil/Bundle", format: .tarGz, level: .best)
        XCTAssertEqual(tgz.deletingLastPathComponent().path, f.dir.path, "name can't escape the folder")
        let tl = try listing(tgz, tool: "/usr/bin/tar", args: ["-tzf"])
        XCTAssertTrue(tl.contains("Report.pdf") && tl.contains("Assets/notes.txt"), tl)
        XCTAssertFalse(tl.contains("._"), "no AppleDouble files")

        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path) && FileManager.default.fileExists(atPath: folder.path))
    }

    func testMissingArchiversFailClearly() async throws {
        try XCTSkipIf(ArchiveFormat.rar.unavailableReason == nil, "rar installed")
        let f = try Fixtures()
        do {
            _ = try await ArchiveEngine.archive([try f.image("a.png")], name: "x", format: .rar)
            XCTFail("should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("brew install"))
        }
    }

    func testCombineMixedFilesIntoPDF() async throws {
        let f = try Fixtures()
        let urls = [try f.pdf("A.pdf", pages: 2), try f.image("B.png", width: 1600, height: 900),
                    try f.text("C.txt", "Hello from a text file")]
        let original = try await CombineEngine.pdf(from: urls)
        XCTAssertEqual(original.pageCount, 4)
        XCTAssertTrue(original.page(at: 3)?.string?.contains("Hello from a text file") == true)

        let letter = try await CombineEngine.pdf(from: urls, pageSize: .letter)
        let imagePage = try XCTUnwrap(letter.page(at: 2)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(imagePage, CGSize(width: 792, height: 612), "wide image on a landscape Letter page")
    }

    func testStitchLayouts() throws {
        let f = try Fixtures()
        let a = try ImageEngine.load(try f.image("a.png", width: 400, height: 300))
        let b = try ImageEngine.load(try f.image("b.png", width: 200, height: 200))
        var o = CombineEngine.StitchOptions()
        o.spacing = 10
        XCTAssertEqual(CombineEngine.stitch([a, b], o)?.size, CGSize(width: 400, height: 300 + 10 + 400), "b scaled to width 400")
        o.layout = .horizontal
        XCTAssertEqual(CombineEngine.stitch([a, b], o)?.size, CGSize(width: 400 + 10 + 300, height: 300))
        o.layout = .grid; o.columns = 2
        XCTAssertEqual(CombineEngine.stitch([a, b, a], o)?.size, CGSize(width: 810, height: 610))
        o.layout = .vertical; o.matchSizes = false
        XCTAssertEqual(CombineEngine.stitch([a, b], o)?.size, CGSize(width: 400, height: 510))
    }

    func testAnimatedGIF() throws {
        let f = try Fixtures()
        let imgs = try ["1.png", "2.png", "3.png", "4.png"].map { try ImageEngine.load(try f.image($0, width: 1200, height: 800)) }
        var o = CombineEngine.GIFOptions()
        o.boomerang = true
        o.maxSize = 300
        let out = f.dir.appendingPathComponent("anim.gif")
        try CombineEngine.gif(imgs, o, to: out)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 6, "4 forward + 2 back")
        XCTAssertEqual(ImageEngine.pixelSize(out), CGSize(width: 300, height: 200))
    }

    func testJoinAudioClips() async throws {
        let f = try Fixtures()
        let a = f.dir.appendingPathComponent("a.wav"), b = f.dir.appendingPathComponent("b.wav")
        try ToneWriter.write(to: a); try ToneWriter.write(to: b)
        let out = try await CombineEngine.join([a, b], name: "Mix", progress: { _ in })
        XCTAssertEqual(out.lastPathComponent, "Mix.m4a")
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.15)
    }
}

final class CombineWheelTests: XCTestCase {
    func testCombineWheelOnlyForSeveralFilesAndMixedDragsOpenOnIt() {
        let r = ActionRegistry()
        r.register(CombineProvider())
        let pdf = URL(fileURLWithPath: "/x/A.pdf"), png = URL(fileURLWithPath: "/x/B.png"), png2 = URL(fileURLWithPath: "/x/C.png")
        let mp3 = URL(fileURLWithPath: "/x/D.mp3"), mp3b = URL(fileURLWithPath: "/x/E.mp3")

        XCTAssertTrue(r.slices(for: [pdf], mode: .combine).isEmpty, "one file: no Combine wheel")
        XCTAssertEqual(r.slices(for: [pdf, png], mode: .combine).map(\.action.title), ["To PDF", "Zip", "Archive"])
        XCTAssertEqual(r.slices(for: [png, png2], mode: .combine).map(\.action.title), ["To PDF", "Zip", "Archive", "Stitch", "GIF"])
        XCTAssertEqual(r.slices(for: [mp3, mp3b], mode: .combine).map(\.action.title), ["Zip", "Archive", "Join"])

        XCTAssertEqual(r.initialMode(for: [pdf, png]), .combine, "mixed files open on Combine")
        XCTAssertEqual(r.initialMode(for: [png, png2]), .convert, "same type opens on Convert (batch)")
        XCTAssertEqual(r.nextMode(after: .convert, for: [png, png2]), .combine, "skips Edit when nothing registered for it")
        XCTAssertEqual(r.nextMode(after: .combine, for: [png, png2]), .convert)
    }
}
