import AlloyCore
import AlloyHighlight
import AlloyLSP
import Foundation
import MetalUI

/// The window's bridge to the language servers of one workspace. Panel views report their document's life
/// (open, edits, save, close) here on the main actor; every report is queued onto one ordered stream and handled by
/// the `LSPManager` off the main actor. The manager (and so every server) exists only once a file a server
/// handles is first opened. Only ``status`` is observable.
@MainActor
public final class LSPCoordinator {
    private enum Command: Sendable {
        case open(String, CodeSnapshot)
        case change(String, DocumentChange)
        case saved(String)
        case semantic(String, probe: Bool)
        case close(String)
        case reload(ServerRegistry)
        /// Resumes once every command before it was handled, so a request sees the text reported so far.
        case barrier(CheckedContinuation<Void, Never>)
        case shutdown(CheckedContinuation<Void, Never>)
    }

    public let status = LSPStatusModel()
    /// The latest diagnostics per open document. Only its counts are observable.
    public let diagnostics = DiagnosticStore()
    private let root: URL
    let builtIn: [ServerConfig]
    let locator: ServerLocator
    private let launcher: ServerLauncher
    private var registry: ServerRegistry
    private var manager: LSPManager?
    private var commands: AsyncStream<Command>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    /// Documents currently reported open, for the status model.
    private var openPaths: Set<String> = []
    /// The latest state per server id (not name: two configs may share a display name).
    private var serverStates: [String: ServerState] = [:]
    private var shutDown = false
    /// Tells the panel's views that a document was saved (they flush their pending edits first, to keep order).
    var savedHandler: ((String) -> Void)?
    /// Tells the panel's views to report their documents again after a settings change.
    var reloadHandler: (() -> Void)?
    /// Tells the panel's views that the diagnostics of a document changed (to paint them).
    var diagnosticsHandler: ((String) -> Void)?
    /// Hands the panel's views the semantic tokens of a document (decoded off the main actor): path, buffer version, runs.
    var semanticHandler: ((String, Int, [(Range<Int>, SyntaxToken)]) -> Void)?
    /// Tells the panel's views whether the server of a document offers semantic tokens.
    var semanticSupportHandler: ((String, Bool) -> Void)?

    public init(root: URL, builtIn: [ServerConfig] = ServerRegistry.builtIn,
                overrides: [String: ServerConfigOverride] = [:], locator: ServerLocator, launcher: ServerLauncher) {
        self.root = root
        self.builtIn = builtIn
        self.locator = locator
        self.launcher = launcher
        registry = ServerRegistry(builtIn: builtIn, overrides: overrides)
    }

    /// Creates the coordinator for `workspace` and wires the workspace's save, settings and quit hooks to it.
    @discardableResult
    public static func install(on workspace: Workspace, builtIn: [ServerConfig] = ServerRegistry.builtIn,
                               locator: ServerLocator = .live, launcher: ServerLauncher) -> LSPCoordinator {
        let coordinator = LSPCoordinator(root: workspace.projectRoot, builtIn: builtIn,
                                         overrides: workspace.settings.languageServers, locator: locator, launcher: launcher)
        workspace.languageServices = coordinator
        workspace.onSaved = { [weak coordinator] path in coordinator?.documentSaved(path) }
        workspace.onLanguageServersChanged = { [weak coordinator] overrides in coordinator?.reload(overrides: overrides) }
        workspace.onStop = { [weak coordinator] in await coordinator?.shutdown() }
        return coordinator
    }

    /// The production wiring: real processes, found through the login shell's PATH.
    @discardableResult
    public static func installLive(on workspace: Workspace, loginPATH: @escaping @Sendable () -> String?) -> LSPCoordinator {
        install(on: workspace, launcher: .live(loginPATH: loginPATH))
    }

    /// Whether the manager (and so any server machinery) exists yet.
    var hasManager: Bool { manager != nil }

    /// Whether a server handles `path`.
    func wants(_ path: String) -> Bool { !shutDown && registry.server(forPath: path) != nil }

    // MARK: - Document reports (main actor, cheap)

    func opened(path: String, snapshot: CodeSnapshot) {
        guard wants(path) else { return }
        send(.open(path, snapshot), creating: true)
        openPaths.insert(path)
        applyKnownState(to: path)
    }

    func changed(path: String, change: DocumentChange) {
        guard openPaths.contains(path) else { return }
        send(.change(path, change))
    }

    /// Asks the server for the document's semantic tokens (after the edits reported so far). A request in flight is
    /// superseded; the answer arrives through ``semanticHandler``.
    /// A `probe` also learns whether the server offers tokens at all (see ``semanticSupportHandler``).
    func requestSemanticTokens(path: String, probe: Bool = false) {
        guard openPaths.contains(path) else { return }
        send(.semantic(path, probe: probe))
    }

    func closed(path: String) {
        guard openPaths.remove(path) != nil else { return }
        status.remove(path: path)
        diagnostics.remove(path: path)
        send(.close(path))
    }

    private func documentSaved(_ path: String) {
        guard openPaths.contains(path) else { return }
        if let savedHandler { savedHandler(path) } else { send(.saved(path)) }
    }

    /// The view flushed its edits; the save follows them.
    func flushedSaved(path: String) {
        guard openPaths.contains(path) else { return }
        send(.saved(path))
    }

    private func reload(overrides: [String: ServerConfigOverride]) {
        let before = Dictionary(uniqueKeysWithValues: openPaths.map { ($0, registry.server(forPath: $0)?.id) })
        registry = ServerRegistry(builtIn: builtIn, overrides: overrides)
        // A path that now belongs to another server (or none) keeps nothing of the old one's. (Keyed by path here, not by
        // a late `.stopped` of the old instance, which could arrive after the new server published.)
        for path in openPaths where (before[path] ?? nil) != nil && registry.server(forPath: path)?.id != (before[path] ?? nil) {
            if diagnostics.remove(path: path) { diagnosticsHandler?(path) }
        }
        for path in openPaths where registry.server(forPath: path) == nil {
            openPaths.remove(path)
            status.remove(path: path)
            if diagnostics.remove(path: path) { diagnosticsHandler?(path) }
        }
        send(.reload(registry))
        reloadHandler?()
    }

    /// Stops every server and waits for them to exit. Nothing is reported afterwards.
    func shutdown() async {
        shutDown = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            guard commands != nil else { done.resume(); return }
            send(.shutdown(done))
        }
        commands?.finish()
        commands = nil
        resultsTask?.cancel()
        status.removeAll()
        diagnostics.removeAll()
        openPaths = []
    }

    // MARK: - Requests

    /// Where the symbol at `utf8Offset` of `snapshot` is defined, once the server has every edit reported so far. Cancel
    /// the calling task to abandon the request (the server is told).
    func definition(path: String, utf8Offset: Int, snapshot: CodeSnapshot) async -> DefinitionOutcome {
        guard openPaths.contains(path), commands != nil, let manager else { return .unavailable }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in send(.barrier(done)) }
        guard !Task.isCancelled else { return .unavailable }
        return await manager.definitionOutcome(path: path, utf8Offset: utf8Offset, snapshot: snapshot)
    }

    // MARK: - Pipeline

    private func send(_ command: Command, creating: Bool = false) {
        if commands == nil {
            guard creating, !shutDown else { return }
            start()
        }
        commands?.yield(command)
    }

    /// Makes the manager, its command pump and its result reader.
    private func start() {
        let manager = LSPManager(root: root, registry: registry, locator: locator, launcher: launcher)
        self.manager = manager
        let (stream, continuation) = AsyncStream<Command>.makeStream()
        commands = continuation
        pump = Task.detached {
            for await command in stream {
                switch command {
                case .open(let path, let snapshot): await manager.documentOpened(path: path, snapshot: snapshot)
                case .change(let path, let change): await manager.documentChanged(path: path, change: change)
                case .saved(let path): await manager.documentSaved(path: path)
                case .semantic(let path, let probe): await manager.requestSemanticTokens(path: path, probe: probe)
                case .close(let path): await manager.documentClosed(path: path)
                case .reload(let registry): await manager.reload(registry: registry)
                case .barrier(let done): done.resume()
                case .shutdown(let done):
                    await manager.shutdownAll()
                    done.resume()
                }
            }
        }
        resultsTask = Task { [weak self] in
            for await result in manager.results { self?.handle(result) }
        }
    }

    func handle(_ result: LSPResult) {
        guard !shutDown else { return }
        switch result {
        case .diagnostics(let path, let version, let items):
            guard openPaths.contains(path) else { return }
            diagnostics.set(path: path, version: version, items: items)
            diagnosticsHandler?(path)
        case .semanticTokens(let path, let version, let runs):
            guard openPaths.contains(path) else { return }
            semanticHandler?(path, version, runs)
        case .semanticSupport(let path, let supported):
            guard openPaths.contains(path) else { return }
            semanticSupportHandler?(path, supported)
        case .status(_, let id, let name, let state):
            if state == .stopped { serverStates[id] = nil } else { serverStates[id] = state }
            for path in openPaths where registry.server(forPath: path)?.id == id {
                if state == .stopped { status.remove(path: path) } else { status.set(path: path, name: name, state: state) }
                // A server that gave up reports nothing more. (A stopped one is not cleared: its late `.stopped` can
                // arrive after the replacement already published.)
                if case .failed = state, diagnostics.remove(path: path) { diagnosticsHandler?(path) }
            }
        }
    }

    private func applyKnownState(to path: String) {
        guard let server = registry.server(forPath: path), let state = serverStates[server.id] else { return }
        status.set(path: path, name: server.name, state: state)
    }
}
