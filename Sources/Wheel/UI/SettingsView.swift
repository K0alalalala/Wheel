import SwiftUI
import WheelCore

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared
    var onShowOnboarding: () -> Void
    @State var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
            SliceOrderSettings().tabItem { Label("Slices", systemImage: "circle.grid.cross") }.tag("slices")
            backends.tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }.tag("tools")
            ScrollView { AboutView().frame(maxWidth: .infinity) }.tabItem { Label("About", systemImage: "info.circle") }.tag("about")
        }
        .padding()
        .frame(minWidth: 640, minHeight: 640)
    }

    private var general: some View {
        Form {
            Section("Trigger") {
                Picker("Hold while dragging", selection: $settings.trigger) {
                    ForEach(TriggerModifier.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Enabled", isOn: $settings.enabled)
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0 }))
            }
            Section("Centre hub") {
                Picker("Switch Convert ⇄ Edit with", selection: $settings.hubSwitch) {
                    ForEach(HubSwitch.allCases) { Text($0.title).tag($0) }
                }
                if settings.hubSwitch.usesHover {
                    LabeledContent("Hover delay") {
                        HStack {
                            Slider(value: $settings.hubHoverDelay, in: 0.15...1.5)
                            Text(String(format: "%.2fs", settings.hubHoverDelay)).monospacedDigit().frame(width: 44)
                        }
                    }
                }
                if settings.hubSwitch.usesForce {
                    Text("Force Click: while dragging, press firmly on the hub (Force Touch trackpad or Magic Trackpad).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Progress toast") {
                Picker("Position", selection: $settings.toastPlacement) {
                    ForEach(ToastPlacement.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Stays for") {
                    HStack {
                        Slider(value: $settings.toastDuration, in: 1...12, step: 0.5)
                        Text(String(format: "%.1fs", settings.toastDuration)).monospacedDigit().frame(width: 44)
                    }
                }
            }
            Section("Output") {
                HStack {
                    Text("JPEG / HEIC / WEBP quality")
                    Slider(value: $settings.quality, in: 0.3...1)
                    Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 40)
                }
                Toggle("Reveal in Finder after saving", isOn: $settings.revealAfterSave)
                Toggle("PDF → image: convert every page", isOn: $settings.pdfAllPages)
                Picker("PDF render resolution", selection: $settings.pdfDPI) {
                    ForEach([72, 150, 200, 300, 600], id: \.self) { Text("\($0) dpi").tag($0) }
                }
            }
            DiagnosticsSection()
            Section {
                Button("Show permissions & setup…", action: onShowOnboarding)
            }
        }
        .formStyle(.grouped)
    }

    private var backends: some View {
        Form {
            Section {
                tool("ffmpeg", ExternalTools.ffmpeg, "MP3, FLAC, GIF, WEBM, and other audio/video", "brew install ffmpeg")
                tool("cwebp", ExternalTools.cwebp, "WEBP output", "brew install webp")
                tool("pandoc", ExternalTools.pandoc, "Better Markdown → PDF/DOCX", "brew install pandoc")
            } header: {
                Text("Optional command-line tools")
            } footer: {
                Text("Images, PDF, DOCX, RTF, HTML, TXT, MP4, MOV, M4A, WAV and AIFF work with no extra installs.")
            }
            Button("Check again") { ExternalTools.refresh(); settings.objectWillChange.send() }
        }
        .formStyle(.grouped)
    }

    private func tool(_ name: String, _ url: URL?, _ purpose: String, _ install: String) -> some View {
        HStack {
            Image(systemName: url == nil ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(url == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading) {
                Text(name).bold()
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if url == nil {
                Text(install).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else {
                Text(url!.path).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
