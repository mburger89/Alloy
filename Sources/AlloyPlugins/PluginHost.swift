import AlloyCore
import AlloyRPC
import Foundation

/// Runs scripted plugins as child processes, off the main actor. UI-free: the app talks to it through `events`,
/// `request`, `notify` and `PluginHostServices`.
public actor PluginHost {
    /// Test counter: bumped once per notification body `notify` encodes. Tests read it only.
    public private(set) var encodeCount = 0

    public nonisolated let events: AsyncStream<PluginHostEvent>
    private let eventSink: AsyncStream<PluginHostEvent>.Continuation

    private let paths: PluginPaths
    private let limits: PluginLimits
    private let clock: any AutosaveClock
    private let probe: any PluginProcessProbe
    private var baseEnvironment: [String: String]
    private let services: PluginHostServices

    private var configs: [String: PluginRuntimeConfig] = [:]
    private var runtimes: [String: PluginRuntime] = [:]
    private var starting: [String: Task<Bool, Never>] = [:]
    private var states: [String: PluginRunState] = [:]
    private var inflight: [UUID: PluginInflightRequest] = [:]
    private var root: URL?
    private var generation = 0
    private var crashTimes: [String: [Double]] = [:]
    private var streaks: [String: Int] = [:]
    private var disabled: Set<String> = []
    private var restartTasks: [String: Task<Void, Never>] = [:]
    private var timeouts: [String: Int] = [:]
    private var openPanels: Set<String> = []
    private var samplerTask: Task<Void, Never>?

    public init(paths: PluginPaths, limits: PluginLimits = PluginLimits(), clock: any AutosaveClock = SystemAutosaveClock(),
                probe: any PluginProcessProbe = LiveProcessProbe(), baseEnvironment: [String: String],
                services: PluginHostServices = PluginHostServices()) {
        self.paths = paths
        self.limits = limits
        self.clock = clock
        self.probe = probe
        self.baseEnvironment = baseEnvironment
        self.services = services
        (events, eventSink) = AsyncStream.makeStream()
    }

    // MARK: - Public surface

    public var runningCount: Int { runtimes.count }

    /// Test observability: the one sampler task exists only while a plugin process runs.
    public var hasSamplerTask: Bool { samplerTask != nil }

    /// Clock time of the plugin's last request, event or message; nil when it is not running.
    public func lastMessageTime(of id: String) -> Double? { runtimes[id]?.lastMessage }

    /// An open panel counts as activity: the plugin is not idle-stopped while one is shown.
    public func setPanelOpen(_ id: String, _ open: Bool) {
        if open { openPanels.insert(id) } else if openPanels.remove(id) != nil { runtimes[id]?.forceTouch(clock.now) }
    }

    public func state(of id: String) -> PluginRunState { states[id] ?? .notStarted }

    public func stderrTail(of id: String) -> String { runtimes[id]?.process.stderrTail ?? lastStderr[id] ?? "" }
    private var lastStderr: [String: String] = [:]

    /// Replaces the environment plugins start with (the app resolves the login shell's PATH off the main actor).
    public func setBaseEnvironment(_ environment: [String: String]) { baseEnvironment = environment }

    /// Replaces the plugin set. A running plugin that was removed (or whose manifest, folder, grants or secrets changed) is
    /// stopped; a changed settings value is not a reason to restart (the app sends `settings/changed`).
    public func configure(_ plugins: [PluginRuntimeConfig]) async {
        let next = Dictionary(plugins.map { ($0.manifest.id, $0) }, uniquingKeysWith: { _, b in b })
        func process(_ c: PluginRuntimeConfig?) -> PluginRuntimeConfig? {
            guard var c else { return nil }
            c.values = [:]
            return c
        }
        for id in Set(runtimes.keys).union(configs.keys) where process(next[id]) != process(configs[id]) {
            await stop(id)
            disabled.remove(id)
            crashTimes[id] = nil
            streaks[id] = nil
            timeouts[id] = nil
            openPanels.remove(id)
        }
        configs = next
        states = states.filter { next[$0.key] != nil }
    }

    /// Starts the plugin's process unless it runs. True when it is running afterwards.
    public func activate(_ id: String, _ reason: ActivationReason) async -> Bool {
        if let running = runtimes[id] {
            if running.lastActivation != .startup { running.lastActivation = reason }
            running.touch(clock.now)
            return true
        }
        // A crashed plugin waits out its backoff; a disabled one stays off until its config changes.
        if restartTasks[id] != nil || disabled.contains(id) { return false }
        if let pending = starting[id] {
            let ok = await pending.value
            if let r = runtimes[id], r.lastActivation != .startup { r.lastActivation = reason }
            return ok
        }
        guard let config = configs[id], config.manifest.isScripted else { return false }
        if config.manifest.apiVersion != PluginManifestLoader.apiVersion {
            setState(id, .needsAPI(config.manifest.apiVersion))
            return false
        }
        let task = Task { await self.start(config, reason: reason) }
        starting[id] = task
        let ok = await task.value
        starting[id] = nil
        return ok
    }

    public func request(_ id: String, _ method: String, _ params: JSONValue?, ui: Bool = false) async throws -> JSONValue {
        guard let runtime = runtimes[id] else { throw JSONRPCError.connectionClosed }
        runtime.touch(clock.now)
        do {
            let answer = try await runtime.connection.request(method, params, timeout: ui ? limits.uiTimeout : limits.requestTimeout)
            timeouts[id] = 0
            return answer
        } catch let error as JSONRPCError {
            if error.code == JSONRPCError.timedOut.code {
                timeouts[id, default: 0] += 1
                if timeouts[id, default: 0] >= limits.timeoutsToRestart { timeouts[id] = 0; await crash(runtime) }
            } else if error.code == JSONRPCError.queueFull.code {
                await crash(runtime)
            } else if error.code != JSONRPCError.connectionClosed.code {
                timeouts[id] = 0
            }
            throw error
        }
    }

    /// Sends one notification to each running plugin among `ids`. The body is encoded once.
    public func notify(_ ids: [String], _ method: String, _ params: JSONValue?) async {
        let targets = ids.compactMap { runtimes[$0] }
        guard !targets.isEmpty else { return }
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { message["params"] = params }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let body = try? encoder.encode(JSONValue.object(message)) else { return }
        encodeCount += 1
        let now = clock.now
        for runtime in targets {
            runtime.touch(now)
            do { try await runtime.connection.notify(encodedBody: body) } catch let error as JSONRPCError {
                if error.code == JSONRPCError.queueFull.code { await crash(runtime) }
            } catch {}
        }
    }

    /// Moves every plugin to a new project: running plugins hear `workspace/closed` then `workspace/opened`, requests in
    /// flight are cancelled, and plugins started for a project-bound reason stop.
    public func setWorkspace(root newRoot: URL?) async {
        let old = root
        if let old { await notify(Array(runtimes.keys), "workspace/closed", .object(["root": .string(Self.fileURI(old))])) }
        cancelInflight()
        for (id, runtime) in runtimes where runtime.lastActivation.isProjectBound { await stop(id) }
        root = newRoot
        if let newRoot {
            await notify(Array(runtimes.keys), "workspace/opened", .object(["root": .string(Self.fileURI(newRoot))]))
        }
    }

    public func stop(_ id: String) async {
        if let pending = starting[id] { _ = await pending.value }
        restartTasks.removeValue(forKey: id)?.cancel()
        guard let runtime = runtimes.removeValue(forKey: id) else { return }
        await terminate(runtime)
        cancelInflight(for: id)
        setState(id, .stopped)
    }

    public func shutdown() async {
        for task in restartTasks.values { task.cancel() }
        restartTasks = [:]
        for id in Array(starting.keys) { _ = await starting[id]?.value }
        // In parallel: one plugin that ignores SIGTERM costs the grace period once, not once per plugin.
        await withTaskGroup(of: Void.self) { group in
            for id in Array(runtimes.keys) { group.addTask { await self.stop(id) } }
        }
        eventSink.finish()
    }

    /// Kills process groups an earlier Alloy left running. An entry whose leader now has another start time is a reused pid
    /// and is left alone. With the leader gone, the group is killed only when every member started at or after the
    /// recorded start (a reused group id then holds no process of ours older than the plugin). The file is cleared
    /// either way; with no file, nothing is written.
    public static func killStaleGroups(paths: PluginPaths, probe: any PluginProcessProbe) {
        guard FileManager.default.fileExists(atPath: paths.running.path) else { return }
        for entry in PluginRunningFile.read(paths.running) where entry.pid > 1 {
            if let start = probe.startTime(pid: entry.pid) {
                if abs(start - entry.start) < 0.01 { kill(-entry.pid, SIGKILL) }
                continue
            }
            let members = probe.groupMembers(pgid: entry.pid)
            guard !members.isEmpty else { continue }
            let tolerance = 0.01
            if members.allSatisfy({ (probe.startTime(pid: $0) ?? .infinity) >= entry.start - tolerance }) { kill(-entry.pid, SIGKILL) }
        }
        PluginRunningFile.write([], to: paths.running)
    }

    // MARK: - Starting

    private func start(_ config: PluginRuntimeConfig, reason: ActivationReason) async -> Bool {
        let id = config.manifest.id
        guard let main = config.manifest.main else { return false }
        setState(id, .starting)
        while runtimes.count >= limits.maxRunning, let oldest = runtimes.values.min(by: { $0.lastMessage < $1.lastMessage }) {
            await stop(oldest.id)
        }
        let scratch = paths.scratch(id)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var environment = baseEnvironment
        environment["TMPDIR"] = scratch.path
        environment["ALLOY_PLUGIN_ID"] = id
        for (key, value) in config.secretEnvironment { environment[key] = value }
        let command = main.command.contains("/") && !main.command.hasPrefix("/")
            ? config.folder.appendingPathComponent(main.command).path : main.command
        let process: ServerProcess
        do {
            process = try ServerProcess(executable: command, arguments: main.args, environment: environment,
                                        currentDirectory: config.folder, processGroup: true)
        } catch {
            let why: String
            switch error as? ServerProcessError {
            case .notInstalled(let c)?: why = "Plugin command not found: \(c)"
            case .launchFailed(let w)?: why = "Could not launch plugin: \(w)"
            default: why = "\(error)"
            }
            setState(id, .failedToStart(why))
            return false
        }
        generation += 1
        let gen = generation
        let connection = JSONRPCConnection(channel: process, requestTimeout: limits.requestTimeout,
                                           maxQueuedBytes: limits.writeQueueBytes, overflow: .fail)
        let runtime = PluginRuntime(id: id, generation: gen, process: process, connection: connection, lastActivation: reason,
                                    now: clock.now)
        runtime.startTime = probe.startTime(pid: process.processIdentifier)
        if let sample = probe.sample(pid: process.processIdentifier) { runtime.cpuSamples = [(clock.now, sample.cpuSeconds)] }
        let clock = self.clock, limits = self.limits
        await connection.setInboundGate { [weak self, weak runtime] in
            guard let runtime else { return }
            let host = self
            runtime.touch(clock.now)
            await runtime.gate.admit(clock: clock, perSecond: limits.messagesPerSecond,
                                     seconds: limits.chattySecondsToRestart, window: limits.chattyWindow) {
                Task { await host?.crash(id: id, generation: gen) }
            }
            if runtime.claimSample(clock.now, interval: limits.sampleInterval) {
                Task { await host?.sampleOne(id: id, generation: gen) }
            }
        }
        let sink = eventSink
        await connection.onNotification { method, params in
            sink.yield(.notification(id: id, method: method, params: params))
        }
        await connection.onRequest { [weak self] method, params in
            guard let self else { return .failure(JSONRPCError(code: JSONRPCError.requestCancelled, message: "Cancelled")) }
            return await self.handleRequest(id, method, params)
        }
        await connection.start()
        runtimes[id] = runtime
        recordRunning()
        syncSampler()
        startIdleWatch(runtime)
        Task { [weak self] in
            for await code in process.exited { await self?.processExited(id, generation: gen, code: code) }
        }

        let root = self.root
        let answer: JSONValue
        do {
            answer = try await connection.request("initialize", .object([
                "apiVersion": .number(Double(PluginManifestLoader.apiVersion)),
                "pluginId": .string(id),
                "grants": .array(config.grants.sorted().map { .string($0.rawValue) }),
                "settings": .object(config.values),
                "root": root.map { .string(Self.fileURI($0)) } ?? .null,
            ]))
        } catch {
            // A plugin that dies or hangs during the handshake is a crash.
            await crash(runtime)
            return false
        }
        guard runtimes[id]?.generation == gen else { return false }
        let served = answer["apiVersion"]?.intValue ?? 0
        if served != PluginManifestLoader.apiVersion {
            runtimes[id] = nil
            await terminate(runtime)
            setState(id, .needsAPI(served))
            return false
        }
        try? await connection.notify("initialized", .object([:]))
        if let root { try? await connection.notify("workspace/opened", .object(["root": .string(Self.fileURI(root))])) }
        guard runtimes[id]?.generation == gen else { return false }
        setState(id, .running)
        eventSink.yield(.started(id: id))
        return true
    }

    private func processExited(_ id: String, generation gen: Int, code: Int32) async {
        guard let runtime = runtimes[id], runtime.generation == gen else { return }
        let polluted = await runtime.connection.closeReason != nil
        if code != 0 || polluted {
            await crash(runtime)
        } else {
            // The plugin left of its own accord with status 0: stopped, not restarted.
            guard runtimes[id]?.generation == gen else { return }
            runtimes[id] = nil
            await terminate(runtime)
            cancelInflight(for: id)
            setState(id, .stopped)
        }
    }

    // MARK: - Crashes and restarts

    private func crash(id: String, generation gen: Int) async {
        guard let runtime = runtimes[id], runtime.generation == gen else { return }
        await crash(runtime)
    }

    /// Kills the plugin's group and counts a crash: backoff restart, or off after `crashesToDisable` inside `crashWindow`.
    private func crash(_ runtime: PluginRuntime) async {
        let id = runtime.id
        guard runtimes[id]?.generation == runtime.generation else { return }
        runtimes[id] = nil
        // A stuck plugin may hold the stdin writer in a blocked write; killing the group first frees it.
        if let group = runtime.process.processGroupID { kill(-group, SIGKILL) }
        await terminate(runtime)
        cancelInflight(for: id)
        let now = clock.now
        if now - runtime.startedAt >= limits.crashWindow { streaks[id] = 0 }
        let streak = streaks[id, default: 0] + 1
        streaks[id] = streak
        var times = (crashTimes[id] ?? []).filter { now - $0 < limits.crashWindow }
        times.append(now)
        crashTimes[id] = times
        if times.count >= limits.crashesToDisable {
            disabled.insert(id)
            setState(id, .disabledAfterCrashes)
            return
        }
        setState(id, .crashed(times.count))
        let delay = limits.backoff.isEmpty ? 0 : limits.backoff[min(streak - 1, limits.backoff.count - 1)]
        let reason = runtime.lastActivation
        restartTasks[id]?.cancel()
        restartTasks[id] = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(until: clock.now + delay) } catch { return }
            await self?.restart(id, reason)
        }
    }

    private func restart(_ id: String, _ reason: ActivationReason) async {
        restartTasks[id] = nil
        _ = await activate(id, reason)
    }

    // MARK: - Idle stop

    private func startIdleWatch(_ runtime: PluginRuntime) {
        let clock = self.clock, idle = limits.idleStop
        runtime.idleTask = Task { [weak self, weak runtime] in
            while !Task.isCancelled {
                guard let runtime else { return }
                let deadline = runtime.lastMessage + idle
                if clock.now < deadline {
                    try? await clock.sleep(until: deadline)
                    continue
                }
                guard let self, await self.idleExpired(runtime) else { continue }
                return
            }
        }
    }

    /// True when the plugin is being stopped for idleness. An open panel counts as activity.
    private func idleExpired(_ runtime: PluginRuntime) -> Bool {
        guard runtimes[runtime.id]?.generation == runtime.generation else { return true }
        if openPanels.contains(runtime.id) {
            runtime.forceTouch(clock.now)
            return false
        }
        let id = runtime.id, gen = runtime.generation
        Task { await self.stopIfCurrent(id, generation: gen) }
        return true
    }

    private func stopIfCurrent(_ id: String, generation gen: Int) async {
        guard runtimes[id]?.generation == gen else { return }
        await stop(id)
    }

    // MARK: - Sampler

    private func syncSampler() {
        if runtimes.isEmpty {
            samplerTask?.cancel()
            samplerTask = nil
        } else if samplerTask == nil {
            let clock = self.clock, interval = limits.sampleInterval
            samplerTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    do { try await clock.sleep(until: clock.now + interval) } catch { return }
                    guard let self else { return }
                    await self.sampleAll()
                }
            }
        }
    }

    private func sampleAll() async {
        for runtime in Array(runtimes.values) {
            if await runtime.connection.closeReason != nil { await crash(runtime); continue }
            await sample(runtime)
        }
    }

    private func sampleOne(id: String, generation gen: Int) async {
        guard let runtime = runtimes[id], runtime.generation == gen else { return }
        await sample(runtime)
    }

    private func sample(_ runtime: PluginRuntime) async {
        let probe = self.probe, pid = runtime.process.processIdentifier
        let reading = await Task.detached { probe.sample(pid: pid) }.value
        guard runtimes[runtime.id]?.generation == runtime.generation, let reading else { return }
        if reading.residentBytes > limits.residentLimit { await crash(runtime); return }
        let now = clock.now
        if let last = runtime.cpuSamples.last, now - last.time < 0.001 { runtime.cpuSamples.removeLast() }
        runtime.cpuSamples.append((now, reading.cpuSeconds))
        while runtime.cpuSamples.count >= 2, runtime.cpuSamples[1].time <= now - limits.cpuWindow { runtime.cpuSamples.removeFirst() }
        if let first = runtime.cpuSamples.first, now - first.time >= limits.cpuWindow - 0.001,
           (reading.cpuSeconds - first.cpu) / (now - first.time) > limits.cpuLimit {
            await crash(runtime)
        }
    }

    /// Ends the process group (stdin closed first), the connection and the pid-file entry.
    private func terminate(_ runtime: PluginRuntime) async {
        lastStderr[runtime.id] = runtime.process.stderrTail
        // `close()` queues behind a send blocked on a full pipe (a plugin that stopped reading), so it gets 100 ms and
        // the group is signalled either way; the killed process frees the blocked write.
        let closed = PluginFlag()
        let process = runtime.process
        Task { await process.close(); closed.set() }
        for _ in 0..<20 where !closed.isSet { try? await Task.sleep(for: .milliseconds(5)) }
        await runtime.process.stop(grace: limits.stopGrace)
        // The leader may have left on stdin EOF while a descendant lives on.
        if let group = runtime.process.processGroupID { kill(-group, SIGKILL) }
        await runtime.connection.close()
        runtime.idleTask?.cancel()
        runtime.idleTask = nil
        recordRunning()
        syncSampler()
    }

    private func recordRunning() {
        let entries = runtimes.values.compactMap { runtime -> PluginRunningFile.Entry? in
            guard let start = runtime.startTime else { return nil }
            return .init(id: runtime.id, pid: runtime.process.processIdentifier, start: start)
        }
        PluginRunningFile.write(entries.sorted { $0.id < $1.id }, to: paths.running)
    }

    private func setState(_ id: String, _ state: PluginRunState) {
        states[id] = state
        eventSink.yield(.state(id: id, state))
    }

    // MARK: - Requests from plugins

    private func handleRequest(_ id: String, _ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        if let needed = PluginMethods.requiredPermission(method), !(configs[id]?.grants.contains(needed) ?? false) {
            return .failure(JSONRPCError(code: -32003, message: "permission denied",
                                         data: .object(["permission": .string(needed.rawValue)])))
        }
        let services = services
        let token = UUID()
        return await withCheckedContinuation { continuation in
            let entry = PluginInflightRequest(pluginID: id, continuation: continuation)
            inflight[token] = entry
            Task {
                let result = await services.answer(id, method, params)
                entry.resolve(result)
                self.finish(token)
            }
        }
    }

    private func finish(_ token: UUID) { inflight[token] = nil }

    private func cancelInflight(for id: String? = nil) {
        for (token, entry) in inflight where id == nil || entry.pluginID == id {
            entry.resolve(.failure(JSONRPCError(code: JSONRPCError.requestCancelled, message: "Cancelled")))
            inflight[token] = nil
        }
    }

    static func fileURI(_ url: URL) -> String { URL(fileURLWithPath: url.path, isDirectory: false).absoluteString }
}
