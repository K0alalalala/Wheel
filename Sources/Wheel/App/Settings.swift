import AppKit
import WheelCore
import Combine
import ServiceManagement

enum TriggerModifier: String, CaseIterable, Identifiable, Codable {
    case shift, option, control, command
    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .option: return .option
        case .control: return .control
        case .command: return .command
        }
    }
    var title: String {
        switch self {
        case .shift: return "Shift ⇧"
        case .option: return "Option ⌥"
        case .control: return "Control ⌃"
        case .command: return "Command ⌘"
        }
    }
}

/// How the centre hub flips between Convert and Edit.
enum HubSwitch: String, CaseIterable, Identifiable, Codable {
    case hover, forceClick, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hover: return "Hover"
        case .forceClick: return "Force Click"
        case .both: return "Hover or Force Click"
        }
    }
    var usesHover: Bool { self != .forceClick }
    var usesForce: Bool { self != .hover }
}

enum ToastPlacement: String, CaseIterable, Identifiable, Codable {
    case cursor, topRight, bottomCenter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cursor: return "Near cursor"
        case .topRight: return "Top right"
        case .bottomCenter: return "Bottom centre"
        }
    }
}

/// Everything shareable about a setup: look, feel and slice layout. Saved as a .wheeltheme JSON file.
struct WheelProfile: Codable {
    var format = 1
    var style: WheelStyle
    var trigger: TriggerModifier?
    var hubSwitch: HubSwitch?
    var hubHoverDelay: Double?
    var toastPlacement: ToastPlacement?
    var toastDuration: Double?
    var sliceOrder: [String: [String]]?
    var hiddenActions: [String]?
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var trigger: TriggerModifier { didSet { d.set(trigger.rawValue, forKey: "trigger") } }
    /// Lossy quality for JPG/HEIC/AVIF/WEBP output, 0...1.
    @Published var quality: Double { didSet { d.set(quality, forKey: "quality") } }
    @Published var revealAfterSave: Bool { didSet { d.set(revealAfterSave, forKey: "revealAfterSave") } }
    @Published var pdfAllPages: Bool { didSet { d.set(pdfAllPages, forKey: "pdfAllPages") } }
    @Published var pdfDPI: Int { didSet { d.set(pdfDPI, forKey: "pdfDPI") } }
    /// Action ids the user turned off in Settings.
    @Published var hiddenActions: Set<String> { didSet { d.set(Array(hiddenActions), forKey: "hiddenActions") } }
    /// Custom slice order per wheel, keyed like "convert.image" or "edit.image". Ids not listed keep their default order after these.
    @Published var sliceOrder: [String: [String]] { didSet { d.set(sliceOrder, forKey: "sliceOrder") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    @Published var style: WheelStyle { didSet { if let data = try? JSONEncoder().encode(style) { d.set(data, forKey: "style") } } }
    @Published var hubSwitch: HubSwitch { didSet { d.set(hubSwitch.rawValue, forKey: "hubSwitch") } }
    /// Seconds the cursor rests on the hub before it flips (hover mode).
    @Published var hubHoverDelay: Double { didSet { d.set(hubHoverDelay, forKey: "hubHoverDelay") } }
    @Published var toastPlacement: ToastPlacement { didSet { d.set(toastPlacement.rawValue, forKey: "toastPlacement") } }
    /// Seconds the "Saved" toast stays up.
    @Published var toastDuration: Double { didSet { d.set(toastDuration, forKey: "toastDuration") } }

    /// Local diagnostic log in ~/Library/Logs/Wheel. On by default; nothing ever leaves the Mac.
    @Published var loggingEnabled: Bool {
        didSet {
            d.set(loggingEnabled, forKey: "loggingEnabled")
            if !loggingEnabled { WheelLog.shared.info("Logging turned off by the user") }
            WheelLog.shared.isEnabled = loggingEnabled
            if loggingEnabled { WheelLog.shared.info("Logging turned on by the user") }
        }
    }
    /// Off by default: logs show ‹pdf› instead of names.
    @Published var logFileNames: Bool {
        didSet { d.set(logFileNames, forKey: "logFileNames"); WheelLog.shared.includeFileNames = logFileNames }
    }

    private init() {
        d.register(defaults: ["enabled": true, "trigger": "shift", "quality": 0.85, "revealAfterSave": false,
                              "pdfAllPages": true, "pdfDPI": 300, "onboarded": false,
                              "hubSwitch": "both", "hubHoverDelay": 0.45, "toastPlacement": "cursor", "toastDuration": 4.0,
                              "loggingEnabled": true, "logFileNames": false])
        enabled = d.bool(forKey: "enabled")
        trigger = TriggerModifier(rawValue: d.string(forKey: "trigger") ?? "") ?? .shift
        quality = d.double(forKey: "quality")
        revealAfterSave = d.bool(forKey: "revealAfterSave")
        pdfAllPages = d.bool(forKey: "pdfAllPages")
        pdfDPI = d.integer(forKey: "pdfDPI")
        hiddenActions = Set(d.stringArray(forKey: "hiddenActions") ?? [])
        var order = d.dictionary(forKey: "sliceOrder") as? [String: [String]] ?? [:]
        if let shared = order.removeValue(forKey: "edit") { // 0.2 kept one Edit order for all kinds
            order["edit.image"] = order["edit.image"] ?? shared
            d.set(order, forKey: "sliceOrder")
        }
        sliceOrder = order
        onboarded = d.bool(forKey: "onboarded")
        var style = d.data(forKey: "style").flatMap { try? JSONDecoder().decode(WheelStyle.self, from: $0) } ?? WheelStyle()
        if let old = d.string(forKey: "accentStyle") { // one-time migration of the 0.1 setting
            if old == "system" { style.accent = .system }
            d.removeObject(forKey: "accentStyle")
            if let data = try? JSONEncoder().encode(style) { d.set(data, forKey: "style") }
        }
        self.style = style
        hubSwitch = HubSwitch(rawValue: d.string(forKey: "hubSwitch") ?? "") ?? .both
        hubHoverDelay = d.double(forKey: "hubHoverDelay")
        toastPlacement = ToastPlacement(rawValue: d.string(forKey: "toastPlacement") ?? "") ?? .cursor
        toastDuration = d.double(forKey: "toastDuration")
        loggingEnabled = d.bool(forKey: "loggingEnabled")
        logFileNames = d.bool(forKey: "logFileNames")
        WheelLog.shared.isEnabled = loggingEnabled
        WheelLog.shared.includeFileNames = logFileNames

        // Repaint when the user changes the accent colour in System Settings.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Turns on launch at login the first time Wheel runs from an Applications folder.
    /// After that the Settings toggle is the user's choice. Dev builds elsewhere are left alone.
    func enableLaunchAtLoginOnFirstRun() {
        let path = Bundle.main.bundlePath
        let installed = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        guard installed, !d.bool(forKey: "loginItemConfigured") else { return }
        d.set(true, forKey: "loginItemConfigured")
        launchAtLogin = true
    }

    /// Snapshot for WheelCore, which doesn't know about UserDefaults.
    var preferences: Preferences {
        var p = Preferences()
        p.quality = quality
        p.pdfAllPages = pdfAllPages
        p.pdfDPI = pdfDPI
        p.hiddenActions = hiddenActions
        p.sliceOrder = sliceOrder
        p.maxSlices = style.maxSlices
        return p
    }

    // MARK: Profiles

    var profile: WheelProfile {
        WheelProfile(style: style, trigger: trigger, hubSwitch: hubSwitch, hubHoverDelay: hubHoverDelay,
                     toastPlacement: toastPlacement, toastDuration: toastDuration,
                     sliceOrder: sliceOrder, hiddenActions: hiddenActions.sorted())
    }

    func apply(_ p: WheelProfile) {
        style = p.style
        if let v = p.trigger { trigger = v }
        if let v = p.hubSwitch { hubSwitch = v }
        if let v = p.hubHoverDelay { hubHoverDelay = min(max(v, 0.15), 2) }
        if let v = p.toastPlacement { toastPlacement = v }
        if let v = p.toastDuration { toastDuration = min(max(v, 1), 15) }
        if let v = p.sliceOrder { sliceOrder = v }
        if let v = p.hiddenActions { hiddenActions = Set(v) }
    }

    func resetLook() {
        style = WheelStyle()
        hubSwitch = .both; hubHoverDelay = 0.45
        toastPlacement = .cursor; toastDuration = 4
        sliceOrder = [:]; hiddenActions = []
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                WheelLog.shared.error("Launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}
