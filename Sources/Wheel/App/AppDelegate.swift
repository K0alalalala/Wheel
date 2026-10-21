import AppKit
import WheelCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let wheel = WheelPanel()
    private let monitor = DragMonitor()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var hideAfterMouseUp: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory) // belt and braces with LSUIElement
        Preferences.current = { Settings.shared.preferences }
        ActionRegistry.shared.register(EditToolsProvider())
        buildStatusItem()

        wheel.onDrop = { action, urls in ActionRunner.shared.run(action, on: urls) }
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        if Settings.shared.enabled { monitor.start() }

        #if DEBUG
        if runPreviewIfRequested() { return }
        #endif
        Settings.shared.enableLaunchAtLoginOnFirstRun()
        if !Settings.shared.onboarded { showOnboarding() }
    }

    #if DEBUG
    /// Developer hook for checking visuals without a real drag:
    ///   Wheel --preview wheel <file> [convert|edit] [sliceIndex]
    ///   Wheel --preview <action id, e.g. edit.crop> <file>
    private func runPreviewIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--preview"), args.count > i + 2 else { return false }
        let what = args[i + 1], file = URL(fileURLWithPath: args[i + 2])
        if what == "settings" {
            showSettings(tab: args[i + 2])
            if let s = args.firstIndex(of: "--snapshot"), args.count > s + 1 {
                let out = URL(fileURLWithPath: args[s + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let view = self.settingsWindow?.contentView?.superview,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    }
                    NSApp.terminate(nil)
                }
            }
            return true
        }
        if what == "wheel" {
            if let p = args.firstIndex(of: "--preset"), args.count > p + 1, let preset = StylePreset(rawValue: args[p + 1]) {
                wheel.model.styleOverride = preset.style // preview only; not saved
            }
            let screen = NSScreen.main?.frame ?? .zero
            wheel.show(at: CGPoint(x: screen.midX, y: screen.midY), urls: [file])
            if args.count > i + 3, args[i + 3] == "edit", wheel.model.mode != .edit { wheel.model.toggleMode() }
            if args.count > i + 4, let n = Int(args[i + 4]) { wheel.model.hover = n < 0 ? .hub : .slice(n) }
            if let s = args.firstIndex(of: "--snapshot"), args.count > s + 1 {
                let out = URL(fileURLWithPath: args[s + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.wheel.snapshot(to: out)
                    NSApp.terminate(nil)
                }
            }
        } else if let action = ActionRegistry.shared.allActions(for: FileKind.of(file), mode: .edit).first(where: { $0.id == what })
                    ?? ActionRegistry.shared.allActions(for: FileKind.of(file), mode: .convert).first(where: { $0.id == what }) {
            ActionRunner.shared.run(action, on: [file])
            if let s = args.firstIndex(of: "--snapshot"), args.count > s + 1 {
                let out = URL(fileURLWithPath: args[s + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if let view = NSApp.windows.first(where: { $0.isVisible && $0 is KeyablePanel })?.contentView,
                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        return true
    }
    #endif

    private func handle(_ event: DragMonitor.Event) {
        #if DEBUG
        NSLog("Wheel drag event: %@", String(describing: event))
        #endif
        switch event {
        case .show(let point, let urls):
            hideAfterMouseUp?.cancel()
            wheel.show(at: point, urls: urls)
        case .hide:
            wheel.hide()
        case .mouseUp:
            // The drop reaches us just after the button goes up; give performDragOperation time to run first.
            let work = DispatchWorkItem { [weak self] in self?.wheel.hide() }
            hideAfterMouseUp = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Wheel")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        if Settings.shared.enabled { monitor.start() } else { monitor.stop() }
        updateIcon()
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = !Settings.shared.enabled
    }

    @objc func openSettings() { showSettings(tab: "general") }

    func showSettings(tab: String) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Wheel Settings"
            w.contentView = NSHostingView(rootView: SettingsView(onShowOnboarding: { [weak self] in self?.showOnboarding() }, tab: tab))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About Wheel"
            w.contentView = NSHostingView(rootView: AboutView())
            w.isReleasedWhenClosed = false
            w.center()
            aboutWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 440),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Welcome to Wheel"
            w.contentView = NSHostingView(rootView: OnboardingView(onDone: { [weak self] in
                Settings.shared.onboarded = true
                self?.onboardingWindow?.close()
            }))
            w.isReleasedWhenClosed = false
            w.center()
            onboardingWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt on open so the Enable item always reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.state = Settings.shared.enabled ? .on : .off
        enabled.target = self
        menu.addItem(enabled)
        let hint = NSMenuItem(title: "Drag a file and hold \(Settings.shared.trigger.title)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About Wheel", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Wheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
