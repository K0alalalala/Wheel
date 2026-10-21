import AppKit
import UniformTypeIdentifiers

/// Broad family a dropped file belongs to. Decides which slices a wheel shows.
public enum FileKind: String, CaseIterable, Codable {
    case image, pdf, document, audio, video, other

    public static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if ["docx", "doc", "txt", "md", "markdown", "html", "htm", "rtf", "odt"].contains(ext) { return .document }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .plainText) || type.conforms(to: .rtf) || type.conforms(to: .html) { return .document }
        return .other
    }

    public var displayName: String {
        switch self {
        case .image: return "Images"
        case .pdf: return "PDF"
        case .document: return "Documents"
        case .audio: return "Audio"
        case .video: return "Video"
        case .other: return "Other"
        }
    }
}

public enum WheelMode: String, Codable {
    case convert, edit

    public var toggled: WheelMode { self == .convert ? .edit : .convert }
    public var title: String { self == .convert ? "Convert" : "Edit" }
}

/// Reports progress for a single job. Values are 0...1.
public typealias ProgressHandler = @MainActor (Double) -> Void

/// One slice of a wheel. Add a new capability by conforming to this and registering it in `ActionRegistry`.
public protocol FileAction {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    var mode: WheelMode { get }
    /// Whether this action can take the file at all.
    func supports(_ url: URL) -> Bool
    /// nil when ready, otherwise a short reason the slice is disabled (missing backend, etc).
    var unavailableReason: String? { get }
    /// Runs the action. Interactive actions present their editor and resume when it closes.
    /// Must write new files only; never touch the inputs.
    func run(_ urls: [URL], progress: @escaping ProgressHandler) async throws -> [URL]
    /// Interactive actions handle all urls in one editor session; batch actions are run per file by the runner.
    var isInteractive: Bool { get }
}

extension FileAction {
    public var unavailableReason: String? { nil }
    public var isInteractive: Bool { false }
}

public struct ActionError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thrown when the user closes an editor without saving. Not shown as an error.
public struct UserCancelled: Error { public init() {} }
