import PDFKit
import XCTest
@testable import WheelCore

final class PDFToolsTests: XCTestCase {
    private var f: Fixtures!
    private var src: URL!
    private var doc: PDFDocument!

    override func setUpWithError() throws {
        f = try Fixtures()
        src = try f.pdf("Doc.pdf", pages: 5)
        doc = try PDFTools.open(src)
    }

    private func text(_ d: PDFDocument, _ i: Int) -> String { d.page(at: i)?.string ?? "" }

    func testRangesParseAndLabel() {
        XCTAssertEqual(PDFTools.parseRanges("1-3, 5", pageCount: 9), [0, 1, 2, 4])
        XCTAssertEqual(PDFTools.parseRanges("8-", pageCount: 9), [7, 8])
        XCTAssertEqual(PDFTools.parseRanges("3-1", pageCount: 9), [2, 1, 0])
        XCTAssertEqual(PDFTools.parseRanges("0, 2, 2, 99", pageCount: 9), [1])
        XCTAssertEqual(PDFTools.rangeLabel([0, 1, 2, 4, 6, 7]), "1–3, 5, 7–8")
    }

    func testDeleteExtractReverseRotate() {
        let removed = PDFTools.pages(doc, removing: [0, 2])
        XCTAssertEqual(removed.pageCount, 3)
        XCTAssertTrue(text(removed, 0).contains("page 2"))

        let extracted = PDFTools.pages(doc, keeping: [4, 1])
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertTrue(text(extracted, 0).contains("page 5"))

        XCTAssertTrue(text(PDFTools.reversed(doc), 0).contains("page 5"))

        let rotated = PDFTools.rotated(doc, by: 90, pages: [1])
        XCTAssertEqual(rotated.page(at: 0)?.rotation, 0)
        XCTAssertEqual(rotated.page(at: 1)?.rotation, 90)
        XCTAssertEqual(PDFTools.rotated(doc, by: -90).page(at: 3)?.rotation, 270)
    }

    func testOrganizeWithBlankAndDuplicate() {
        let out = PDFTools.assemble(doc, [.init(source: 2), .init(source: nil), .init(source: 2, rotation: 180)])
        XCTAssertEqual(out.pageCount, 3)
        XCTAssertTrue(text(out, 0).contains("page 3"))
        XCTAssertEqual(text(out, 1).trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertEqual(out.page(at: 2)?.rotation, 180)
    }

    func testSplitAndMerge() throws {
        let parts = PDFTools.split(doc, every: 2)
        XCTAssertEqual(parts.map(\.range), [0...1, 2...3, 4...4])
        XCTAssertEqual(parts.map(\.doc.pageCount), [2, 2, 1])

        let other = try f.pdf("Other.pdf", pages: 2)
        let image = try f.image("Pic.png")
        let merged = try PDFTools.merge([src, other, image])
        XCTAssertEqual(merged.pageCount, 8)
        XCTAssertThrowsError(try PDFTools.merge([try f.text("a.txt", "x")]))
    }

    func testWatermarkAndPageNumbersAreBurnedIn() throws {
        var w = PDFTools.WatermarkOptions()
        w.text = "DRAFT COPY"
        let wURL = f.dir.appendingPathComponent("w.pdf")
        try PDFTools.restamp(doc, to: wURL) { ctx, rect, _, _ in PDFTools.drawWatermark(w, in: ctx, page: rect) }
        let wd = try XCTUnwrap(PDFDocument(url: wURL))
        XCTAssertEqual(wd.pageCount, 5)
        XCTAssertTrue(text(wd, 3).contains("DRAFT COPY"))
        XCTAssertTrue(text(wd, 3).contains("page 4"), "original text survives")

        var n = PDFTools.PageNumberOptions()
        n.format = .pageOf
        let nURL = f.dir.appendingPathComponent("n.pdf")
        try PDFTools.restamp(doc, to: nURL) { ctx, rect, i, c in PDFTools.drawPageNumber(n, in: ctx, page: rect, index: i, count: c) }
        XCTAssertTrue(text(try XCTUnwrap(PDFDocument(url: nURL)), 4).contains("Page 5 of 5"))
    }

    func testRestampKeepsRotatedPagesUpright() throws {
        let rotated = PDFTools.rotated(doc, by: 90)
        let out = f.dir.appendingPathComponent("r.pdf")
        try PDFTools.restamp(rotated, to: out) { _, _, _, _ in }
        let page = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 792, height: 612), "landscape after baking in rotation")
    }

    func testTwoUp() throws {
        let out = f.dir.appendingPathComponent("2up.pdf")
        try PDFTools.twoUp(doc, to: out)
        let d = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(d.pageCount, 3)
        let size = try XCTUnwrap(d.page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertGreaterThan(size.width, size.height)
    }

    func testProtectAndUnlock() throws {
        var o = PDFTools.ProtectOptions()
        o.openPassword = "s3cret"
        let locked = try PDFTools.protect(doc, source: src, o)
        XCTAssertEqual(locked.lastPathComponent, "Doc Protected.pdf")
        let check = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(check.isEncrypted && check.isLocked)
        XCTAssertTrue(PDFTools.needsPassword(locked))
        XCTAssertThrowsError(try PDFTools.open(locked))

        XCTAssertThrowsError(try PDFTools.unlock(locked, password: "nope"))
        let open = try PDFTools.unlock(locked, password: "s3cret")
        let opened = try XCTUnwrap(PDFDocument(url: open))
        XCTAssertFalse(opened.isEncrypted)
        XCTAssertEqual(opened.pageCount, 5)

        var restrictOnly = PDFTools.ProtectOptions()
        restrictOnly.allowCopying = false
        let restricted = try XCTUnwrap(PDFDocument(url: try PDFTools.protect(doc, source: src, restrictOnly)))
        XCTAssertTrue(restricted.isEncrypted)
        XCTAssertFalse(restricted.isLocked, "opens without a password")
        XCTAssertFalse(restricted.allowsCopying)

        XCTAssertThrowsError(try PDFTools.protect(doc, source: src, PDFTools.ProtectOptions()), "nothing to protect")
    }

    func testFlattenRemovesTextAndGrayscaleKeepsIt() throws {
        let flat = f.dir.appendingPathComponent("flat.pdf")
        try PDFTools.flatten(doc, to: flat, dpi: 72)
        let fd = try XCTUnwrap(PDFDocument(url: flat))
        XCTAssertEqual(fd.pageCount, 5)
        XCTAssertEqual(text(fd, 0).trimmingCharacters(in: .whitespacesAndNewlines), "")

        let gray = f.dir.appendingPathComponent("gray.pdf")
        try PDFTools.grayscale(doc, to: gray)
        XCTAssertTrue(text(try XCTUnwrap(PDFDocument(url: gray)), 0).contains("page 1"))
    }

    func testOCRMakesScansSearchable() throws {
        let scan = f.dir.appendingPathComponent("scan.pdf")
        try PDFTools.flatten(PDFTools.pages(doc, keeping: [0, 1]), to: scan, dpi: 200)
        let scanned = try XCTUnwrap(PDFDocument(url: scan))
        XCTAssertEqual(text(scanned, 0).trimmingCharacters(in: .whitespacesAndNewlines), "")

        let out = f.dir.appendingPathComponent("ocr.pdf")
        let pages = try PDFTools.makeSearchable(scanned, to: out)
        XCTAssertEqual(pages, 2)
        let searchable = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertTrue(text(searchable, 1).localizedCaseInsensitiveContains("page 2"), "got: \(text(searchable, 1))")
        XCTAssertFalse(searchable.findString("Hello", withOptions: .caseInsensitive).isEmpty)
    }

    func testTrimMarginsShrinksCropBox() throws {
        let trimmed = PDFTools.trimmed(doc, padding: 10)
        let crop = try XCTUnwrap(trimmed.page(at: 0)?.bounds(for: .cropBox))
        XCTAssertLessThan(crop.width, 400)
        XCTAssertLessThan(crop.height, 100)
        // The text sits at y≈700 in the fixture.
        XCTAssertGreaterThan(crop.minY, 650)
    }

    func testRemoveAnnotationsKeepsLinks() throws {
        let page = try XCTUnwrap(doc.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 50), forType: .square, withProperties: nil))
        let link = PDFAnnotation(bounds: CGRect(x: 100, y: 10, width: 50, height: 20), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)
        let clean = PDFTools.removingAnnotations(doc)
        XCTAssertEqual(clean.page(at: 0)?.annotations.map(\.type), ["Link"])
    }

    func testLockedFilesFailClearly() throws {
        var o = PDFTools.ProtectOptions()
        o.openPassword = "x"
        let locked = try PDFTools.protect(doc, source: src, o)
        XCTAssertThrowsError(try PDFTools.open(locked)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unlock"))
        }
    }
}
