import Foundation

/// Builds output paths next to the source. Never returns a path that already exists.
public enum OutputPath {
    /// "Page 001.pdf" + ext "jpg" -> "Page 001.jpg"; with suffix "Cropped" -> "Page 001 Cropped.jpg".
    public static func beside(_ source: URL, suffix: String? = nil, ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix, !suffix.isEmpty { base += " " + suffix }
        return unique(in: dir, base: base, ext: ext)
    }

    /// A fresh folder next to the source, for multi-page output.
    public static func folderBeside(_ source: URL, suffix: String) throws -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + " " + suffix
        let url = unique(in: dir, base: base, ext: nil)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    public static func unique(in dir: URL, base: String, ext: String?) -> URL {
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name)
            if let ext, !ext.isEmpty { return u.appendingPathExtension(ext) }
            return u
        }
        let fm = FileManager.default
        var candidate = make(base)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }
}
