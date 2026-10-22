import Foundation
import os

/// Local, private diagnostic log.
///
/// - Lives in `~/Library/Logs/Wheel/` (folder 0700, files 0600). Never sent anywhere.
/// - Never records file contents, passwords or full paths. The home folder becomes `~`, and file
///   names become `‹pdf›` unless the user opts in to names.
/// - Capped at 1 MB per file, three files kept; anything older than 14 days is removed.
/// - When disabled, nothing is written.
public final class WheelLog: @unchecked Sendable {
    public enum Level: String { case info, warning, error, crash }

    public static let shared = WheelLog(directory: defaultDirectory)

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Wheel", isDirectory: true)
    }

    public let directory: URL
    public var maxBytes = 1_000_000
    public var keepFiles = 3
    public var maxAge: TimeInterval = 14 * 24 * 3600

    private let queue = DispatchQueue(label: "wheel.log", qos: .utility)
    private var handle: FileHandle?
    private let system = Logger(subsystem: "io.github.k0alalalala.wheel", category: "app")
    private var _enabled = true
    private var _includeFileNames = false
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    public init(directory: URL) {
        self.directory = directory
    }

    public var logFile: URL { directory.appendingPathComponent("wheel.log") }

    /// Turning logging off closes the file; existing logs stay until `deleteAll()`.
    public var isEnabled: Bool {
        get { queue.sync { _enabled } }
        set { queue.sync { _enabled = newValue; if !newValue { try? handle?.close(); handle = nil } } }
    }

    public var includeFileNames: Bool {
        get { queue.sync { _includeFileNames } }
        set { queue.sync { _includeFileNames = newValue } }
    }

    // MARK: Writing

    public func log(_ level: Level, _ message: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) {
        let text = redact(message())
        let source = "\(file)".split(separator: "/").last.map(String.init) ?? "\(file)"
        let entry = "\(Self.timestamp()) [\(level.rawValue)] \(source):\(line) \(text)\n"
        queue.async { self.write(entry, level: level, text: text) }
    }

    public func info(_ m: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) { log(.info, m(), file: file, line: line) }
    public func warning(_ m: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) { log(.warning, m(), file: file, line: line) }
    public func error(_ m: @autoclosure () -> String, file: StaticString = #fileID, line: UInt = #line) { log(.error, m(), file: file, line: line) }

    /// Waits until queued lines are on disk (tests, and before quitting).
    public func flush() { queue.sync { try? handle?.synchronize() } }

    private func write(_ entry: String, level: Level, text: String) {
        guard _enabled else { return }
        switch level {
        case .info: system.info("\(text, privacy: .public)")
        case .warning: system.warning("\(text, privacy: .public)")
        case .error, .crash: system.error("\(text, privacy: .public)")
        }
        guard let h = openHandle() else { return }
        h.write(Data(entry.utf8))
        if (try? h.offset()) ?? 0 > UInt64(maxBytes) { rotate() }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            if !fm.fileExists(atPath: logFile.path) {
                fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
                pruneOld()
            }
            let h = try FileHandle(forWritingTo: logFile)
            try h.seekToEnd()
            handle = h
            return h
        } catch {
            return nil
        }
    }

    /// wheel.log → wheel.1.log → wheel.2.log …; the oldest falls off.
    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        for i in stride(from: keepFiles - 1, through: 1, by: -1) {
            let older = directory.appendingPathComponent("wheel.\(i).log")
            let newer = i == 1 ? logFile : directory.appendingPathComponent("wheel.\(i - 1).log")
            try? fm.removeItem(at: older)
            try? fm.moveItem(at: newer, to: older)
        }
    }

    private func pruneOld() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if date < cutoff, url.lastPathComponent != "session.lock" { try? fm.removeItem(at: url) }
        }
    }

    // MARK: Privacy

    /// How a file appears in the log: `‹pdf›` by default, the bare file name if the user opted in. Never the path.
    public func describe(_ url: URL) -> String {
        if includeFileNames { return url.lastPathComponent }
        let ext = url.pathExtension.lowercased()
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        return isDir ? "‹folder›" : "‹\(ext.isEmpty ? "file" : ext)›"
    }

    public func describe(_ urls: [URL]) -> String {
        let shown = urls.prefix(6).map(describe).joined(separator: ", ")
        return "\(urls.count) file\(urls.count == 1 ? "" : "s") (\(shown)\(urls.count > 6 ? ", …" : ""))"
    }

    /// Matches absolute or ~-relative paths with at least two components, e.g. "/Users/x/a.pdf", "~/Desktop/b".
    private static let pathPattern = try! NSRegularExpression(pattern: #"(?:~|/(?:Users|Volumes|private|var|tmp|Applications))/[^\s:,'"]*"#)

    /// Removes the home folder and full paths from any text, and the names of `files` unless names are allowed.
    public func redact(_ text: String, files: [URL] = []) -> String {
        var out = text.replacingOccurrences(of: home, with: "~")
        let names = includeFileNames
        let range = NSRange(out.startIndex..., in: out)
        for match in Self.pathPattern.matches(in: out, range: range).reversed() {
            guard let r = Range(match.range, in: out) else { continue }
            let path = String(out[r])
            out.replaceSubrange(r, with: names ? (path as NSString).lastPathComponent : "‹path›")
        }
        if !names {
            for url in files {
                let name = url.lastPathComponent
                guard name.count > 2 else { continue }
                out = out.replacingOccurrences(of: name, with: describe(url))
                let stem = url.deletingPathExtension().lastPathComponent
                if stem.count > 2 { out = out.replacingOccurrences(of: stem, with: "‹name›") }
            }
        }
        return out
    }

    // MARK: Managing

    /// All log and crash files, newest first.
    public var files: [URL] {
        let fm = FileManager.default
        let all = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return all.filter { ["log", "txt"].contains($0.pathExtension) }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    public var totalSize: Int64 {
        files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    public func deleteAll() {
        queue.sync {
            try? handle?.close()
            handle = nil
            for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent != "session.lock" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The last `count` lines of the current log, for "Copy Recent Log".
    public func tail(_ count: Int) -> String {
        flush()
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count).joined(separator: "\n")
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current // local time with offset, easier to match against what the user remembers
        return f
    }()

    static func timestamp() -> String { formatter.string(from: Date()) }
}
