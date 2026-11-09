import AlloyCore
import MetalUI

/// The gear button at the bottom of the sidebar; it opens the Settings view over the chat column.
struct SettingsButton: Component {
    let workspace: Workspace
    @Binding var showSettings: Bool

    var content: some ElementGroup {
        HStack(spacing: 0) {
            Spacer()
            Button(action: {
                if !showSettings { Task { await workspace.detectClaude() } }
                showSettings = true
            }) {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings")
        }
        .padding(inset(10, 4))
    }
}
