import AppKit
import WheelCore

/// Runs a dropped action: batch actions file by file with the progress toast, interactive ones through their editor.
@MainActor
final class ActionRunner {
    static let shared = ActionRunner()
    private var current: Task<Void, Never>?
    private let log = WheelLog.shared
    /// For log lines: what's running, on which files, since when.
    private var running: (id: String, files: [URL], started: Date)?

    func run(_ action: FileAction, on urls: [URL]) {
        let files = urls.filter(action.supports)
        guard !files.isEmpty else {
            log.warning("\(action.id): none of \(log.describe(urls)) supported")
            Toast.shared.finish(title: "Nothing to do", subtitle: "\(action.title) doesn't apply to these files.", failed: true)
            return
        }
        if let reason = action.unavailableReason {
            log.warning("\(action.id) unavailable: \(reason)")
            Toast.shared.finish(title: "\(action.title) unavailable", subtitle: reason, failed: true)
            return
        }
        running = (action.id, files, Date())
        log.info("Start \(action.id) on \(log.describe(files))")
        current = Task { [weak self] in
            if action.isInteractive {
                await self?.runInteractive(action, files)
            } else if action.combinesFiles {
                await self?.runCombined(action, files)
            } else {
                await self?.runBatch(action, files)
            }
        }
    }

    private func runInteractive(_ action: FileAction, _ files: [URL]) async {
        do {
            let outs = try await action.run(files, progress: { _ in })
            succeeded(outs)
        } catch is UserCancelled {
            finishLog("closed without saving")
        } catch {
            failed(action, error)
        }
    }

    /// One run over all files with a single progress bar (Merge).
    private func runCombined(_ action: FileAction, _ files: [URL]) async {
        Toast.shared.begin(title: action.title, subtitle: "\(files.count) files") { [weak self] in self?.current?.cancel() }
        do {
            let outs = try await action.run(files) { p in Toast.shared.update(progress: p) }
            succeeded(outs)
        } catch is CancellationError {
            finishLog("cancelled")
            Toast.shared.finish(title: "Cancelled", subtitle: "Nothing was saved")
        } catch {
            failed(action, error)
        }
    }

    private func runBatch(_ action: FileAction, _ files: [URL]) async {
        let verb = action.mode == .convert ? "Converting to \(action.title)" : action.title
        let total = files.count
        Toast.shared.begin(title: verb, subtitle: "0 of \(total) saved") { [weak self] in self?.current?.cancel() }

        var outputs: [URL] = []
        var errors: [String] = []
        for (i, file) in files.enumerated() {
            if Task.isCancelled { break }
            do {
                let outs = try await action.run([file]) { p in
                    Toast.shared.update(progress: (Double(i) + p) / Double(total))
                }
                outputs += outs
            } catch is CancellationError {
                break
            } catch {
                errors.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
            Toast.shared.update(progress: Double(i + 1) / Double(total), subtitle: "\(outputs.count) of \(total) saved")
        }

        if Task.isCancelled {
            finishLog("cancelled after \(outputs.count) of \(total)")
            Toast.shared.finish(title: "Cancelled", subtitle: "\(outputs.count) of \(total) saved")
        } else if !errors.isEmpty {
            Toast.shared.finish(title: outputs.isEmpty ? "\(action.title) failed" : "Saved \(outputs.count) of \(total)",
                                subtitle: errors.first ?? "", failed: true)
            finishLog("\(errors.count) of \(total) failed: " + errors.prefix(5).joined(separator: " | "), level: .error)
        } else {
            succeeded(outputs)
        }
    }

    private func succeeded(_ outputs: [URL]) {
        finishLog("saved \(log.describe(outputs))")
        guard let first = outputs.first else { return }
        let title = outputs.count == 1 ? "Saved \(first.lastPathComponent)" : "Saved \(outputs.count) files"
        Toast.shared.finish(title: title, subtitle: "Click to show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            Toast.shared.hide()
        }
        if Settings.shared.revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    private func failed(_ action: FileAction, _ error: Error) {
        finishLog("failed: \(error.localizedDescription)", level: .error)
        Toast.shared.finish(title: "\(action.title) failed", subtitle: error.localizedDescription, failed: true)
    }

    /// One line per run: outcome and duration. File names in messages are redacted unless allowed.
    private func finishLog(_ outcome: String, level: WheelLog.Level = .info) {
        guard let r = running else { return }
        let ms = Int(Date().timeIntervalSince(r.started) * 1000)
        log.log(level, "End \(r.id) after \(ms) ms: " + log.redact(outcome, files: r.files))
        running = nil
    }
}
