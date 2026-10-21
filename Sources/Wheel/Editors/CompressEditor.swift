import PDFKit
import WheelCore
import SwiftUI

struct CompressAction: FileAction {
    let id = "edit.compress", title = "Compress", symbol = "arrow.down.right.and.arrow.up.left", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { [.image, .pdf].contains(FileKind.of(url)) }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        try await EditorWindow.present(title: urls.count > 1 ? "Compress \(urls.count) Files" : "Compress",
                                       size: CGSize(width: 360, height: 330)) { finish in
            CompressEditor(urls: urls, finish: finish)
        }
    }
}

enum CompressEngine {
    struct ImageOptions: Equatable {
        var format: ImageFormat?   // nil keeps the source format where possible
        var quality: Double
        var maxPixel: Int?         // nil keeps the size
    }

    static func compressImage(_ url: URL, _ o: ImageOptions) throws -> Data {
        let image = try ImageEngine.load(url, maxPixel: o.maxPixel)
        return try ImageEngine.encode(image, format: format(for: url, o), quality: o.quality)
    }

    static func format(for url: URL, _ o: ImageOptions) -> ImageFormat {
        if let f = o.format { return f }
        if let f = ImageFormat.of(url), f.supportsQuality, f.writableByImageIO || f == .webp && ExternalTools.cwebp != nil { return f }
        return .jpg // PNG/TIFF/BMP have no quality knob; JPG is what "compress" usually means for them
    }

    /// Re-saves a PDF with images recompressed as JPEG and downsampled for screen.
    static func compressPDF(_ url: URL, to out: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw ActionError("Couldn't open \(url.lastPathComponent).") }
        let opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard doc.write(to: out, withOptions: opts) else { throw ActionError("Couldn't write compressed PDF.") }
    }
}

struct CompressEditor: View {
    let urls: [URL]
    let finish: EditorFinish

    @State private var format: ImageFormat? = nil
    @State private var quality: Double = 0.7
    @State private var maxPixel: Int? = nil
    @State private var estimate: Int?
    @State private var busy = false

    private var isPDF: Bool { FileKind.of(urls[0]) == .pdf }
    private var originalBytes: Int { urls.reduce(0) { $0 + (fileSize($1) ?? 0) } }
    private var options: CompressEngine.ImageOptions { .init(format: format, quality: quality, maxPixel: maxPixel) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isPDF {
                Text("Recompresses images inside the PDF as JPEG and downsamples them for screen. Text and vectors stay sharp.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Text("Format").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: [nil, .jpg, .heic, .avif, .webp], selection: $format) { $0?.title ?? "Same" }
                }
                LabeledSlider(title: "Quality", value: $quality, range: 0.1...1, unit: "%", format: { String(Int(($0 * 100).rounded())) })
                HStack {
                    Text("Max size").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: [nil, 4096, 2560, 1600, 1024], selection: $maxPixel) { $0.map { "\($0)" } ?? "Original" }
                }
            }

            HStack(spacing: 16) {
                sizeBlock("Before", originalBytes)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                sizeBlock(isPDF ? "After" : "Estimated", estimate)
                Spacer()
                if let estimate, originalBytes > 0 {
                    let pct = 100 - Double(estimate) * 100 / Double(originalBytes)
                    Text(pct >= 0 ? "−\(Int(pct))%" : "+\(Int(-pct))%")
                        .font(.system(size: 18, weight: .bold).monospacedDigit())
                        .foregroundStyle(pct >= 0 ? Theme.accent : .secondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))

            if let estimate, estimate >= originalBytes {
                Text("Already well compressed. Try a lower quality, a smaller max size, or HEIC/AVIF.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            EditorFooter(primaryTitle: urls.count > 1 ? "Compress \(urls.count) Files" : "Save Compressed", busy: busy, onReset: nil, onPrimary: save)
                .padding(.horizontal, -14)
        }
        .padding(.horizontal, 14)
        .task(id: options) { await updateEstimate() }
    }

    private func sizeBlock(_ title: String, _ bytes: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            Text(bytes.map(Self.format) ?? "…").font(.system(size: 14, weight: .semibold).monospacedDigit())
        }
    }

    static func format(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    private func fileSize(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// Estimates from the first file, scaled to the whole batch.
    private func updateEstimate() async {
        try? await Task.sleep(for: .milliseconds(200)) // debounce slider drags
        if Task.isCancelled { return }
        estimate = nil
        let url = urls[0], o = options, pdf = isPDF
        let bytes: Int? = await Task.detached(priority: .utility) {
            if pdf {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                guard (try? CompressEngine.compressPDF(url, to: tmp)) != nil else { return nil }
                return (try? tmp.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            }
            return try? CompressEngine.compressImage(url, o).count
        }.value
        guard !Task.isCancelled, let bytes else { return }
        let first = fileSize(url) ?? 1
        estimate = urls.count == 1 ? bytes : Int(Double(bytes) / Double(max(first, 1)) * Double(originalBytes))
    }

    private func save() {
        busy = true
        let urls = self.urls, o = options, pdf = isPDF
        Task {
            do {
                let outs = try await Task.detached(priority: .userInitiated) {
                    try urls.map { url -> URL in
                        try Task.checkCancellation()
                        if pdf {
                            let out = OutputPath.beside(url, suffix: "Compressed", ext: "pdf")
                            try CompressEngine.compressPDF(url, to: out)
                            return out
                        }
                        let fmt = CompressEngine.format(for: url, o)
                        let out = OutputPath.beside(url, suffix: "Compressed", ext: fmt.ext)
                        try CompressEngine.compressImage(url, o).write(to: out, options: .withoutOverwriting)
                        return out
                    }
                }.value
                finish(.success(outs))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
