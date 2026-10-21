import AppKit
import SwiftUI

/// sRGB colour that survives JSON round-trips (for theme export).
struct RGBA: Codable, Equatable, Hashable {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? .black
        r = c.redComponent; g = c.greenComponent; b = c.blueComponent; a = c.alphaComponent
    }
    init(hex: Int) { self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255) }

    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(nsColor: ns) }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case wheel, system, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wheel: return "Wheel Orange"
        case .system: return "System Accent"
        case .custom: return "Custom"
        }
    }
}

enum GlassMaterial: String, Codable, CaseIterable, Identifiable {
    case hud, popover, menu, sidebar, header, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hud: return "HUD (smoky)"
        case .popover: return "Popover (bright)"
        case .menu: return "Menu"
        case .sidebar: return "Sidebar"
        case .header: return "Frosted"
        case .solid: return "Solid (no blur)"
        }
    }
    var ns: NSVisualEffectView.Material? {
        switch self {
        case .hud: return .hudWindow
        case .popover: return .popover
        case .menu: return .menu
        case .sidebar: return .sidebar
        case .header: return .headerView
        case .solid: return nil
        }
    }
}

enum SliceFill: String, Codable, CaseIterable, Identifiable {
    case filled, glass, outline
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum LabelMode: String, Codable, CaseIterable, Identifiable {
    case auto, iconsAndText, textOnly, iconsOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .iconsAndText: return "Icon + Text"
        case .textOnly: return "Text"
        case .iconsOnly: return "Icons"
        }
    }
}

enum LabelFont: String, Codable, CaseIterable, Identifiable {
    case standard, rounded, mono, serif
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var design: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        case .serif: return .serif
        }
    }
}

enum AppearAnimation: String, Codable, CaseIterable, Identifiable {
    case pop, fade, spin, bloom, none
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Everything about how the wheel looks and moves. Exported/imported as part of a profile.
struct WheelStyle: Codable, Equatable {
    // Size & shape
    var size = 1.0              // overall scale
    var hubRatio = 0.42         // hub radius ÷ outer radius
    var sliceGap = 4.0          // pt between slices
    var roundness = 12.0        // corner radius of slices, pt
    var rotation = 0.0          // degrees; 0 = first slice at 12 o'clock
    var maxSlices = 8

    // Colour & material
    var accent = AccentChoice.wheel
    var customAccent = RGBA(hex: 0x8B5CF6)
    var material = GlassMaterial.hud
    var discTint = RGBA(r: 1, g: 1, b: 1, a: 0)   // colour wash over the glass
    var sliceFill = SliceFill.filled
    var sliceOpacity = 0.55
    var hoverGradient = true
    var rimHighlight = true
    var dropShadow = true

    // Labels
    var labels = LabelMode.auto
    var labelScale = 1.0
    var uppercase = true
    var font = LabelFont.standard

    // Motion & feel
    var hoverScale = 1.05
    var springiness = 0.35      // 0 = stiff, 1 = very bouncy
    var appear = AppearAnimation.pop
    var haptics = true

    static let classic = WheelStyle()

    var accentNS: NSColor {
        switch accent {
        case .wheel: return Theme.wheelOrange
        case .system: return .controlAccentColor
        case .custom: return customAccent.ns
        }
    }

    var spring: Animation { .spring(response: 0.28, dampingFraction: 1 - springiness * 0.75) }

    // Tolerant decoding: themes saved by older/newer versions still load, missing keys keep defaults.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WheelStyle()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        size = v(.size, d.size); hubRatio = v(.hubRatio, d.hubRatio); sliceGap = v(.sliceGap, d.sliceGap)
        roundness = v(.roundness, d.roundness); rotation = v(.rotation, d.rotation); maxSlices = v(.maxSlices, d.maxSlices)
        accent = v(.accent, d.accent); customAccent = v(.customAccent, d.customAccent); material = v(.material, d.material)
        discTint = v(.discTint, d.discTint); sliceFill = v(.sliceFill, d.sliceFill); sliceOpacity = v(.sliceOpacity, d.sliceOpacity)
        hoverGradient = v(.hoverGradient, d.hoverGradient); rimHighlight = v(.rimHighlight, d.rimHighlight); dropShadow = v(.dropShadow, d.dropShadow)
        labels = v(.labels, d.labels); labelScale = v(.labelScale, d.labelScale); uppercase = v(.uppercase, d.uppercase); font = v(.font, d.font)
        hoverScale = v(.hoverScale, d.hoverScale); springiness = v(.springiness, d.springiness); appear = v(.appear, d.appear); haptics = v(.haptics, d.haptics)
        clamp()
    }

    /// Keeps imported values inside the ranges the UI allows.
    mutating func clamp() {
        size = min(max(size, 0.6), 1.8)
        hubRatio = min(max(hubRatio, 0.25), 0.6)
        sliceGap = min(max(sliceGap, 0), 16)
        roundness = min(max(roundness, 0), 40)
        rotation = rotation.truncatingRemainder(dividingBy: 360)
        maxSlices = min(max(maxSlices, 3), 10)
        sliceOpacity = min(max(sliceOpacity, 0.05), 1)
        labelScale = min(max(labelScale, 0.7), 1.6)
        hoverScale = min(max(hoverScale, 1), 1.2)
        springiness = min(max(springiness, 0), 1)
    }
}

/// Named looks. Picking one replaces the style; everything stays editable afterwards.
enum StylePreset: String, CaseIterable, Identifiable {
    case classic, compact, bigAndBold, liquid, minimal, neon, terminal, bubblegum, system

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .compact: return "Compact"
        case .bigAndBold: return "Big & Bold"
        case .liquid: return "Liquid"
        case .minimal: return "Minimal"
        case .neon: return "Neon"
        case .terminal: return "Terminal"
        case .bubblegum: return "Bubblegum"
        case .system: return "Native"
        }
    }

    var style: WheelStyle {
        var s = WheelStyle()
        switch self {
        case .classic: break
        case .compact:
            s.size = 0.75; s.labels = .iconsOnly; s.sliceGap = 3; s.roundness = 8; s.hubRatio = 0.38
        case .bigAndBold:
            s.size = 1.4; s.labelScale = 1.25; s.font = .rounded; s.hoverScale = 1.08; s.roundness = 18
        case .liquid:
            s.roundness = 30; s.sliceGap = 8; s.font = .rounded; s.springiness = 0.75; s.appear = .bloom
            s.material = .popover; s.sliceFill = .glass; s.hubRatio = 0.36
        case .minimal:
            s.sliceFill = .outline; s.rimHighlight = false; s.hoverGradient = false; s.labels = .textOnly
            s.uppercase = false; s.roundness = 6; s.appear = .fade; s.dropShadow = false
        case .neon:
            s.accent = .custom; s.customAccent = RGBA(hex: 0xFF2BD6); s.material = .hud
            s.discTint = RGBA(r: 0.1, g: 0, b: 0.25, a: 0.45); s.sliceFill = .outline; s.font = .rounded
            s.springiness = 0.6; s.appear = .spin; s.hoverScale = 1.1
        case .terminal:
            s.accent = .custom; s.customAccent = RGBA(hex: 0x22C55E); s.material = .solid
            s.discTint = RGBA(r: 0.04, g: 0.06, b: 0.05, a: 0.92); s.sliceFill = .outline; s.font = .mono
            s.uppercase = false; s.roundness = 0; s.sliceGap = 6; s.rimHighlight = false; s.springiness = 0; s.appear = .none
        case .bubblegum:
            s.accent = .custom; s.customAccent = RGBA(hex: 0xFF6FB5); s.discTint = RGBA(r: 1, g: 0.75, b: 0.9, a: 0.35)
            s.material = .popover; s.roundness = 26; s.sliceGap = 6; s.font = .rounded; s.springiness = 0.9; s.appear = .bloom
            s.hoverScale = 1.12; s.size = 1.1
        case .system:
            s.accent = .system; s.material = .menu; s.hoverGradient = false; s.rimHighlight = false; s.appear = .fade
        }
        return s
    }
}
