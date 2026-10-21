import AppKit
import WheelCore

/// Runs a dropped action: batch actions file by file with the progress toast, interactive ones through their editor.
@MainActor
final class ActionRunner {
    static let shared = ActionRunner()
    private var current: Task<Void, Never>?

    func run(_ action: FileAction, on urls: [URL]) {
        let files = urls.filter(action.supports)
        guard !files.isEmpty else {
            Toast.shared.finish(title: "Nothing to do", subtitle: "\(action.title) doesn't apply to these files.", failed: true)
            return
        }
        if let reason = action.unavailableReason {
            Toast.shared.finish(title: "\(action.title) unavailable", subtitle: reason, failed: true)
            return
        }
        current = Task { [weak self] in
            if action.isInteractive {
                await self?.runInteractive(action, files)
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
            // Closed without saving.
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
            Toast.shared.finish(title: "Cancelled", subtitle: "\(outputs.count) of \(total) saved")
        } else if !errors.isEmpty {
            Toast.shared.finish(title: outputs.isEmpty ? "\(action.title) failed" : "Saved \(outputs.count) of \(total)",
                                subtitle: errors.first ?? "", failed: true)
            NSLog("Wheel: %@", errors.joined(separator: "\n"))
        } else {
            succeeded(outputs)
        }
    }

    private func succeeded(_ outputs: [URL]) {
        guard let first = outputs.first else { return }
        let title = outputs.count == 1 ? "Saved \(first.lastPathComponent)" : "Saved \(outputs.count) files"
        Toast.shared.finish(title: title, subtitle: "Click to show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
            Toast.shared.hide()
        }
        if Settings.shared.revealAfterSave { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    }

    private func failed(_ action: FileAction, _ error: Error) {
        Toast.shared.finish(title: "\(action.title) failed", subtitle: error.localizedDescription, failed: true)
    }
}
