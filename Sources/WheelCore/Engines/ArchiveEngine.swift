import Foundation

public enum ArchiveFormat: String, CaseIterable, Codable {
    case zip, tarGz, sevenZip, rar

    public var title: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "TAR.GZ"
        case .sevenZip: return "7Z"
        case .rar: return "RAR"
        }
    }

    public var ext: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        case .sevenZip: return "7z"
        case .rar: return "rar"
        }
    }

    /// nil when the format can be written on this Mac, otherwise how to get it.
    public var unavailableReason: String? {
        switch self {
        case .zip: return ExternalTools.zip == nil ? "zip is missing" : nil
        case .tarGz: return ExternalTools.tar == nil ? "tar is missing" : nil
        case .sevenZip: return ExternalTools.sevenZip == nil ? "brew install sevenzip" : nil
        case .rar: return ExternalTools.rar == nil ? "brew install --cask rar" : nil
        }
    }
}

public enum CompressionLevel: String, CaseIterable, Codable {
    case store, fast, normal, best

    public var title: String { rawValue.capitalized }
}

/// Packs files and folders into one archive. Inputs are cloned into a private staging folder first
/// (APFS clones: instant, no extra disk space), so names can be relative and inputs are never touched.
public enum ArchiveEngine {
    /// Writes `<dir>/<name>.<ext>` next to the first item and returns its URL.
    public static func archive(_ items: [URL], name: String, format: ArchiveFormat,
                               level: CompressionLevel = .normal) async throws -> URL {
        guard !items.isEmpty else { throw ActionError("Nothing to archive.") }
        if let reason = format.unavailableReason { throw ActionError("\(format.title) needs a tool: \(reason)") }

        let dir = items[0].deletingLastPathComponent()
        let base = sanitized(name).isEmpty ? "Archive" : sanitized(name)
        let out = OutputPath.unique(in: dir, base: base, ext: format.ext)

        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("WheelArchive-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        // Clone each item into staging under a unique name.
        var names: [String] = []
        for item in items {
            let stem = item.deletingPathExtension().lastPathComponent, ext = item.pathExtension
            let target = OutputPath.unique(in: stage, base: stem, ext: ext.isEmpty ? nil : ext)
            try fm.copyItem(at: item, to: target)
            names.append(target.lastPathComponent)
        }

        do {
            switch format {
            case .zip:
                let lvl = ["store": "-0", "fast": "-1", "normal": "-6", "best": "-9"][level.rawValue]!
                // -X: no extra attributes, -y: keep symlinks as links. Skip Finder clutter.
                try await ExternalTools.run(ExternalTools.zip!, ["-r", "-q", "-X", "-y", lvl, out.path] + names
                                            + ["-x", "*.DS_Store", "-x", "__MACOSX/*"], in: stage)
            case .tarGz:
                // COPYFILE_DISABLE stops bsdtar from adding ._ AppleDouble files.
                let gz = level == .store ? "--options=gzip:compression-level=1" : "--options=gzip:compression-level=\(level == .best ? 9 : 6)"
                try await ExternalTools.run(ExternalTools.tar!, ["-czf", out.path, gz, "--exclude", ".DS_Store"] + names,
                                            in: stage, environment: ["COPYFILE_DISABLE": "1"])
            case .sevenZip:
                let mx = ["store": "-mx=0", "fast": "-mx=1", "normal": "-mx=5", "best": "-mx=9"][level.rawValue]!
                try await ExternalTools.run(ExternalTools.sevenZip!, ["a", "-bd", "-y", mx, "-xr!.DS_Store", out.path] + names, in: stage)
            case .rar:
                let m = ["store": "-m0", "fast": "-m1", "normal": "-m3", "best": "-m5"][level.rawValue]!
                try await ExternalTools.run(ExternalTools.rar!, ["a", "-r", "-idq", "-ep1", m, "-x*.DS_Store", out.path] + names, in: stage)
            }
        } catch {
            try? fm.removeItem(at: out)
            throw error
        }
        guard fm.fileExists(atPath: out.path) else { throw ActionError("\(format.title) archive wasn't created.") }
        return out
    }

    /// A file name typed by the user that can't escape the folder or hide itself.
    public static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
    }

    /// Total size of files and folders, for the editor's "N items, 12 MB" line.
    public static func totalSize(_ items: [URL]) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            if values?.isDirectory == true {
                let e = fm.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey])
                while let f = e?.nextObject() as? URL {
                    total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
