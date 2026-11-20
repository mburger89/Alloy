import Foundation

/// The built-in agents. Alloy never installs them; it shows the install command.
public enum AgentPresets {
    public static let all: [AgentDefinition] = [
        AgentDefinition(id: "codex", name: "Codex", command: "codex-acp",
                        installHint: "npm install -g @agentclientprotocol/codex-acp", isPreset: true),
        AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", args: ["--acp"],
                        installHint: "npm install -g @google/gemini-cli", isPreset: true),
        AgentDefinition(id: "opencode", name: "OpenCode", command: "opencode", args: ["acp"],
                        installHint: "brew install opencode", isPreset: true),
        AgentDefinition(id: "goose", name: "Goose", command: "goose", args: ["acp"],
                        installHint: "brew install block-goose-cli", isPreset: true),
    ]

    /// Older Gemini CLI releases only know this flag.
    public static let geminiFallbackArgs = ["--experimental-acp"]

    public static func preset(id: String) -> AgentDefinition? { all.first { $0.id == id } }
}
