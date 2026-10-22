import AppKit
import WheelCore
import SwiftUI

enum Theme {
    static let wheelOrange = NSColor(srgbRed: 1.0, green: 0.353, blue: 0.122, alpha: 1) // #FF5A1F

    /// The highlight colour: Wheel's orange, the System Settings accent, or a custom colour.
    static var accentNS: NSColor { Settings.shared.style.accentNS }
    static var accent: Color { Color(nsColor: accentNS) }
}

/// Behind-window blur. SwiftUI materials only blur within the window, which is empty in our transparent panels.
struct GlassBackground: NSViewRepresentable {
    enum Shape { case circle, rounded(CGFloat) }
    var material: NSVisualEffectView.Material = .hudWindow
    var shape: Shape = .rounded(18)
    /// `.withinWindow` for previews drawn over in-window content (e.g. Settings).
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.maskImage = mask
        return v
    }

    /// Always fill the offered space and never ask AppKit for a fitting size. Without this, SwiftUI
    /// measures the effect view through Auto Layout, which can trip AppKit's `_nsis_frameInEngine`
    /// assertion and abort the app (the crash seen in 0.4.0 reports).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.maskImage = mask
    }

    private var mask: NSImage {
        switch shape {
        case .rounded(let r):
            let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
            let img = NSImage(size: size, flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
                return true
            }
            img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
            img.resizingMode = .stretch
            return img
        case .circle:
            // Large enough to stay crisp; the view stretches it to its own (square) bounds.
            let img = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            img.resizingMode = .stretch
            return img
        }
    }
}

/// Borderless panel that can still take keyboard focus (needed for text fields in editors).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Esc closes the editor like the X button.
        (delegate as? EditorWindowDelegate)?.closeRequested()
    }
}

@MainActor
protocol EditorWindowDelegate: NSWindowDelegate {
    func closeRequested()
}

struct AccentButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(enabled ? 1 : 0.4)))
            .brightness(configuration.isPressed ? -0.08 : 0)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

/// Row of selectable chips, like the aspect ratio picker in the reference.
struct ChipPicker<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                Text(label(opt))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selection == opt ? Color.white : Color.primary.opacity(0.75))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selection == opt ? Theme.accent : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }
}

/// Label + slider + value, as in the Add BG panel.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "px"
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Slider(value: $value, in: range).tint(Theme.accent).controlSize(.small)
            Text("\(format(value))\(unit.isEmpty ? "" : " " + unit)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}
