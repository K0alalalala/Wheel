import SwiftUI
import UniformTypeIdentifiers
import WheelCore

// MARK: - Ordered files (To PDF, Join)

/// Extra controls shown under the file list of an `OrderedFilesEditor`.
protocol EditorOptions: ObservableObject {
    associatedtype Controls: View
    @ViewBuilder @MainActor func controls() -> Controls
}

final class NoOptions: EditorOptions {
    func controls() -> some View { EmptyView() }
}

final class CombinePDFOptions: EditorOptions {
    @Published var pageSize = CombineEngine.PageSize.original

    func controls() -> some View { CombinePDFControls(options: self) }
}

private struct CombinePDFControls: View {
    @ObservedObject var options: CombinePDFOptions
    var body: some View {
        HStack {
            Text("Image pages").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            ChipPicker(options: CombineEngine.PageSize.allCases, selection: $options.pageSize) { $0.title }
        }
    }
}

/// A reorderable list of the dropped files, an output name, and one button.
struct OrderedFilesEditor<Options: EditorOptions>: View {
    let defaultName: String
    let ext: String
    let primary: String
    let finish: EditorFinish
    let perform: ([URL], String, Options) async throws -> URL

    @State private var files: [URL]
    @State private var name: String
    @StateObject private var options: Options
    @State private var busy = false
    @State private var error: String?

    init(files: [URL], defaultName: String, ext: String, primary: String, options: @escaping () -> Options,
         finish: @escaping EditorFinish, perform: @escaping ([URL], String, Options) async throws -> URL) {
        self.defaultName = defaultName
        self.ext = ext
        self.primary = primary
        self.finish = finish
        self.perform = perform
        _files = State(initialValue: files)
        _name = State(initialValue: defaultName)
        _options = StateObject(wrappedValue: options())
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Drag to set the order").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("Sort") {
                    Button("Name") { files = byName(files) }
                    Button("Date modified") { files.sort { modified($0) < modified($1) } }
                    Button("Reverse") { files.reverse() }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 14)

            List {
                ForEach(Array(files.enumerated()), id: \.element) { i, url in
                    HStack(spacing: 8) {
                        Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { files.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Leave this file out")
                            .disabled(files.count <= 2)
                    }
                }
                .onMove { files.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)

            VStack(spacing: 8) {
                options.controls()
                HStack {
                    Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField(defaultName, text: $name).textFieldStyle(.roundedBorder)
                    Text(".\(ext)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .padding(.horizontal, 14)

            EditorFooter(primaryTitle: "\(primary) \(files.count) Files", primaryEnabled: files.count >= 2, busy: busy,
                         onReset: nil, onPrimary: save)
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func save() {
        busy = true
        error = nil
        let typed = ArchiveEngine.sanitized(name)
        let clean = typed.isEmpty ? defaultName : typed
        Task {
            do {
                finish(.success([try await perform(files, clean, options)]))
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Archive

struct ArchiveEditor: View {
    let items: [URL]
    let finish: EditorFinish
    @State private var format = ArchiveFormat.zip
    @State private var level = CompressionLevel.normal
    @State private var name = "Archive"
    @State private var busy = false
    @State private var error: String?
    @State private var size: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(items.count) items" + (size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                .font(.system(size: 13, weight: .semibold))
            Text(items.prefix(4).map(\.lastPathComponent).joined(separator: ", ") + (items.count > 4 ? ", …" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)

            HStack {
                Text("Format").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                ChipPicker(options: ArchiveFormat.allCases, selection: $format) { $0.title }
            }
            if let reason = format.unavailableReason {
                Label("Needs a free tool: \(reason)", systemImage: "wrench.and.screwdriver")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Text("Compression").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                ChipPicker(options: CompressionLevel.allCases, selection: $level) { $0.title }
            }
            HStack {
                Text("Name").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Archive", text: $name).textFieldStyle(.roundedBorder)
                Text(".\(format.ext)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
            EditorFooter(primaryTitle: "Create \(format.title)", primaryEnabled: format.unavailableReason == nil, busy: busy,
                         onReset: nil, onPrimary: save)
                .padding(.horizontal, -14)
        }
        .padding(.horizontal, 14)
        .task {
            let items = self.items
            size = await Task.detached { ArchiveEngine.totalSize(items) }.value
        }
    }

    private func save() {
        busy = true
        error = nil
        let items = self.items, format = self.format, level = self.level
        let name = ArchiveEngine.sanitized(self.name)
        Task {
            do {
                finish(.success([try await ArchiveEngine.archive(items, name: name, format: format, level: level)]))
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Stitch

struct StitchEditor: View {
    let files: [URL]
    let images: [CGImage]
    let finish: EditorFinish

    @State private var o = CombineEngine.StitchOptions()
    @State private var reversed = false
    @State private var background = Color.white
    @State private var format = ImageFormat.png
    @State private var preview: NSImage?
    @State private var busy = false
    private let small: [CGImage]

    init(files: [URL], images: [CGImage], finish: @escaping EditorFinish) {
        self.files = files
        self.images = images
        self.finish = finish
        small = images.map { $0.preview(maxPixel: 360) }
    }

    private var ordered: [CGImage] { reversed ? Array(images.reversed()) : images }

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let preview { Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
                else { ProgressView() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .background(Color.black.opacity(0.06))

            VStack(spacing: 8) {
                HStack {
                    Text("Layout").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: CombineEngine.StitchLayout.allCases, selection: $o.layout) { $0.rawValue.capitalized }
                }
                if o.layout == .grid {
                    Stepper("Columns: \(o.columns)", value: $o.columns, in: 1...max(images.count, 1)).font(.system(size: 12))
                }
                LabeledSlider(title: "Spacing", value: Binding(get: { Double(o.spacing) }, set: { o.spacing = CGFloat($0) }), range: 0...120)
                HStack {
                    Toggle("Match sizes", isOn: $o.matchSizes)
                    Toggle("Reverse order", isOn: $reversed)
                    Spacer()
                    ColorPicker("Background", selection: $background, supportsOpacity: true)
                }
                .font(.system(size: 12)).toggleStyle(.checkbox)
                HStack {
                    Text("Save as").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: [ImageFormat.png, .jpg, .heic], selection: $format) { $0.title }
                }
            }
            .padding(.horizontal, 14)
            EditorFooter(primaryTitle: "Stitch \(images.count) Images", busy: busy, onReset: nil, onPrimary: save)
        }
        .onAppear(perform: refresh)
        .onChange(of: o) { _, _ in refresh() }
        .onChange(of: reversed) { _, _ in refresh() }
        .onChange(of: background) { _, c in o.background = NSColor(c) }
    }

    private func refresh() {
        var p = o
        // Preview images are ~1/10 size: scale spacing to match.
        p.spacing = o.spacing * CGFloat(small[0].width) / CGFloat(images[0].width)
        let imgs = reversed ? Array(small.reversed()) : small
        preview = CombineEngine.stitch(imgs, p).map { NSImage(cgImage: $0) }
    }

    private func save() {
        busy = true
        let imgs = ordered, o = self.o, fmt = format, dir = files[0].deletingLastPathComponent()
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) { () -> URL in
                    guard let img = CombineEngine.stitch(imgs, o) else { throw ActionError("Couldn't stitch these images.") }
                    let out = OutputPath.unique(in: dir, base: "Stitched", ext: fmt.ext)
                    try ImageEngine.write(img, to: out, format: fmt, quality: 0.92)
                    return out
                }.value
                finish(.success([out]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}

// MARK: - GIF

struct GIFEditor: View {
    let files: [URL]
    let images: [CGImage]
    let finish: EditorFinish

    @State private var o = CombineEngine.GIFOptions()
    @State private var reversed = false
    @State private var busy = false
    private let frames: [NSImage]

    init(files: [URL], images: [CGImage], finish: @escaping EditorFinish) {
        self.files = files
        self.images = images
        self.finish = finish
        frames = images.map { NSImage(cgImage: $0.preview(maxPixel: 600)) }
    }

    /// The frame sequence as it will play, for the live preview.
    private var sequence: [NSImage] {
        var f = reversed ? Array(frames.reversed()) : frames
        if o.boomerang, f.count > 2 { f += f.dropFirst().dropLast().reversed() }
        return f
    }

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: max(o.frameDelay, 0.03))) { context in
                let seq = sequence
                let i = Int(context.date.timeIntervalSinceReferenceDate / max(o.frameDelay, 0.03)) % max(seq.count, 1)
                Image(nsImage: seq[i]).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
            .background(Color.black.opacity(0.06))

            VStack(spacing: 8) {
                LabeledSlider(title: "Frame time", value: $o.frameDelay, range: 0.04...2, unit: "s",
                              format: { String(format: "%.2f", $0) })
                HStack {
                    Text("Max size").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: [1600, 1080, 800, 480, 320], selection: $o.maxSize) { "\($0)" }
                }
                HStack {
                    Toggle("Loop forever", isOn: $o.loop)
                    Toggle("Boomerang", isOn: $o.boomerang)
                    Toggle("Reverse", isOn: $reversed)
                    Spacer()
                }
                .font(.system(size: 12)).toggleStyle(.checkbox)
            }
            .padding(.horizontal, 14)
            EditorFooter(primaryTitle: "Make GIF", busy: busy, onReset: { o = CombineEngine.GIFOptions(); reversed = false }, onPrimary: save)
        }
    }

    private func save() {
        busy = true
        let imgs = reversed ? Array(images.reversed()) : images, o = self.o, dir = files[0].deletingLastPathComponent()
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) { () -> URL in
                    let out = OutputPath.unique(in: dir, base: "Animation", ext: "gif")
                    do { try CombineEngine.gif(imgs, o, to: out) } catch { try? FileManager.default.removeItem(at: out); throw error }
                    return out
                }.value
                finish(.success([out]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}
