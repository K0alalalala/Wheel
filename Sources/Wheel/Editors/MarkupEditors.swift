import SwiftUI
import WheelCore

struct AnnotateAction: FileAction {
    let id = "edit.annotate", title = "Annotate", symbol = "pencil.tip.crop.circle", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let img = try LoadedImage(urls[0])
        return try await EditorWindow.present(title: "Annotate", size: CGSize(width: 440, height: 520)) { finish in
            MarkupEditor(image: img, redactOnly: false, finish: finish)
        }
    }
}

struct RedactAction: FileAction {
    let id = "edit.redact", title = "Redact", symbol = "eye.slash", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let img = try LoadedImage(urls[0])
        return try await EditorWindow.present(title: "Redact", size: CGSize(width: 440, height: 520)) { finish in
            MarkupEditor(image: img, redactOnly: true, finish: finish)
        }
    }
}

/// Annotate (pen, arrow, box, text) and Redact (black boxes) share one canvas.
/// Output is always a single flattened bitmap: nothing under a redaction survives.
struct MarkupEditor: View {
    enum Tool: String, CaseIterable { case pen, arrow, box, text }

    let image: LoadedImage
    let redactOnly: Bool
    let finish: EditorFinish

    @State private var marks: [Mark] = []
    @State private var live: Mark?
    @State private var tool: Tool = .pen
    @State private var color: Color = Color(nsColor: Theme.accentNS)
    @State private var width: Double = 1
    @State private var text = "Text"
    @State private var busy = false

    private static let palette: [NSColor] = [Theme.accentNS, .systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .white]

    /// Stroke width and text size scale with the image so marks look the same at any resolution.
    private var unit: CGFloat { CGFloat(max(image.full.width, image.full.height)) / 400 }

    var body: some View {
        VStack(spacing: 8) {
            if !redactOnly { toolbar }
            ImageCanvas(image: image.preview, pixelSize: image.full.size) { m in
                ZStack {
                    MarksOverlay(marks: marks + (live.map { [$0] } ?? []), mapper: m)
                    Color.white.opacity(0.001)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in dragChanged(m.clamp(m.toImage(g.startLocation)), m.clamp(m.toImage(g.location))) }
                            .onEnded { _ in if let l = live { marks.append(l) }; live = nil })
                }
                .onContinuousHover { phase in
                    if case .active = phase { (redactOnly || tool != .text ? NSCursor.crosshair : NSCursor.iBeam).set() }
                    else { NSCursor.arrow.set() }
                }
            }
            .background(Color.black.opacity(0.06))

            Text(redactOnly ? "Drag boxes over anything to hide. Pixels underneath are destroyed on save."
                            : "Drag on the image to draw. Text tool: click to place.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            EditorFooter(resetTitle: "Undo", primaryTitle: redactOnly ? "Save Redacted" : "Save", primaryEnabled: !marks.isEmpty,
                         busy: busy, onReset: { _ = marks.popLast() }, onPrimary: save)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            ChipPicker(options: Tool.allCases, selection: $tool) { $0.rawValue.capitalized }
            if tool == .text {
                TextField("Text", text: $text).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 80)
            }
            Spacer()
            ForEach(Self.palette, id: \.self) { c in
                Circle().fill(Color(nsColor: c)).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3).opacity(NSColor(color) == c ? 1 : 0))
                    .onTapGesture { color = Color(nsColor: c) }
            }
            Menu {
                Button("Thin") { width = 0.6 }; Button("Medium") { width = 1 }; Button("Thick") { width = 2 }
            } label: { Image(systemName: "lineweight") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 14)
    }

    private func dragChanged(_ start: CGPoint, _ p: CGPoint) {
        let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if redactOnly { live = .redact(rect); return }
        let c = NSColor(color), w = CGFloat(width) * unit * 1.5
        switch tool {
        case .pen:
            if case let .stroke(pts, _, _) = live { live = .stroke(pts + [p], c, w) } else { live = .stroke([start, p], c, w) }
        case .arrow: live = .arrow(start, p, c, w)
        case .box: live = .box(rect, c, w)
        case .text:
            guard !text.isEmpty else { return }
            let size = CGFloat(width) * unit * 9
            live = .text(text, CGPoint(x: p.x, y: p.y - size / 2), c, size)
        }
    }

    private func save() {
        busy = true
        let full = image.full, marks = self.marks, url = image.url, suffix = redactOnly ? "Redacted" : "Annotated"
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    guard let r = MarkRenderer.flatten(full, marks: marks) else { throw ActionError("Couldn't render image.") }
                    return r
                }.value
                // Re-encoding from raw pixels also drops all source metadata.
                finish(.success([try await saveEdited(out, source: url, suffix: suffix)]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
