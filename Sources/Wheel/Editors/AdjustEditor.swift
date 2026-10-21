import CoreImage
import WheelCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct AdjustAction: FileAction {
    let id = "edit.adjust", title = "Edit", symbol = "slider.horizontal.3", mode = WheelMode.edit
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let img = try LoadedImage(urls[0])
        return try await EditorWindow.present(title: "Edit Image", size: CGSize(width: 380, height: 520)) { finish in
            AdjustEditor(image: img, finish: finish)
        }
    }
}

struct Adjustments: Equatable {
    var brightness = 0.0    // -0.5...0.5
    var contrast = 1.0      // 0.5...1.5
    var saturation = 1.0    // 0...2
    var quarterTurns = 0    // clockwise
    var flipH = false
    var flipV = false

    var isIdentity: Bool { self == Adjustments() }

    func apply(to image: CGImage) -> CGImage? {
        var ci = CIImage(cgImage: image)
        let f = CIFilter.colorControls()
        f.inputImage = ci
        f.brightness = Float(brightness)
        f.contrast = Float(contrast)
        f.saturation = Float(saturation)
        ci = f.outputImage ?? ci

        var t = CGAffineTransform.identity
        if flipH { t = t.scaledBy(x: -1, y: 1) }
        if flipV { t = t.scaledBy(x: 1, y: -1) }
        t = t.rotated(by: -CGFloat(quarterTurns % 4) * .pi / 2)
        ci = ci.transformed(by: t)
        ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        return ImageEngine.ciContext.createCGImage(ci, from: ci.extent.integral, format: .RGBA8,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}

struct AdjustEditor: View {
    let image: LoadedImage
    let finish: EditorFinish

    @State private var adj = Adjustments()
    @State private var preview: NSImage
    @State private var busy = false
    private let small: CGImage

    init(image: LoadedImage, finish: @escaping EditorFinish) {
        self.image = image
        self.finish = finish
        small = image.full.preview(maxPixel: 900)
        _preview = State(initialValue: image.preview)
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 14)

            VStack(spacing: 8) {
                LabeledSlider(title: "Brightness", value: $adj.brightness, range: -0.5...0.5, unit: "", format: signedPercent(scale: 200))
                LabeledSlider(title: "Contrast", value: $adj.contrast, range: 0.5...1.5, unit: "", format: { signedPercent(scale: 200)($0 - 1) })
                LabeledSlider(title: "Saturation", value: $adj.saturation, range: 0...2, unit: "", format: { signedPercent(scale: 100)($0 - 1) })
                HStack(spacing: 6) {
                    iconButton("rotate.left", "Rotate left") { adj.quarterTurns = (adj.quarterTurns + 3) % 4 }
                    iconButton("rotate.right", "Rotate right") { adj.quarterTurns = (adj.quarterTurns + 1) % 4 }
                    iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontal") { adj.flipH.toggle() }
                    iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertical") { adj.flipV.toggle() }
                    Spacer()
                }
            }
            .padding(.horizontal, 14)

            EditorFooter(primaryTitle: "Save", primaryEnabled: !adj.isIdentity, busy: busy, onReset: { adj = Adjustments() }, onPrimary: save)
        }
        .onChange(of: adj) { _, a in
            if let img = a.apply(to: small) { preview = NSImage(cgImage: img) }
        }
    }

    private func signedPercent(scale: Double) -> (Double) -> String {
        { v in let p = Int((v * scale).rounded()); return p > 0 ? "+\(p)" : "\(p)" }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 22)
        }
        .buttonStyle(SubtleButtonStyle())
        .help(help)
    }

    private func save() {
        busy = true
        let full = image.full, a = adj, url = image.url
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    guard let r = a.apply(to: full) else { throw ActionError("Couldn't apply edits.") }
                    return r
                }.value
                finish(.success([try await saveEdited(out, source: url, suffix: "Edited")]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
