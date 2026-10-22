#if DEBUG
import AppKit
import PDFKit
import SwiftUI
import WheelCore

/// Renders the README screenshots: `Wheel --readme-shots <dir>` (or `make screenshots`).
///
/// Everything is synthetic: sample photos and a report are generated, settings come from a
/// throwaway defaults suite, and nothing from the user's screen or files appears.
@MainActor
enum ReadmeShots {
    static func run(to dir: URL) {
        Glass.renderStandIn = (disc: Color.black.opacity(0.28), panel: Color(white: 0.965).opacity(0.97))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let samples = FileManager.default.temporaryDirectory.appendingPathComponent("WheelReadmeSamples-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: samples) }

        do {
            let lake = try Samples.photo(samples.appendingPathComponent("Lake Sunset.jpg"), palette: .sunset)
            let peaks = try Samples.photo(samples.appendingPathComponent("Mountain Morning.jpg"), palette: .morning)
            let dusk = try Samples.photo(samples.appendingPathComponent("Blue Hour.jpg"), palette: .dusk)
            let report = try Samples.report(samples.appendingPathComponent("Quarterly Report.pdf"))

            // Hero: dragging a PDF onto "JPG".
            render(Hero(file: report), size: CGSize(width: 1200, height: 720), to: dir.appendingPathComponent("hero.png"))

            // The three wheels.
            render(WheelScene(urls: [lake], mode: .edit, hover: 5), size: CGSize(width: 560, height: 560),
                   to: dir.appendingPathComponent("wheel-edit.png"))
            render(WheelScene(urls: [report], mode: .edit, hover: 0), size: CGSize(width: 560, height: 560),
                   to: dir.appendingPathComponent("wheel-pdf.png"))
            render(WheelScene(urls: [report, lake, peaks], mode: .combine, hover: 0), size: CGSize(width: 560, height: 560),
                   to: dir.appendingPathComponent("wheel-combine.png"))

            // Presets.
            render(PresetStrip(file: lake), size: CGSize(width: 1900, height: 470), to: dir.appendingPathComponent("presets.png"))

            // Editors.
            let photo = try LoadedImage(lake)
            editor("Crop Image", CGSize(width: 380, height: 500), dir, "editor-crop.png") {
                CropEditor(image: photo, finish: { _ in })
            }
            editor("Add BG", CGSize(width: 400, height: 560), dir, "editor-background.png") {
                AddBackgroundEditor(image: photo, finish: { _ in })
            }
            let doc = try PDFTools.open(report)
            editor("Organize Pages", CGSize(width: 600, height: 520), dir, "editor-organize.png") {
                PageGridEditor(source: report, doc: doc, mode: .organize, finish: { _ in })
            }
            editor("Watermark", CGSize(width: 420, height: 600), dir, "editor-watermark.png") {
                WatermarkEditor(source: report, doc: doc, finish: { _ in })
            }
            let tools = ActionRegistry.shared.allActions(for: .pdf, mode: .edit).filter { $0.id != "pdf.tools" && $0.supports(report) }
            editor("PDF Tools", CGSize(width: 560, height: 520), dir, "editor-pdf-tools.png") {
                PDFLauncher(tools: tools, fileCount: 1, pick: { _ in })
            }
            editor("Combine into PDF", CGSize(width: 420, height: 440), dir, "editor-combine.png") {
                OrderedFilesEditor(files: [report, lake, peaks, dusk], defaultName: "Combined", ext: "pdf", primary: "Combine",
                                   options: { CombinePDFOptions() }, finish: { _ in }) { _, _, _ in report }
            }
            let frames = try [lake, peaks, dusk].map { try ImageEngine.load($0, maxPixel: 1200) }
            editor("Make GIF", CGSize(width: 420, height: 520), dir, "editor-gif.png") {
                GIFEditor(files: [lake, peaks, dusk], images: frames, finish: { _ in })
            }

            render(ToastScene(), size: CGSize(width: 760, height: 250), to: dir.appendingPathComponent("toast.png"))
            render(MockWindow(title: "Wheel Settings") { AppearanceSettings() }, size: CGSize(width: 980, height: 800),
                   to: dir.appendingPathComponent("settings-appearance.png"), wait: 1.2)
            print("README screenshots written to \(dir.path)")
        } catch {
            print("README screenshots failed: \(error)")
        }
    }

    // MARK: Rendering

    private static func editor<V: View>(_ title: String, _ size: CGSize, _ dir: URL, _ name: String, @ViewBuilder _ content: () -> V) {
        let margin: CGFloat = 70
        let view = ZStack {
            Wallpaper()
            EditorChrome(title: title, onClose: {}) { content() }
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
        }
        render(view, size: CGSize(width: size.width + margin * 2, height: size.height + margin * 2), to: dir.appendingPathComponent(name), wait: 1.0)
    }

    /// JPEG (the gradient wallpaper makes PNGs huge), at most 1800 px wide: sharp on retina at README width.
    private static func save(_ rep: NSBitmapImageRep, to url: URL) {
        var out = rep
        if rep.pixelsWide > 1800, let cg = rep.cgImage {
            let k = 1800 / CGFloat(rep.pixelsWide)
            let w = 1800, h = Int(CGFloat(rep.pixelsHigh) * k)
            if let ctx = ImageEngine.bitmap(width: w, height: h) {
                ctx.interpolationQuality = .high
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let small = ctx.makeImage() { out = NSBitmapImageRep(cgImage: small) }
            }
        }
        let jpg = url.deletingPathExtension().appendingPathExtension("jpg")
        try? out.representation(using: .jpeg, properties: [.compressionFactor: 0.86])?.write(to: jpg)
    }

    /// Lays the view out in an offscreen window, lets async content load, and saves it as a PNG at screen scale.
    static func render<V: View>(_ view: V, size: CGSize, to url: URL, wait: TimeInterval = 0.6) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .light))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            save(rep, to: url)
        }
        window.orderOut(nil)
    }
}

// MARK: - Scenes

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.42), Color(red: 1, green: 0.37, blue: 0.38),
                                    Color(red: 0.56, green: 0.33, blue: 0.91)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.18, y: 0.12), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.31, green: 0.67, blue: 1).opacity(0.5), .clear],
                           center: UnitPoint(x: 0.92, y: 0.95), startRadius: 0, endRadius: 600)
        }
    }
}

@MainActor
private func model(_ urls: [URL], mode: WheelMode, hover: Int?, style: WheelStyle? = nil) -> WheelModel {
    let m = WheelModel()
    m.styleOverride = style
    m.load(urls)
    m.mode = mode
    m.rebuild()
    if let hover { m.hover = hover < 0 ? .hub : .slice(hover) }
    m.visible = true
    return m
}

private struct WheelScene: View {
    let urls: [URL]
    let mode: WheelMode
    let hover: Int?
    var body: some View {
        ZStack {
            Wallpaper()
            // Default look, just larger so labels read well in the README.
            WheelView(model: model(urls, mode: mode, hover: hover, style: { var s = WheelStyle(); s.size = 1.6; return s }()))
        }
    }
}

/// A PDF on the "desktop" being dragged onto the JPG slice, with Finder's name pill and copy badge.
private struct Hero: View {
    let file: URL
    var body: some View {
        let m = model([file], mode: .convert, hover: 0, style: { var s = WheelStyle(); s.size = 1.45; return s }())
        let geo = m.geo
        let target = -(geo.inner + geo.outer) / 2   // y of the JPG label, relative to centre
        ZStack {
            Wallpaper()
            // The original file, still on the desktop.
            fileIcon(dimmed: true).offset(x: -440, y: -40)
            WheelView(model: m).offset(x: 60)
            // The copy being dragged: cursor inside the JPG slice, file icon trailing above it like Finder.
            fileIcon(dimmed: false)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green).offset(x: 10, y: -18)
                }
                .opacity(0.9)
                .offset(x: 60 + 34, y: target - 112)
            Image(nsImage: NSCursor.arrow.image).offset(x: 60 + 52, y: target - 34)
        }
    }

    private func fileIcon(dimmed: Bool) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable().frame(width: 76, height: 76)
                .opacity(dimmed ? 0.55 : 1)
            Text(file.lastPathComponent).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(dimmed ? Color.black.opacity(0.25) : Color.blue))
        }
    }
}

private struct PresetStrip: View {
    let file: URL
    var body: some View {
        let picks: [(StylePreset, Int)] = [(.classic, 1), (.neon, 3), (.liquid, 0), (.terminal, 2), (.bubblegum, 4)]
        ZStack {
            Wallpaper()
            HStack(spacing: 6) {
                ForEach(picks, id: \.0) { preset, hover in
                    VStack(spacing: 2) {
                        WheelView(model: model([file], mode: preset == .terminal || preset == .classic ? .convert : .edit,
                                               hover: hover, style: preset.style))
                            .scaleEffect(1.08)
                            .frame(width: 360, height: 380)
                        Text(preset.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.3), radius: 3)
                    }
                }
            }
        }
    }
}

private struct ToastScene: View {
    var body: some View {
        let working = ToastModel(), done = ToastModel()
        working.title = "Converting to JPG"; working.subtitle = "3 of 8 saved"; working.progress = 0.42; working.state = .working
        done.title = "Saved Quarterly Report.jpg"; done.subtitle = "Click to show in Finder"; done.state = .done
        return ZStack {
            Wallpaper()
            HStack(spacing: 40) {
                ToastView(model: working).shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                ToastView(model: done).shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            }
        }
    }
}

/// A plain macOS-style window frame for content that normally lives in a titled window.
private struct MockWindow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            Wallpaper()
            VStack(spacing: 0) {
                ZStack {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 12, height: 12)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: 30)
                Divider()
                content
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.3), radius: 24, y: 12)
            .padding(50)
        }
    }
}

// MARK: - Sample files

private enum Samples {
    enum Palette { case sunset, morning, dusk }

    /// A simple generated landscape: sky, sun, layered hills and a lake reflection.
    static func photo(_ url: URL, palette: Palette) throws -> URL {
        let w = 2400, h = 1600
        guard let ctx = ImageEngine.bitmap(width: w, height: h) else { throw ActionError("No memory") }
        let (top, horizon, sun, hills): (NSColor, NSColor, NSColor, [NSColor]) = {
            switch palette {
            case .sunset: return (NSColor(srgbRed: 0.98, green: 0.55, blue: 0.35, alpha: 1), NSColor(srgbRed: 1, green: 0.83, blue: 0.55, alpha: 1),
                                  NSColor(srgbRed: 1, green: 0.95, blue: 0.75, alpha: 1),
                                  [NSColor(srgbRed: 0.62, green: 0.32, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.42, green: 0.2, blue: 0.38, alpha: 1)])
            case .morning: return (NSColor(srgbRed: 0.45, green: 0.72, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.88, green: 0.95, blue: 1, alpha: 1),
                                   NSColor(srgbRed: 1, green: 1, blue: 0.9, alpha: 1),
                                   [NSColor(srgbRed: 0.42, green: 0.62, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.22, green: 0.42, blue: 0.38, alpha: 1)])
            case .dusk: return (NSColor(srgbRed: 0.12, green: 0.15, blue: 0.38, alpha: 1), NSColor(srgbRed: 0.45, green: 0.42, blue: 0.75, alpha: 1),
                                NSColor(srgbRed: 0.98, green: 0.9, blue: 0.85, alpha: 1),
                                [NSColor(srgbRed: 0.25, green: 0.22, blue: 0.45, alpha: 1), NSColor(srgbRed: 0.12, green: 0.1, blue: 0.25, alpha: 1)])
            }
        }()
        let horizonY = CGFloat(h) * 0.38
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [horizon.cgColor, top.cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: horizonY), end: CGPoint(x: 0, y: CGFloat(h)), options: [.drawsAfterEndLocation])
        ctx.setFillColor(sun.cgColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(w) * 0.62, y: horizonY + 180, width: 260, height: 260))
        for (i, color) in hills.enumerated() {
            ctx.setFillColor(color.cgColor)
            ctx.move(to: CGPoint(x: 0, y: horizonY))
            for x in stride(from: 0, through: w, by: 40) {
                let fx = CGFloat(x) / CGFloat(w)
                let y = horizonY + CGFloat(120 + i * 70) * (0.6 + 0.4 * sin(fx * .pi * CGFloat(2 + i) + CGFloat(i)))
                ctx.addLine(to: CGPoint(x: CGFloat(x), y: y))
            }
            ctx.addLine(to: CGPoint(x: CGFloat(w), y: horizonY))
            ctx.closePath(); ctx.fillPath()
        }
        // Lake: a darker, mirrored band below the horizon.
        let lake = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [hills[1].cgColor, horizon.withAlphaComponent(0.9).cgColor] as CFArray, locations: nil)!
        ctx.drawLinearGradient(lake, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: horizonY), options: [])
        ctx.setFillColor(sun.withAlphaComponent(0.35).cgColor)
        for k in 0..<6 { ctx.fill(CGRect(x: CGFloat(w) * 0.62 + CGFloat(k * 18), y: horizonY - CGFloat(40 + k * 45), width: 260 - CGFloat(k * 36), height: 10)) }
        try ImageEngine.write(ctx.makeImage()!, to: url, format: .jpg, quality: 0.9)
        return url
    }

    /// A six-page mock report with real text, coloured headers and placeholder lines.
    static func report(_ url: URL) throws -> URL {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ActionError("No PDF") }
        let titles = ["Overview", "Revenue", "Customers", "Product", "Team", "Outlook"]
        for (i, title) in titles.enumerated() {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSColor(hue: CGFloat(i) / 7 + 0.02, saturation: 0.5, brightness: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 54, y: 560, width: 504, height: 170), xRadius: 14, yRadius: 14).fill()
            ("Quarterly Report" as NSString).draw(at: NSPoint(x: 72, y: 690), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.6)])
            ("\(i + 1). \(title)" as NSString).draw(at: NSPoint(x: 72, y: 600), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34)])
            for l in 0..<16 {
                NSColor(white: 0.86, alpha: 1).setFill()
                NSRect(x: 72, y: 500 - l * 26, width: 468 - (l % 4) * 55, height: 9).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
#endif
