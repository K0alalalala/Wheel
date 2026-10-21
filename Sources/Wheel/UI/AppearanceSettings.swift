import SwiftUI
import UniformTypeIdentifiers
import WheelCore

/// Live preview + every style knob + presets + theme files.
struct AppearanceSettings: View {
    @ObservedObject private var settings = Settings.shared
    @StateObject private var preview = PreviewWheel()
    @State private var backdrop = Backdrop.sunset
    @State private var message: String?

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .frame(width: 270)
            Divider()
            Form {
                presets
                sizeAndShape
                colour
                labels
                motion
                themeFiles
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        VStack(spacing: 10) {
            ZStack {
                backdrop.view
                GeometryReader { g in
                    let geo = preview.model.geo
                    let side = geo.diameter * CGFloat(settings.style.hoverScale) + 20
                    let fit = min(1, min(g.size.width, g.size.height) / side)
                    WheelView(model: preview.model, blending: .withinWindow)
                        .scaleEffect(fit)
                        .frame(width: g.size.width, height: g.size.height)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p):
                                // Undo the fit scale to hit-test in wheel coordinates.
                                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                                let q = CGPoint(x: c.x + (p.x - c.x) / fit, y: c.y + (p.y - c.y) / fit)
                                preview.hover(at: q, center: c)
                            case .ended:
                                preview.endHover()
                            }
                        }
                }
            }
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Picker("", selection: $preview.kind) {
                    Text("Image").tag(FileKind.image)
                    Text("PDF").tag(FileKind.pdf)
                    Text("Doc").tag(FileKind.document)
                    Text("Video").tag(FileKind.video)
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            HStack {
                Button(preview.model.mode == .convert ? "Show Edit" : "Show Convert") { preview.model.toggleMode() }
                Spacer()
                Button("Replay") { preview.replay() }
            }
            .buttonStyle(SubtleButtonStyle())
            Picker("Backdrop", selection: $backdrop) {
                ForEach(Backdrop.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Text("Hover the preview to try it.").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(14)
        .onChange(of: settings.style) { _, _ in preview.model.rebuild() }
    }

    // MARK: Sections

    private var presets: some View {
        Section("Presets") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(StylePreset.allCases) { preset in
                    Button {
                        withAnimation { settings.style = preset.style }
                        preview.replay()
                    } label: {
                        VStack(spacing: 4) {
                            Circle().fill(Color(nsColor: preset.style.accentNS).gradient)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.white.opacity(0.5)))
                            Text(preset.title).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(settings.style == preset.style ? 0.14 : 0.05)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sizeAndShape: some View {
        Section("Size & shape") {
            slider("Wheel size", \.size, 0.6...1.8, format: { "\(Int(($0 * 100).rounded()))%" })
            slider("Hub size", \.hubRatio, 0.25...0.6, format: { "\(Int(($0 * 100).rounded()))%" })
            slider("Slice gap", \.sliceGap, 0...16, format: { "\(Int($0)) pt" })
            slider("Roundness", \.roundness, 0...40, format: { "\(Int($0)) pt" })
            slider("Rotation", \.rotation, -180...180, step: 5, format: { "\(Int($0))°" })
            Stepper("Max slices: \(settings.style.maxSlices)", value: $settings.style.maxSlices, in: 3...10)
        }
    }

    private var colour: some View {
        Section("Colour & material") {
            Picker("Highlight", selection: $settings.style.accent) {
                ForEach(AccentChoice.allCases) { Text($0.title).tag($0) }
            }
            if settings.style.accent == .custom {
                ColorPicker("Custom highlight", selection: rgba(\.customAccent), supportsOpacity: false)
            }
            if settings.style.accent == .system {
                Text("Follows System Settings → Appearance → Accent color.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Glass", selection: $settings.style.material) {
                ForEach(GlassMaterial.allCases) { Text($0.title).tag($0) }
            }
            ColorPicker("Glass tint", selection: rgba(\.discTint), supportsOpacity: true)
            Picker("Slices", selection: $settings.style.sliceFill) {
                ForEach(SliceFill.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if settings.style.sliceFill != .outline {
                slider("Slice opacity", \.sliceOpacity, 0.05...1, format: { "\(Int(($0 * 100).rounded()))%" })
            }
            Toggle("Gradient highlight", isOn: $settings.style.hoverGradient)
            Toggle("Rim highlight", isOn: $settings.style.rimHighlight)
            Toggle("Drop shadow", isOn: $settings.style.dropShadow)
        }
    }

    private var labels: some View {
        Section("Labels") {
            Picker("Show", selection: $settings.style.labels) {
                ForEach(LabelMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Font", selection: $settings.style.font) {
                ForEach(LabelFont.allCases) { Text($0.title).font(.system(size: 13, design: $0.design)).tag($0) }
            }
            slider("Text size", \.labelScale, 0.7...1.6, format: { "\(Int(($0 * 100).rounded()))%" })
            Toggle("ALL CAPS", isOn: $settings.style.uppercase)
        }
    }

    private var motion: some View {
        Section("Motion & feel") {
            Picker("Appear", selection: $settings.style.appear) {
                ForEach(AppearAnimation.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: settings.style.appear) { _, _ in preview.replay() }
            slider("Hover zoom", \.hoverScale, 1...1.2, format: { "+\(Int((($0 - 1) * 100).rounded()))%" })
            slider("Bounciness", \.springiness, 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
            Toggle("Haptic ticks on trackpad", isOn: $settings.style.haptics)
            Text("Animations are skipped when System Settings → Accessibility → Reduce motion is on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var themeFiles: some View {
        Section {
            HStack {
                Button("Export Theme…", action: exportTheme)
                Button("Import Theme…", action: importTheme)
                Spacer()
                Button("Reset Everything", role: .destructive) {
                    settings.resetLook()
                    preview.replay()
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Theme files")
        } footer: {
            Text("A .wheeltheme file holds the look, hub and toast behaviour, and slice order. Share it, or keep a few to switch between.")
        }
    }

    // MARK: Helpers

    private func slider(_ title: String, _ kp: WritableKeyPath<WheelStyle, Double>, _ range: ClosedRange<Double>,
                        step: Double? = nil, format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack {
                if let step {
                    Slider(value: $settings.style[dynamicMember: kp], in: range, step: step)
                } else {
                    Slider(value: $settings.style[dynamicMember: kp], in: range)
                }
                Text(format(settings.style[keyPath: kp])).monospacedDigit().frame(width: 50, alignment: .trailing)
            }
        }
    }

    private func rgba(_ kp: WritableKeyPath<WheelStyle, RGBA>) -> Binding<Color> {
        Binding(get: { settings.style[keyPath: kp].color },
                set: { settings.style[keyPath: kp] = RGBA(NSColor($0)) })
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wheelTheme]
        panel.nameFieldStringValue = "My Wheel.wheeltheme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(settings.profile).write(to: url)
            message = "Saved \(url.lastPathComponent)."
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wheelTheme, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 256_000 else { throw ActionError("That file is too big to be a theme.") }
            settings.apply(try JSONDecoder().decode(WheelProfile.self, from: data))
            preview.replay()
            message = "Loaded \(url.lastPathComponent)."
        } catch {
            message = "Not a Wheel theme: \(error.localizedDescription)"
        }
    }
}

extension UTType {
    static let wheelTheme = UTType(exportedAs: "io.github.k0alalalala.wheel.theme", conformingTo: .json)
}

/// Demo state for the Settings preview: fake files, mouse hover, replayable appear animation.
@MainActor
final class PreviewWheel: ObservableObject {
    let model = WheelModel()
    @Published var kind: FileKind = .image { didSet { load() } }
    private var hubTimer: Timer?

    init() {
        load()
        model.visible = true
    }

    private func load() {
        let ext = ["image": "jpg", "pdf": "pdf", "document": "docx", "video": "mov"][kind.rawValue] ?? "jpg"
        let mode = model.mode
        model.reset()
        model.load([URL(fileURLWithPath: "/Preview/Example.\(ext)")])
        if model.mode != mode, !ActionRegistry.shared.slices(for: model.urls, mode: mode).isEmpty { model.toggleMode() }
        model.visible = true
    }

    func hover(at p: CGPoint, center: CGPoint) {
        let hit = model.geo.hit(p, center: center, count: model.slices.count)
        guard hit != model.hover else { return }
        model.hover = hit
        hubTimer?.invalidate()
        if hit == .hub, Settings.shared.hubSwitch.usesHover {
            hubTimer = Timer.scheduledTimer(withTimeInterval: Settings.shared.hubHoverDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.model.hover == .hub else { return }
                    self.model.toggleMode()
                }
            }
        }
    }

    func endHover() {
        hubTimer?.invalidate()
        model.hover = .none
    }

    func replay() {
        model.visible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.model.visible = true }
    }
}

enum Backdrop: String, CaseIterable, Identifiable {
    case sunset, ocean, forest, dark, light
    var id: String { rawValue }

    @ViewBuilder var view: some View {
        switch self {
        case .sunset: LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ocean: LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .forest: LinearGradient(colors: [.mint, .green, Color(red: 0.05, green: 0.3, blue: 0.2)], startPoint: .top, endPoint: .bottom)
        case .dark: Color(white: 0.12)
        case .light: Color(white: 0.93)
        }
    }
}
