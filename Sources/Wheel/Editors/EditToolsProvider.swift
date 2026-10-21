import Foundation
import WheelCore

/// The Edit wheel. To add a tool: write a `FileAction` (plus its editor view) and list it here.
struct EditToolsProvider: ActionProvider {
    /// Slice order, clockwise from the top.
    static let tools: [FileAction] = [
        CompressAction(), MetadataAction(), AdjustAction(), AnnotateAction(),
        AddBackgroundAction(), CropAction(), RedactAction(),
    ]

    func actions(for kind: FileKind, mode: WheelMode) -> [FileAction] {
        mode == .edit ? Self.tools : []
    }
}
