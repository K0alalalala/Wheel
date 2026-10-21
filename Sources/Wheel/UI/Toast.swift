import AppKit
import WheelCore
import SwiftUI

@MainActor
final class ToastModel: ObservableObject {
    enum State: Equatable { case working, done, failed }

    @Published var title = ""
    @Published var subtitle = ""
    @Published var progress: Double = 0
    @Published var state: State = .working
    var onCancel: (() -> Void)?
    var onClick: (() -> Void)?
}

/// Floating glass progress toast near the cursor: X, title, "1 of 1 saved", thin accent bar.
@MainActor
final class Toast {
    static let shared = Toast()

    let model = ToastModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 58),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ToastView(model: model))
    }

    func begin(title: String, subtitle: String, onCancel: @escaping () -> Void) {
        hideWork?.cancel()
        model.title = title
        model.subtitle = subtitle
        model.progress = 0
        model.state = .working
        model.onCancel = onCancel
        model.onClick = nil
        if !panel.isVisible { place() }
        panel.orderFrontRegardless()
    }

    func update(progress: Double, subtitle: String? = nil) {
        model.progress = max(model.progress, min(progress, 1))
        if let subtitle { model.subtitle = subtitle }
    }

    func finish(title: String, subtitle: String, failed: Bool = false, onClick: (() -> Void)? = nil) {
        model.title = title
        model.subtitle = subtitle
        model.progress = 1
        model.state = failed ? .failed : .done
        model.onCancel = { [weak self] in self?.hide() }
        model.onClick = onClick
        if !panel.isVisible { place(); panel.orderFrontRegardless() }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Settings.shared.toastDuration * (failed ? 1.75 : 1), execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func place() {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        if let vis = screen?.visibleFrame {
            switch Settings.shared.toastPlacement {
            case .cursor: break
            case .topRight: origin = CGPoint(x: vis.maxX - size.width - 16, y: vis.maxY - size.height - 16)
            case .bottomCenter: origin = CGPoint(x: vis.midX - size.width / 2, y: vis.minY + 48)
            }
        }
        if let vis = screen?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            origin.y = min(max(origin.y, vis.minY + 8), vis.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }
}

private struct ToastView: View {
    @ObservedObject var model: ToastModel
    @ObservedObject private var settings = Settings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Button { model.onCancel?() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help(model.state == .working ? "Cancel" : "Dismiss")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(model.subtitle).font(.system(size: 11)).foregroundStyle(model.state == .failed ? Color.red : .secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if model.state == .done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            if model.state == .failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red) }
        }
        .padding(.horizontal, 12)
        .frame(width: 300, height: 58)
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(Theme.accent)
                    .frame(width: g.size.width * model.progress, height: 3)
                    .animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: model.progress)
            }
            .frame(height: 3)
            .padding(.horizontal, 14).padding(.bottom, 5)
            .opacity(model.state == .working ? 1 : 0)
        }
        .background(GlassBackground(material: .hudWindow, shape: .rounded(14)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture { model.onClick?() }
    }
}
