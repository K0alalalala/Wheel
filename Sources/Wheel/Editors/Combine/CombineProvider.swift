import Foundation
import WheelCore

/// The Combine wheel: actions that take several dropped files and make one.
/// Each action decides from the whole set whether it's offered (`accepts`).
struct CombineProvider: ActionProvider {
    static let tools: [FileAction] = [
        CombinePDFAction(), ZipAction(), ArchiveAction(), StitchAction(), GIFAction(), JoinAction(),
    ]

    func actions(for kind: FileKind, mode: WheelMode) -> [FileAction] {
        mode == .combine ? Self.tools : []
    }
}

/// Files in a stable, human order: Finder-style name sort.
func byName(_ urls: [URL]) -> [URL] {
    urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

private func all(_ urls: [URL], are kinds: Set<FileKind>) -> Bool {
    urls.count > 1 && urls.allSatisfy { kinds.contains(FileKind.of($0)) }
}

struct CombinePDFAction: FileAction {
    let id = "combine.pdf", title = "To PDF", symbol = "doc.on.doc.fill", mode = WheelMode.combine
    var isInteractive: Bool { true }
    var summary: String { "Combine PDFs, images and documents into one PDF, in the order you choose." }
    func supports(_ url: URL) -> Bool { CombineEngine.canCombineIntoPDF(url) }
    func accepts(_ urls: [URL]) -> Bool { all(urls, are: [.pdf, .image, .document]) }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        try await EditorWindow.present(title: "Combine into PDF", size: CGSize(width: 420, height: 480)) { finish in
            OrderedFilesEditor(files: byName(urls), defaultName: "Combined", ext: "pdf", primary: "Combine",
                               options: { CombinePDFOptions() }, finish: finish) { files, name, options in
                let doc = try await CombineEngine.pdf(from: files, pageSize: options.pageSize)
                let out = OutputPath.unique(in: files[0].deletingLastPathComponent(), base: name, ext: "pdf")
                try PDFTools.save(doc, to: out)
                return out
            }
        }
    }
}

struct ZipAction: FileAction {
    let id = "combine.zip", title = "Zip", symbol = "archivebox", mode = WheelMode.combine
    var combinesFiles: Bool { true }
    var summary: String { "Pack everything into Archive.zip next to the files. One drop, no questions." }
    func supports(_ url: URL) -> Bool { true }
    func accepts(_ urls: [URL]) -> Bool { urls.count > 1 }
    var unavailableReason: String? { ArchiveFormat.zip.unavailableReason }

    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        [try await ArchiveEngine.archive(byName(urls), name: "Archive", format: .zip)]
    }
}

struct ArchiveAction: FileAction {
    let id = "combine.archive", title = "Archive", symbol = "shippingbox", mode = WheelMode.combine
    var isInteractive: Bool { true }
    var summary: String { "Choose ZIP, TAR.GZ, 7Z or RAR, the name and how hard to compress." }
    func supports(_ url: URL) -> Bool { true }
    func accepts(_ urls: [URL]) -> Bool { urls.count > 1 }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        try await EditorWindow.present(title: "Archive", size: CGSize(width: 380, height: 360)) { finish in
            ArchiveEditor(items: byName(urls), finish: finish)
        }
    }
}

struct StitchAction: FileAction {
    let id = "combine.stitch", title = "Stitch", symbol = "square.split.1x2", mode = WheelMode.combine
    var isInteractive: Bool { true }
    var summary: String { "Join images into one: a long strip, side by side, or a grid." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }
    func accepts(_ urls: [URL]) -> Bool { all(urls, are: [.image]) }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let files = byName(urls)
        let images = try files.map { try ImageEngine.load($0, maxPixel: 4000) }
        return try await EditorWindow.present(title: "Stitch Images", size: CGSize(width: 440, height: 600)) { finish in
            StitchEditor(files: files, images: images, finish: finish)
        }
    }
}

struct GIFAction: FileAction {
    let id = "combine.gif", title = "GIF", symbol = "play.rectangle.on.rectangle", mode = WheelMode.combine
    var isInteractive: Bool { true }
    var summary: String { "Turn images into an animated GIF: speed, size, loop and boomerang." }
    func supports(_ url: URL) -> Bool { FileKind.of(url) == .image }
    func accepts(_ urls: [URL]) -> Bool { all(urls, are: [.image]) }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        let files = byName(urls)
        let images = try files.map { try ImageEngine.load($0, maxPixel: 1600) }
        return try await EditorWindow.present(title: "Make GIF", size: CGSize(width: 420, height: 560)) { finish in
            GIFEditor(files: files, images: images, finish: finish)
        }
    }
}

struct JoinAction: FileAction {
    let id = "combine.join", title = "Join", symbol = "film.stack", mode = WheelMode.combine
    var isInteractive: Bool { true }
    var summary: String { "Play audio or video clips back to back in one file (MP4, or M4A for audio only)." }
    func supports(_ url: URL) -> Bool { [.audio, .video].contains(FileKind.of(url)) }
    func accepts(_ urls: [URL]) -> Bool { all(urls, are: [.audio, .video]) }

    @MainActor
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        try await EditorWindow.present(title: "Join Clips", size: CGSize(width: 420, height: 440)) { finish in
            OrderedFilesEditor(files: byName(urls), defaultName: "Joined", ext: "mp4 / m4a", primary: "Join",
                               options: { NoOptions() }, finish: finish) { files, name, _ in
                try await CombineEngine.join(files, name: name, progress: { _ in })
            }
        }
    }
}
