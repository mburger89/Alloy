import Foundation

extension Workspace {
    /// The agent's display name for a backend; "Claude" for the native one, the id when the definition is gone.
    func agentDisplayName(for backend: SessionBackend) -> String {
        guard case .acp(let id) = backend else { return "Claude" }
        return agentDefinitions().first { $0.id == id }?.name ?? id
    }

    /// The name of the default agent ("Claude" when none is set or its definition is gone).
    public var defaultAgentName: String { agentDisplayName(for: defaultBackend) }

    /// Starts the ACP agent of an ACP session. Everything Claude-specific (hooks, `--mcp-config`, resume flags) stays
    /// in `launch`; this path resolves the agent command, its environment and secrets, and hands over to the injected
    /// transport factory.
    func launchACP(_ s: Session, agentID: String) async {
        guard let definition = agentDefinitions().first(where: { $0.id == agentID }) else {
            failLaunch(s, "Unknown agent \"\(agentID)\".")
            return
        }
        guard let factory = makeACPTransport else {
            failLaunch(s, "\(definition.name) is not available in this build.")
            return
        }
        if stoppedDuringLaunch.contains(s.id) || isShuttingDown { markStopped(s); return }
        let detector = agentDetector, secrets = agentSecrets, loginPATH = self.loginPATH
        // Off the main actor: the login-shell lookup and the Keychain can each take a while.
        let prepared = await Task.detached { () -> (URL, [String], [String: String], [String], String?)? in
            guard case .installed(let url) = detector.detect([definition])[0] else { return nil }
            let resolved = definition.resolveEnvironment(store: secrets)
            return (url, detector.launchArgs(for: definition, executable: url), resolved.env, resolved.missing, loginPATH())
        }.value
        guard let (executable, args, env, missing, login) = prepared else {
            let hint = definition.installHint.map { " Install it with: \($0)" } ?? ""
            failLaunch(s, "\(definition.name) was not found.\(hint)")
            return
        }
        if stoppedDuringLaunch.contains(s.id) || isShuttingDown { markStopped(s); return }
        for name in missing {
            s.transcript.appendNotice(kind: .warning, text: "\(definition.name) starts without \(name): add it under Settings, Agents.")
        }
        // Shared notes: the same local server and per-session token as a Claude session gets.
        var mcp: ACPMCPDescriptor?
        var guidance: String?
        // The server is also offered when only a plugin scope applies (then without the guidance text).
        let isTheme = s.purpose == .theme
        var scopes: Set<MCPToolScope> = settings.shareKnowledge ? [.shared] : []
        if isTheme { scopes.insert(.theme) }
        scopes.formUnion(pluginToolScopes())
        if !scopes.isEmpty, let token = await mcpToken(for: s.id, scopes: scopes), let url = serverURL {
            mcp = ACPMCPDescriptor(name: "alloy", url: url.absoluteString, token: token)
            var texts: [String] = []
            if settings.shareKnowledge {
                texts.append(Guidance.text(shareKnowledge: settings.shareKnowledge, shareAcrossProjects: settings.shareAcrossProjects))
            }
            if isTheme { texts.append(ThemeGuidance.acpText) }
            if !texts.isEmpty { guidance = texts.joined(separator: "\n\n") }
        }
        if stoppedDuringLaunch.contains(s.id) || isShuttingDown { markStopped(s); return }
        s.beginProcess()
        sessionRunEnded.remove(s.id)
        let sessionID = s.id
        var configuration = ACPLaunchConfiguration(
            agent: definition, executable: executable, arguments: args, projectDirectory: projectRoot,
            sessionID: s.id, acpSessionID: s.acpSessionID, resume: s.acpSessionID == nil ? .new : .resume,
            env: env, loginPATH: login, mcp: mcp, systemPrompt: guidance,
            fileService: ACPSessionFiles(workspace: self, session: s.id, root: projectRoot))
        configuration.history = ACPHistory(directory: acpHistoryDirectory, sessionID: s.id)
        configuration.autoAllowAlloyTools = mcp != nil && settings.shareKnowledge && !settings.askBeforeSharedNotes
        if isTheme {
            // The theme tools are pre-approved like a Claude theme session's; an agent that cannot take them gets the
            // file-writing prompt and a notice instead (set even when the server is not running).
            configuration.autoAllowThemeTools = mcp != nil && !settings.askBeforeSharedNotes
            let folder = themeWorkshop?.themesFolderPath ?? ThemeLibrary.userDirectory(appSupport: appSupport).path
            configuration.promptWithoutTools = ThemeGuidance.fileModeText(themesFolder: folder)
            configuration.toolsUnavailableNotice = "\(definition.name) can't use Alloy's theme tools, so it will write the theme "
                + "file into your themes folder instead; Alloy picks it up live."
        }
        configuration.leadingContext = { [weak self] in await self?.takeACPOverlapContext(for: sessionID) }
        let transport = factory(configuration)
        let stream: AsyncStream<ProcessEvent>
        do { stream = try await transport.start() } catch {
            failLaunch(s, "Could not start \(definition.name): \(error.localizedDescription)")
            return
        }
        if stoppedDuringLaunch.contains(s.id) || isShuttingDown {
            await transport.stopAndWait(timeout: .seconds(3))
            markStopped(s)
            return
        }
        await runSession(s, transport: transport, stream: stream, initialStatus: .starting)
    }
}

extension Workspace {
    /// Where Alloy keeps the history files of ACP sessions (the translated wire lines), beside the other per-project state.
    var acpHistoryDirectory: URL { storeDirectory.appendingPathComponent("acp-history", isDirectory: true) }

    /// Send now: the queued message `messageID` goes first and the running turn is cancelled so it starts at once.
    public func sendNow(_ messageID: UUID, in id: Session.ID) async {
        guard !isShuttingDown, let s = session(id), s.backend.isACP, let t = live[id]?.transport,
              s.queued.contains(messageID) else { return }
        await deliver(.user(content: [], uuid: messageID, priority: .now), via: t, to: s)
    }

    /// What an ACP transport asks of the workspace beyond the ordinary events. True when it was one of those.
    func handleACPRequest(subtype: String, body: JSONValue, session s: Session) -> Bool {
        switch subtype {
        case "acp_auth_terminal":
            let command = (body["command"]?.arrayValue ?? []).compactMap(\.stringValue)
            var env: [String: String] = [:]
            for (k, v) in body["env"]?.objectValue ?? [:] { if let text = v.stringValue { env[k] = text } }
            guard !command.isEmpty else { return true }
            openACPAuthTerminal(command: command, env: env)
            return true
        case "acp_reinitialize":
            let id = s.id
            track { [weak self] in await self?.restartACP(id) }
            return true
        default:
            return false
        }
    }

    /// A terminal tab (Code mode) that starts the agent's own sign-in. The line is typed into the tab's shell once it runs.
    func openACPAuthTerminal(command: [String], env: [String: String]) {
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let words = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(quoted($0.value))" } + command.map(quoted)
        let pane = UUID()
        var layout = terminalLayout
        layout.addTab(cwd: projectRoot.path, paneID: pane)
        terminalStartupInput[pane] = (words.joined(separator: " ") + "\n")
        if mode != .code { setMode(.code) }
        terminalLayout = layout
    }

    /// Queues text for a new pane (see `takeTerminalStartupInput`).
    public func queueTerminalStartupInput(_ pane: UUID, _ text: String) { terminalStartupInput[pane] = text }

    /// The text a new terminal pane starts with (an agent sign-in command); taken once, by whoever spawns the pane.
    public func takeTerminalStartupInput(_ pane: UUID) -> String? { terminalStartupInput.removeValue(forKey: pane) }
}

/// One row of the New Session menu: an agent and whether its command was found.
public struct AgentMenuEntry: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var installHint: String?
}

extension Workspace {
    /// The agents whose command was found on the login PATH, in definition order. Empty until `detectAgents()` ran.
    public var installedAgents: [AgentMenuEntry] {
        agentDefinitions().compactMap { def in
            if case .installed = detectedAgents[def.id] { AgentMenuEntry(id: def.id, name: def.name, installHint: nil) } else { nil }
        }
    }

    /// One login-shell lookup for every agent command not yet looked up; agents already answered keep their answer.
    /// `force` forgets every answer and the login-shell caches first (the Detect button), so a command installed
    /// meanwhile is found.
    public func detectAgents(force: Bool = false) async {
        if force {
            cachedLoginPATH = nil
            CommandLocator.resetCache()
            ClaudeLocator.resetLoginShellCache()
            detectedAgents = [:]
        }
        let defs = agentDefinitions().filter { detectedAgents[$0.id] == nil }, detector = agentDetector
        if defs.isEmpty { return }
        let statuses = await Task.detached { detector.detect(defs) }.value
        var found = detectedAgents
        for (d, s) in zip(defs, statuses) { found[d.id] = s }
        detectedAgents = found
    }

    /// The presets and the injected base list, then the user's custom agents from settings (a custom id never shadows one).
    public func agentDefinitions() -> [AgentDefinition] {
        var out = baseAgentDefinitions()
        for def in settings.agents where !out.contains(where: { $0.id == def.id }) { out.append(def) }
        return out
    }

    /// Whether the secret store can hold secrets here; Settings hides the Secrets list when not.
    public var agentSecretsAvailable: Bool { agentSecrets.isAvailable }

    /// The stored secret names (never values) of every agent, as (agent id, variable).
    public func storedAgentSecrets() -> [(agent: String, name: String)] {
        guard agentSecrets.isAvailable else { return [] }
        return agentDefinitions().flatMap { def in
            ((try? agentSecrets.names(agent: def.id)) ?? []).map { (agent: def.id, name: $0) }
        }
    }

    /// Adds or replaces a custom agent. Refuses a secret-looking plain variable (`AgentDefinitionError`) and an id
    /// that belongs to a preset.
    public func saveAgent(_ def: AgentDefinition) throws {
        try def.validate()
        guard !baseAgentDefinitions().contains(where: { $0.id == def.id }) else { throw AgentIDTakenError(id: def.id) }
        var s = settings
        var custom = def
        custom.isPreset = false
        if let i = s.agents.firstIndex(where: { $0.id == def.id }) { s.agents[i] = custom } else { s.agents.append(custom) }
        try updateSettings(s)
        detectedAgents[def.id] = nil
    }

    /// Removes a custom agent, its Keychain items, and the default-agent choice when it pointed at it.
    public func removeAgent(id: String) throws {
        guard let def = settings.agents.first(where: { $0.id == id }) else { return }
        try def.removeSecrets(from: agentSecrets)
        var s = settings
        s.agents.removeAll { $0.id == id }
        if s.defaultAgentID == id { s.defaultAgentID = nil }
        try updateSettings(s)
        detectedAgents[id] = nil
    }

    /// Writes one secret to the store only (never to settings or a log); launch finds it through the store's names.
    /// Returns true when it replaced an existing value. The caller clears its copy of `value` before calling.
    @discardableResult
    public func saveSecret(_ value: String, agent: String, name: String) throws -> Bool {
        let existed = ((try? agentSecrets.names(agent: agent)) ?? []).contains(name)
        try agentSecrets.set(value, agent: agent, variable: name)
        return existed
    }

    /// Deletes one stored secret and forgets its name on a custom agent.
    public func removeSecret(agent: String, name: String) throws {
        try agentSecrets.delete(agent: agent, variable: name)
        guard var s = Optional(settings), let i = s.agents.firstIndex(where: { $0.id == agent }),
              s.agents[i].secretNames.contains(name) else { return }
        s.agents[i].secretNames.removeAll { $0 == name }
        try updateSettings(s)
    }

    /// The agent ⌘N starts: nil is Claude.
    public func setDefaultAgent(_ id: String?) throws {
        var s = settings
        s.defaultAgentID = id
        try updateSettings(s)
    }

    /// The backend ⌘N starts: the default agent when one is set and still defined, else Claude.
    public var defaultBackend: SessionBackend {
        if let id = settings.defaultAgentID, agentDefinitions().contains(where: { $0.id == id }) { return .acp(agentID: id) }
        return .claude
    }
}

/// A custom agent may not reuse a preset's id.
public struct AgentIDTakenError: Error, LocalizedError, Equatable {
    public var id: String
    public var errorDescription: String? { "\"\(id)\" is a built-in agent id; pick another name." }
}
