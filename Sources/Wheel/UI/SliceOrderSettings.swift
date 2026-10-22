import SwiftUI
import WheelCore

/// Drag to reorder each wheel's slices, toggle to hide them.
struct SliceOrderSettings: View {
    @ObservedObject private var settings = Settings.shared
    @State private var wheel = WheelChoice.convertImage

    enum WheelChoice: String, CaseIterable, Identifiable {
        case convertImage, convertPDF, convertDocument, convertVideo, convertAudio, edit, editPDF, combine
        var id: String { rawValue }
        var title: String {
            switch self {
            case .convertImage: return "Convert · Images"
            case .convertPDF: return "Convert · PDF"
            case .convertDocument: return "Convert · Documents"
            case .convertVideo: return "Convert · Video"
            case .convertAudio: return "Convert · Audio"
            case .edit: return "Edit · Images"
            case .editPDF: return "Edit · PDF"
            case .combine: return "Combine (several files)"
            }
        }
        var kind: FileKind {
            switch self {
            case .convertImage, .edit, .combine: return .image
            case .convertPDF, .editPDF: return .pdf
            case .convertDocument: return .document
            case .convertVideo: return .video
            case .convertAudio: return .audio
            }
        }
        var mode: WheelMode {
            switch self {
            case .edit, .editPDF: return .edit
            case .combine: return .combine
            default: return .convert
            }
        }
        var key: String { ActionRegistry.orderKey(kind: kind, mode: mode) }
    }

    private var actions: [FileAction] {
        let sample = URL(fileURLWithPath: "/Preview/Example." + (wheel.kind == .pdf ? "pdf" : "png"))
        let all = ActionRegistry.shared.allActions(for: wheel.kind, mode: wheel.mode)
            .filter { wheel.mode != .edit || $0.supports(sample) }
        return ActionRegistry.shared.ordered(all, kind: wheel.kind, mode: wheel.mode, prefs: settings.preferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Wheel", selection: $wheel) {
                ForEach(WheelChoice.allCases) { Text($0.title).tag($0) }
            }
            Text("Drag to reorder. The first slice sits at the top (adjust with Appearance → Rotation) and the rest go clockwise. The wheel shows the first \(settings.style.maxSlices) visible slices.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, action in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text("\(i + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                        Label(action.title, systemImage: action.symbol)
                        if let reason = action.unavailableReason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !settings.hiddenActions.contains(action.id) },
                            set: { if $0 { settings.hiddenActions.remove(action.id) } else { settings.hiddenActions.insert(action.id) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    var ids = actions.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    settings.sliceOrder[wheel.key] = ids
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            HStack {
                Spacer()
                Button("Restore Default Order") { settings.sliceOrder[wheel.key] = nil }
                    .disabled(settings.sliceOrder[wheel.key] == nil)
            }
        }
        .padding()
    }
}
