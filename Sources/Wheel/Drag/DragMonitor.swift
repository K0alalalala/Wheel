import AppKit
import WheelCore

/// Watches for "a file drag is in progress AND the trigger modifier is held".
///
/// Detection combines:
/// - polling `NSEvent.pressedMouseButtons` / `modifierFlags` (works without any permission),
/// - global event monitors for snappier response (mouse events need no permission; Esc needs Accessibility),
/// - the drag pasteboard's change count, which bumps when any app starts a drag.
@MainActor
final class DragMonitor {
    enum Event { case show(CGPoint, [URL]), hide, mouseUp }

    var onEvent: ((Event) -> Void)?

    private var timer: Timer?
    private var monitors: [Any] = []
    private let dragPasteboard = NSPasteboard(name: .drag)

    private var mouseWasDown = false
    private var changeCountAtPress = 0
    private var fileDragActive = false
    private var showing = false
    /// Set by Esc; keeps the wheel closed until the mouse is released.
    private var suppressed = false

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.005
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }) { monitors.append(g) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            MainActor.assumeIsolated { if e.keyCode == 53 { self?.cancel() } }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask.union(.keyDown), handler: { [weak self] e in
            MainActor.assumeIsolated {
                if e.type == .keyDown, e.keyCode == 53, self?.showing == true { self?.cancel() }
                self?.tick()
            }
            return e
        }) { monitors.append(l) }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if showing { showing = false; onEvent?(.hide) }
    }

    /// Esc: close the wheel and ignore the rest of this drag.
    func cancel() {
        suppressed = true
        if showing { showing = false; onEvent?(.hide) }
    }

    /// Files on the drag pasteboard, so the wheel can fill in before the first draggingEntered.
    private func draggedFiles() -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return dragPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1

        if !down {
            if mouseWasDown {
                mouseWasDown = false
                fileDragActive = false
                suppressed = false
                if showing { showing = false; onEvent?(.mouseUp) }
            }
            return
        }

        if !mouseWasDown {
            mouseWasDown = true
            changeCountAtPress = dragPasteboard.changeCount
            fileDragActive = false
        }

        // A new drag writes the drag pasteboard. Only file drags count.
        if !fileDragActive, dragPasteboard.changeCount != changeCountAtPress {
            let types = dragPasteboard.types ?? []
            fileDragActive = types.contains(.fileURL)
            changeCountAtPress = dragPasteboard.changeCount
        }

        let modifierHeld = NSEvent.modifierFlags.contains(Settings.shared.trigger.flag)
        if fileDragActive, modifierHeld, !showing, !suppressed {
            showing = true
            onEvent?(.show(NSEvent.mouseLocation, draggedFiles()))
        } else if showing, !modifierHeld {
            showing = false
            onEvent?(.hide)
        }
    }
}
