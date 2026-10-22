import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WheelCore

/// Organize, Delete Pages and Extract Pages share one thumbnail grid.
struct PageGridAction: FileAction {
    enum Mode { case organize, delete, extract }
    let mode_: Mode

    init(mode: Mode) { mode_ = mode }

    var id: String { ["pdf.organize", "pdf.delete", "pdf.extract"][[Mode.organize, .delete, .extract].firstIndex(of: mode_)!] }
    var title: String {
        switch mode_ { case .organize: return "Organize"; case .delete: return "Delete"; case .extract: return "Extract" }
    }
    var symbol: String {
        switch mode_ { case .organize: return "square.grid.2x2"; case .delete: return "trash"; case .extract: return "doc.badge.plus" }
    }
    var summary: String {
        switch mode_ {
        case .organize: return "Reorder, rotate, duplicate, insert blank pages and delete, all in one grid."
        case .delete: return "Strip the pages you pick and save the rest."
        case .extract: return "Save the pages you pick as a new PDF, or one PDF per page."
        }
    }
    var mode: WheelMode { .edit }
    var isInteractive: Bool { true }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .pdf }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let doc = try PDFTools.open(urls[0])
        let titles: [Mode: String] = [.organize: "Organize Pages", .delete: "Delete Pages", .extract: "Extract Pages"]
        return try await EditorWindow.present(title: titles[mode_]!, size: CGSize(width: 600, height: 600)) { finish in
            PageGridEditor(source: urls[0], doc: doc, mode: mode_, finish: finish)
        }
    }
}

/// Lazily rendered page thumbnails, shared by the grid cells.
@MainActor
final class ThumbnailCache: ObservableObject {
    @Published private(set) var images: [Int: NSImage] = [:]
    private let doc: PDFDocument
    private var pending = Set<Int>()

    init(doc: PDFDocument) { self.doc = doc }

    func image(_ i: Int) -> NSImage? {
        if let img = images[i] { return img }
        if !pending.contains(i) {
            pending.insert(i)
            DispatchQueue.main.async { [weak self] in
                guard let self, let page = self.doc.page(at: i),
                      let img = PDFTools.preview(page, maxPixel: 240) else { return }
                // Rendered as displayed (the page's own rotation applied); cells add only pending rotation.
                self.images[i] = NSImage(cgImage: img)
            }
        }
        return nil
    }
}

struct PageGridEditor: View {
    let source: URL
    let doc: PDFDocument
    let mode: PageGridAction.Mode
    let finish: EditorFinish

    @StateObject private var thumbs: ThumbnailCache
    @State private var items: [PDFTools.PageItem]
    @State private var selection = Set<UUID>()
    @State private var lastClicked: UUID?
    @State private var rangeText = ""
    @State private var onePerPage = false
    @State private var busy = false
    @State private var error: String?

    init(source: URL, doc: PDFDocument, mode: PageGridAction.Mode, finish: @escaping EditorFinish) {
        self.source = source
        self.doc = doc
        self.mode = mode
        self.finish = finish
        _thumbs = StateObject(wrappedValue: ThumbnailCache(doc: doc))
        _items = State(initialValue: (0..<doc.pageCount).map { PDFTools.PageItem(source: $0) })
    }

    private var original: [PDFTools.PageItem] { (0..<doc.pageCount).map { PDFTools.PageItem(source: $0) } }
    private var changed: Bool { items.map(\.source) != original.map(\.source) || items.contains { $0.rotation % 360 != 0 } }
    private var selectedIndices: [Int] { items.enumerated().filter { selection.contains($0.element.id) }.map(\.offset) }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        cell(i, item)
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.05))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            footer
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            TextField("Pages, e.g. 1-3, 7", text: $rangeText)
                .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 140)
                .onSubmit(selectRange)
            Menu("Select") {
                Button("All") { selection = Set(items.map(\.id)) }
                Button("None") { selection = [] }
                Button("Odd pages") { select { $0 % 2 == 0 } }
                Button("Even pages") { select { $0 % 2 == 1 } }
                Button("Invert") { selection = Set(items.map(\.id)).subtracting(selection) }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if mode == .organize {
                tool("rotate.left", "Rotate left") { rotate(-90) }
                tool("rotate.right", "Rotate right") { rotate(90) }
                tool("plus.square.on.square", "Duplicate") { duplicate() }
                tool("doc.badge.plus", "Insert blank page after selection") { insertBlank() }
                tool("trash", "Delete selected") { items.removeAll { selection.contains($0.id) }; selection = [] }
                    .disabled(selection.isEmpty || selection.count == items.count)
            }
        }
        .padding(.horizontal, 14)
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .buttonStyle(SubtleButtonStyle()).help(help)
            .disabled(selection.isEmpty && symbol != "doc.badge.plus")
    }

    // MARK: Cells

    private func cell(_ i: Int, _ item: PDFTools.PageItem) -> some View {
        let selected = selection.contains(item.id)
        let marked = selected && mode == .delete
        let rotation = item.rotation
        return VStack(spacing: 4) {
            ZStack {
                if let s = item.source {
                    if let img = thumbs.image(s) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .rotationEffect(.degrees(Double(rotation)))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Rectangle().fill(Color.white).aspectRatio(0.77, contentMode: .fit)
                        .overlay(Text("Blank").font(.caption2).foregroundStyle(.secondary))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                }
                if marked {
                    Rectangle().fill(Color.red.opacity(0.25))
                    Image(systemName: "xmark").font(.system(size: 30, weight: .bold)).foregroundStyle(.red)
                }
            }
            .frame(width: 96, height: 120)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? (marked ? Color.red : Theme.accent) : .clear, lineWidth: 2.5))
            Text(item.source.map { "\($0 + 1)" } ?? "+").font(.system(size: 11, weight: selected ? .bold : .regular)).monospacedDigit()
        }
        .contentShape(Rectangle())
        .onTapGesture { click(item.id) }
        .draggable(item.id.uuidString) {
            Image(systemName: "doc").font(.largeTitle)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard mode == .organize, let id = ids.first.flatMap(UUID.init), let from = items.firstIndex(where: { $0.id == id }),
                  let to = items.firstIndex(where: { $0.id == item.id }), from != to else { return false }
            withAnimation { items.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
            return true
        }
    }

    private func click(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift), let last = lastClicked,
           let a = items.firstIndex(where: { $0.id == last }), let b = items.firstIndex(where: { $0.id == id }) {
            for k in min(a, b)...max(a, b) { selection.insert(items[k].id) }
        } else if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        lastClicked = id
    }

    private func select(_ predicate: (Int) -> Bool) {
        selection = Set(items.enumerated().filter { predicate($0.offset) }.map(\.element.id))
    }

    private func selectRange() {
        let picked = Set(PDFTools.parseRanges(rangeText, pageCount: items.count))
        select { picked.contains($0) }
    }

    // MARK: Organize operations

    private func rotate(_ degrees: Int) {
        for k in items.indices where selection.contains(items[k].id) { items[k].rotation += degrees }
    }

    private func duplicate() {
        var out: [PDFTools.PageItem] = []
        for item in items {
            out.append(item)
            if selection.contains(item.id) { out.append(PDFTools.PageItem(source: item.source, rotation: item.rotation)) }
        }
        items = out
    }

    private func insertBlank() {
        let at = (selectedIndices.max() ?? (items.count - 1)) + 1
        items.insert(PDFTools.PageItem(source: nil), at: at)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(status).font(.caption).foregroundStyle(.secondary)
            if mode == .extract {
                Toggle("One file per page", isOn: $onePerPage).toggleStyle(.checkbox).controlSize(.small)
            }
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(primaryTitle, action: save)
                .buttonStyle(AccentButtonStyle(enabled: primaryEnabled && !busy))
                .disabled(!primaryEnabled || busy)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private var status: String {
        let n = selection.count
        switch mode {
        case .organize: return "\(items.count) pages · drag to reorder"
        case .delete: return n == 0 ? "Click pages to strip" : "\(items.count - n) of \(items.count) pages stay"
        case .extract: return n == 0 ? "Click pages to extract" : "\(n) selected"
        }
    }

    private var primaryTitle: String {
        let n = selection.count
        switch mode {
        case .organize: return "Save"
        case .delete: return n == 0 ? "Delete Pages" : "Delete \(n) Page\(n == 1 ? "" : "s")"
        case .extract: return n == 0 ? "Extract Pages" : "Extract \(n) Page\(n == 1 ? "" : "s")"
        }
    }

    private var primaryEnabled: Bool {
        switch mode {
        case .organize: return changed
        case .delete: return !selection.isEmpty && selection.count < items.count
        case .extract: return !selection.isEmpty
        }
    }

    private func save() {
        busy = true
        error = nil
        let items = self.items, picked = selectedIndices, mode = self.mode, src = source, doc = self.doc, single = onePerPage
        Task {
            do {
                let outs: [URL] = try await pdfWork({ _ in }) { _ in
                    switch mode {
                    case .organize:
                        return [try PDFTools.saveBeside(PDFTools.assemble(doc, items), source: src, suffix: "Organized")]
                    case .delete:
                        let label = PDFTools.rangeLabel(picked)
                        let suffix = label.count <= 16 ? "Without p. \(label)" : "Pages Removed"
                        return [try PDFTools.saveBeside(PDFTools.pages(doc, removing: Set(picked)), source: src, suffix: suffix)]
                    case .extract:
                        let chosen = picked.map { PDFTools.PageItem(source: items[$0].source, rotation: items[$0].rotation) }
                        if single {
                            let folder = try OutputPath.folderBeside(src, suffix: "Pages")
                            let base = src.deletingPathExtension().lastPathComponent
                            for item in chosen {
                                let out = OutputPath.unique(in: folder, base: "\(base) p\((item.source ?? 0) + 1)", ext: "pdf")
                                try PDFTools.save(PDFTools.assemble(doc, [item]), to: out)
                            }
                            return [folder]
                        }
                        let label = PDFTools.rangeLabel(picked)
                        let suffix = label.count <= 16 ? "p. \(label)" : "Extract"
                        return [try PDFTools.saveBeside(PDFTools.assemble(doc, chosen), source: src, suffix: suffix)]
                    }
                }
                finish(.success(outs))
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
