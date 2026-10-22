import AppKit
import SwiftUI
import WheelCore

/// Settings → General → Diagnostics: the local log, its privacy, and the opt-out.
struct DiagnosticsSection: View {
    @ObservedObject private var settings = Settings.shared
    @State private var size: Int64 = 0
    @State private var note: String?
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle("Keep a local diagnostic log", isOn: $settings.loggingEnabled)
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if settings.loggingEnabled {
                Toggle("Include file names", isOn: $settings.logFileNames)
                Text("Off: files show as ‹pdf›, ‹jpg›. Full paths and file contents are never logged either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Show in Finder", action: reveal)
                Button("Copy Recent Log", action: copyRecent).disabled(size == 0)
                Spacer()
                Button("Delete Logs…", role: .destructive) { confirmDelete = true }.disabled(size == 0)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) in ~/Library/Logs/Wheel")
        }
        .onAppear(perform: refresh)
        .onChange(of: settings.loggingEnabled) { _, _ in refresh() }
        .confirmationDialog("Delete all Wheel logs and crash summaries?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                WheelLog.shared.deleteAll()
                note = "Logs deleted."
                refresh()
            }
        }
    }

    private var explanation: String {
        settings.loggingEnabled
            ? "Wheel notes what it did and any errors or crashes in a log that stays on this Mac. It is never uploaded. If something breaks, the log helps you, the developers, or an AI coding agent you choose to work out why, but only if you share it. Only you can read it (permissions 600), it's capped at a few MB and old entries delete themselves after 14 days."
            : "Logging is off: Wheel writes nothing. Existing logs stay until you delete them. Turning it back on helps when tracking down a crash. The log never leaves this Mac unless you share it."
    }

    private func refresh() {
        WheelLog.shared.flush()
        size = WheelLog.shared.totalSize
    }

    private func reveal() {
        let dir = WheelLog.shared.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.activateFileViewerSelecting([WheelLog.shared.files.first ?? dir])
    }

    /// The last 300 lines plus the newest crash summary: ready to paste into an issue or an AI chat.
    private func copyRecent() {
        var text = "Wheel diagnostic log (local, redacted)\n\n" + WheelLog.shared.tail(300)
        if let crash = WheelLog.shared.files.first(where: { $0.lastPathComponent.hasPrefix("crash-") }),
           let summary = try? String(contentsOf: crash, encoding: .utf8) {
            text += "\n\n" + summary
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        note = "Copied. Review it before pasting anywhere."
    }
}
