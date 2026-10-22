import AppKit
import WheelCore

MainActor.assumeIsolated {
    #if DEBUG
    AppDelegate.prepareReadmeShots() // must run before Settings.shared exists
    #endif
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
