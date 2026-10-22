import ApplicationServices
import Combine
import WheelCore
import SwiftUI

/// First-run screen. Wheel's drag detection works without permissions; Accessibility only adds Esc-to-cancel.
struct OnboardingView: View {
    var onDone: () -> Void
    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "circle.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading) {
                    Text("Wheel").font(.title.bold())
                    Text("Convert and edit files by dragging them.").foregroundStyle(.secondary)
                }
            }

            step(1, "Start dragging any file", "From Finder or the Desktop.")
            step(2, "Hold \(Settings.shared.trigger.title)", "A wheel appears under the cursor.")
            step(3, "Drop on a slice", "The result is saved next to the original. Originals are never changed. To switch between Convert, Edit and (for several files) Combine, move off the centre and back onto it.")

            GroupBox {
                HStack(alignment: .top) {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "hand.raised")
                        .foregroundStyle(trusted ? Color.green : Theme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility (optional)").bold()
                        Text(trusted ? "Granted. Esc closes the wheel while dragging."
                                     : "Lets Esc close the wheel mid-drag. Everything else works without it.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !trusted {
                            Button("Open Accessibility Settings…") {
                                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                AXIsProcessTrustedWithOptions(opts)
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(4)
            }

            Label {
                Text("Wheel keeps a private diagnostic log on this Mac to help fix crashes. It's never uploaded. Turn it off any time in Settings → General.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Get Started", action: onDone).buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 490)
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
