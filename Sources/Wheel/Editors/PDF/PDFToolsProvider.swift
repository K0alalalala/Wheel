import Foundation
import PDFKit
import WheelCore

/// The PDF Edit wheel. Registered first, so these lead the wheel; Compress and Metadata follow.
/// The first eight show by default; "All Tools" opens a launcher with every one of them.
struct PDFToolsProvider: ActionProvider {
    static let tools: [FileAction] = [
        PDFLauncherAction(),
        PageGridAction(mode: .organize),
        PDFMergeAction(),
        PDFSplitAction(),
        PDFProtectAction(),
        PDFBatchAction.ocr,
        PDFWatermarkAction(),
        PageGridAction(mode: .extract),
        PageGridAction(mode: .delete),
        PDFPageNumbersAction(),
        PDFBatchAction.rotate,
        PDFUnlockAction(),
        PDFBatchAction.flatten,
        PDFBatchAction.grayscale,
        PDFBatchAction.trim,
        PDFBatchAction.reverse,
        PDFBatchAction.clean,
        PDFBatchAction.twoUp,
    ]

    func actions(for kind: FileKind, mode: WheelMode) -> [FileAction] {
        mode == .edit && kind == .pdf ? Self.tools : []
    }
}

/// Runs PDF work off the main thread and reports progress back on it.
func pdfWork<T>(_ progress: @escaping ProgressHandler, _ body: @escaping (@escaping (Double) -> Void) throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try body { p in Task { @MainActor in progress(p) } }
    }.value
}

/// A one-shot PDF tool: open, transform, save beside the source. No options.
struct PDFBatchAction: FileAction {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let work: (PDFDocument, URL, @escaping (Double) -> Void) throws -> URL
    var mode: WheelMode { .edit }

    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let src = urls[0], work = self.work
        return [try await pdfWork(progress) { report in try work(try PDFTools.open(src), src, report) }]
    }

    /// For tools that draw a new file directly: picks the name, cleans up on failure.
    static func writing(_ src: URL, suffix: String, _ body: (URL) throws -> Void) throws -> URL {
        let out = OutputPath.beside(src, suffix: suffix, ext: "pdf")
        do { try body(out) } catch { try? FileManager.default.removeItem(at: out); throw error }
        return out
    }

    static let rotate = PDFBatchAction(id: "pdf.rotate", title: "Rotate", symbol: "rotate.right",
                                       summary: "Turn every page 90° clockwise. Use Organize to rotate single pages.") { doc, src, _ in
        try PDFTools.saveBeside(PDFTools.rotated(doc, by: 90), source: src, suffix: "Rotated")
    }

    static let reverse = PDFBatchAction(id: "pdf.reverse", title: "Reverse", symbol: "arrow.up.arrow.down",
                                        summary: "Put the pages in reverse order, e.g. for back-to-front scans.") { doc, src, _ in
        try PDFTools.saveBeside(PDFTools.reversed(doc), source: src, suffix: "Reversed")
    }

    static let ocr = PDFBatchAction(id: "pdf.ocr", title: "OCR", symbol: "text.viewfinder",
                                    summary: "Make scanned pages searchable and selectable. Runs on this Mac, nothing is uploaded.") { doc, src, report in
        try writing(src, suffix: "Searchable") { out in
            if try PDFTools.makeSearchable(doc, to: out, progress: report) == 0 {
                throw ActionError("No scanned pages found. The PDF already has text, or the pages contain no readable text.")
            }
        }
    }

    static let flatten = PDFBatchAction(id: "pdf.flatten", title: "Flatten", symbol: "square.3.layers.3d.down.right",
                                        summary: "Turn pages into images: removes hidden text, layers, forms and comments.") { doc, src, report in
        try writing(src, suffix: "Flattened") { try PDFTools.flatten(doc, to: $0, dpi: CGFloat(Preferences.current().pdfDPI), progress: report) }
    }

    static let grayscale = PDFBatchAction(id: "pdf.grayscale", title: "Grayscale", symbol: "circle.lefthalf.filled",
                                          summary: "Convert to black and white for printing. Text stays sharp and selectable.") { doc, src, _ in
        try writing(src, suffix: "Grayscale") { try PDFTools.grayscale(doc, to: $0) }
    }

    static let trim = PDFBatchAction(id: "pdf.trim", title: "Trim", symbol: "crop",
                                     summary: "Crop away empty margins around the content of every page.") { doc, src, _ in
        try PDFTools.saveBeside(PDFTools.trimmed(doc), source: src, suffix: "Trimmed")
    }

    static let clean = PDFBatchAction(id: "pdf.clean", title: "Clean", symbol: "eraser",
                                      summary: "Remove comments, highlights, stamps and other annotations. Links stay.") { doc, src, _ in
        try PDFTools.saveBeside(PDFTools.removingAnnotations(doc), source: src, suffix: "Clean")
    }

    static let twoUp = PDFBatchAction(id: "pdf.twoup", title: "2-Up", symbol: "rectangle.split.2x1",
                                      summary: "Two pages side by side per sheet, to print handouts with half the paper.") { doc, src, _ in
        try writing(src, suffix: "2-Up") { try PDFTools.twoUp(doc, to: $0) }
    }
}

/// Joins every dropped PDF (and image) into one file, in name order.
struct PDFMergeAction: FileAction {
    let id = "pdf.merge", title = "Merge", symbol = "doc.on.doc", mode = WheelMode.edit
    var combinesFiles: Bool { true }
    var summary: String { "Join all the dropped PDFs and images into one PDF, sorted by name." }
    func supports(_ url: URL) -> Bool { [.pdf, .image].contains(FileKind.of(url)) }

    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        guard urls.count > 1 else { throw ActionError("Drag two or more files to merge them.") }
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return [try await pdfWork(progress) { _ in
            try PDFTools.saveBeside(try PDFTools.merge(sorted), source: sorted[0], suffix: "Merged")
        }]
    }
}
