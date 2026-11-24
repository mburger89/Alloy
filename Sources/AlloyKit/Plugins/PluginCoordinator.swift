import AlloyCore
import AlloyPlugins
import AlloyRPC
import Foundation

public enum PluginError: Error, Equatable {
    case noWorkspace
    case unknownPlugin(String)
    case badManifest(String)
    case needsAPI(Int)
    case sandboxUnavailable
    case scriptedUnsupported
}

/// What the coordinator's ordered pump hands the host, one at a time, in the order the app issued them.
private enum HostCommand: Sendable {
    case configure([PluginRuntimeConfig])
    case activate(String, ActivationReason, reply: (@Sendable (Bool) -> Void)?)
    case notify([String], String, JSONValue?)
    case workspace(URL?)
    case setPanelOpen(String, Bool)
    case forgetDecorations(plugin: String?, uri: String)
    case stop(String)
    case shutdown
}

private struct ThemeFileRef: Equatable {
    let pluginID: String
    let url: URL
}

/// One host with the task that feeds it and the task that reads its events.
private struct HostPump {
    let host: PluginHost
    let commands: AsyncStream<HostCommand>.Continuation
    let pump: Task<Void, Never>
    let events: Task<Void, Never>
}

/// The one app-wide plugin owner. It applies what enabled plugins contribute (themes, language servers), runs scripted
/// plugins through a `PluginHost` and feeds the status model that Settings › Plugins reads. Not observable: nothing in a
/// view body reads it. With no enabled plugin it holds no host, task or timer, and a settings change that moves no
/// contribution changes nothing.
@MainActor
public final class PluginCoordinator {
    public let status = PluginStatusModel()
    /// Test seam for Settings › Plugins' folder picker; nil uses the window's open-folder dialog.
    public var pickFolder: (@MainActor () async -> URL?)?

    private let paths: PluginPaths
    /// The home directory plugin processes start with (tests point it at a temporary one).
    private let home: String
    let registry: CommandRegistry
    private let themes: ThemeController?
    private let pathDirs: @Sendable () -> [String]
    weak var workspace: Workspace?
    /// The command specs registered per plugin, the row notes registration produced and the language ids already looked up
    /// (see `PluginCoordinator+Commands`).
    var registeredCommands: [String: [PluginCommandSpec]] = [:]
    var commandNotes: [String: [String]] = [:]
    /// The center whose registry holds the commands; its shortcut claims vet a plugin's chords (set by `CommandCenter.plugins`).
    weak var center: CommandCenter?
    /// Per command id, why its proposed shortcut was not bound (see `shortcutNote(for:)`).
    var shortcutNotes: [String: String] = [:]
    /// The plugin that owns each command id in `shortcutNotes` (an id is `<plugin id>.<command>`, and a plugin id may itself
    /// be a prefix of another's, so ownership is never derived from the text).
    var shortcutOwners: [String: String] = [:]
    /// The task commands registered per plugin (see `PluginCoordinator+Tasks`).
    var registeredTasks: [String: [PluginTaskSpec]] = [:]
    var languageCache: [String: String?] = [:]
    /// What plugins decorate open documents with (see `PluginCoordinator+Decorations`).
    let decorations = PluginDecorationStore()
    /// The panel tabs and trees (see `PluginCoordinator+Panels`).
    let panels: PluginPanelStore
    /// Plugins whose process went down while a panel was open; the next start re-sends `panel/opened`.
    var panelWasDown: Set<String> = []
    /// When each plugin last posted a `window/showMessage` notice (clock time), for the toast interval.
    var lastToast: [String: Double] = [:]
    /// The bound project's plugin state (created on first use, flushed on shutdown and when the workspace changes).
    var stateStore: PluginStateStore?
    var stateStoreWorkspace: ObjectIdentifier?
    /// The MCP tool specs per plugin the server currently serves, the workspace they went to and the last server update.
    var appliedMCP: [String: [PluginMCPToolSpec]] = [:]
    var mcpWorkspace: ObjectIdentifier?
    var mcpUpdate: Task<Void, Never>?
    /// Test seam: how each command run ended, as the plugin's error code (nil: answered).
    var commandOutcomes: [(plugin: String, command: String, code: Int?)] = [] {
        didSet { if commandOutcomes.count > Self.maxLogLines { commandOutcomes.removeFirst(commandOutcomes.count - Self.maxLogLines) } }
    }
    /// What each plugin's inline Log shows besides its stderr: dropped messages, rejected panel trees, failed commands. At
    /// most `maxLogLines` per plugin, newest last; written only through `appendLog`.
    private(set) var commandErrors: [String: [String]] = [:]
    static let maxLogLines = 50

    /// Adds a line to the plugin's log (token shapes hidden now, its secret values when the log is read), keeping the newest 50.
    func appendLog(plugin: String, _ line: String) {
        var lines = commandErrors[plugin] ?? []
        lines.append(PluginLogRedactor.redact(line))
        if lines.count > Self.maxLogLines { lines.removeFirst(lines.count - Self.maxLogLines) }
        commandErrors[plugin] = lines
    }
    /// Test seam: how git is run for installs and update checks.
    var gitRunner: any PluginGitRunner = LivePluginGitRunner()
    /// What the last update check found per plugin, and the update it offers (shown by the row's Update button).
    private var updateStates: [String: PluginRowUpdate] = [:]
    private var availableUpdates: [String: PluginUpdate] = [:]
    /// Plugins whose new version has not started yet, with the settings entry to put back if it never does.
    private var pendingPrevious: [String: PluginSetting] = [:]
    /// Plugins whose update runs right now, and whether an install from git does: a second request is a no-op.
    private var updatesInFlight: Set<String> = []
    private var catalog: [String: PluginCatalogEntry] = [:]
    private var appliedThemes: [ThemeEntry] = []
    private var appliedServers: [String: ServerConfigOverride] = [:]
    private weak var appliedLSP: LSPCoordinator?
    let clock: any AutosaveClock
    private let probe: any PluginProcessProbe
    /// Where plugin secrets live (Keychain service `dev.alloy.plugin-secret`); a value is read only by the host at spawn.
    public let secrets: any AgentSecretStore
    let limits: PluginLimits
    private var hostPump: HostPump?
    /// The previous host's wind-down; the next host waits for it so two hosts never own one plugin's processes.
    private var retiring: Task<Void, Never>?
    var appliedConfigs: [String: PluginRuntimeConfig] = [:]
    private var runStates: [String: PluginRunState] = [:]
    private var scriptedOrder: [String] = []
    private var scanned = false
    private var startupNoted = false
    private var startupRan = false
    private var staleCleaned = false
    /// False while Alloy cannot run scripted plugins end to end; then a plugin with `main` is listed but stays off.
    public let scriptedPluginsSupported: Bool
    /// What stands in for the platform's sandbox backend (a test passes its own; production leaves `.none`).
    public let sandbox: PluginSandboxOverride
    /// Whether scripted plugins can run confined on this machine.
    public var sandboxAvailable: Bool { PluginSandbox.backendAvailable(sandbox) }
    /// The enabled theme files the applied themes were loaded from.
    private var appliedThemeFiles: [ThemeFileRef]?
    /// Test seam: reads the theme files (counted by a test).
    var loadThemes: ([(pluginID: String, url: URL)]) -> [ThemeEntry] = { ThemeLibrary.loadPluginThemes($0).entries }

    /// The servers enabled plugins contribute right now (read by a language coordinator installed after the plugins bound).
    public private(set) var effectiveServers: [String: ServerConfigOverride] = [:]

    public init(paths: PluginPaths, registry: CommandRegistry, themes: ThemeController?, pathDirs: @escaping @Sendable () -> [String],
                clock: any AutosaveClock = SystemAutosaveClock(), probe: any PluginProcessProbe = LiveProcessProbe(),
                limits: PluginLimits = PluginLimits(), scriptedPluginsSupported: Bool = false,
                secrets: any AgentSecretStore = UnavailableSecretStore(),
                home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
                sandbox: PluginSandboxOverride = .none) {
        self.sandbox = sandbox
        self.home = home
        self.secrets = secrets
        self.scriptedPluginsSupported = scriptedPluginsSupported
        self.paths = paths
        self.registry = registry
        self.themes = themes
        self.pathDirs = pathDirs
        self.clock = clock
        self.probe = probe
        self.limits = limits
        panels = PluginPanelStore(debounce: limits.textFieldDebounce)
    }

    /// Whether the plugin is one the host currently runs for (enabled, granted and not retired).
    func isActive(_ id: String) -> Bool { appliedConfigs[id] != nil }

    /// The host; it exists only while at least one effectively enabled scripted plugin does.
    var host: PluginHost? { hostPump?.host }
    var hasHost: Bool { hostPump != nil }

    /// The production wiring: the login shell's PATH resolves a plugin's interpreter.
    public static func live(appSupport: URL, center: CommandCenter, themes: ThemeController?) -> PluginCoordinator {
        PluginCoordinator(paths: PluginPaths(appSupport: appSupport), registry: center.registry, themes: themes, pathDirs: {
            (ClaudeLocator.loginShell().path ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
        }, scriptedPluginsSupported: true, secrets: systemSecretStore(service: Self.pluginSecretService))
    }

    /// The Keychain service plugin secrets use.
    public static var pluginSecretService: String {
        #if canImport(Security)
        KeychainSecretStore.pluginService
        #else
        "dev.alloy.plugin-secret"
        #endif
    }

    /// Valid manifests of the installed plugin folders.
    public var installedManifests: [String: PluginManifest] {
        catalog.compactMapValues { try? $0.manifest.get() }
    }

    // MARK: Binding and activation

    /// Makes `workspace` the one whose settings hold the plugin entries, and follows its `plugins` changes.
    public func bind(_ workspace: Workspace) {
        let previous = self.workspace
        self.workspace = workspace
        workspace.pluginServices = self
        workspace.onPluginsChanged = { [weak self] _ in self?.recompute() }
        workspace.pluginToolScopes = { [weak self] in self?.pluginToolScopes ?? [] }
        if let previous, previous !== workspace {
            decorations.removeAll()
            if let store = stateStore { Task { await store.flush() } }
            stateStore = nil
            stateStoreWorkspace = nil
        }
        installDocumentEvents(on: workspace)
        installPanelSelection(on: workspace)
        installSessionEvents(on: workspace)
        workspace.addStopHook { [weak self, weak workspace] in
            guard let self, let workspace, self.workspace === workspace else { return }
            await self.shutdown()
        }
        if let previous, previous !== workspace { hostPump?.commands.yield(.workspace(workspace.projectRoot)) }
        recompute()
    }

    /// Scans the plugin folder off the main actor, then applies.
    public func activate() async {
        await cleanStaleGroups()
        dropStalePreviousFolders()
        await rescan()
        recompute()
        startScriptedOnStartup()
    }

    /// A `.<id>.previous` folder an earlier run left behind (it quit before the new version started) is garbage now that no
    /// update is pending.
    private func dropStalePreviousFolders() {
        guard pendingPrevious.isEmpty else { return }
        let paths = paths
        Task.detached { PluginGitInstaller.dropStalePrevious(paths: paths) }
    }

    /// Kills process groups an earlier Alloy left running, off the main actor, once, before anything can start.
    private func cleanStaleGroups() async {
        guard !staleCleaned else { return }
        staleCleaned = true
        let paths = paths, probe = probe
        await Task.detached { PluginHost.killStaleGroups(paths: paths, probe: probe) }.value
    }

    /// Called once the saved layout is back: starts at most `maxStartup` `onStartup` plugins, in the order they were enabled.
    public func noteStartupComplete() {
        StartupTrace.mark("plugins-startup")
        startupNoted = true
        startScriptedOnStartup()
    }

    private func startScriptedOnStartup() {
        guard startupNoted, scanned, !startupRan else { return }
        startupRan = true
        guard let commands = hostPump?.commands else { return }
        var started = 0
        for id in scriptedOrder where started < limits.maxStartup {
            guard case .success(let m)? = catalog[id]?.manifest, m.activationEvents.contains(.startup) else { continue }
            commands.yield(.activate(id, .startup, reply: nil))
            started += 1
        }
    }

    /// Stops every plugin process and the host (quit, or the workspace closing). Returns when every group is gone.
    public func shutdown() async {
        retire()
        await retiring?.value
        await stateStore?.flush()
    }

    /// The plugin's stderr tail (secrets and token shapes redacted) and the last error the host reported.
    public func logText(for id: String) async -> String {
        let tail = await hostPump?.host.stderrTail(of: id) ?? ""
        var lines = [PluginLogRedactor.redact(tail)]
        switch runStates[id] {
        case .crashed(let n)?: lines.append("Last error: crashed (\(n) in the last ten minutes)")
        case .disabledAfterCrashes?: lines.append("Last error: disabled after repeated crashes")
        case .failedToStart(let why)?: lines.append("Last error: could not start: \(PluginLogRedactor.redact(why))")
        case .needsAPI(let v)?: lines.append("Last error: needs plugin API v\(v)")
        default: break
        }
        lines += commandErrors[id] ?? []
        let text = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        guard let host = hostPump?.host else { return text }
        return await host.redact(text, for: id)
    }

    /// Sends one notification to the plugin if it runs (the ordered pump keeps it behind earlier commands).
    func notifyPlugin(_ id: String, _ method: String, _ params: JSONValue?) {
        hostPump?.commands.yield(.notify([id], method, params))
    }

    /// Sends one notification to every running plugin among `ids`; the host encodes the body once.
    func notifyPlugins(_ ids: [String], _ method: String, _ params: JSONValue?) {
        guard !ids.isEmpty else { return }
        hostPump?.commands.yield(.notify(ids, method, params))
    }

    /// The host stops remembering what it emitted for `uri` (the document closed or was not open).
    func forgetDecorations(plugin: String? = nil, uri: String) { hostPump?.commands.yield(.forgetDecorations(plugin: plugin, uri: uri)) }

    func setPanelOpen(_ id: String, _ open: Bool) { hostPump?.commands.yield(.setPanelOpen(id, open)) }

    /// Starts the plugin without waiting for it.
    func activateAsync(_ id: String, _ reason: ActivationReason) { hostPump?.commands.yield(.activate(id, reason, reply: nil)) }

    /// Starts the plugin's process now (test seam; later tasks activate through events). True when it runs afterwards.
    func activate(plugin id: String, _ reason: ActivationReason) async -> Bool {
        guard let commands = hostPump?.commands else { return false }
        return await withCheckedContinuation { continuation in
            let sent = commands.yield(.activate(id, reason, reply: { continuation.resume(returning: $0) }))
            // A finished stream drops the command; nobody else would answer it.
            if case .terminated = sent { continuation.resume(returning: false) }
        }
    }

    // MARK: Host

    private func makeHostPump() -> HostPump {
        let services = PluginHostServices { [weak self] id, method, params in
            guard let self else { return .failure(JSONRPCError(code: JSONRPCError.requestCancelled, message: "Cancelled")) }
            return await self.answerRequest(from: id, method, params)
        }
        let store = secrets
        let host = PluginHost(paths: paths, limits: limits, clock: clock, probe: probe,
                              baseEnvironment: Self.environment(pathDirs: [], home: home), services: services, sandbox: sandbox,
                              secretProvider: { config in Self.secretEnvironment(config.manifest, store) })
        let (stream, commands) = AsyncStream<HostCommand>.makeStream()
        let prior = retiring, pathDirs = pathDirs, home = home
        let pump = Task.detached {
            await prior?.value
            // The login shell's PATH can block, so it is resolved here, before the first command.
            await host.setBaseEnvironment(Self.environment(pathDirs: pathDirs(), home: home))
            loop: for await command in stream {
                switch command {
                case .configure(let configs): await host.configure(configs)
                case .activate(let id, let reason, let reply):
                    let ok = await host.activate(id, reason)
                    reply?(ok)
                case .notify(let ids, let method, let params): await host.notify(ids, method, params)
                case .workspace(let root): await host.setWorkspace(root: root)
                case .setPanelOpen(let id, let open): await host.setPanelOpen(id, open)
                case .forgetDecorations(let plugin, let uri): await host.forgetDecorations(plugin: plugin, uri: uri)
                case .stop(let id): await host.stop(id)
                case .shutdown:
                    await host.shutdown()
                    break loop
                }
            }
            await host.shutdown()
            // Commands queued after the shutdown (or after the stream ended) are answered, so no caller waits for ever.
            for await command in stream { if case .activate(_, _, let reply) = command { reply?(false) } }
        }
        let events = Task { @MainActor [weak self] in
            for await event in host.events { self?.handle(event) }
        }
        commands.yield(.workspace(workspace?.projectRoot))
        return HostPump(host: host, commands: commands, pump: pump, events: events)
    }

    private nonisolated static func environment(pathDirs: [String], home: String) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        return ["PATH": pathDirs.isEmpty ? "/usr/bin:/bin" : pathDirs.joined(separator: ":"),
                "HOME": home, "LANG": env["LANG"] ?? "en_US.UTF-8"]
    }

    /// Closes the host: it stops every plugin, then ends its tasks. `hasHost` is false at once.
    private func retire() {
        guard let old = hostPump else { return }
        hostPump = nil
        appliedConfigs = [:]
        runStates = [:]
        lastToast = [:]
        decorations.removeAll()
        old.commands.yield(.shutdown)
        old.commands.finish()
        retiring = Task { await old.pump.value; await old.events.value }
    }

    private func handle(_ event: PluginHostEvent) {
        if case .decorations(let id, let uri, let set) = event { applyDecorations(id: id, uri: uri, set: set); return }
        if handlePanelEvent(event) { return }
        if case .showMessage(let id, let type, let message) = event { showMessage(id: id, type: type, message: message); return }
        if case .started(let id) = event { updateStarted(id); panelPluginStarted(id); pluginStartedForEvents(id); return }
        if case .state(let id, let state) = event, pendingPrevious[id] != nil {
            switch state {
            case .crashed, .failedToStart, .disabledAfterCrashes, .sandboxUnavailable, .needsAPI: restorePreviousVersion(id)
            default: break
            }
        }
        guard case .state(let id, let state) = event, appliedConfigs[id] != nil else { return }
        runStates[id] = state
        panelStateChanged(id, state)
        switch state {
        case .running, .starting, .notStarted: break
        default: decorations.remove(pluginID: id)   // a stopped, crashed or disabled plugin shows nothing
        }
        if state == .disabledAfterCrashes {
            try? mutate(id) { $0.enabled = false; $0.disabledAfterCrashes = true }
        }
        recompute()
    }

    private func rescan() async {
        let directory = paths.plugins, pathDirs = pathDirs
        adopt(catalog: await Task.detached {
            // The login-shell PATH lookup can block, so it stays off the main actor and is skipped with no plugins.
            let contents = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }
            return PluginCatalog.scan(directory, pathDirs: contents.isEmpty ? [] : pathDirs())
        }.value)
    }

    /// Uses `entries` as the installed-folder catalog and applies (also lets a test set up without awaiting).
    func adopt(catalog entries: [PluginCatalogEntry]) {
        catalog = Dictionary(entries.map { ($0.folderName, $0) }, uniquingKeysWith: { a, _ in a })
        scanned = true
        appliedThemeFiles = nil  // the files on disk may have changed under the same names
        backfillCommandHashes()
        recompute()
    }

    /// Settings saved before commands were hashed: an enabled plugin whose manifest still has the version recorded at its
    /// enabling is taken as unchanged since then, and its hash is stored. Any other plugin waits for approval.
    private func backfillCommandHashes() {
        guard let workspace else { return }
        var s = workspace.settings
        var changed = false
        for (id, setting) in s.plugins where setting.enabled && setting.approvedCommandsHash == nil {
            guard case .success(let m)? = catalog[id]?.manifest, m.version == setting.version, !Self.commandLines(m).isEmpty else { continue }
            s.plugins[id]?.approvedCommandsHash = Self.commandsHash(m)
            changed = true
        }
        if changed { try? workspace.updateSettings(s) }
    }

    // MARK: Actions

    /// Copies a folder into the plugin directory. A new plugin starts disabled; a reinstall keeps its settings.
    public func install(folder: URL) async throws {
        guard let workspace else { throw PluginError.noWorkspace }
        let paths = paths, pathDirs = pathDirs
        let installed = workspace.settings.plugins
        let result = await Task.detached {
            PluginInstaller(paths: paths, pathDirs: pathDirs()).install(folder: folder, installed: installed)
        }.value
        let manifest = try result.get()
        var s = workspace.settings
        var entry = s.plugins[manifest.id] ?? PluginSetting(source: .folder(path: folder.path))
        // A reinstall over an enabled plugin keeps what the user approved, so changed commands ask again.
        if let existing = s.plugins[manifest.id] { entry.approvedCommandsHash = approvedHash(for: manifest.id, existing) }
        entry.version = manifest.version
        entry.source = .folder(path: folder.path)
        s.plugins[manifest.id] = entry
        await rescan()
        try workspace.updateSettings(s)
        recompute()
    }

    /// Clones one tag of a git repository into the plugin directory. A new plugin starts disabled; a reinstall keeps its
    /// settings.
    public func install(gitURL: String, tag: String) async throws {
        guard let workspace else { throw PluginError.noWorkspace }
        guard !status.installingGit else { return }
        status.installingGit = true
        defer { status.installingGit = false }
        let installer = gitInstaller()
        let (manifest, commit) = try await installer.install(url: gitURL, tag: tag, installed: workspace.settings.plugins)
        var s = workspace.settings
        var entry = s.plugins[manifest.id] ?? PluginSetting(source: .git(url: gitURL, tag: tag, commit: commit))
        if let existing = s.plugins[manifest.id] { entry.approvedCommandsHash = approvedHash(for: manifest.id, existing) }
        entry.version = manifest.version
        entry.source = .git(url: gitURL, tag: tag, commit: commit)
        s.plugins[manifest.id] = entry
        await rescan()
        try workspace.updateSettings(s)
        recompute()
    }

    private func gitInstaller() -> PluginGitInstaller {
        PluginGitInstaller(paths: paths, runner: gitRunner, pathDirs: pathDirs())
    }

    /// Asks the remote for a newer tag (or a moved one) and shows the answer on the plugin's row.
    public func checkForUpdate(_ id: String) async {
        guard let setting = workspace?.settings.plugins[id], case .git(let url, _, _) = setting.source,
              !updatesInFlight.contains(id) else { return }
        updateStates[id] = .checking
        recompute()
        let result: PluginRowUpdate
        do {
            let found = try await gitInstaller().availableUpdate(for: setting, url: url)
            availableUpdates[id] = found
            switch found {
            case .newer(_, let version, _)?: result = .available(version: version)
            case .tagMoved?: result = .tagMoved
            case nil: result = .upToDate
            }
        } catch {
            availableUpdates[id] = nil
            result = .failed(PluginsSection.describe(error))
        }
        updateStates[id] = result
        recompute()
    }

    /// Installs the update the last check found. The old folder stays until the new version has started once; if it never
    /// does, the old folder comes back. A new permission leaves the plugin waiting for the user's approval.
    public func applyUpdate(_ id: String) async throws {
        guard let workspace, let setting = workspace.settings.plugins[id], case .git(let url, _, _) = setting.source else { throw PluginError.unknownPlugin(id) }
        // A second tap while the first runs would move `.previous` twice and lose the old version.
        guard !updatesInFlight.contains(id) else { return }
        guard let update = availableUpdates[id], case .newer(let tag, _, let commit) = update else { throw PluginError.unknownPlugin(id) }
        updatesInFlight.insert(id)
        defer { updatesInFlight.remove(id) }
        availableUpdates[id] = nil
        updateStates[id] = .updating
        recompute()
        let installer = gitInstaller()
        let manifest: PluginManifest
        do {
            manifest = try await installer.update(id: id, to: update, url: url)
        } catch {
            updateStates[id] = nil
            recompute()
            throw error
        }
        pendingPrevious[id] = setting
        var s = workspace.settings
        var entry = setting
        entry.approvedCommandsHash = approvedHash(for: id, setting)
        entry.version = manifest.version
        entry.source = .git(url: url, tag: tag, commit: commit)
        s.plugins[id] = entry
        updateStates[id] = .upToDate
        try workspace.updateSettings(s)
        await rescan()
        recompute()
        if appliedConfigs[id] != nil { activateAsync(id, .startup) } else { settleUpdate(id) }
    }

    /// The new version initialized: the old folder can go.
    private func updateStarted(_ id: String) {
        guard pendingPrevious[id] != nil else { return }
        settleUpdate(id)
    }

    private func settleUpdate(_ id: String) {
        pendingPrevious[id] = nil
        let installer = gitInstaller()
        Task.detached { installer.dropPrevious(id: id) }
    }

    /// The new version failed before it initialized: its folder is replaced by the old one and the old entry comes back.
    private func restorePreviousVersion(_ id: String) {
        guard let old = pendingPrevious.removeValue(forKey: id) else { return }
        let installer = gitInstaller()
        updateStates[id] = nil
        Task { @MainActor in
            await Task.detached { try? installer.restorePrevious(id: id) }.value
            if var s = workspace?.settings, var entry = s.plugins[id] {
                entry.version = old.version
                entry.source = old.source
                s.plugins[id] = entry
                try? workspace?.updateSettings(s)
            }
            await rescan()
            recompute()
        }
    }

    /// Grants every permission the manifest declares and switches the plugin on.
    public func enable(_ id: String) throws {
        guard let workspace else { throw PluginError.noWorkspace }
        guard let catalogEntry = catalog[id] else { throw PluginError.unknownPlugin(id) }
        var entry = workspace.settings.plugins[id] ?? PluginSetting(source: .folder(path: catalogEntry.folder.path))
        let manifest: PluginManifest
        switch catalogEntry.manifest {
        case .success(let m): manifest = m
        case .failure(let e): throw PluginError.badManifest(e.description)
        }
        guard manifest.apiVersion == PluginManifestLoader.apiVersion else { throw PluginError.needsAPI(manifest.apiVersion) }
        guard scriptedPluginsSupported || !manifest.isScripted else { throw PluginError.scriptedUnsupported }
        entry.version = manifest.version
        guard !needsSandbox(manifest) else { throw PluginError.sandboxUnavailable }
        var s = workspace.settings
        entry.enabled = true
        entry.grants = manifest.permissions
        entry.enableOrder = (s.plugins.values.map(\.enableOrder).max() ?? 0) + 1
        entry.disabledAfterCrashes = false
        entry.approvedCommandsHash = Self.commandsHash(manifest)
        s.plugins[id] = entry
        try workspace.updateSettings(s)
    }

    public func disable(_ id: String) throws {
        try mutate(id) { $0.enabled = false }
    }

    /// Switches the plugin off, deletes its folder and data and drops its settings entry.
    public func remove(_ id: String) async throws {
        guard let workspace else { throw PluginError.noWorkspace }
        var s = workspace.settings
        guard s.plugins.removeValue(forKey: id) != nil || catalog[id] != nil else { throw PluginError.unknownPlugin(id) }
        try workspace.updateSettings(s)
        let installer = PluginInstaller(paths: paths, pathDirs: [])
        let store = secrets
        try await Task.detached {
            try installer.remove(id: id)
            try store.deleteAll(agent: id)
        }.value
        catalog[id] = nil
        recompute()
    }

    public func setGrant(_ p: PluginPermission, _ on: Bool, for id: String) throws {
        try mutate(id) { if on { $0.grants.insert(p) } else { $0.grants.remove(p) } }
    }

    public func setValue(_ value: JSONValue?, key: String, for id: String) throws {
        // A secret never lands in settings.json.
        if case .success(let m)? = catalog[id]?.manifest,
           m.contributes.settings.contains(where: { $0.key == key && Self.isSecret($0) }) { throw PluginError.badManifest("\(key) is a secret setting") }
        try mutate(id) { $0.values[key] = value }
    }

    private static func isSecret(_ spec: PluginSettingSpec) -> Bool {
        if case .secret = spec.type { true } else { false }
    }

    /// The environment variables of a plugin's secret settings, read from the store (Keychain; call off the main actor).
    nonisolated static func secretEnvironment(_ manifest: PluginManifest, _ store: any AgentSecretStore) -> [String: String] {
        var out: [String: String] = [:]
        for spec in manifest.contributes.settings {
            guard case .secret(let env) = spec.type, let value = try? store.get(agent: manifest.id, variable: spec.key),
                  !value.isEmpty else { continue }
            out[env] = value
        }
        return out
    }

    private func requireSecret(_ key: String, _ id: String) throws {
        guard case .success(let m)? = catalog[id]?.manifest else { throw PluginError.unknownPlugin(id) }
        guard m.contributes.settings.contains(where: { $0.key == key && Self.isSecret($0) }) else {
            throw PluginError.badManifest("\(key) is not a secret setting")
        }
    }

    /// Whether secrets can be kept here (the Keychain exists).
    public var secretsAvailable: Bool { secrets.isAvailable }

    /// The keys of the plugin's stored secrets, never their values; read off the main actor.
    public func storedSecretKeys(for id: String) async -> Set<String> {
        let store = secrets
        return await Task.detached { Set((try? store.names(agent: id)) ?? []) }.value
    }

    /// Stores the secret and stops the plugin's process; the next activation starts it with the new value.
    public func setSecret(_ value: String, key: String, for id: String) throws {
        try requireSecret(key, id)
        try secrets.set(value, agent: id, variable: key)
        hostPump?.commands.yield(.stop(id))
    }

    public func clearSecret(key: String, for id: String) throws {
        try requireSecret(key, id)
        try secrets.delete(agent: id, variable: key)
        hostPump?.commands.yield(.stop(id))
    }

    private func mutate(_ id: String, _ change: (inout PluginSetting) -> Void) throws {
        guard let workspace else { throw PluginError.noWorkspace }
        var s = workspace.settings
        guard var entry = s.plugins[id] else { throw PluginError.unknownPlugin(id) }
        change(&entry)
        s.plugins[id] = entry
        try workspace.updateSettings(s)
    }

    // MARK: Applying

    /// Whether the commands the manifest launches are the ones the user approved. A manifest with no such commands needs no
    /// approval; with some, the stored hash must match (a missing one does not, until `adopt` fills it for a plugin whose
    /// version has not changed since it was enabled).
    private func commandsApproved(_ setting: PluginSetting, _ m: PluginManifest) -> Bool {
        guard !Self.commandLines(m).isEmpty else { return true }
        return setting.approvedCommandsHash == Self.commandsHash(m)
    }

    /// The hash an existing entry stands for, read before its folder is replaced: the stored one, else the one of the
    /// manifest installed at the entry's version, else "" (which matches nothing, so changed commands ask again).
    private func approvedHash(for id: String, _ setting: PluginSetting) -> String {
        if let stored = setting.approvedCommandsHash { return stored }
        if case .success(let old)? = catalog[id]?.manifest, old.version == setting.version { return Self.commandsHash(old) }
        return ""
    }

    private func needsSandbox(_ m: PluginManifest) -> Bool {
        m.isScripted && !sandboxAvailable && !m.permissions.isDisjoint(with: [.network, .processSpawn])
    }

    /// Recomputes the rows and applies what changed. Cheap and synchronous; the theme files are read only when the set of
    /// enabled theme files changed.
    func recompute() {
        let plugins = workspace?.settings.plugins ?? [:]
        var rows: [PluginRowState] = []
        var themeFiles: [(pluginID: String, url: URL)] = []
        var servers: [String: ServerConfigOverride] = [:]
        var serverOwner: [String: String] = [:]

        let ids = Set(plugins.keys).union(catalog.keys).sorted()
        // Servers are claimed in enable order: the lower `enableOrder` wins a shared server id.
        let order = ids.sorted { (plugins[$0]?.enableOrder ?? 0, $0) < (plugins[$1]?.enableOrder ?? 0, $1) }
        var notes: [String: [String]] = [:]
        var effective: Set<String> = []
        var configs: [PluginRuntimeConfig] = []
        var commandSpecs: [String: [PluginCommandSpec]] = [:]
        var taskSpecs: [String: [PluginTaskSpec]] = [:]
        var panelSpecs: [(pluginID: String, panels: [PluginPanelSpec])] = []
        var mcpSpecs: [String: [PluginMCPToolSpec]] = [:]
        for id in order {
            guard let setting = plugins[id], setting.enabled, let entry = catalog[id], case .success(let m) = entry.manifest,
                  scriptedPluginsSupported || !m.isScripted, m.apiVersion == PluginManifestLoader.apiVersion, !needsSandbox(m), m.permissions.isSubset(of: setting.grants), commandsApproved(setting, m),
                  !setting.disabledAfterCrashes else { continue }
            effective.insert(id)
            if m.isScripted {
                configs.append(PluginRuntimeConfig(manifest: m, folder: entry.folder, grants: setting.grants, values: setting.values))
                if !m.contributes.commands.isEmpty { commandSpecs[id] = m.contributes.commands }
                if !m.contributes.panels.isEmpty { panelSpecs.append((id, m.contributes.panels)) }
                if !m.contributes.mcpTools.isEmpty, setting.grants.contains(.mcpTools) {
                    mcpSpecs[id] = m.contributes.mcpTools
                    notes[id, default: []].append(Self.mcpRowNote)
                }
            }
            if !m.contributes.taskCommands.isEmpty { taskSpecs[id] = m.contributes.taskCommands }
            for ref in m.contributes.themes {
                themeFiles.append((id, entry.folder.appendingPathComponent(ref.path)))
            }
            for sid in m.contributes.languageServers.keys.sorted() {
                if let owner = serverOwner[sid] {
                    notes[id, default: []].append("Server \(sid) is already provided by \(name(of: owner))")
                } else {
                    serverOwner[sid] = id
                    servers[sid] = m.contributes.languageServers[sid]
                }
            }
        }

        applyCommands(commandSpecs, tasks: taskSpecs)
        applyPanels(panelSpecs.sorted { $0.pluginID < $1.pluginID })
        applyMCPTools(mcpSpecs)
        for id in ids {
            // A folder with no settings entry is listed as not enabled.
            let setting = plugins[id] ?? PluginSetting(source: .folder(path: catalog[id]?.folder.path ?? ""))
            rows.append(row(id: id, setting: setting, hasEntry: plugins[id] != nil, effective: effective.contains(id),
                            notes: (notes[id] ?? []) + (commandNotes[id] ?? [])))
        }
        status.update(rows)
        applyScripted(configs)

        // Themes
        let refs = themeFiles.map { ThemeFileRef(pluginID: $0.pluginID, url: $0.url) }
        if refs != appliedThemeFiles {
            appliedThemeFiles = refs
            let loaded = refs.isEmpty ? [] : loadThemes(themeFiles)
            if loaded != appliedThemes {
                appliedThemes = loaded
                themes?.setPluginThemes(loaded)
            }
        }
        // Servers
        effectiveServers = servers
        let lsp = workspace?.languageServices as? LSPCoordinator
        if servers != appliedServers || lsp !== appliedLSP {
            appliedServers = servers
            languageCache = [:]
            appliedLSP = lsp
            lsp?.setPluginServers(servers)
        }
    }

    /// Hands the host the scripted plugins that are effectively enabled; creates it for the first and retires it after the last.
    private func applyScripted(_ configs: [PluginRuntimeConfig]) {
        scriptedOrder = configs.map(\.manifest.id)
        if configs.isEmpty { retire(); return }
        let next = Dictionary(configs.map { ($0.manifest.id, $0) }, uniquingKeysWith: { a, _ in a })
        if hostPump == nil { hostPump = makeHostPump() }
        guard next != appliedConfigs, let commands = hostPump?.commands else { return }
        let previous = appliedConfigs
        appliedConfigs = next
        for id in previous.keys where next[id] == nil { decorations.remove(pluginID: id) }
        runStates = runStates.filter { next[$0.key] != nil }
        commands.yield(.configure(configs))
        for config in configs {
            let id = config.manifest.id
            guard let old = previous[id], old.values != config.values else { continue }
            commands.yield(.notify([id], "settings/changed", .object(["values": .object(config.values)])))
        }
    }

    private func name(of id: String) -> String {
        if case .success(let m)? = catalog[id]?.manifest { return m.name }
        return id
    }

    private static func rowStatus(_ state: PluginRunState?) -> PluginRowStatus {
        switch state {
        case nil, .notStarted?, .starting?: .notStarted
        case .running?: .running
        case .stopped?: .stopped
        case .crashed(let n)?: .crashed(n)
        case .disabledAfterCrashes?: .disabledAfterCrashes
        case .needsAPI(let v)?: .needsAPI(v)
        case .sandboxUnavailable?: .sandboxUnavailable
        case .failedToStart(let why)?: .failedToStart(why)
        }
    }

    private func row(id: String, setting: PluginSetting, hasEntry: Bool, effective: Bool, notes: [String]) -> PluginRowState {
        guard let entry = catalog[id] else {
            return PluginRowState(id: id, name: id, version: setting.version, source: setting.source, enabled: setting.enabled,
                                  permissions: [], status: .missing, notes: [], settings: [], isScripted: false, commandsToRun: [])
        }
        switch entry.manifest {
        case .failure(let e):
            return PluginRowState(id: id, name: id, version: setting.version, source: setting.source, enabled: setting.enabled,
                                  permissions: [], status: .badManifest(e.description), notes: [], settings: [], isScripted: false,
                                  commandsToRun: [])
        case .success(let m):
            let missing = m.permissions.subtracting(setting.grants).sorted()
            let state: PluginRowStatus
            if m.apiVersion != PluginManifestLoader.apiVersion {
                state = .needsAPI(m.apiVersion)
            } else if m.isScripted && !scriptedPluginsSupported {
                state = .scriptedUnavailable
            } else if !hasEntry {
                state = .notEnabled
            } else if needsSandbox(m) {
                state = .sandboxUnavailable
            } else if setting.disabledAfterCrashes {
                state = .disabledAfterCrashes
            } else if !setting.enabled {
                state = .disabled
            } else if !missing.isEmpty || !commandsApproved(setting, m) {
                state = .needsPermissions(missing)
            } else if m.isScripted {
                state = Self.rowStatus(runStates[id])
            } else {
                state = .enabled
            }
            var commands = m.contributes.languageServers.keys.sorted().compactMap { sid -> String? in
                guard let o = m.contributes.languageServers[sid], let c = o.command else { return nil }
                return ([c] + (o.arguments ?? [])).joined(separator: " ")
            }
            commands += m.contributes.taskCommands.map { typedLine(of: $0) }
            var notes = notes
            if hasEntry, setting.enabled, !commandsApproved(setting, m) {
                notes.append("The commands it runs changed. Switch it off and on to approve them.")
            }
            var row = PluginRowState(id: id, name: m.name, version: m.version, source: setting.source, enabled: setting.enabled,
                                     permissions: m.permissions.sorted(), status: state, notes: notes, settings: m.contributes.settings,
                                     isScripted: m.isScripted, commandsToRun: commands)
            if case .git = setting.source { row.update = updateStates[id] }
            return row
        }
    }
}
