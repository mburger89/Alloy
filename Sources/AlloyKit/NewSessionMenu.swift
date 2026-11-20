import AlloyCore
import Foundation
import MetalUI

/// The New Session menu: Claude first, then every agent found on the PATH, then "Add agent...". It sits beside the
/// sidebar's "+" (which, like ⌘N and the title pill, starts the default agent). Closed, it is one button.
struct NewSessionMenu: Component {
    let workspace: Workspace

    /// The rows in order, for tests: Claude, one per installed agent, then Add agent.
    static func itemIDs(_ agents: [AgentMenuEntry]) -> [String] {
        ["new-session-claude"] + agents.map { "new-session-agent-\($0.id)" } + ["new-session-add-agent"]
    }

    var content: some ElementGroup {
        let workspace = workspace
        let agents = workspace.installedAgents
        Menu {
            items(agents)
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 10)).foregroundColor(.mutedInk).padding(Pixels(4))
        }
        .help("New session with\u{2026}")
        .accessibilityLabel("New session with an agent")
        .accessibilityIdentifier("new-session-menu")
        .padding(inset(2, 0))
    }

    @MenuContentBuilder
    private func items(_ agents: [AgentMenuEntry]) -> some MenuContent {
        Button("Claude") { workspace.startNewSession(backend: .claude) }
            .accessibilityIdentifier("new-session-claude")
        for agent in agents {
            Button(agent.name) { workspace.startNewSession(backend: .acp(agentID: agent.id)) }
                .accessibilityIdentifier("new-session-agent-\(agent.id)")
        }
        Button("Add agent\u{2026}") { workspace.onAddAgent?() }
            .accessibilityIdentifier("new-session-add-agent")
    }
}
