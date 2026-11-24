import Foundation

/// What a session or its tools did, as plugins with `sessions.read` hear of it (`Workspace.onSessionEvent`). `agent` is
/// `"claude"` for the native backend, else the ACP agent definition id; `paths` are project-relative.
public enum SessionPluginEvent: Sendable, Equatable {
    case turnEnded(sessionID: UUID, isError: Bool, agent: String)
    case ended(sessionID: UUID, agent: String)
    case toolUsed(sessionID: UUID, toolName: String, paths: [String])
}
