import SwiftUI
import WheelCore

/// Observable state behind the wheel panel.
@MainActor
final class WheelModel: ObservableObject {
    @Published var mode: WheelMode = .convert
    @Published var urls: [URL] = []
    @Published var slices: [WheelSlice] = []
    @Published var hover: WheelGeometry.Hit = .none
    @Published var visible = false

    /// Style override for previews; nil uses the saved style.
    var styleOverride: WheelStyle?
    var style: WheelStyle { styleOverride ?? Settings.shared.style }
    var geo: WheelGeometry { WheelGeometry(style: style) }

    func load(_ urls: [URL]) {
        guard urls != self.urls else { return }
        self.urls = urls
        // Mixed files open on Combine; otherwise the first wheel that has something to offer.
        mode = ActionRegistry.shared.initialMode(for: urls)
        rebuild()
    }

    /// The wheel the hub switches to next (skips wheels with nothing to offer).
    var nextMode: WheelMode { ActionRegistry.shared.nextMode(after: mode, for: urls) }

    func toggleMode() {
        mode = nextMode
        rebuild()
    }

    func rebuild() { slices = ActionRegistry.shared.slices(for: urls, mode: mode) }

    /// The wheel opens centred on the cursor, so the cursor starts on the hub. The hub only switches
    /// wheels once it's "armed": after the cursor has left it at least once since the wheel appeared.
    /// Without this, simply pausing after pressing Shift would flip the wheel on its own.
    @Published private(set) var hubArmed = false

    /// True when resting on (or force-clicking) the hub should switch wheels.
    var hubActive: Bool { hover == .hub && hubArmed }

    /// Records where the cursor is. Returns true if the hovered target changed.
    @discardableResult
    func updateHover(_ hit: WheelGeometry.Hit) -> Bool {
        if hit != .hub, !hubArmed { hubArmed = true }
        guard hit != hover else { return false }
        hover = hit
        return true
    }

    /// Called whenever the wheel appears: the cursor is on the hub, so disarm it.
    func disarmHub() { hubArmed = false }

    func reset() {
        urls = []; slices = []; hover = .none; mode = .convert; hubArmed = false
    }

    var hubTitle: String {
        if case .slice(let i) = hover, slices.indices.contains(i) { return slices[i].action.title }
        if hubActive { return nextMode == mode ? mode.title : nextMode.title }
        if urls.isEmpty { return "…" }
        return slices.isEmpty ? "No actions" : mode.title
    }

    var hubSubtitle: String? {
        if case .slice(let i) = hover, slices.indices.contains(i) { return slices[i].disabledReason }
        if hubActive {
            switch Settings.shared.hubSwitch {
            case .hover: return "hold to switch"
            case .forceClick: return "press firmly"
            case .both: return "hold or press"
            }
        }
        return urls.count > 1 ? "\(urls.count) files" : nil
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject private var settings = Settings.shared
    /// Previews draw over in-window content, so they blur within the window.
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var style: WheelStyle { model.style }
    private var accent: Color { Color(nsColor: style.accentNS) }

    var body: some View {
        let geo = model.geo
        let motion = !reduceMotion && style.appear != .none
        ZStack {
            disc(geo)
            ForEach(Array(model.slices.enumerated()), id: \.element.id) { i, slice in
                sliceView(i, slice, geo)
            }
            hub(geo)
        }
        .frame(width: geo.diameter, height: geo.diameter)
        .fontDesign(style.font.design)
        .scaleEffect(model.visible || !motion ? 1 : appearScale)
        .rotationEffect(.degrees(model.visible || !motion || style.appear != .spin ? 0 : -45))
        .blur(radius: model.visible || !motion || style.appear != .bloom ? 0 : 12)
        .opacity(model.visible ? 1 : 0)
        .animation(reduceMotion ? .none : style.spring, value: model.visible)
        .animation(reduceMotion ? .none : style.spring, value: model.hover)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.18), value: model.mode)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: style)
    }

    private var appearScale: CGFloat {
        switch style.appear {
        case .pop: return 0.85
        case .spin: return 0.7
        case .bloom: return 0.4
        case .fade, .none: return 1
        }
    }

    @ViewBuilder
    private func disc(_ geo: WheelGeometry) -> some View {
        ZStack {
            if let material = style.material.ns {
                Glass(material: material, shape: .circle, blending: blending)
            } else {
                Circle().fill(Color(nsColor: .windowBackgroundColor))
            }
            Circle().fill(style.discTint.color)
            if style.rimHighlight {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            } else {
                Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
        }
        .frame(width: geo.diameter, height: geo.diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(style.dropShadow ? 0.28 : 0), radius: 18 * geo.labelScale, y: 8 * geo.labelScale)
    }

    private var restingFill: Color {
        let o = style.sliceOpacity
        return scheme == .dark ? Color.white.opacity(o * 0.3) : Color.white.opacity(o)
    }

    private func fill(hovered: Bool, enabled: Bool) -> AnyShapeStyle {
        if hovered && enabled { return style.hoverGradient ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(accent) }
        switch style.sliceFill {
        case .filled: return AnyShapeStyle(restingFill)
        case .glass: return AnyShapeStyle(LinearGradient(colors: [restingFill, restingFill.opacity(0.25)], startPoint: .top, endPoint: .bottom))
        case .outline: return AnyShapeStyle(Color.clear)
        }
    }

    private func showsIcon(_ count: Int) -> Bool {
        switch style.labels {
        case .auto: return model.mode != .convert || count > 6
        case .iconsAndText, .iconsOnly: return true
        case .textOnly: return false
        }
    }

    @ViewBuilder
    private func sliceView(_ i: Int, _ slice: WheelSlice, _ geo: WheelGeometry) -> some View {
        let count = model.slices.count
        let hovered = model.hover == .slice(i)
        let center = CGPoint(x: geo.diameter / 2, y: geo.diameter / 2)
        let lp = geo.labelPoint(i, count: count, center: center)
        let k = geo.labelScale * CGFloat(style.labelScale)
        let hot = hovered && slice.isEnabled
        let outline = style.sliceFill == .outline

        ZStack {
            WedgeShape(index: i, count: count, geo: geo)
                .fill(fill(hovered: hovered, enabled: slice.isEnabled))
            WedgeShape(index: i, count: count, geo: geo)
                .stroke(outline ? (hot ? accent : accent.opacity(0.55)) : Color.white.opacity(hovered ? 0 : 0.35),
                        lineWidth: outline ? 1.5 : 0.75)

            VStack(spacing: 3 * k) {
                if showsIcon(count) {
                    Image(systemName: slice.action.symbol)
                        .font(.system(size: (style.labels == .iconsOnly ? 20 : 14) * k, weight: .medium))
                }
                if style.labels != .iconsOnly {
                    Text(style.uppercase ? slice.action.title.uppercased() : slice.action.title)
                        .font(.system(size: (model.mode != .convert || count > 6 ? 9.5 : 12) * k, weight: .bold))
                        .tracking(style.uppercase ? 0.6 : 0)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .foregroundStyle(hot ? Color.white : Color.primary.opacity(slice.isEnabled ? 0.85 : 0.3))
            .frame(width: (geo.outer - geo.inner) * 1.05)
            .position(lp)
            .help(slice.disabledReason ?? "")
        }
        .frame(width: geo.diameter, height: geo.diameter)
        .scaleEffect(hovered && !reduceMotion ? style.hoverScale : 1)
    }

    private func hub(_ geo: WheelGeometry) -> some View {
        let hot = model.hubActive
        let k = geo.labelScale * CGFloat(style.labelScale)
        let outline = style.sliceFill == .outline
        return VStack(spacing: 1) {
            Text(style.uppercase ? model.hubTitle.uppercased() : model.hubTitle)
                .font(.system(size: 11 * k, weight: .bold)).tracking(style.uppercase ? 0.5 : 0)
                .lineLimit(1).minimumScaleFactor(0.5)
            if let sub = model.hubSubtitle {
                Text(sub).font(.system(size: 8 * k, weight: .medium)).opacity(0.7).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(hot && !outline ? Color.white : (outline ? accent : Color.primary.opacity(0.85)))
        .frame(width: geo.hub * 2 - 14 * geo.labelScale)
        .frame(width: geo.hub * 2, height: geo.hub * 2)
        .background(Circle().fill(hot && !outline
                                  ? (style.hoverGradient ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(accent))
                                  : AnyShapeStyle(accent.opacity(outline ? 0.08 : 0.22))))
        .overlay(Circle().strokeBorder(outline ? accent.opacity(hot ? 1 : 0.55) : Color.white.opacity(0.4), lineWidth: outline ? 1.5 : 0.75))
        .scaleEffect(hot && !reduceMotion ? style.hoverScale + 0.01 : 1)
    }
}
