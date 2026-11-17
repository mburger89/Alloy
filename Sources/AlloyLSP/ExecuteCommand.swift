import AlloyCore
import Foundation
import MetalUICodeBuffer

extension LSPManager {
    /// Runs `command` on the server `serverID` of `path` through `workspace/executeCommand`. A command the server did not
    /// list in its `executeCommandProvider` is refused with `.unavailable`. The server may ask for an edit meanwhile;
    /// that arrives as `LSPResult.applyEdit`. Times out after 5 s.
    public func executeCommand(path: String, serverID: String, command: CodeActionCommand,
                               snapshot: CodeSnapshot) async -> LSPOutcome<Void> {
        guard let target = requestTargets(path: path, roles: [.main, .linter]).first(where: { $0.id == serverID }) else {
            return .unavailable
        }
        guard (try? await target.server.connection()) != nil, !Task.isCancelled else { return .unavailable }
        let known = target.capabilities
        let caps = if let known { known } else { await target.server.capabilities }
        guard let caps, caps.executeCommands.contains(command.command) else { return .unavailable }
        noteCommand(path: path, serverID: serverID)
        return await send(.executeCommand, path: path, snapshot: snapshot, target: target, timeout: .seconds(5),
                          params: { _, _ in
            .object(["command": .string(command.command), "arguments": .array(command.arguments)])
        }, parse: { _, _, _ in () })
    }
}
