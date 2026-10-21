import Foundation

/// User choices that core code needs. The app supplies them through `Preferences.current`;
/// tests and other hosts (CLI, Finder extension) can supply their own.
public struct Preferences {
    /// Lossy quality for JPG/HEIC/AVIF/WEBP output, 0...1.
    public var quality: Double = 0.85
    public var pdfAllPages = true
    public var pdfDPI = 300
    /// Action ids hidden from the wheel.
    public var hiddenActions: Set<String> = []
    /// Custom order per wheel, keyed by `ActionRegistry.orderKey(kind:mode:)`. Unlisted ids follow in default order.
    public var sliceOrder: [String: [String]] = [:]
    /// The wheel shows at most this many slices.
    public var maxSlices = 8

    public init() {}

    nonisolated(unsafe) public static var current: () -> Preferences = { Preferences() }
}

/// What the wheel shows for a set of dragged files.
public struct WheelSlice: Identifiable {
    public let action: FileAction
    public var id: String { action.id }
    public var disabledReason: String?
    public var isEnabled: Bool { disabledReason == nil }
}

/// A source of wheel slices. Register one to add a whole family of actions
/// (e.g. a "Share" wheel, an AI tools set) without touching existing code.
public protocol ActionProvider {
    /// Every action this provider offers for files of `kind` in `mode`, in slice order.
    func actions(for kind: FileKind, mode: WheelMode) -> [FileAction]
}

/// Built-in conversions.
public struct ConvertProvider: ActionProvider {
    public init() {}
    public func actions(for kind: FileKind, mode: WheelMode) -> [FileAction] {
        guard mode == .convert else { return [] }
        return (ConvertAction.targets[kind] ?? []).map { ConvertAction(target: $0, kind: kind) }
    }
}

/// Collects actions from registered providers and decides which slices a drag gets.
public final class ActionRegistry {
    nonisolated(unsafe) public static let shared = ActionRegistry()

    private var providers: [ActionProvider] = [ConvertProvider()]

    public init() {}

    public func register(_ provider: ActionProvider) { providers.append(provider) }

    /// Convert wheels are ordered per file kind; the Edit wheel shares one order across kinds.
    public static func orderKey(kind: FileKind, mode: WheelMode) -> String {
        mode == .edit ? "edit" : "\(mode.rawValue).\(kind.rawValue)"
    }

    /// Actions in the user's order: listed ids first (in that order), then the rest as providers return them.
    public func ordered(_ actions: [FileAction], kind: FileKind, mode: WheelMode, prefs: Preferences) -> [FileAction] {
        guard let order = prefs.sliceOrder[Self.orderKey(kind: kind, mode: mode)], !order.isEmpty else { return actions }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return actions.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? order.count + a.offset, rb = rank[b.element.id] ?? order.count + b.offset
            return ra < rb
        }.map(\.element)
    }

    /// All actions for a kind and mode, ignoring hidden ones and the custom order. Used by Settings.
    public func allActions(for kind: FileKind, mode: WheelMode) -> [FileAction] {
        providers.flatMap { $0.actions(for: kind, mode: mode) }
    }

    /// Slices for the dragged files, in wheel order. Based on the first file's kind;
    /// files an action can't take are skipped when it runs.
    public func slices(for urls: [URL], mode: WheelMode) -> [WheelSlice] {
        guard let first = urls.first else { return [] }
        let prefs = Preferences.current()
        let kind = FileKind.of(first)
        let actions = ordered(allActions(for: kind, mode: mode), kind: kind, mode: mode, prefs: prefs)
            .filter { $0.supports(first) && !prefs.hiddenActions.contains($0.id) }
        return actions.prefix(max(prefs.maxSlices, 1)).map { WheelSlice(action: $0, disabledReason: $0.unavailableReason) }
    }
}
