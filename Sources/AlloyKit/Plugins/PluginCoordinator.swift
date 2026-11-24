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
    private let registry: CommandRegistry
    private let themes: ThemeController?
    private let pathDirs: @Sendable () -> [String]
    private weak var workspace: Workspace?
    private var catalog: [String: PluginCatalogEntry] = [:]
    private var appliedThemes: [ThemeEntry] = []
    private var appliedServers: [String: ServerConfigOverride] = [:]
    private weak var appliedLSP: LSPCoordinator?
    private let clock: any AutosaveClock
    private let probe: any PluginProcessProbe
    private let limits: PluginLimits
    private var hostPump: HostPump?
    /// The previous host's wind-down; the next host waits for it so two hosts never own one plugin's processes.
    private var retiring: Task<Void, Never>?
    private var appliedConfigs: [String: PluginRuntimeConfig] = [:]
    private var runStates: [String: PluginRunState] = [:]
    private var scriptedOrder: [String] = []
    private var scanned = false
    private var startupNoted = false
    private var startupRan = false
    private var staleCleaned = false
    /// False until Alloy can run scripted plugins end to end (their commands, panels and tools); then a plugin with `main`
    /// is listed but stays off.
    public let scriptedPluginsSupported: Bool
    /// The enabled theme files the applied themes were loaded from.
    private var appliedThemeFiles: [ThemeFileRef]?
    /// Test seam: reads the theme files (counted by a test).
    var loadThemes: ([(pluginID: String, url: URL)]) -> [ThemeEntry] = { ThemeLibrary.loadPluginThemes($0).entries }

    /// The servers enabled plugins contribute right now (read by a language coordinator installed after the plugins bound).
    public private(set) var effectiveServers: [String: ServerConfigOverride] = [:]

    public init(paths: PluginPaths, registry: CommandRegistry, themes: ThemeController?, pathDirs: @escaping @Sendable () -> [String],
                clock: any AutosaveClock = SystemAutosaveClock(), probe: any PluginProcessProbe = LiveProcessProbe(),
                limits: PluginLimits = PluginLimits(), scriptedPluginsSupported: Bool = false) {
        self.scriptedPluginsSupported = scriptedPluginsSupported
        self.paths = paths
        self.registry = registry
        self.themes = themes
        self.pathDirs = pathDirs
        self.clock = clock
        self.probe = probe
        self.limits = limits
    }

    /// The host; it exists only while at least one effectively enabled scripted plugin does.
    var host: PluginHost? { hostPump?.host }
    var hasHost: Bool { hostPump != nil }

    /// The production wiring: the login shell's PATH resolves a plugin's interpreter.
    public static func live(appSupport: URL, center: CommandCenter, themes: ThemeController?) -> PluginCoordinator {
        PluginCoordinator(paths: PluginPaths(appSupport: appSupport), registry: center.registry, themes: themes, pathDirs: {
            (ClaudeLocator.loginShell().path ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
        }, scriptedPluginsSupported: false)
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
        await rescan()
        recompute()
        startScriptedOnStartup()
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
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

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
        let host = PluginHost(paths: paths, limits: limits, clock: clock, probe: probe, baseEnvironment: Self.environment(pathDirs: []))
        let (stream, commands) = AsyncStream<HostCommand>.makeStream()
        let prior = retiring, pathDirs = pathDirs
        let pump = Task.detached {
            await prior?.value
            // The login shell's PATH can block, so it is resolved here, before the first command.
            await host.setBaseEnvironment(Self.environment(pathDirs: pathDirs()))
            loop: for await command in stream {
                switch command {
                case .configure(let configs): await host.configure(configs)
                case .activate(let id, let reason, let reply):
                    let ok = await host.activate(id, reason)
                    reply?(ok)
                case .notify(let ids, let method, let params): await host.notify(ids, method, params)
                case .workspace(let root): await host.setWorkspace(root: root)
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

    private nonisolated static func environment(pathDirs: [String]) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        return ["PATH": pathDirs.isEmpty ? "/usr/bin:/bin" : pathDirs.joined(separator: ":"),
                "HOME": env["HOME"] ?? NSHomeDirectory(), "LANG": env["LANG"] ?? "en_US.UTF-8"]
    }

    /// Closes the host: it stops every plugin, then ends its tasks. `hasHost` is false at once.
    private func retire() {
        guard let old = hostPump else { return }
        hostPump = nil
        appliedConfigs = [:]
        runStates = [:]
        old.commands.yield(.shutdown)
        old.commands.finish()
        retiring = Task { await old.pump.value; await old.events.value }
    }

    private func handle(_ event: PluginHostEvent) {
        guard case .state(let id, let state) = event, appliedConfigs[id] != nil else { return }
        runStates[id] = state
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
        recompute()
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
        entry.version = manifest.version
        entry.source = .folder(path: folder.path)
        s.plugins[manifest.id] = entry
        await rescan()
        try workspace.updateSettings(s)
        recompute()
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
        guard !Self.needsSandbox(manifest) else { throw PluginError.sandboxUnavailable }
        var s = workspace.settings
        entry.enabled = true
        entry.grants = manifest.permissions
        entry.enableOrder = (s.plugins.values.map(\.enableOrder).max() ?? 0) + 1
        entry.disabledAfterCrashes = false
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
        try await Task.detached { try installer.remove(id: id) }.value
        catalog[id] = nil
        recompute()
    }

    public func setGrant(_ p: PluginPermission, _ on: Bool, for id: String) throws {
        try mutate(id) { if on { $0.grants.insert(p) } else { $0.grants.remove(p) } }
    }

    public func setValue(_ value: JSONValue?, key: String, for id: String) throws {
        try mutate(id) { $0.values[key] = value }
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

    private static func needsSandbox(_ m: PluginManifest) -> Bool {
        m.isScripted && !PluginSandbox.backendAvailable && !m.permissions.isDisjoint(with: [.network, .processSpawn])
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
        for id in order {
            guard let setting = plugins[id], setting.enabled, let entry = catalog[id], case .success(let m) = entry.manifest,
                  scriptedPluginsSupported || !m.isScripted, m.apiVersion == PluginManifestLoader.apiVersion, !Self.needsSandbox(m), m.permissions.isSubset(of: setting.grants),
                  !setting.disabledAfterCrashes else { continue }
            effective.insert(id)
            if m.isScripted {
                configs.append(PluginRuntimeConfig(manifest: m, folder: entry.folder, grants: setting.grants, values: setting.values))
            }
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

        for id in ids {
            // A folder with no settings entry is listed as not enabled.
            let setting = plugins[id] ?? PluginSetting(source: .folder(path: catalog[id]?.folder.path ?? ""))
            rows.append(row(id: id, setting: setting, hasEntry: plugins[id] != nil, effective: effective.contains(id), notes: notes[id] ?? []))
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
            } else if Self.needsSandbox(m) {
                state = .sandboxUnavailable
            } else if setting.disabledAfterCrashes {
                state = .disabledAfterCrashes
            } else if !setting.enabled {
                state = .disabled
            } else if !missing.isEmpty {
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
            commands += m.contributes.taskCommands.map { ([$0.command] + $0.args).joined(separator: " ") }
            return PluginRowState(id: id, name: m.name, version: m.version, source: setting.source, enabled: setting.enabled,
                                  permissions: m.permissions.sorted(), status: state, notes: notes, settings: m.contributes.settings,
                                  isScripted: m.isScripted, commandsToRun: commands)
        }
    }
}
