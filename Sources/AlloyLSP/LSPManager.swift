import AlloyCore
import AlloyHighlight
import Foundation
import MetalUICodeBuffer

/// What the manager reports to the UI side.
public enum LSPResult: Sendable {
    case diagnostics(path: String, version: Int?, items: [LSPDiagnostic])
    /// A server's state changed. `path` is one of the documents it serves (the first it was started for).
    case status(path: String, serverID: String, serverName: String, state: ServerState)
    /// Semantic tokens decoded (off the main actor) for the document text of buffer version `version`.
    case semanticTokens(path: String, version: Int, runs: [(Range<Int>, SyntaxToken)])
    /// Whether the server of `path` offers semantic tokens; sent when a probing request first learns it and when it changes.
    case semanticSupport(path: String, supported: Bool)
}

/// Starts a server process: the config, the resolved executable path and the workspace root.
public struct ServerLauncher: Sendable {
    public var make: @Sendable (ServerConfig, String, URL) throws -> any LSPByteChannel & ServerExitObserving

    public init(make: @escaping @Sendable (ServerConfig, String, URL) throws -> any LSPByteChannel & ServerExitObserving) {
        self.make = make
    }

    /// The real launcher: a `ServerProcess` whose PATH is the login shell's merged into the app's own.
    public static func live(loginPATH: @escaping @Sendable () -> String?) -> ServerLauncher {
        ServerLauncher { config, resolved, root in
            var environment = ProcessInfo.processInfo.environment
            if let path = ClaudeLocator.mergePATH(login: loginPATH(), existing: environment["PATH"]) { environment["PATH"] = path }
            return try ServerProcess(executable: resolved, arguments: config.arguments, environment: environment,
                                     currentDirectory: root)
        }
    }
}

/// Owns the language servers of one workspace: one `LanguageServer` and `DocumentSync` per server id, started on
/// the first open of a document the server handles. Paths are the workspace's (project relative; an absolute path is
/// used as it is). All work happens on this actor, never on the main actor.
public actor LSPManager {
    private final class Entry: @unchecked Sendable {
        let config: ServerConfig
        let server: LanguageServer
        let sync: DocumentSync
        /// The document whose open started the server; status results name it.
        let representative: String
        var observer: Task<Void, Never>?
        var starter: Task<Void, Never>?
        /// `publishDiagnostics` params in arrival order, and the task that maps them one after the other.
        var inbox: AsyncStream<JSONValue>.Continuation?
        var diagnosticsTask: Task<Void, Never>?
        /// Whether the server ever pushed diagnostics; a server that did is not asked to pull them.
        var pushed = false
        var pullTasks: [String: Task<Void, Never>] = [:]
        init(config: ServerConfig, server: LanguageServer, sync: DocumentSync, representative: String) {
            self.config = config
            self.server = server
            self.sync = sync
            self.representative = representative
        }
    }

    private struct Tracked {
        var serverID: String
        var languageID: String
        var snapshot: CodeSnapshot
    }

    public nonisolated let results: AsyncStream<LSPResult>
    private let continuation: AsyncStream<LSPResult>.Continuation
    private let root: URL
    private var registry: ServerRegistry
    private let locator: ServerLocator
    private let launcher: ServerLauncher
    private var entries: [String: Entry] = [:]
    private var tracked: [String: Tracked] = [:]
    /// Servers whose command could not be found, reported once until the next `reload`.
    private var missing: Set<String> = []
    private var isShutDown = false
    /// Servers being stopped after a reload; their documents wait for the stop to finish before the replacement starts.
    private var restarting: Set<String> = []
    /// Stops running off the command path (a slow server must not hold up the others).
    private var pendingStops: [Task<Void, Never>] = []

    public init(root: URL, registry: ServerRegistry, locator: ServerLocator, launcher: ServerLauncher) {
        self.root = root
        self.registry = registry
        self.locator = locator
        self.launcher = launcher
        (results, continuation) = AsyncStream<LSPResult>.makeStream()
    }

    // MARK: - Documents

    public func documentOpened(path: String, snapshot: CodeSnapshot) async {
        guard !isShutDown else { return }
        guard let config = registry.server(forPath: path), let languageID = registry.languageID(forPath: path) else {
            await untrack(path)
            return
        }
        guard snapshot.utf8Count <= DocumentSync.maxFileBytes else {
            await untrack(path)   // too large for a server (and a tracked one that grew leaves it)
            return
        }
        if let old = tracked[path], old.serverID != config.id {
            semantic[path]?.base = nil
            await entries[old.serverID]?.sync.close(uri: uri(path))
        }
        tracked[path] = Tracked(serverID: config.id, languageID: languageID, snapshot: snapshot)
        guard !restarting.contains(config.id), let entry = await entry(for: config, path: path) else { return }
        // The lookup suspended this actor: the document may be gone, or moved to another server, meanwhile.
        guard !isShutDown, let latest = tracked[path], latest.serverID == config.id else { return }
        await entry.sync.open(uri: uri(path), languageID: languageID, snapshot: latest.snapshot)
        schedulePull(path: path, entry: entry)
    }

    public func documentChanged(path: String, change: DocumentChange) async {
        guard var doc = tracked[path] else { return }
        switch change {
        case .edits(_, let after): doc.snapshot = after
        case .resync(let snapshot): doc.snapshot = snapshot
        }
        tracked[path] = doc
        // Tokens of the old text are no use; the view asks again after its debounce.
        if let state = semantic[path] {
            // A document that has not yet learned whether its server offers tokens asks again at once (the wait for a
            // server that is still starting costs nothing); the others wait for the view's debounce.
            if state.reportedSupport == nil { requestSemanticTokens(path: path) } else { state.task?.cancel() }
        }
        guard let entry = entries[doc.serverID] else { return }
        await entry.sync.apply(uri: uri(path), change: change)
        schedulePull(path: path, entry: entry)
    }

    public func documentSaved(path: String) async {
        guard let doc = tracked[path], let entry = entries[doc.serverID] else { return }
        await entry.sync.saved(uri: uri(path))
    }

    public func documentClosed(path: String) async {
        await untrack(path)
    }

    private func untrack(_ path: String) async {
        dropSemantic(path: path)
        guard let doc = tracked.removeValue(forKey: path) else { return }
        entries[doc.serverID]?.pullTasks.removeValue(forKey: path)?.cancel()
        await entries[doc.serverID]?.sync.close(uri: uri(path))
    }

    // MARK: - Lifecycle

    /// Stops every server (`shutdown`, `exit`, then the process). The manager takes no documents afterwards.
    public func shutdownAll() async {
        isShutDown = true
        let all = Array(entries.values)
        entries = [:]
        tracked = [:]
        let earlier = pendingStops
        pendingStops = []
        await stop(all)
        for task in earlier { await task.value }
    }

    /// Applies a new registry: servers whose config changed (or that were removed or disabled) are stopped in the
    /// background, and only once they are gone do their documents move to the replacement, which starts lazily.
    /// Unchanged servers keep running and keep taking edits meanwhile.
    public func reload(registry new: ServerRegistry) async {
        guard !isShutDown else { return }
        locator.invalidate()
        resolvedCommands = [:]
        resolveGeneration += 1
        registry = new
        missing = []
        var stale: [Entry] = []
        for (id, entry) in entries where new.all.first(where: { $0.id == id }) != entry.config {
            stale.append(entry)
            entries[id] = nil
            restarting.insert(id)
        }
        for (path, doc) in tracked.sorted(by: { $0.key < $1.key }) {
            guard let config = new.server(forPath: path), let languageID = new.languageID(forPath: path) else {
                tracked[path] = nil
                dropSemantic(path: path)
                if let live = entries[doc.serverID] { await live.sync.close(uri: uri(path)) }
                continue
            }
            // Same server: running (kept) or waiting for its restart. One that was missing gets another try below.
            if config.id == doc.serverID, entries[config.id] != nil || restarting.contains(config.id) { continue }
            if config.id != doc.serverID, let live = entries[doc.serverID] { await live.sync.close(uri: uri(path)) }
            tracked[path] = Tracked(serverID: config.id, languageID: languageID, snapshot: doc.snapshot)
            if !restarting.contains(config.id), let entry = await entry(for: config, path: path),
               let latest = tracked[path], latest.serverID == config.id {
                await entry.sync.open(uri: uri(path), languageID: languageID, snapshot: latest.snapshot)
                // The other server never issued the old one's result ids.
                if semantic[path] != nil { semantic[path]?.base = nil; requestSemanticTokens(path: path) }
            }
        }
        for entry in stale {
            let id = entry.config.id
            let task = Task { [weak self] in
                await self?.stop([entry])
                await self?.finishRestart(id)
            }
            pendingStops.append(task)
        }
    }

    /// The old instance of `id` is gone: start its replacement for the documents that still belong to it.
    private func finishRestart(_ id: String) async {
        restarting.remove(id)
        for path in tracked.keys.sorted() {
            // A reload during an await below may have stopped the instance made here and marked `id` as restarting again;
            // its own `finishRestart` takes over, and this one must not make a second instance meanwhile.
            guard !isShutDown, !restarting.contains(id) else { return }
            guard let doc = tracked[path], doc.serverID == id, let config = registry.server(forPath: path), config.id == id,
                  let languageID = registry.languageID(forPath: path) else { continue }
            guard let entry = await entry(for: config, path: path) else { continue }
            guard !isShutDown, !restarting.contains(id), entries[id] === entry,
                  let latest = tracked[path], latest.serverID == id else { continue }
            await entry.sync.open(uri: uri(path), languageID: languageID, snapshot: latest.snapshot)
            // The new instance never issued the old one's result ids.
            if semantic[path] != nil { semantic[path]?.base = nil; requestSemanticTokens(path: path) }
            await restartGate?()
        }
        // Documents the registry no longer gives to any server were dropped at reload; nothing else to do.
    }

    private var restartGate: (@Sendable () async -> Void)?
    /// Test hook: runs after each document `finishRestart` opened on the replacement server.
    func setRestartGate(_ gate: (@Sendable () async -> Void)?) { restartGate = gate }

    // MARK: - Semantic tokens

    private struct SemanticDoc {
        var task: Task<Void, Never>?
        /// Tells the current request from a superseded one.
        var sequence = 0
        /// Only kept when the server offers delta and gave a result id: otherwise it could never be used.
        var base: SemanticBase?
        var reportedSupport: Bool?
    }

    /// The documents that asked for tokens.
    private var semantic: [String: SemanticDoc] = [:]
    private var semanticGate: (@Sendable () async -> Void)?

    /// Test hook: runs after a reply arrived and before it is checked against the document's version.
    func setSemanticGate(_ gate: (@Sendable () async -> Void)?) { semanticGate = gate }
    /// Test hook: the number of integers kept as the delta base of `path`.
    func semanticBaseSize(path: String) -> Int? { semantic[path]?.base?.data.count }

    /// Asks for the semantic tokens of `path` once the server has its text, and reports them as an
    /// `LSPResult.semanticTokens` (decoded off this actor). A request still in flight is cancelled first (the server is
    /// told); a later edit of the document cancels it too, since its answer would be for older text. A `probe` also
    /// reports whether the server offers tokens at all (`.semanticSupport`); nothing is asked of one that does not.
    public func requestSemanticTokens(path: String, probe: Bool = false) {
        guard let doc = tracked[path] else { return }
        var state = semantic[path] ?? SemanticDoc()
        // Tasks of one document run one after the other: the superseded task, cancelled, ends promptly, but its reply may
        // still move the delta base, and this request must read the base only after that.
        let previous = state.task
        previous?.cancel()
        state.sequence += 1
        if probe { state.reportedSupport = nil }
        let sequence = state.sequence
        state.task = Task { [weak self] in
            await previous?.value
            await self?.runSemantic(path: path, serverID: doc.serverID, sequence: sequence)
        }
        semantic[path] = state
    }

    private func dropSemantic(path: String) {
        semantic.removeValue(forKey: path)?.task?.cancel()
    }

    /// The server restarted: its result ids mean nothing, so ask again for every document that wants tokens.
    private func resetSemantic(forServer id: String) {
        for path in semantic.keys where tracked[path]?.serverID == id {
            semantic[path]?.base = nil
            requestSemanticTokens(path: path)
        }
    }

    /// `workspace/semanticTokens/refresh`: the server's tokens changed (it finished indexing, say).
    private func refreshSemantic(forServer id: String) {
        for path in semantic.keys where tracked[path]?.serverID == id { requestSemanticTokens(path: path) }
    }

    private func reportSupport(_ supported: Bool, path: String, sequence: Int) {
        guard semantic[path]?.sequence == sequence, semantic[path]?.reportedSupport != supported else { return }
        semantic[path]?.reportedSupport = supported
        continuation.yield(.semanticSupport(path: path, supported: supported))
    }

    /// The server's connection once it is ready, without polling: waits on its state changes. The state before the first
    /// start is `.stopped`, which is not an end; a `.stopped` after that is.
    private static func readyConnection(_ server: LanguageServer) async -> JSONRPCConnection? {
        var first = true
        for await state in await server.stateChanges {
            defer { first = false }
            switch state {
            case .ready: return try? await server.connection()
            case .starting: continue
            case .stopped where first: continue
            default: return nil
            }
        }
        return nil
    }

    private func runSemantic(path: String, serverID: String, sequence: Int) async {
        guard !Task.isCancelled, let target = requestTarget(path: path), tracked[path]?.serverID == serverID else { return }
        guard let rpc = await Self.readyConnection(target.server), !Task.isCancelled,
              let caps = await target.server.capabilities else { return }
        guard let legend = caps.semanticTokens else {
            reportSupport(false, path: path, sequence: sequence)
            return
        }
        reportSupport(true, path: path, sequence: sequence)
        await target.sync.waitUntilSent()
        guard !Task.isCancelled, let now = requestTarget(path: path), semantic[path]?.sequence == sequence else { return }
        let snapshot = now.snapshot
        let base = semantic[path]?.base
        var method = "textDocument/semanticTokens/full"
        var isDelta = false
        var params: [String: JSONValue] = ["textDocument": .object(["uri": .string(target.uri.absoluteString)])]
        if caps.semanticTokensDelta, let base {
            method += "/delta"
            isDelta = true
            params["previousResultId"] = .string(base.resultID)
        }
        let reply: JSONValue
        do {
            reply = try await rpc.request(method, .object(params))
        } catch {
            // A cancelled request says nothing about the server's state; any other failure (a timeout, ContentModified,
            // an error on a stale id) means the base may be wrong. It is dropped, and a failed delta, if still wanted, is
            // asked again once as a full request (a failed full request waits for the next edit).
            if !Task.isCancelled, !(error is CancellationError) {
                semantic[path]?.base = nil
                if isDelta, semantic[path]?.sequence == sequence { requestSemanticTokens(path: path) }
            }
            return
        }
        await semanticGate?()
        let previous = isDelta ? base?.data : nil
        let keep = caps.semanticTokensDelta, encoding = caps.positionEncoding
        let processed = await Task.detached(priority: .userInitiated) {
            SemanticTokens.process(reply, previous: previous, legend: legend, snapshot: snapshot, encoding: encoding, keepData: keep)
        }.value
        guard let processed else {
            // A delta that did not fit (or a malformed reply): forget the base and ask for the whole thing.
            semantic[path]?.base = nil
            if isDelta, semantic[path]?.sequence == sequence { requestSemanticTokens(path: path) }
            return
        }
        // The server's cache moved with this reply whether or not the colours are still wanted, so the base follows it.
        if let id = processed.resultID, let data = processed.data { semantic[path]?.base = SemanticBase(resultID: id, data: data) }
        else { semantic[path]?.base = nil }
        guard !isShutDown, semantic[path]?.sequence == sequence, tracked[path]?.snapshot.version == snapshot.version else { return }
        continuation.yield(.semanticTokens(path: path, version: Int(snapshot.version), runs: processed.runs))
    }

    // MARK: - Servers

    private func stop(_ list: [Entry]) async {
        for entry in list {
            entry.observer?.cancel()
            entry.inbox?.finish()
            entry.diagnosticsTask?.cancel()
            for task in entry.pullTasks.values { task.cancel() }
            entry.pullTasks = [:]
        }
        await withTaskGroup(of: Void.self) { group in
            for entry in list {
                let starter = entry.starter, server = entry.server, sync = entry.sync
                starter?.cancel()
                group.addTask {
                    await server.shutdown()
                    // A start that had not begun yet may have launched the server after the shutdown above.
                    await starter?.value
                    if await server.state != .stopped { await server.shutdown() }
                    // Nothing will start this server again: free the pump and whoever waits for it to have sent.
                    await sync.shutdown()
                }
            }
        }
        for entry in list {
            continuation.yield(.status(path: entry.representative, serverID: entry.config.id, serverName: entry.config.name, state: .stopped))
        }
    }

    /// Command lookups (the login shell, `xcrun`) can take seconds, so they run off this actor; only hits are kept here.
    private var resolvedCommands: [String: String] = [:]
    private var resolveGeneration = 0

    private func resolveCommand(_ command: String) async -> String? {
        if let hit = resolvedCommands[command] { return hit }
        let locator = locator, generation = resolveGeneration
        let found = await Task.detached(priority: .userInitiated) { locator.resolve(command) }.value
        if let found, generation == resolveGeneration { resolvedCommands[command] = found }
        return found
    }

    /// Test hook: the number of commands whose path is cached.
    func resolvedCommandCount() -> Int { resolvedCommands.count }

    /// The running entry for `config`, created (and started in the background) on first use. Nil when the
    /// server's command cannot be found, or when the state changed while it was looked up.
    private func entry(for config: ServerConfig, path: String) async -> Entry? {
        if let existing = entries[config.id] { return existing }
        if missing.contains(config.id) { return nil }
        let found = await resolveCommand(config.command)
        // The lookup suspended this actor: a reload, a quit or another caller may have changed the picture.
        guard !isShutDown, !restarting.contains(config.id), registry.all.contains(config) else { return nil }
        if let existing = entries[config.id] { return existing }
        guard let resolved = found else {
            if missing.insert(config.id).inserted {
                continuation.yield(.status(path: path, serverID: config.id, serverName: config.name,
                                           state: .notInstalled(command: config.command)))
            }
            return nil
        }
        let root = self.root, launcher = self.launcher
        let server = LanguageServer(config: config, root: root, launcher: { try launcher.make(config, resolved, root) })
        let sync = DocumentSync(server: server)
        let entry = Entry(config: config, server: server, sync: sync, representative: path)
        entries[config.id] = entry
        let cont = continuation, name = config.name, id = config.id
        entry.observer = Task {
            var first = true
            for await state in await server.stateChanges {
                defer { first = false }
                if first && state == .stopped { continue }
                cont.yield(.status(path: path, serverID: id, serverName: name, state: state))
            }
        }
        let (incoming, inbox) = AsyncStream<JSONValue>.makeStream()
        entry.inbox = inbox
        entry.diagnosticsTask = Task { [weak self, weak entry] in
            for await params in incoming {
                guard let self, let entry else { return }
                await self.publish(params, from: entry)
            }
        }
        entry.starter = Task {
            let serverID = config.id
            await server.setOnNotification { [weak self] method, params in
                if method == "textDocument/publishDiagnostics", let params { inbox.yield(params) }
                if method == "workspace/semanticTokens/refresh" { Task { await self?.refreshSemantic(forServer: serverID) } }
            }
            await server.setOnRestart { [weak self, weak entry] in
                await sync.reopenAll()
                if let self, let entry {
                    await self.pullAll(entry)
                    await self.resetSemantic(forServer: entry.config.id)
                }
            }
            if Task.isCancelled { return }
            await server.start()
        }
        return entry
    }

    // MARK: - Diagnostics

    /// A `publishDiagnostics` of `entry`'s server: mapped with the snapshot of the version it names and reported.
    private func publish(_ params: JSONValue, from entry: Entry) async {
        entry.pushed = true
        guard let text = params["uri"]?.stringValue, let url = URL(string: text)?.standardizedFileURL,
              let path = tracked.first(where: { $0.value.serverID == entry.config.id && uri($0.key) == url })?.key else { return }
        await deliver(params["diagnostics"]?.arrayValue ?? [], version: params["version"]?.intValue, path: path, entry: entry)
    }

    private func deliver(_ raw: [JSONValue], version: Int?, path: String, entry: Entry) async {
        guard let doc = tracked[path], doc.serverID == entry.config.id else { return }
        guard let items = await DiagnosticMapping.map(raw, version: version, sync: entry.sync, uri: uri(path),
                                                       current: doc.snapshot) else { return }   // evicted: cannot be placed
        guard !isShutDown, tracked[path]?.serverID == entry.config.id else { return }
        continuation.yield(.diagnostics(path: path, version: version ?? Int(doc.snapshot.version), items: items))
    }

    /// Pull diagnostics: only for a server that advertises `diagnosticProvider` and has not pushed, 300 ms after the
    /// last change of the document.
    private func schedulePull(path: String, entry: Entry) {
        guard !entry.pushed else { return }
        entry.pullTasks[path]?.cancel()
        entry.pullTasks[path] = Task { [weak self, weak entry] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let entry else { return }
            await self.pull(path: path, entry: entry)
        }
    }

    /// After a restart the new server has pushed nothing yet: ask again for every document of `entry`.
    private func pullAll(_ entry: Entry) {
        for (path, doc) in tracked where doc.serverID == entry.config.id { schedulePull(path: path, entry: entry) }
    }

    private func pull(path: String, entry: Entry) async {
        guard !entry.pushed, let doc = tracked[path], doc.serverID == entry.config.id else { return }
        // Wait for the server (no polling: `connection()` resumes when it is ready), then ask only a server that
        // offers pull, and only once it has the text it will be asked about.
        guard let rpc = try? await entry.server.connection(), !Task.isCancelled,
              let caps = await entry.server.capabilities, caps.pullDiagnostics else { return }
        await entry.sync.waitUntilSent()
        guard !Task.isCancelled, !entry.pushed, let snapshot = tracked[path]?.snapshot else { return }
        let params: JSONValue = .object(["textDocument": .object(["uri": .string(uri(path).absoluteString)])])
        guard let report = try? await rpc.request("textDocument/diagnostic", params), !Task.isCancelled,
              report["kind"]?.stringValue != "unchanged", !entry.pushed,
              let items = report["items"]?.arrayValue else { return }
        await deliver(items, version: Int(snapshot.version), path: path, entry: entry)
    }

    // MARK: - Requests

    /// What a request about `path` needs: its running server, that server's sync and the document's URI, and the
    /// text the manager last passed on. Nil when no server holds the document.
    struct RequestTarget {
        var server: LanguageServer
        var sync: DocumentSync
        var uri: URL
        var snapshot: CodeSnapshot
        var root: URL
    }

    func requestTarget(path: String) -> RequestTarget? {
        guard let doc = tracked[path], let entry = entries[doc.serverID] else { return nil }
        return RequestTarget(server: entry.server, sync: entry.sync, uri: uri(path), snapshot: doc.snapshot, root: root)
    }

    private func uri(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return root.appendingPathComponent(path).standardizedFileURL
    }
}
