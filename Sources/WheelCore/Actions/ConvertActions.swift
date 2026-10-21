import AppKit
import PDFKit

/// A single "convert to X" slice. Which converter runs depends on the input's kind.
public struct ConvertAction: FileAction {
    public let target: String      // lowercase extension, e.g. "jpg"
    public let kind: FileKind

    public var id: String { "convert.\(kind.rawValue).\(target)" }
    public var title: String { target.uppercased() }
    public var mode: WheelMode { .convert }

    public var symbol: String {
        switch target {
        case "pdf": return "doc.richtext"
        case "txt": return "text.alignleft"
        case "docx", "rtf": return "doc.text"
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "mp4", "mov", "webm": return "film"
        case "gif": return "photo.stack"
        case "m4a", "mp3", "wav", "aiff", "flac": return "waveform"
        default: return "photo"
        }
    }

    /// Slice order per kind. Fixed so the same format is always in the same place.
    public static let targets: [FileKind: [String]] = [
        .image: ["png", "jpg", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
        .pdf: ["jpg", "png", "tiff", "txt", "docx", "rtf"],
        .document: ["pdf", "docx", "txt", "rtf", "html"],
        .video: ["mp4", "mov", "gif", "webm", "m4a", "mp3"],
        .audio: ["m4a", "mp3", "wav", "aiff", "flac"],
    ]

    public func supports(_ url: URL) -> Bool {
        FileKind.of(url) == kind && normalizedExt(url) != target
    }

    private func normalizedExt(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        case "htm": return "html"
        case "aif": return "aiff"
        case let e: return e
        }
    }

    public var unavailableReason: String? {
        if let f = ImageFormat(rawValue: target), kind == .image || kind == .pdf {
            if f == .webp && !f.writableByImageIO && ExternalTools.cwebp == nil && ExternalTools.ffmpeg == nil { return "brew install webp" }
            if f != .webp && !f.writableByImageIO { return "Not supported on this Mac" }
        }
        if let m = MediaFormat(rawValue: target), kind == .audio || kind == .video {
            let native = m.isNative && !(kind == .video && (m == .wav || m == .aiff))
            if !native && ExternalTools.ffmpeg == nil { return "brew install ffmpeg" }
        }
        return nil
    }

    public func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        guard let src = urls.first else { return [] }
        switch FileKind.of(src) {
        case .image: return try await convertImage(src, progress: progress)
        case .pdf: return try await convertPDF(src, progress: progress)
        case .document: return try await convertDocument(src)
        case .audio, .video:
            guard let f = MediaFormat(rawValue: target) else { throw ActionError("Unknown format \(title).") }
            let out = OutputPath.beside(src, ext: target)
            do {
                try await MediaEngine.convert(src, to: f, out: out, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: out) // don't leave half-written files
                throw error
            }
            return [out]
        case .other:
            throw ActionError("Wheel doesn't know how to convert \(src.lastPathComponent).")
        }
    }

    private func convertImage(_ src: URL, progress: @escaping ProgressHandler) async throws -> [URL] {
        let quality = Preferences.current().quality
        let target = self.target
        return try await Task.detached(priority: .userInitiated) {
            let image = try ImageEngine.load(src)
            try Task.checkCancellation()
            if target == "pdf" {
                let out = OutputPath.beside(src, ext: "pdf")
                try ImageEngine.writePDF([image], to: out)
                return [out]
            }
            guard let format = ImageFormat(rawValue: target) else { throw ActionError("Unknown format.") }
            let out = OutputPath.beside(src, ext: format.ext)
            try ImageEngine.write(image, to: out, format: format, quality: quality)
            return [out]
        }.value
    }

    private func convertPDF(_ src: URL, progress: @escaping ProgressHandler) async throws -> [URL] {
        let target = self.target
        if ["txt", "docx", "rtf"].contains(target) {
            let out = OutputPath.beside(src, ext: target)
            if target == "txt" {
                try PDFEngine.text(of: src).write(to: out, atomically: true, encoding: .utf8)
            } else {
                let text = try PDFEngine.attributedText(of: src)
                try DocumentEngine.write(text, as: DocFormat(rawValue: target)!, to: out)
            }
            return [out]
        }
        guard let format = ImageFormat(rawValue: target) else { throw ActionError("Unknown format.") }
        let quality = Preferences.current().quality
        let allPages = Preferences.current().pdfAllPages
        let dpi = CGFloat(Preferences.current().pdfDPI)

        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else { throw ActionError("Couldn't open \(src.lastPathComponent).") }
        let count = allPages ? doc.pageCount : 1

        if count == 1 {
            let out = OutputPath.beside(src, ext: format.ext)
            let image = try PDFEngine.render(page: doc.page(at: 0)!, dpi: dpi)
            try ImageEngine.write(image, to: out, format: format, quality: quality)
            return [out]
        }

        // Several pages: a multipage TIFF, or a folder of numbered images.
        if format == .tiff {
            let out = OutputPath.beside(src, ext: "tiff")
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.utType.identifier as CFString, count, nil) else {
                throw ActionError("Couldn't create TIFF.")
            }
            for i in 0..<count {
                try Task.checkCancellation()
                CGImageDestinationAddImage(dest, try PDFEngine.render(page: doc.page(at: i)!, dpi: dpi), nil)
                await progress(Double(i + 1) / Double(count))
                await Task.yield()
            }
            guard CGImageDestinationFinalize(dest) else { throw ActionError("Couldn't write TIFF.") }
            return [out]
        }

        let folder = try OutputPath.folderBeside(src, suffix: format.title)
        let base = src.deletingPathExtension().lastPathComponent
        let digits = max(3, String(count).count)
        do {
            for i in 0..<count {
                try Task.checkCancellation()
                let name = "\(base) \(String(format: "%0\(digits)d", i + 1))"
                let out = OutputPath.unique(in: folder, base: name, ext: format.ext)
                let image = try PDFEngine.render(page: doc.page(at: i)!, dpi: dpi)
                try ImageEngine.write(image, to: out, format: format, quality: quality)
                await progress(Double(i + 1) / Double(count))
                await Task.yield()
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return [folder]
    }

    @MainActor
    private func convertDocument(_ src: URL) async throws -> [URL] {
        guard let format = DocFormat(rawValue: target) else { throw ActionError("Unknown format.") }
        let text = try await DocumentEngine.read(src)
        let out = OutputPath.beside(src, ext: target)
        try DocumentEngine.write(text, as: format, to: out)
        return [out]
    }
}
