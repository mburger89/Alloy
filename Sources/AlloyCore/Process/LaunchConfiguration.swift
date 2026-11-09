import Foundation

public struct LaunchConfiguration: Sendable, Equatable {
    public var executable: URL
    public var projectDirectory: URL
    public var sessionID: UUID
    public var resume: Bool
    /// With `resume`, the CLI conversation to resume (it differs from `sessionID` after `/clear`).
    public var resumeID: String?
    public var extraSettingsJSON: String?
    public var mcpConfigJSON: String?
    /// The login shell's PATH, merged in front of the child's own PATH (a GUI launch has a minimal one).
    public var loginPATH: String?
    /// Guidance appended to the CLI's system prompt (`--append-system-prompt`, with the snapshot turned off).
    public var appendSystemPrompt: String?
    /// Tools approved without asking (`--allowedTools`, comma-joined).
    public var allowedTools: [String]
    /// With `resume`, branch into a new conversation instead of continuing the source one.
    public var forkSession: Bool
    /// With `resume` and `forkSession`, the message uuid to fork at (`--resume-session-at`, an undocumented flag the
    /// CLI accepts; see protocol-notes-plan5.md). Without it a fork starts from the source's latest message.
    public var resumeSessionAt: String?

    public init(executable: URL, projectDirectory: URL, sessionID: UUID, resume: Bool, resumeID: String? = nil,
                extraSettingsJSON: String? = nil, mcpConfigJSON: String? = nil, loginPATH: String? = nil,
                appendSystemPrompt: String? = nil, allowedTools: [String] = [], forkSession: Bool = false) {
        self.appendSystemPrompt = appendSystemPrompt
        self.allowedTools = allowedTools
        self.forkSession = forkSession
        self.loginPATH = loginPATH
        self.executable = executable
        self.projectDirectory = projectDirectory
        self.sessionID = sessionID
        self.resume = resume
        self.resumeID = resumeID
        self.extraSettingsJSON = extraSettingsJSON
        self.mcpConfigJSON = mcpConfigJSON
    }

    public func arguments() -> [String] {
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                    "--thinking-display", "summarized",
                    resume ? "--resume" : "--session-id",
                    resume ? (resumeID ?? sessionID.uuidString.lowercased()) : sessionID.uuidString.lowercased()]
        if resume && forkSession {
            args.append("--fork-session")
            if let resumeSessionAt { args += ["--resume-session-at", resumeSessionAt] }
        }
        if let extraSettingsJSON { args += ["--settings", extraSettingsJSON] }
        if let mcpConfigJSON { args += ["--mcp-config", mcpConfigJSON] }
        if let appendSystemPrompt { args += ["--append-system-prompt", appendSystemPrompt, "--system-prompt-snapshot", "off"] }
        if !allowedTools.isEmpty { args += ["--allowedTools", allowedTools.joined(separator: ",")] }
        return args
    }
}
