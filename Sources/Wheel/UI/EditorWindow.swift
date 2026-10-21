import AppKit
import WheelCore
import SwiftUI

/// Callback an editor uses to finish: `.success(urls)` after saving, `.failure(UserCancelled())` when closed.
typealias EditorFinish = @MainActor (Result<[URL], Error>) -> Void

/// Small floating glass window that hosts one editor (Crop, Add BG...) and resumes the caller when it closes.
@MainActor
final class EditorWindow: NSObject, EditorWindowDelegate {
    private static var open: [EditorWindow] = []

    private let panel: KeyablePanel
    private var continuation: CheckedContinuation<[URL], Error>?

    private init<Content: View>(title: String, size: CGSize, content: (@escaping EditorFinish) -> Content) {
        panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size),
                             styleMask: [.borderless, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = size
        panel.delegate = self

        let finish: EditorFinish = { [weak self] result in self?.complete(result) }
        let root = EditorChrome(title: title, onClose: { [weak self] in self?.closeRequested() }) {
            content(finish)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
    }

    /// Shows an editor near the mouse and waits until it saves or is closed.
    static func present<Content: View>(title: String, size: CGSize,
                                       @ViewBuilder content: @escaping (@escaping EditorFinish) -> Content) async throws -> [URL] {
        let editor = EditorWindow(title: title, size: size, content: content)
        open.append(editor)
        return try await withCheckedThrowingContinuation { cont in
            editor.continuation = cont
            editor.show()
        }
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var frame = panel.frame
        frame.origin = CGPoint(x: mouse.x - frame.width / 2, y: mouse.y - frame.height / 2)
        if let vis = screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, vis.minX + 8), vis.maxX - frame.width - 8)
            frame.origin.y = min(max(frame.minY, vis.minY + 8), vis.maxY - frame.height - 8)
        }
        panel.setFrame(frame, display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func closeRequested() { complete(.failure(UserCancelled())) }

    private func complete(_ result: Result<[URL], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        panel.orderOut(nil)
        Self.open.removeAll { $0 === self }
        cont.resume(with: result)
    }
}

/// Glass card with an X at the top left and a centered title.
private struct EditorChrome<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Close (Esc)")
                    Spacer()
                }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            content
        }
        .background(GlassBackground(material: .hudWindow, shape: .rounded(18)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
