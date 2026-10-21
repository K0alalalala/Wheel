import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import WheelCore

final class OutputPathTests: XCTestCase {
    func testNamesFollowTheSourceAndNeverOverwrite() throws {
        let f = try Fixtures()
        let src = try f.pdf("Page 001.pdf", pages: 1)
        XCTAssertEqual(OutputPath.beside(src, ext: "jpg").lastPathComponent, "Page 001.jpg")
        XCTAssertEqual(OutputPath.beside(src, suffix: "Cropped", ext: "jpg").lastPathComponent, "Page 001 Cropped.jpg")

        try Data().write(to: f.dir.appendingPathComponent("Page 001.jpg"))
        try Data().write(to: f.dir.appendingPathComponent("Page 001 2.jpg"))
        XCTAssertEqual(OutputPath.beside(src, ext: "jpg").lastPathComponent, "Page 001 3.jpg")
    }
}

final class RegistryTests: XCTestCase {
    func testSlicesAdaptToFileTypeAndSkipTheSourceFormat() {
        let r = ActionRegistry()
        let jpg = r.slices(for: [URL(fileURLWithPath: "/x/a.jpeg")], mode: .convert).map(\.action.title)
        XCTAssertEqual(jpg, ["PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF"])
        let pdf = r.slices(for: [URL(fileURLWithPath: "/x/a.pdf")], mode: .convert).map(\.action.title)
        XCTAssertEqual(pdf, ["JPG", "PNG", "TIFF", "TXT", "DOCX", "RTF"])
        XCTAssertTrue(r.slices(for: [URL(fileURLWithPath: "/x/a.zip")], mode: .convert).isEmpty)
    }

    func testPreferencesHideReorderAndCap() {
        let saved = Preferences.current
        defer { Preferences.current = saved }
        var p = Preferences()
        p.sliceOrder = ["convert.image": ["convert.image.pdf", "convert.image.heic"]]
        p.hiddenActions = ["convert.image.bmp"]
        Preferences.current = { p }
        let titles = ActionRegistry().slices(for: [URL(fileURLWithPath: "/x/a.png")], mode: .convert).map(\.action.title)
        XCTAssertEqual(titles, ["PDF", "HEIC", "JPG", "WEBP", "TIFF", "AVIF"])
        p.maxSlices = 3
        Preferences.current = { p }
        XCTAssertEqual(ActionRegistry().slices(for: [URL(fileURLWithPath: "/x/a.png")], mode: .convert).count, 3)
    }

    func testProvidersPlugIn() {
        struct Fake: FileAction {
            let id = "fake", title = "Fake", symbol = "star", mode = WheelMode.edit
            func supports(_ url: URL) -> Bool { true }
            func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] { [] }
        }
        struct P: ActionProvider {
            func actions(for kind: FileKind, mode: WheelMode) -> [FileAction] { mode == .edit ? [Fake()] : [] }
        }
        let r = ActionRegistry()
        XCTAssertTrue(r.slices(for: [URL(fileURLWithPath: "/a.png")], mode: .edit).isEmpty)
        r.register(P())
        XCTAssertEqual(r.slices(for: [URL(fileURLWithPath: "/a.png")], mode: .edit).map(\.id), ["fake"])
    }
}

final class ConversionTests: XCTestCase {
    private func convert(_ src: URL, to target: String) async throws -> [URL] {
        try await ConvertAction(target: target, kind: FileKind.of(src)).run([src], progress: { _ in })
    }

    func testImageConversions() async throws {
        let f = try Fixtures()
        let src = try f.image("Photo.png")
        for target in ["jpg", "heic", "tiff", "bmp", "avif"] {
            let out = try await convert(src, to: target)
            XCTAssertEqual(out.first?.lastPathComponent, "Photo.\(target)")
            XCTAssertEqual(ImageEngine.pixelSize(out[0]), CGSize(width: 400, height: 300), target)
        }
        let pdf = try await convert(src, to: "pdf")
        XCTAssertEqual(PDFDocument(url: pdf[0])?.pageCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "source must be untouched")
    }

    func testWebPWhenBackendPresent() async throws {
        try XCTSkipIf(ConvertAction(target: "webp", kind: .image).unavailableReason != nil, "no WebP encoder installed")
        let f = try Fixtures()
        let out = try await convert(try f.image("A.png"), to: "webp")
        XCTAssertNotNil(ImageEngine.pixelSize(out[0]))
    }

    func testSinglePagePDFToJPG() async throws {
        let f = try Fixtures()
        let out = try await convert(try f.pdf("Page 001.pdf", pages: 1), to: "jpg")
        XCTAssertEqual(out.map(\.lastPathComponent), ["Page 001.jpg"])
        XCTAssertEqual(ImageEngine.pixelSize(out[0]), CGSize(width: 2550, height: 3300)) // Letter at 300 dpi
    }

    func testMultiPagePDFToFolderAndTIFF() async throws {
        let f = try Fixtures()
        let src = try f.pdf("Doc.pdf", pages: 3)
        let folder = try await convert(src, to: "png")
        XCTAssertEqual(folder.first?.lastPathComponent, "Doc PNG")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder[0].path).sorted(),
                       ["Doc 001.png", "Doc 002.png", "Doc 003.png"])
        let tiff = try await convert(src, to: "tiff")
        let source = CGImageSourceCreateWithURL(tiff[0] as CFURL, nil)!
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
    }

    func testPDFToTextAndDocx() async throws {
        let f = try Fixtures()
        let src = try f.pdf("Doc.pdf", pages: 2)
        let txt = try await convert(src, to: "txt")
        let s = try String(contentsOf: txt[0], encoding: .utf8)
        XCTAssertTrue(s.contains("Hello page 1") && s.contains("Hello page 2"))
        let docx = try await convert(src, to: "docx")
        let back = try NSAttributedString(url: docx[0], options: [:], documentAttributes: nil)
        XCTAssertTrue(back.string.contains("Hello page 2"))
    }

    @MainActor
    func testDocumentConversions() async throws {
        let f = try Fixtures()
        let src = try f.text("Notes.txt", "First line\nSecond line")
        let docx = try await convert(src, to: "docx")
        let pdf = try await convert(docx[0], to: "pdf")
        XCTAssertEqual(pdf[0].lastPathComponent, "Notes.pdf")
        XCTAssertTrue(PDFDocument(url: pdf[0])?.string?.contains("Second line") == true)
        let html = try await convert(src, to: "html")
        XCTAssertTrue(try String(contentsOf: html[0], encoding: .utf8).contains("Second line"))

        let long = try f.text("Long.txt", String(repeating: "Lorem ipsum dolor sit amet. ", count: 2000))
        let longPDF = try await convert(long, to: "pdf")
        XCTAssertGreaterThan(PDFDocument(url: longPDF[0])!.pageCount, 1, "text should paginate")
    }

    func testMissingBackendFailsClearly() async throws {
        try XCTSkipIf(ExternalTools.ffmpeg != nil, "ffmpeg installed")
        let action = ConvertAction(target: "mp3", kind: .audio)
        XCTAssertEqual(action.unavailableReason, "brew install ffmpeg")
    }

    func testAudioViaAfconvert() async throws {
        let f = try Fixtures()
        // Generate a short AIFF with afconvert's sibling tool isn't available; write raw PCM via AVFoundation instead.
        let url = f.dir.appendingPathComponent("Tone.wav")
        try ToneWriter.write(to: url)
        let out = try await convert(url, to: "aiff")
        XCTAssertEqual(out[0].lastPathComponent, "Tone.aiff")
        let m4a = try await convert(url, to: "m4a")
        XCTAssertGreaterThan(try m4a[0].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }
}
