import AlloyCore
import AlloyPlugins
import AlloyRPC
import Foundation

/// Events plugins hear of: documents opening, saving and closing (`project.read`), sessions and tools (`sessions.read`),
/// the `document/text` request, and `window/showMessage`. Everything here is a notification handed to the ordered pump;
/// nothing waits on a plugin, and a plugin that is not running is not started by an event (only `onLanguage:<id>` does).
extension PluginCoordinator {
    /// Listens for the workspace's session and tool events (called when a workspace is bound).
    func installSessionEvents(on workspace: Workspace) {
        workspace.onSessionEvent = { [weak self] event in self?.forwardSessionEvent(event) }
    }

    private func pluginsHolding(_ permission: PluginPermission) -> [String] {
        appliedConfigs.compactMap { $0.value.grants.contains(permission) ? $0.key : nil }.sorted()
    }

    func documentURI(_ path: String) -> String? {
        guard let root = workspace?.projectRoot else { return nil }
        return URL(fileURLWithPath: root.path + "/" + path).absoluteString
    }

    private func openedParams(_ path: String, version: Int) -> JSONValue? {
        guard let uri = documentURI(path) else { return nil }
        return .object(["uri": .string(uri), "languageId": .string(languageID(forPath: path) ?? "plaintext"),
                        "version": .number(Double(version))])
    }

    /// A document opened, was saved or closed: running plugins with `project.read` hear of it; a plugin that activates on
    /// the document's language is started by an open.
    func forwardDocumentEvent(_ event: DocumentEvent) {
        guard hasHost else { return }
        let readers = pluginsHolding(.projectRead)
        switch event {
        case .opened(let path, let version):
            if let params = openedParams(path, version: version) { notifyPlugins(readers, "document/opened", params) }
            if let language = languageID(forPath: path) {
                for id in readers where installedManifests[id]?.activationEvents.contains(.language(language)) == true {
                    activateAsync(id, .language)
                }
            }
        case .saved(let path, let version):
            if let uri = documentURI(path) {
                notifyPlugins(readers, "document/saved", .object(["uri": .string(uri), "version": .number(Double(version))]))
            }
        case .closed(let path):
            if let uri = documentURI(path) { notifyPlugins(readers, "document/closed", .object(["uri": .string(uri)])) }
        }
    }

    /// A plugin's process just started: it hears of every document that is open now.
    func pluginStartedForEvents(_ id: String) {
        guard appliedConfigs[id]?.grants.contains(.projectRead) == true, let workspace else { return }
        for path in workspace.openDocumentPaths {
            guard let doc = workspace.document(path), let params = openedParams(path, version: Int(doc.buffer.version)) else { continue }
            notifyPlugin(id, "document/opened", params)
        }
    }

    func forwardSessionEvent(_ event: SessionPluginEvent) {
        guard hasHost else { return }
        let readers = pluginsHolding(.sessionsRead)
        guard !readers.isEmpty else { return }
        switch event {
        case .turnEnded(let session, let isError, let agent):
            notifyPlugins(readers, "session/turnEnded",
                          .object(["sessionId": .string(session.uuidString), "isError": .bool(isError), "agent": .string(agent)]))
        case .ended(let session, let agent):
            notifyPlugins(readers, "session/ended", .object(["sessionId": .string(session.uuidString), "agent": .string(agent)]))
        case .toolUsed(let session, let tool, let paths):
            notifyPlugins(readers, "claude/toolUsed",
                          .object(["sessionId": .string(session.uuidString), "toolName": .string(tool),
                                   "paths": .array(paths.map { .string($0) })]))
        }
    }

    /// A request a plugin made to Alloy (the host already checked the permission).
    func answerRequest(from id: String, _ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "document/text": return documentText(params)
        case "project/read": return await projectRead(params)
        case "project/write": return await projectWrite(params)
        case "state/get": return await stateGet(id, params)
        case "state/set": return await stateSet(id, params)
        default: return .failure(JSONRPCError(code: JSONRPCError.methodNotFoundCode, message: "Method not found: \(method)"))
        }
    }

    private func documentText(_ params: JSONValue?) -> Result<JSONValue, JSONRPCError> {
        guard let uri = params?["uri"]?.stringValue, let path = relativePath(forURI: uri), let doc = workspace?.document(path) else {
            return .failure(JSONRPCError(code: -32012, message: "not open"))
        }
        let snapshot = doc.buffer.snapshot()
        return .success(.object(["text": .string(snapshot.text), "version": .number(Double(snapshot.version))]))
    }

    /// `window/showMessage`: a workspace notice prefixed with the plugin's name, at most one per `toastInterval` per plugin.
    func showMessage(id: String, type: String, message: String) {
        guard isActive(id), let workspace else { return }
        let now = clock.now
        if let last = lastToast[id], now - last < limits.toastInterval {
            appendLog(plugin: id, "Message dropped (too frequent): \(message)")
            return
        }
        lastToast[id] = now
        let kind: NoticeKind = type == "error" ? .error : type == "warning" ? .warning : .commandOutput
        workspace.postPluginNotice("\(installedManifests[id]?.name ?? id): \(message)", kind: kind)
    }
}
