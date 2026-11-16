import AlloyCore
import Foundation
import MetalUI

/// The chat island's content: the theme bar, the coordination notice and the chat. Chat mode's middle island and Code
/// mode's chat column share it.
struct ChatIslandBody: Component {
    let workspace: Workspace
    let store: SessionUIStore
    var themes: ThemeController?

    var content: some ElementGroup {
        VStack(spacing: 0) {
            if let themes { ThemeBar(themes: themes) }
            CoordinationNotice(workspace: workspace)
            ChatView(workspace: workspace, store: store, themes: themes).equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
