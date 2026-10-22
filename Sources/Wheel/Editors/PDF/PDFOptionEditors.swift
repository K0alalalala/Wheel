import PDFKit
import SwiftUI
import WheelCore

// MARK: - Split

struct PDFSplitAction: FileAction {
    let id = "pdf.split", title = "Split", symbol = "scissors", mode = WheelMode.edit
    var isInteractive: Bool { true }
    var summary: String { "Break a PDF into several files: every N pages, or at the pages you choose." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try PDFTools.open(urls[0])
        guard doc.pageCount > 1 else { throw ActionError("A one-page PDF can't be split.") }
        return try await EditorWindow.present(title: "Split PDF", size: CGSize(width: 380, height: 330)) { finish in
            SplitEditor(source: urls[0], doc: doc, finish: finish)
        }
    }
}

struct SplitEditor: View {
    enum Method: String, CaseIterable { case every = "Every N pages", at = "Before pages" }
    let source: URL
    let doc: PDFDocument
    let finish: EditorFinish

    @State private var method = Method.every
    @State private var every = 1
    @State private var points = ""
    @State private var busy = false

    /// 0-based page ranges each output file will hold.
    private var ranges: [ClosedRange<Int>] {
        let n = doc.pageCount
        switch method {
        case .every:
            return stride(from: 0, to: n, by: max(every, 1)).map { $0...min($0 + every - 1, n - 1) }
        case .at:
            let starts = ([0] + PDFTools.parseRanges(points, pageCount: n)).sorted()
            let unique = starts.reduce(into: [Int]()) { if $0.last != $1 { $0.append($1) } }
            return unique.enumerated().map { k, s in s...((k + 1 < unique.count ? unique[k + 1] : n) - 1) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $method) { ForEach(Method.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if method == .every {
                Stepper("Every \(every) page\(every == 1 ? "" : "s")", value: $every, in: 1...max(doc.pageCount - 1, 1))
            } else {
                TextField("Start a new file at pages, e.g. 4, 9", text: $points).textFieldStyle(.roundedBorder)
            }
            Text("\(doc.pageCount) pages → \(ranges.count) files")
                .font(.system(size: 13, weight: .semibold))
            Text(ranges.prefix(6).map { PDFTools.rangeLabel(Array($0)) }.joined(separator: " · ") + (ranges.count > 6 ? " …" : ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            EditorFooter(primaryTitle: "Split into \(ranges.count) Files", primaryEnabled: ranges.count > 1, busy: busy,
                         onReset: nil, onPrimary: save)
                .padding(.horizontal, -14)
        }
        .padding(.horizontal, 14)
    }

    private func save() {
        busy = true
        let ranges = self.ranges, doc = self.doc, src = source
        Task {
            do {
                let folder: URL = try await pdfWork({ _ in }) { _ in
                    let folder = try OutputPath.folderBeside(src, suffix: "Split")
                    let base = src.deletingPathExtension().lastPathComponent
                    for r in ranges {
                        let out = OutputPath.unique(in: folder, base: "\(base) p. \(PDFTools.rangeLabel(Array(r)))", ext: "pdf")
                        try PDFTools.save(PDFTools.pages(doc, keeping: Array(r)), to: out)
                    }
                    return folder
                }
                finish(.success([folder]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}

// MARK: - Live page preview

/// Shows page 1 (or `index`) with an overlay, re-rendered whenever `token` changes.
struct StampPreview<Token: Equatable>: View {
    let page: PDFPage
    var index = 0
    var count = 1
    let token: Token
    let overlay: (CGContext, CGRect, Int, Int) -> Void
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
        .background(Color.black.opacity(0.05))
        .onAppear(perform: render)
        .onChange(of: token) { _, _ in render() }
    }

    private func render() {
        if let cg = PDFTools.preview(page, maxPixel: 700, index: index, count: count, overlay: overlay) {
            image = NSImage(cgImage: cg)
        }
    }
}

// MARK: - Watermark

struct PDFWatermarkAction: FileAction {
    let id = "pdf.watermark", title = "Watermark", symbol = "seal", mode = WheelMode.edit
    var isInteractive: Bool { true }
    var summary: String { "Stamp text like DRAFT or CONFIDENTIAL across every page. Burned in, not a removable layer." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try PDFTools.open(urls[0])
        return try await EditorWindow.present(title: "Watermark", size: CGSize(width: 420, height: 600)) { finish in
            WatermarkEditor(source: urls[0], doc: doc, finish: finish)
        }
    }
}

struct WatermarkEditor: View {
    let source: URL
    let doc: PDFDocument
    let finish: EditorFinish
    @State private var o = PDFTools.WatermarkOptions()
    @State private var color = Color.red
    @State private var busy = false

    var body: some View {
        VStack(spacing: 10) {
            if let page = doc.page(at: 0) {
                StampPreview(page: page, token: o) { ctx, rect, _, _ in PDFTools.drawWatermark(o, in: ctx, page: rect) }
            }
            VStack(spacing: 8) {
                HStack {
                    TextField("Watermark text", text: $o.text).textFieldStyle(.roundedBorder)
                    ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
                }
                HStack {
                    Text("Layout").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: PDFTools.WatermarkOptions.Layout.allCases, selection: $o.layout) { $0.rawValue.capitalized }
                }
                LabeledSlider(title: "Size", value: cg(\.size), range: 12...160, unit: "pt")
                LabeledSlider(title: "Opacity", value: cg(\.opacity), range: 0.05...0.8, unit: "%", format: { String(Int(($0 * 100).rounded())) })
                LabeledSlider(title: "Angle", value: cg(\.angle), range: -90...90, unit: "°")
            }
            .padding(.horizontal, 14)
            EditorFooter(primaryTitle: "Save Watermarked", primaryEnabled: !o.text.isEmpty, busy: busy,
                         onReset: { o = PDFTools.WatermarkOptions(); color = .red }, onPrimary: save)
        }
        .onChange(of: color) { _, c in o.color = NSColor(c) }
    }

    private func cg(_ kp: WritableKeyPath<PDFTools.WatermarkOptions, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(o[keyPath: kp]) }, set: { o[keyPath: kp] = CGFloat($0) })
    }

    private func save() {
        busy = true
        let o = self.o, doc = self.doc, src = source
        Task {
            do {
                let out = try await pdfWork({ _ in }) { _ in
                    try PDFBatchAction.writing(src, suffix: "Watermarked") { url in
                        try PDFTools.restamp(doc, to: url) { ctx, rect, _, _ in PDFTools.drawWatermark(o, in: ctx, page: rect) }
                    }
                }
                finish(.success([out]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}

// MARK: - Page numbers

struct PDFPageNumbersAction: FileAction {
    let id = "pdf.numbers", title = "Numbers", symbol = "number", mode = WheelMode.edit
    var isInteractive: Bool { true }
    var summary: String { "Add page numbers: pick the corner, style (1 · Page 1 of 9 · – 1 –) and starting number." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try PDFTools.open(urls[0])
        return try await EditorWindow.present(title: "Page Numbers", size: CGSize(width: 420, height: 600)) { finish in
            PageNumbersEditor(source: urls[0], doc: doc, finish: finish)
        }
    }
}

struct PageNumbersEditor: View {
    let source: URL
    let doc: PDFDocument
    let finish: EditorFinish
    @State private var o = PDFTools.PageNumberOptions()
    @State private var busy = false

    private typealias Pos = PDFTools.PageNumberOptions.Position

    var body: some View {
        VStack(spacing: 10) {
            let previewIndex = o.skipFirst && doc.pageCount > 1 ? 1 : 0
            if let page = doc.page(at: previewIndex) {
                StampPreview(page: page, index: previewIndex, count: doc.pageCount, token: o) { ctx, rect, i, c in
                    PDFTools.drawPageNumber(o, in: ctx, page: rect, index: i, count: c)
                }
            }
            VStack(spacing: 8) {
                HStack(alignment: .top) {
                    Text("Position").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    positionPad
                }
                HStack {
                    Text("Style").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    ChipPicker(options: PDFTools.PageNumberOptions.Format.allCases, selection: $o.format) {
                        switch $0 { case .plain: return "1"; case .pageOf: return "Page 1 of N"; case .dashed: return "– 1 –" }
                    }
                }
                HStack {
                    Stepper("Start at \(o.start)", value: $o.start, in: 0...9999)
                    Spacer()
                    Toggle("Skip first page", isOn: $o.skipFirst).toggleStyle(.checkbox)
                }
                .font(.system(size: 12))
                LabeledSlider(title: "Size", value: Binding(get: { Double(o.size) }, set: { o.size = CGFloat($0) }), range: 7...24, unit: "pt")
            }
            .padding(.horizontal, 14)
            EditorFooter(primaryTitle: "Save Numbered", busy: busy, onReset: { o = PDFTools.PageNumberOptions() }, onPrimary: save)
        }
    }

    /// Six spots around a little page outline.
    private var positionPad: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) { dot(.topLeft); dot(.topCenter); dot(.topRight) }
            HStack(spacing: 10) { dot(.bottomLeft); dot(.bottomCenter); dot(.bottomRight) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.5)))
    }

    private func dot(_ p: Pos) -> some View {
        Circle().fill(o.position == p ? Theme.accent : Color.secondary.opacity(0.3))
            .frame(width: 12, height: 12)
            .contentShape(Rectangle().inset(by: -4))
            .onTapGesture { o.position = p }
    }

    private func save() {
        busy = true
        let o = self.o, doc = self.doc, src = source
        Task {
            do {
                let out = try await pdfWork({ _ in }) { _ in
                    try PDFBatchAction.writing(src, suffix: "Numbered") { url in
                        try PDFTools.restamp(doc, to: url) { ctx, rect, i, c in PDFTools.drawPageNumber(o, in: ctx, page: rect, index: i, count: c) }
                    }
                }
                finish(.success([out]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}

// MARK: - Protect

struct PDFProtectAction: FileAction {
    let id = "pdf.protect", title = "Protect", symbol = "lock", mode = WheelMode.edit
    var isInteractive: Bool { true }
    var summary: String { "Add a password, and optionally block printing or copying text." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try PDFTools.open(urls[0])
        return try await EditorWindow.present(title: "Protect PDF", size: CGSize(width: 380, height: 420)) { finish in
            ProtectEditor(source: urls[0], doc: doc, finish: finish)
        }
    }
}

struct ProtectEditor: View {
    let source: URL
    let doc: PDFDocument
    let finish: EditorFinish
    @State private var requirePassword = true
    @State private var password = ""
    @State private var confirm = ""
    @State private var ownerPassword = ""
    @State private var allowPrinting = true
    @State private var allowCopying = true
    @State private var busy = false

    private var mismatch: Bool { requirePassword && !confirm.isEmpty && password != confirm }
    private var valid: Bool {
        if requirePassword { return !password.isEmpty && password == confirm }
        return !allowPrinting || !allowCopying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Require a password to open", isOn: $requirePassword)
            if requirePassword {
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder)
                if mismatch { Text("Passwords don't match.").font(.caption).foregroundStyle(.red) }
            }
            Divider()
            Toggle("Allow printing", isOn: $allowPrinting)
            Toggle("Allow copying text", isOn: $allowCopying)
            if !allowPrinting || !allowCopying {
                SecureField("Permissions password (optional)", text: $ownerPassword).textFieldStyle(.roundedBorder)
                Text("Needed to lift the restrictions later. Leave empty to lock them for good.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Label("Wheel doesn't keep the password. If you forget it, the file can't be opened.", systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            EditorFooter(primaryTitle: "Save Protected", primaryEnabled: valid, busy: busy, onReset: nil, onPrimary: save)
                .padding(.horizontal, -14)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
    }

    private func save() {
        busy = true
        var o = PDFTools.ProtectOptions()
        o.openPassword = requirePassword ? password : ""
        o.ownerPassword = ownerPassword
        o.allowPrinting = allowPrinting
        o.allowCopying = allowCopying
        let doc = self.doc, src = source
        Task {
            do {
                let out = try await pdfWork({ _ in }) { _ in try PDFTools.protect(doc, source: src, o) }
                finish(.success([out]))
            } catch {
                busy = false
                finish(.failure(error))
            }
        }
    }
}

// MARK: - Unlock

struct PDFUnlockAction: FileAction {
    let id = "pdf.unlock", title = "Unlock", symbol = "lock.open", mode = WheelMode.edit
    var isInteractive: Bool { true }
    var summary: String { "Save a copy without the password or printing/copying restrictions. You need the password." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let src = urls[0]
        // Restriction-only files open without a password: unlock straight away.
        if !PDFTools.needsPassword(src) {
            return [try await pdfWork(progress) { _ in try PDFTools.unlock(src, password: nil) }]
        }
        return try await EditorWindow.present(title: "Unlock PDF", size: CGSize(width: 340, height: 200)) { finish in
            UnlockEditor(source: src, finish: finish)
        }
    }
}

struct UnlockEditor: View {
    let source: URL
    let finish: EditorFinish
    @State private var password = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(source.lastPathComponent) needs a password to open.").font(.system(size: 12)).foregroundStyle(.secondary)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit(unlock)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Spacer(minLength: 0)
            EditorFooter(primaryTitle: "Unlock", primaryEnabled: !password.isEmpty, busy: busy, onReset: nil, onPrimary: unlock)
                .padding(.horizontal, -14)
        }
        .padding(.horizontal, 14)
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        busy = true
        let pw = password, src = source
        Task {
            do {
                let out = try await pdfWork({ _ in }) { _ in try PDFTools.unlock(src, password: pw) }
                finish(.success([out]))
            } catch {
                busy = false
                self.error = error.localizedDescription
                password = ""
            }
        }
    }
}

// MARK: - All tools launcher

struct PDFLauncherAction: FileAction {
    let id = "pdf.tools", title = "All Tools", symbol = "square.grid.3x3.fill", mode = WheelMode.edit
    var isInteractive: Bool { true }
    var summary: String { "Every PDF tool in one place." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let tools = ActionRegistry.shared.allActions(for: .pdf, mode: .edit).filter { $0.id != id && $0.supports(urls[0]) }
        var chosen: FileAction?
        _ = try? await EditorWindow.present(title: "PDF Tools", size: CGSize(width: 560, height: 520)) { finish in
            PDFLauncher(tools: tools, fileCount: urls.count) { tool in
                chosen = tool
                finish(.failure(UserCancelled()))
            }
        }
        if let chosen {
            // Hand off to the runner so the chosen tool gets its own editor or progress toast.
            DispatchQueue.main.async { ActionRunner.shared.run(chosen, on: urls) }
        }
        throw UserCancelled()
    }
}

struct PDFLauncher: View {
    let tools: [FileAction]
    let fileCount: Int
    let pick: (FileAction) -> Void
    @State private var query = ""

    private var shown: [FileAction] {
        query.isEmpty ? tools : tools.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search tools", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 14)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(shown, id: \.id) { tool in
                        Button { pick(tool) } label: { row(tool) }.buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
            if fileCount > 1 {
                Text("\(fileCount) files dropped. Merge uses all of them; other tools work on the first.")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
            }
        }
    }

    private func row(_ tool: FileAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tool.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.system(size: 13, weight: .semibold))
                Text(tool.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let reason = tool.unavailableReason { Text(reason).font(.caption2).foregroundStyle(.red) }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .contentShape(Rectangle())
    }
}
