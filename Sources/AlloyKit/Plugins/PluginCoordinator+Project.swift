import AlloyCore
import AlloyPlugins
import AlloyRPC
import Foundation

/// `project/read`, `project/write` and `state/get`/`state/set`: a plugin's access to the project's files and its own
/// per-project state. The host has already checked `project.read` / `project.write`. Disk work runs off the main actor.
extension PluginCoordinator {
    static let maxReadBytes = 16 << 20

    private func failure(_ code: Int, _ message: String, reason: String) -> Result<JSONValue, JSONRPCError> {
        .failure(JSONRPCError(code: code, message: message, data: .object(["reason": .string(reason)])))
    }

    private func pathParameter(_ params: JSONValue?) -> String? { params?["path"]?.stringValue }

    private enum ReadOutcome: Sendable {
        case text(String)
        case unreadable(String)
    }

    func projectRead(_ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let workspace, let path = pathParameter(params) else {
            return .failure(JSONRPCError(code: -32602, message: "path required"))
        }
        let target: URL
        switch workspace.pluginResolve(path) {
        case .failure(let refusal): return failure(-32010, "read refused", reason: refusal.rawValue)
        case .success(let resolved): target = resolved.url
        }
        let limit = Self.maxReadBytes
        let outcome = await Task.detached { () -> ReadOutcome in
            // Regular files only (a link to one is followed): a FIFO or device would block this thread on open.
            let resolved = target.resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { return .unreadable("missing") }
            if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > limit { return .unreadable("tooLarge") }
            guard let data = try? Data(contentsOf: target) else { return .unreadable("missing") }
            guard let text = String(data: data, encoding: .utf8) else { return .unreadable("binary") }
            return .text(text)
        }.value
        switch outcome {
        case .text(let text): return .success(.object(["text": .string(text)]))
        case .unreadable(let reason): return failure(-32012, "cannot read", reason: reason)
        }
    }

    func projectWrite(_ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let workspace, let path = pathParameter(params), let text = params?["text"]?.stringValue else {
            return .failure(JSONRPCError(code: -32602, message: "path and text required"))
        }
        if let refusal = workspace.pluginWriteRefusal(for: path) { return failure(-32010, "write refused", reason: refusal.rawValue) }
        guard case .success(let resolved) = workspace.pluginResolve(path) else { return failure(-32010, "write refused", reason: "outsideProject") }
        let target = resolved.url
        let wrote = await Task.detached { () -> Bool in
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: target, options: .atomic)
                return true
            } catch { return false }
        }.value
        // The buffer is not touched: the file watcher sees an outside edit and reloads a clean buffer.
        return wrote ? .success(.object([:])) : failure(-32012, "cannot write", reason: "writeFailed")
    }

    private func store() -> PluginStateStore? {
        guard let workspace else { return nil }
        if let stateStore, stateStoreWorkspace == ObjectIdentifier(workspace) { return stateStore }
        let created = PluginStateStore(directory: workspace.projectStoreDirectory.appendingPathComponent("plugin-state", isDirectory: true),
                                       limits: limits, clock: clock)
        stateStore = created
        stateStoreWorkspace = ObjectIdentifier(workspace)
        return created
    }

    func stateGet(_ id: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let key = params?["key"]?.stringValue, let store = store() else {
            return .failure(JSONRPCError(code: -32602, message: "key required"))
        }
        return .success(.object(["value": await store.get(id, key: key) ?? .null]))
    }

    func stateSet(_ id: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let key = params?["key"]?.stringValue, let store = store() else {
            return .failure(JSONRPCError(code: -32602, message: "key required"))
        }
        do { try await store.set(id, key: key, value: params?["value"]) } catch {
            return .failure(JSONRPCError(code: -32011, message: "state too large"))
        }
        return .success(.object([:]))
    }
}
