import Darwin
import Foundation

/// Notices crashes and keeps a short, private summary of them next to the log.
///
/// 1. `session.lock` is created at launch and removed on a normal quit. If it's still there at the next
///    launch, the previous run ended unexpectedly.
/// 2. A signal handler appends one line ("fatal signal SIGABRT") using only async-signal-safe calls.
/// 3. At the next launch, macOS's own crash report for Wheel (~/Library/Logs/DiagnosticReports) is
///    summarized into `crash-<date>.txt`: exception, reason and the crashing thread's stack.
///    Registers, other threads and other apps' details are left out.
public enum CrashReporter {
    private static var log: WheelLog { WheelLog.shared }
    static var lockURL: URL { log.directory.appendingPathComponent("session.lock") }

    /// Call once at launch, after logging preferences are applied.
    public static func start(version: String) {
        let previousRunCrashed = FileManager.default.fileExists(atPath: lockURL.path)
        if log.isEnabled {
            try? FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: lockURL.path, contents: Data("\(version)\n".utf8),
                                           attributes: [.posixPermissions: 0o600])
            installHandlers()
        }
        if previousRunCrashed {
            log.warning("The previous session ended unexpectedly (crash or force quit).")
        }
        if log.isEnabled { importSystemReports() }
    }

    /// Call from applicationWillTerminate.
    public static func stopCleanly() {
        log.info("Quit")
        log.flush()
        try? FileManager.default.removeItem(at: lockURL)
    }

    // MARK: Handlers

    nonisolated(unsafe) private static var signalFD: Int32 = -1
    /// Pre-formatted lines indexed by signal number (a plain C array: no Swift runtime work in the handler).
    nonisolated(unsafe) private static let signalLines = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 32)

    private static func installHandlers() {
        NSSetUncaughtExceptionHandler { e in
            WheelLog.shared.log(.crash, "Uncaught exception \(e.name.rawValue): \(e.reason ?? "")")
            WheelLog.shared.flush()
        }

        // Pre-open the log and pre-format messages: the handler itself may only call write().
        signalFD = open(log.logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard signalFD >= 0 else { return }
        let signals: [(Int32, String)] = [(SIGABRT, "SIGABRT"), (SIGSEGV, "SIGSEGV"), (SIGBUS, "SIGBUS"),
                                          (SIGILL, "SIGILL"), (SIGTRAP, "SIGTRAP"), (SIGFPE, "SIGFPE")]
        signalLines.initialize(repeating: nil, count: 32)
        for (sig, name) in signals {
            signalLines[Int(sig)] = strdup("\(WheelLog.timestamp()) [crash] fatal signal \(name) (time is session start; see crash report)\n")
            signal(sig, crashSignalHandler)
        }
    }

    /// Reads only pre-built globals, writes once, then lets the default handler produce the system report.
    private static let crashSignalHandler: @convention(c) (Int32) -> Void = { sig in
        if sig >= 0, sig < 32, let line = CrashReporter.signalLines[Int(sig)], CrashReporter.signalFD >= 0 {
            _ = write(CrashReporter.signalFD, line, strlen(line))
        }
        signal(sig, SIG_DFL)
        raise(sig)
    }

    // MARK: System crash reports

    static var reportsDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")
    private static var stampURL: URL { log.directory.appendingPathComponent("last-import") }

    /// Summarizes Wheel crash reports newer than the last import. Returns the summaries written.
    @discardableResult
    public static func importSystemReports() -> [URL] {
        let fm = FileManager.default
        let since = (try? String(contentsOf: stampURL, encoding: .utf8)).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(-14 * 24 * 3600)
        let reports = ((try? fm.contentsOfDirectory(at: reportsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Wheel") && $0.pathExtension == "ips" }
            .filter { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) > since }
        var written: [URL] = []
        for report in reports {
            guard let raw = try? String(contentsOf: report, encoding: .utf8), let summary = summarize(raw) else { continue }
            let out = log.directory.appendingPathComponent("crash-\(report.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Wheel-", with: "")).txt")
            guard !fm.fileExists(atPath: out.path) else { continue }
            fm.createFile(atPath: out.path, contents: Data(log.redact(summary).utf8), attributes: [.posixPermissions: 0o600])
            written.append(out)
            log.log(.crash, "Crash report saved as \(out.lastPathComponent): \(summary.split(separator: "\n").dropFirst(3).first ?? "")")
        }
        try? FileManager.default.removeItem(at: stampURL)
        FileManager.default.createFile(atPath: stampURL.path, contents: Data(String(Date().timeIntervalSince1970).utf8),
                                       attributes: [.posixPermissions: 0o600])
        // Keep the ten newest crash summaries.
        let crashes = log.files.filter { $0.lastPathComponent.hasPrefix("crash-") }
        for old in crashes.dropFirst(10) { try? fm.removeItem(at: old) }
        return written
    }

    /// Turns a macOS .ips report into a short text summary. nil if it isn't a Wheel report.
    public static func summarize(_ ips: String) -> String? {
        let parts = ips.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
              (header["bundleID"] as? String)?.contains("wheel") == true else { return nil }

        var lines = ["Wheel crash summary (from the macOS crash report; registers and other threads omitted)",
                     "When: \(header["timestamp"] as? String ?? "?")",
                     "Version: \(header["app_version"] as? String ?? "?") · \(header["os_version"] as? String ?? "?")"]
        let ex = body["exception"] as? [String: Any] ?? [:]
        lines.append("Exception: \(ex["type"] as? String ?? "?") \(ex["signal"] as? String ?? "") \(ex["subtype"] as? String ?? "")"
            .trimmingCharacters(in: .whitespaces))
        if let term = (body["termination"] as? [String: Any])?["indicator"] as? String { lines.append("Termination: \(term)") }
        if let asi = body["asi"] as? [String: [String]] {
            for (lib, msgs) in asi { lines.append("Message (\(lib)): \(msgs.joined(separator: " "))") }
        }

        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let index = body["faultingThread"] as? Int ?? 0
        if threads.indices.contains(index) {
            let thread = threads[index]
            lines.append("Crashed thread: \(index) \(thread["name"] as? String ?? thread["queue"] as? String ?? "")")
            for (n, frame) in ((thread["frames"] as? [[String: Any]]) ?? []).prefix(40).enumerated() {
                let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "?"
                let symbol = frame["symbol"] as? String ?? "0x" + String(frame["imageOffset"] as? Int ?? 0, radix: 16)
                lines.append(String(format: "%3d  %@  %@", n, image.padding(toLength: 22, withPad: " ", startingAt: 0), symbol))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
