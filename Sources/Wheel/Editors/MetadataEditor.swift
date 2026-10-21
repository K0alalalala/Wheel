import ImageIO
import WheelCore
import PDFKit
import SwiftUI

struct MetadataAction: FileAction {
    let id = "edit.metadata", title = "Metadata", symbol = "tag", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { [.image, .pdf].contains(FileKind.of(url)) }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        try await EditorWindow.present(title: "Metadata", size: CGSize(width: 380, height: 480)) { finish in
            MetadataEditor(urls: urls, finish: finish)
        }
    }
}

enum MetadataEngine {
    struct Entry: Identifiable {
        let id = UUID()
        let group: String
        let key: String
        let value: String
    }

    static func entries(_ url: URL) -> [Entry] {
        if FileKind.of(url) == .pdf {
            guard let attrs = PDFDocument(url: url)?.documentAttributes else { return [] }
            return attrs.map { Entry(group: "PDF", key: "\($0.key)", value: describe($0.value)) }.sorted { $0.key < $1.key }
        }
        var out: [Entry] = []
        let props = ImageEngine.properties(url)
        for (k, v) in props.sorted(by: { $0.key < $1.key }) {
            if let dict = v as? [String: Any] {
                let group = k.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
                for (k2, v2) in dict.sorted(by: { $0.key < $1.key }) {
                    out.append(Entry(group: group, key: k2, value: describe(v2)))
                }
            } else {
                out.append(Entry(group: "File", key: k, value: describe(v)))
            }
        }
        return out
    }

    static func hasLocation(_ url: URL) -> Bool {
        ImageEngine.properties(url)[kCGImagePropertyGPSDictionary as String] != nil
    }

    private static func describe(_ v: Any) -> String {
        if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
        if let d = v as? Date { return d.formatted(date: .abbreviated, time: .shortened) }
        return "\(v)"
    }

    /// Writes a copy without EXIF/GPS/XMP/IPTC. JPEG data is copied losslessly when ImageIO allows it.
    static func strip(_ url: URL) throws -> URL {
        if FileKind.of(url) == .pdf {
            guard let doc = PDFDocument(url: url) else { throw ActionError("Couldn't open \(url.lastPathComponent).") }
            doc.documentAttributes = [:]
            let out = OutputPath.beside(url, suffix: "No Metadata", ext: "pdf")
            guard doc.write(to: out) else { throw ActionError("Couldn't write PDF.") }
            return out
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw ActionError("Couldn't read \(url.lastPathComponent).")
        }
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let out = OutputPath.beside(url, suffix: "No Metadata", ext: ext)

        // Keep orientation, or the photo would appear rotated once the EXIF tag is gone.
        let orientation = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        let meta = CGImageMetadataCreateMutable()
        if orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            let opts: [CFString: Any] = [
                kCGImageDestinationMetadata: meta,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeXMP: true,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            var err: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err), !hasPrivateMetadata(out) {
                return out
            }
            try? FileManager.default.removeItem(at: out)
        }
        // Fallback: decode and re-encode pixels only, which carries no metadata at all.
        let fmt = ImageFormat.of(url).flatMap { $0.writableByImageIO ? $0 : nil } ?? .png
        let fallback = OutputPath.beside(url, suffix: "No Metadata", ext: fmt.ext)
        try ImageEngine.write(try ImageEngine.load(url), to: fallback, format: fmt, quality: 0.95)
        return fallback
    }

    static func hasPrivateMetadata(_ url: URL) -> Bool {
        let p = ImageEngine.properties(url)
        if p[kCGImagePropertyGPSDictionary as String] != nil { return true }
        if let exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any],
           exif.keys.contains(where: { ["DateTimeOriginal", "BodySerialNumber", "LensModel"].contains($0) }) { return true }
        if let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           tiff.keys.contains(where: { ["Make", "Model", "Software", "DateTime"].contains($0) }) { return true }
        return false
    }
}

struct MetadataEditor: View {
    let urls: [URL]
    let finish: EditorFinish

    @State private var entries: [MetadataEngine.Entry] = []
    @State private var busy = false

    var body: some View {
        VStack(spacing: 8) {
            if urls.count == 1, MetadataEngine.hasLocation(urls[0]) {
                Label("This file contains GPS location", systemImage: "location.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
            }
            Text(urls.count > 1 ? "Showing \(urls[0].lastPathComponent) (1 of \(urls.count))" : urls[0].lastPathComponent)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)

            if entries.isEmpty {
                Text("No metadata").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Dictionary(grouping: entries, by: \.group).sorted(by: { $0.key < $1.key }), id: \.key) { group, items in
                        Section(group) {
                            ForEach(items) { e in
                                HStack(alignment: .top) {
                                    Text(e.key).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                    Text(e.value).font(.system(size: 11)).textSelection(.enabled).lineLimit(3)
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.inset)
            }
            EditorFooter(primaryTitle: urls.count > 1 ? "Strip \(urls.count) Files" : "Save Stripped Copy", busy: busy, onReset: nil, onPrimary: strip)
        }
        .onAppear { entries = MetadataEngine.entries(urls[0]) }
    }

    private func strip() {
        busy = true
        let urls = self.urls
        Task {
            do {
                let outs = try await Task.detached(priority: .userInitiated) { try urls.map(MetadataEngine.strip) }.value
                finish(.success(outs))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
