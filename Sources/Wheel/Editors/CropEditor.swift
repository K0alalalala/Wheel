import SwiftUI
import WheelCore

enum AspectRatio: String, CaseIterable, Identifiable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", fourThree = "4:3", threeFour = "3:4", fourFive = "4:5"
    case auto = "Auto"
    var id: String { rawValue }

    var value: CGFloat? {
        switch self {
        case .free, .auto: return nil
        case .square: return 1
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        case .fourThree: return 4 / 3
        case .threeFour: return 3 / 4
        case .fourFive: return 4 / 5
        }
    }
}

struct CropAction: FileAction {
    let id = "edit.crop", title = "Crop", symbol = "crop", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let img = try LoadedImage(urls[0])
        return try await EditorWindow.present(title: "Crop Image", size: CGSize(width: 380, height: 500)) { finish in
            CropEditor(image: img, finish: finish)
        }
    }
}

struct CropEditor: View {
    let image: LoadedImage
    let finish: EditorFinish

    @State private var crop: CGRect
    @State private var aspect: AspectRatio = .free
    @State private var busy = false
    @State private var dragStart: CGRect?

    init(image: LoadedImage, finish: @escaping EditorFinish) {
        self.image = image
        self.finish = finish
        _crop = State(initialValue: CGRect(origin: .zero, size: image.full.size))
    }

    private var bounds: CGRect { CGRect(origin: .zero, size: image.full.size) }

    var body: some View {
        VStack(spacing: 10) {
            ImageCanvas(image: image.preview, pixelSize: image.full.size) { m in
                cropOverlay(m)
            }
            .background(Color.black.opacity(0.06))

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Aspect ratio").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: [.free, .square, .wide, .tall, .fourThree, .threeFour], selection: $aspect) { $0.rawValue }
                }
                HStack(spacing: 8) {
                    dimensionField("W", value: Binding(get: { Int(crop.width.rounded()) }, set: { setSize(width: CGFloat($0)) }))
                    dimensionField("H", value: Binding(get: { Int(crop.height.rounded()) }, set: { setSize(height: CGFloat($0)) }))
                    Text("px").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)

            EditorFooter(primaryTitle: "Apply", primaryEnabled: crop.width >= 1 && crop.height >= 1, busy: busy,
                         onReset: { aspect = .free; crop = bounds }, onPrimary: apply)
        }
        .onChange(of: aspect) { _, a in applyAspect(a) }
    }

    private func dimensionField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 70).controlSize(.small)
        }
    }

    // MARK: Overlay

    private enum Handle: CaseIterable { case tl, t, tr, r, br, b, bl, l }

    @ViewBuilder
    private func cropOverlay(_ m: ImageMapper) -> some View {
        let r = m.toView(crop)
        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { p in
                p.addRect(m.rect)
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Theme.accent, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: r.width, height: r.height)
                .offset(x: r.minX, y: r.minY)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let start = dragStart ?? crop
                    dragStart = start
                    var n = start.offsetBy(dx: g.translation.width / m.scale, dy: g.translation.height / m.scale)
                    n.origin.x = min(max(n.minX, 0), bounds.width - n.width)
                    n.origin.y = min(max(n.minY, 0), bounds.height - n.height)
                    crop = n
                }.onEnded { _ in dragStart = nil })

            ForEach(Handle.allCases, id: \.self) { h in
                let p = point(of: h, in: r)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent)
                    .frame(width: isCorner(h) ? 10 : 8, height: isCorner(h) ? 10 : 8)
                    .padding(6).contentShape(Rectangle())
                    .position(p)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let start = dragStart ?? crop
                        dragStart = start
                        crop = resized(start, handle: h, by: CGSize(width: g.translation.width / m.scale, height: g.translation.height / m.scale))
                    }.onEnded { _ in dragStart = nil })
            }
        }
    }

    private func isCorner(_ h: Handle) -> Bool { [.tl, .tr, .br, .bl].contains(h) }

    private func point(of h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .tl: return CGPoint(x: r.minX, y: r.minY)
        case .t: return CGPoint(x: r.midX, y: r.minY)
        case .tr: return CGPoint(x: r.maxX, y: r.minY)
        case .r: return CGPoint(x: r.maxX, y: r.midY)
        case .br: return CGPoint(x: r.maxX, y: r.maxY)
        case .b: return CGPoint(x: r.midX, y: r.maxY)
        case .bl: return CGPoint(x: r.minX, y: r.maxY)
        case .l: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func resized(_ s: CGRect, handle h: Handle, by d: CGSize) -> CGRect {
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        if [.tl, .l, .bl].contains(h) { minX = min(max(0, minX + d.width), maxX - 8) }
        if [.tr, .r, .br].contains(h) { maxX = max(min(bounds.width, maxX + d.width), minX + 8) }
        if [.tl, .t, .tr].contains(h) { minY = min(max(0, minY + d.height), maxY - 8) }
        if [.bl, .b, .br].contains(h) { maxY = max(min(bounds.height, maxY + d.height), minY + 8) }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let a = aspect.value else { return r }

        // Keep the ratio, anchored on the opposite side of the handle.
        let horizontalDriven = [.l, .r].contains(h) || ([.tl, .tr, .bl, .br].contains(h) && abs(d.width) >= abs(d.height))
        if horizontalDriven { r.size.height = r.width / a } else { r.size.width = r.height * a }
        if [.tl, .t, .tr].contains(h) { r.origin.y = maxY - r.height }
        if [.tl, .l, .bl].contains(h) { r.origin.x = maxX - r.width }
        if [.t, .b].contains(h) { r.origin.x = s.midX - r.width / 2 }
        if [.l, .r].contains(h) { r.origin.y = s.midY - r.height / 2 }
        return fitted(r, ratio: a)
    }

    /// Shrinks a rect (keeping its ratio and centre) until it lies inside the image.
    private func fitted(_ r: CGRect, ratio a: CGFloat) -> CGRect {
        var r = r
        let maxW = min(bounds.width, bounds.height * a)
        if r.width > maxW { r.size = CGSize(width: maxW, height: maxW / a) }
        r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
        r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
        return r
    }

    private func applyAspect(_ a: AspectRatio) {
        guard let ratio = a.value else { return }
        // Largest rect of this ratio centred on the current crop.
        var w = min(bounds.width, bounds.height * ratio)
        var h = w / ratio
        if crop.width / crop.height > ratio { h = min(crop.height, h); w = h * ratio } else { w = min(crop.width, w); h = w / ratio }
        crop = fitted(CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h), ratio: ratio)
    }

    private func setSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        var r = crop
        if let width { r.size.width = min(max(1, width), bounds.width); if let a = aspect.value { r.size.height = r.width / a } }
        if let height { r.size.height = min(max(1, height), bounds.height); if let a = aspect.value { r.size.width = r.height * a } }
        if let a = aspect.value { r = fitted(r, ratio: a) }
        r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
        r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
        crop = r
    }

    private func apply() {
        busy = true
        Task {
            do {
                guard let out = ImageEngine.crop(image.full, to: crop) else { throw ActionError("Crop failed.") }
                finish(.success([try await saveEdited(out, source: image.url, suffix: "Cropped")]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
