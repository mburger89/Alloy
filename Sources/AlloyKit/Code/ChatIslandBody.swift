import AlloyCore
import Foundation
import MetalUI

/// The chat island's content: the theme bar, the coordination notice and the chat. Chat mode's middle island and Code
/// mode's chat column share it.
struct ChatIslandBody: Component, Equatable {
    let workspace: Workspace
    let store: SessionUIStore
    var themes: ThemeController?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.store === b.store && a.themes === b.themes }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("ChatIslandBody")
        VStack(spacing: 0) {
            if let themes { ThemeBar(themes: themes).equatable() }
            CoordinationNotice(workspace: workspace).equatable()
            LaunchFailureRow(workspace: workspace).equatable()
            ChatView(workspace: workspace, store: store, themes: themes).equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Why the selected session could not start, above its chat. Healthy sessions render nothing, so the row costs no
/// element per frame; it reads only the selection and the session's status.
struct LaunchFailureRow: Component, Equatable {
    let workspace: Workspace

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("LaunchFailureRow")
        if let session = workspace.sessions.first(where: { $0.id == workspace.selectedSessionID }),
           case .failedToLaunch(let message) = session.status {
            Text(verbatim: message.isEmpty ? Workspace.claudeInstallHint : message)
                .font(size: 12).foregroundColor(.errorInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityIdentifier("session-launch-error")
        }
    }
}
