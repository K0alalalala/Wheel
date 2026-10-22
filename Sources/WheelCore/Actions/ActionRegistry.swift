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

    /// Registers a provider ahead of the others, so its actions get the first slots by default.
    public func registerFirst(_ provider: ActionProvider) { providers.insert(provider, at: 0) }

    /// Each wheel (mode + file kind) keeps its own order, e.g. "edit.pdf". Combine has one order for all files.
    public static func orderKey(kind: FileKind, mode: WheelMode) -> String {
        mode == .combine ? "combine" : "\(mode.rawValue).\(kind.rawValue)"
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

    /// Slices for the dragged files, in wheel order. Convert/Edit are based on the first file's kind
    /// (files an action can't take are skipped when it runs); Combine looks at the whole set.
    public func slices(for urls: [URL], mode: WheelMode) -> [WheelSlice] {
        guard let first = urls.first else { return [] }
        let prefs = Preferences.current()
        let kind = FileKind.of(first)
        if mode == .combine && urls.count < 2 { return [] }
        let actions = ordered(allActions(for: kind, mode: mode), kind: kind, mode: mode, prefs: prefs)
            .filter { $0.accepts(urls) && !prefs.hiddenActions.contains($0.id) }
        return actions.prefix(max(prefs.maxSlices, 1)).map { WheelSlice(action: $0, disabledReason: $0.unavailableReason) }
    }

    /// The wheel a drag opens on: Combine for mixed file types or folders, otherwise the first mode with slices.
    public func initialMode(for urls: [URL]) -> WheelMode {
        let kinds = Set(urls.map(FileKind.of))
        let hasFolder = urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if urls.count > 1, kinds.count > 1 || hasFolder, !slices(for: urls, mode: .combine).isEmpty { return .combine }
        return WheelMode.cycle.first { !slices(for: urls, mode: $0).isEmpty } ?? .convert
    }

    /// The next mode in the hub cycle that has slices for these files.
    public func nextMode(after mode: WheelMode, for urls: [URL]) -> WheelMode {
        let cycle = WheelMode.cycle
        let start = cycle.firstIndex(of: mode) ?? 0
        for step in 1...cycle.count {
            let m = cycle[(start + step) % cycle.count]
            if !slices(for: urls, mode: m).isEmpty { return m }
        }
        return mode
    }
}
