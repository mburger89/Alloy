import AlloyCore
import Foundation
import MetalUI

/// The replace field, Replace All and the inline confirmation for a large replace. A separate component, so the
/// result-dependent enabled state never re-runs `SearchView` while results stream in.
struct SearchReplaceBar: Component {
    let workspace: Workspace

    var content: some ElementGroup {
        let _ = BodyProbe.hit("SearchReplaceBar")
        let model = workspace.search
        let replacement = Binding(get: { model.replacement }, set: { model.replacement = $0 })
        VStack(alignment: .leading, spacing: Pixels(4)) {
            HStack(spacing: Pixels(4)) {
                TextField("Replace", text: replacement)
                    .onSubmit { model.replaceAll() }
                    .accessibilityIdentifier("search-replace")
                Button("Replace All") { model.replaceAll() }
                    .disabled(!model.canReplace || model.pendingConfirm != nil)
                    .accessibilityIdentifier("search-replace-all")
            }
            if let message = model.confirmMessage {
                HStack(spacing: Pixels(6)) {
                    Text(verbatim: message).font(size: searchFontSize).lineLimit(1)
                    Spacer()
                    Button("Replace") { model.confirmReplaceAll() }
                        .accessibilityIdentifier("search-replace-confirm")
                    Button("Cancel") { model.cancelConfirm() }
                        .accessibilityIdentifier("search-replace-cancel")
                }
            }
        }
    }
}
