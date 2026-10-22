import AppKit

/// Optional command-line backends. Found once at launch; slices that need a missing tool are grayed out.
public enum ExternalTools {
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/Applications/LibreOffice.app/Contents/MacOS"]

    public static private(set) var ffmpeg: URL? = find("ffmpeg")
    public static private(set) var cwebp: URL? = find("cwebp")
    public static private(set) var pandoc: URL? = find("pandoc")
    public static private(set) var soffice: URL? = find("soffice")
    public static private(set) var sevenZip: URL? = find("7zz") ?? find("7z")
    public static private(set) var rar: URL? = find("rar")
    public static let zip: URL? = find("zip")
    public static let tar: URL? = find("tar")
    public static let afconvert: URL? = find("afconvert")

    public static func refresh() {
        ffmpeg = find("ffmpeg"); cwebp = find("cwebp"); pandoc = find("pandoc"); soffice = find("soffice")
        sevenZip = find("7zz") ?? find("7z"); rar = find("rar")
    }

    public static func find(_ name: String) -> URL? {
        var dirs = searchPaths
        if let path = ProcessInfo.processInfo.environment["PATH"] { dirs += path.split(separator: ":").map(String.init) }
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs a tool and waits. Cancelling the surrounding task terminates the process.
    @discardableResult
    public static func run(_ tool: URL, _ args: [String], in directory: URL? = nil,
                           environment: [String: String] = [:]) async throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        if let directory { process.currentDirectoryURL = directory }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let errPipe = Pipe(), outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                process.terminationHandler = { p in
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else if p.terminationStatus != 0 {
                        let tail = err.split(separator: "\n").suffix(3).joined(separator: " ")
                        // Tool name and status only: arguments contain file paths.
                        WheelLog.shared.error("\(tool.lastPathComponent) exited with status \(p.terminationStatus): \(String(tail.prefix(300)))")
                        cont.resume(throwing: ActionError("\(tool.lastPathComponent) failed: \(tail)"))
                    } else {
                        cont.resume(returning: out)
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// WebP via `cwebp` (or ffmpeg) because ImageIO can read WebP but not write it.
    public static func encodeWebP(_ image: CGImage, quality: Double) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = tmp.appendingPathExtension("png"), webp = tmp.appendingPathExtension("webp")
        defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: webp) }
        try ImageEngine.encode(image, format: .png).write(to: png)
        let q = String(Int(quality * 100))
        let process = Process()
        if let cwebp {
            process.executableURL = cwebp
            process.arguments = ["-quiet", "-q", q, "-alpha_q", "100", png.path, "-o", webp.path]
        } else if let ffmpeg {
            process.executableURL = ffmpeg
            process.arguments = ["-y", "-loglevel", "error", "-i", png.path, "-quality", q, webp.path]
        } else {
            throw ActionError("WebP needs cwebp or ffmpeg. Install with: brew install webp")
        }
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: webp) else {
            throw ActionError("WebP encoding failed.")
        }
        return data
    }
}
