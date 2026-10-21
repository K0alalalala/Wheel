import AppKit
import WheelCore
import SwiftUI

/// The transparent, always-on-top panel that holds the wheel and receives the drop.
@MainActor
final class WheelPanel {
    let model = WheelModel()
    private let panel: NSPanel
    private let dropView: WheelDropView
    /// Called when a file is dropped on an enabled slice.
    var onDrop: ((FileAction, [URL]) -> Void)?

    private var hubTimer: Timer?

    /// Panel side length for the current style, with room for hover scale-up and the shadow.
    private var panelSide: CGFloat { model.geo.diameter * CGFloat(model.style.hoverScale) + 60 }

    init() {
        let size: CGFloat = 400
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        dropView = WheelDropView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        let host = NSHostingView(rootView: WheelView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity))
        host.frame = dropView.bounds
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
        panel.contentView = dropView
        dropView.owner = self
    }

    var isShown: Bool { panel.isVisible }

    #if DEBUG
    /// Renders the panel's content over a gradient into a PNG (developer aid; the blur doesn't capture).
    func snapshot(to url: URL) {
        let view = panel.contentView!
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: view.bounds.size, flipped: false) { r in
            NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])?.draw(in: r, angle: -45)
            rep.draw(in: r)
            return true
        }
        if let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
    #endif

    /// Shows the wheel centred on the cursor, kept on screen.
    func show(at point: CGPoint, urls: [URL]) {
        if !urls.isEmpty { model.load(urls) }
        guard !panel.isVisible else { return }
        // Size follows the style, which may have changed since last time.
        let side = panelSide
        panel.setContentSize(CGSize(width: side, height: side))
        let size = panel.frame.size
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX), f.maxX - size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        model.visible = true
    }

    func hide() {
        hubTimer?.invalidate(); hubTimer = nil
        guard panel.isVisible else { return }
        model.visible = false
        panel.orderOut(nil)
        model.reset()
    }

    // MARK: Drag destination callbacks

    fileprivate func dragMoved(to p: CGPoint, urls: [URL]) -> NSDragOperation {
        if !urls.isEmpty { model.load(urls) }
        let c = CGPoint(x: dropView.bounds.midX, y: dropView.bounds.midY)
        let hit = model.geo.hit(p, center: c, count: model.slices.count)
        if hit != model.hover {
            model.hover = hit
            hubTimer?.invalidate(); hubTimer = nil
            if hit == .hub, Settings.shared.hubSwitch.usesHover {
                // Resting on the hub flips Convert <-> Edit, like a spring-loaded folder.
                hubTimer = Timer.scheduledTimer(withTimeInterval: Settings.shared.hubHoverDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.model.hover == .hub else { return }
                        self.switchMode()
                    }
                }
            }
            if case .slice = hit { haptic(.alignment) }
        }
        if case .slice(let i) = hit, model.slices.indices.contains(i), model.slices[i].isEnabled { return .copy }
        if hit == .hub { return .generic }
        return []
    }

    private func switchMode() {
        model.toggleMode()
        haptic(.generic)
    }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard model.style.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Force click is offered only while the cursor is on the hub.
    fileprivate func springLoadingOptions(at p: CGPoint) -> NSSpringLoadingOptions {
        guard Settings.shared.hubSwitch.usesForce else { return .disabled }
        let c = CGPoint(x: dropView.bounds.midX, y: dropView.bounds.midY)
        return model.geo.hit(p, center: c, count: model.slices.count) == .hub ? [.enabled, .noHover] : .disabled
    }

    /// A firm press on the hub during the drag (macOS spring-loading with `.noHover` = force click only).
    fileprivate func forceClicked() {
        hubTimer?.invalidate(); hubTimer = nil
        switchMode()
    }

    fileprivate func dragExited() {
        model.hover = .none
        hubTimer?.invalidate(); hubTimer = nil
    }

    fileprivate func performDrop(at p: CGPoint, urls: [URL]) -> Bool {
        let c = CGPoint(x: dropView.bounds.midX, y: dropView.bounds.midY)
        let hit = model.geo.hit(p, center: c, count: model.slices.count)
        #if DEBUG
        NSLog("Wheel drop: %@ on %@", String(describing: hit), urls.map(\.lastPathComponent).joined(separator: ", "))
        #endif
        defer { hide() }
        switch hit {
        case .slice(let i) where model.slices.indices.contains(i) && model.slices[i].isEnabled:
            let action = model.slices[i].action
            let files = urls.isEmpty ? model.urls : urls
            DispatchQueue.main.async { self.onDrop?(action, files) }
            return true
        default:
            return false
        }
    }
}

/// AppKit drag destination. SwiftUI's onDrop can't report per-slice hover with the precision we need.
/// Also a spring-loading destination, which is how macOS delivers force clicks during a drag.
final class WheelDropView: NSView, NSSpringLoadingDestination {
    weak var owner: WheelPanel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
    }

    private func point(_ info: NSDraggingInfo) -> CGPoint {
        // Flip to top-left origin to match SwiftUI and WheelGeometry.
        let p = convert(info.draggingLocation, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = point(sender), u = urls(sender)
        return MainActor.assumeIsolated { owner?.dragMoved(to: p, urls: u) ?? [] }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { owner?.dragExited() }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = point(sender), u = urls(sender)
        return MainActor.assumeIsolated { owner?.performDrop(at: p, urls: u) ?? false }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        MainActor.assumeIsolated { owner?.dragExited() }
    }

    // MARK: Force click (spring loading)

    func springLoadingEntered(_ info: NSDraggingInfo) -> NSSpringLoadingOptions { springLoadingUpdated(info) }

    func springLoadingUpdated(_ info: NSDraggingInfo) -> NSSpringLoadingOptions {
        let p = point(info)
        return MainActor.assumeIsolated { owner?.springLoadingOptions(at: p) ?? .disabled }
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo: NSDraggingInfo) {
        guard activated else { return }
        MainActor.assumeIsolated { owner?.forceClicked() }
    }

    func springLoadingHighlightChanged(_ info: NSDraggingInfo) {}
}
