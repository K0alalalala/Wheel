import SwiftUI
import WheelCore

struct BackgroundStyle: Hashable {
    let colors: [NSColor]   // one color = solid

    static let gradients: [BackgroundStyle] = [
        .init(hex: 0xFFB347, 0xFF5A1F, 0xD6336C),
        .init(hex: 0xE0EAFC, 0xCFDEF3),
        .init(hex: 0xFAD0C4, 0xFFD1FF, 0xA1C4FD),
        .init(hex: 0xF6D365, 0xFDA085),
        .init(hex: 0xA18CD1, 0xFBC2EB),
        .init(hex: 0x43E97B, 0x38F9D7),
        .init(hex: 0x4FACFE, 0x00F2FE),
        .init(hex: 0x0F2027, 0x203A43, 0x2C5364),
    ]
    static let solids: [BackgroundStyle] = [
        .init(hex: 0xFFFFFF), .init(hex: 0xF5C542), .init(hex: 0x8BC34A), .init(hex: 0x2E9E5B),
        .init(hex: 0x1FA2A6), .init(hex: 0x3B82F6), .init(hex: 0x1F2937), .init(hex: 0x111111),
    ]

    init(colors: [NSColor]) { self.colors = colors }
    init(hex: Int...) {
        colors = hex.map { NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
    }

    var swatch: AnyShapeStyle {
        colors.count == 1
            ? AnyShapeStyle(Color(nsColor: colors[0]))
            : AnyShapeStyle(LinearGradient(colors: colors.map { Color(nsColor: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

struct BackgroundOptions {
    var style = BackgroundStyle.gradients[0]
    var padding: CGFloat = 160
    var corners: CGFloat = 40
    var shadow: CGFloat = 24
    var aspect: AspectRatio = .auto
}

enum BackgroundRenderer {
    /// Places the image on the background. Lengths are in pixels of `image`.
    static func render(_ image: CGImage, _ o: BackgroundOptions) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var cw = w + o.padding * 2, ch = h + o.padding * 2
        if let a = o.aspect.value {
            if cw / ch < a { cw = ch * a } else { ch = cw / a }
        }
        guard let ctx = ImageEngine.bitmap(width: Int(cw.rounded()), height: Int(ch.rounded())) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)

        if o.style.colors.count == 1 {
            ctx.setFillColor(o.style.colors[0].cgColor)
            ctx.fill(canvas)
        } else if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: o.style.colors.map(\.cgColor) as CFArray, locations: nil) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        }

        let imageRect = CGRect(x: (canvas.width - w) / 2, y: (canvas.height - h) / 2, width: w, height: h)
        let radius = min(o.corners, min(w, h) / 2)
        let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if o.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -o.shadow * 0.4), blur: o.shadow * 1.5, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: imageRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

struct AddBackgroundAction: FileAction {
    let id = "edit.background", title = "Add BG", symbol = "photo.on.rectangle", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let img = try LoadedImage(urls[0])
        return try await EditorWindow.present(title: "Add BG", size: CGSize(width: 400, height: 560)) { finish in
            AddBackgroundEditor(image: img, finish: finish)
        }
    }
}

struct AddBackgroundEditor: View {
    let image: LoadedImage
    let finish: EditorFinish

    @State private var options: BackgroundOptions
    @State private var preview: NSImage?
    @State private var busy = false
    @State private var custom = Color.orange
    private let small: CGImage

    init(image: LoadedImage, finish: @escaping EditorFinish) {
        self.image = image
        self.finish = finish
        small = image.full.preview(maxPixel: 700)
        // Default padding scales with the image so it looks the same on small and large files.
        var o = BackgroundOptions()
        let base = CGFloat(max(image.full.width, image.full.height))
        o.padding = (base * 0.08).rounded()
        o.corners = (base * 0.02).rounded()
        o.shadow = (base * 0.012).rounded()
        _options = State(initialValue: o)
    }

    private var maxLen: Double { Double(max(image.full.width, image.full.height)) }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let preview { Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
                else { Color.clear }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text("Background").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        swatchRow(BackgroundStyle.gradients)
                        HStack(spacing: 6) {
                            swatchRow(BackgroundStyle.solids)
                            ColorPicker("", selection: $custom, supportsOpacity: false).labelsHidden().controlSize(.mini)
                        }
                    }
                }
                LabeledSlider(title: "Padding", value: binding(\.padding), range: 0...maxLen * 0.5)
                LabeledSlider(title: "Corners", value: binding(\.corners), range: 0...maxLen * 0.2)
                LabeledSlider(title: "Shadow", value: binding(\.shadow), range: 0...maxLen * 0.06)
                HStack {
                    Text("Ratio").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: [.auto, .square, .wide, .fourFive, .tall, .threeFour], selection: $options.aspect) { $0.rawValue }
                }
            }
            .padding(.horizontal, 14)

            EditorFooter(primaryTitle: "Save with Background", busy: busy, onReset: reset, onPrimary: save)
        }
        .onAppear(perform: refresh)
        .onChange(of: custom) { _, c in options.style = BackgroundStyle(colors: [NSColor(c)]) }
        .onChange(of: options.style) { _, _ in refresh() }
        .onChange(of: options.padding) { _, _ in refresh() }
        .onChange(of: options.corners) { _, _ in refresh() }
        .onChange(of: options.shadow) { _, _ in refresh() }
        .onChange(of: options.aspect) { _, _ in refresh() }
    }

    private func binding(_ kp: WritableKeyPath<BackgroundOptions, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(options[keyPath: kp]) }, set: { options[keyPath: kp] = CGFloat($0) })
    }

    private func swatchRow(_ styles: [BackgroundStyle]) -> some View {
        HStack(spacing: 6) {
            ForEach(styles, id: \.self) { s in
                RoundedRectangle(cornerRadius: 6)
                    .fill(s.swatch)
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.accent, lineWidth: 2).padding(-3).opacity(options.style == s ? 1 : 0))
                    .onTapGesture { options.style = s }
            }
        }
    }

    private func refresh() {
        let s = CGFloat(small.width) / CGFloat(image.full.width)
        var o = options
        o.padding *= s; o.corners *= s; o.shadow *= s
        if let img = BackgroundRenderer.render(small, o) { preview = NSImage(cgImage: img) }
    }

    private func reset() {
        let keep = options.style
        let base = CGFloat(maxLen)
        options = BackgroundOptions(style: keep, padding: (base * 0.08).rounded(), corners: (base * 0.02).rounded(),
                                    shadow: (base * 0.012).rounded(), aspect: .auto)
    }

    private func save() {
        busy = true
        let full = image.full, o = options, url = image.url
        Task {
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    guard let r = BackgroundRenderer.render(full, o) else { throw ActionError("Couldn't render background.") }
                    return r
                }.value
                finish(.success([try await saveEdited(rendered, source: url, suffix: "With Background", format: .png)]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
