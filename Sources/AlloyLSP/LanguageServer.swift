import AlloyCore
import Foundation

public enum PositionEncoding: String, Sendable {
    case utf8 = "utf-8"
    case utf16 = "utf-16"
    case utf32 = "utf-32"
}

public enum TextSyncKind: Int, Sendable {
    case none = 0
    case full = 1
    case incremental = 2
}

public struct SemanticTokensLegend: Sendable, Equatable {
    public var tokenTypes: [String]
    public var tokenModifiers: [String]

    public init(tokenTypes: [String], tokenModifiers: [String]) {
        self.tokenTypes = tokenTypes
        self.tokenModifiers = tokenModifiers
    }
}

/// What the server announced in its `initialize` result.
public struct ServerCapabilities: Sendable {
    public var positionEncoding: PositionEncoding
    public var sync: TextSyncKind
    public var definition: Bool
    public var semanticTokens: SemanticTokensLegend?
    public var semanticTokensDelta: Bool
    public var pullDiagnostics: Bool

    /// - Parameter json: the `capabilities` object (an `InitializeResult` is unwrapped too).
    public init(json: JSONValue) {
        let caps = json["capabilities"] ?? json
        // Servers that do not answer positionEncoding use UTF-16.
        positionEncoding = caps["positionEncoding"]?.stringValue.flatMap(PositionEncoding.init(rawValue:)) ?? .utf16
        let syncValue = caps["textDocumentSync"]
        let kind = syncValue?.intValue ?? syncValue?["change"]?.intValue
        sync = kind.flatMap(TextSyncKind.init(rawValue:)) ?? .none
        definition = Self.isProvided(caps["definitionProvider"])
        // A provider that offers only ranges (`full` absent or false) is not asked: phase 1 requests whole documents.
        if let provider = caps["semanticTokensProvider"], provider.objectValue != nil, let legend = provider["legend"],
           Self.isProvided(provider["full"]) {
            semanticTokens = SemanticTokensLegend(
                tokenTypes: legend["tokenTypes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                tokenModifiers: legend["tokenModifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            let full = provider["full"]
            semanticTokensDelta = full?["delta"]?.boolValue ?? false
        } else {
            semanticTokens = nil
            semanticTokensDelta = false
        }
        pullDiagnostics = Self.isProvided(caps["diagnosticProvider"])
    }

    private static func isProvided(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let b): b
        case .object: true
        default: false
        }
    }
}

public enum ServerState: Sendable, Equatable {
    case starting
    case ready
    case notInstalled(command: String)
    case failed(reason: String)
    case stopped
}

public enum LanguageServerError: Error, Equatable {
    case notReady(ServerState)
}

/// Owns one language server: launch, handshake, answering its requests, and the restart policy.
public actor LanguageServer {
    public typealias Channel = any LSPByteChannel & ServerExitObserving

    public static let maxRestarts = 3
    public static let restartWindow: Duration = .seconds(300)

    private final class NotificationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (String, JSONValue?) -> Void)?
        func set(_ h: (@Sendable (String, JSONValue?) -> Void)?) { lock.lock(); handler = h; lock.unlock() }
        func call(_ method: String, _ params: JSONValue?) {
            lock.lock(); let h = handler; lock.unlock()
            h?(method, params)
        }
    }

    private let config: ServerConfig
    private let root: URL
    private let launcher: @Sendable () throws -> Channel
    private let now: @Sendable () -> ContinuousClock.Instant
    private let initializeTimeout: Duration
    private let notificationBox = NotificationBox()

    public private(set) var state: ServerState = .stopped
    public private(set) var capabilities: ServerCapabilities?

    public var onNotification: (@Sendable (String, JSONValue?) -> Void)? {
        didSet { notificationBox.set(onNotification) }
    }
    /// Called once per restart that reached `.ready` and is still current, so document sync can re-open its documents.
    public var onRestart: (@Sendable () async -> Void)?

    public func setOnRestart(_ handler: (@Sendable () async -> Void)?) { onRestart = handler }
    public func setOnNotification(_ handler: (@Sendable (String, JSONValue?) -> Void)?) { onNotification = handler }

    private var channel: Channel?
    private var rpc: JSONRPCConnection?
    private var generation = 0
    private var stopping = false
    private var restartTimes: [ContinuousClock.Instant] = []
    private var subscribers: [UUID: AsyncStream<ServerState>.Continuation] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(config: ServerConfig, root: URL,
                launcher: @escaping @Sendable () throws -> Channel,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
                initializeTimeout: Duration = .seconds(30)) {
        self.config = config
        self.root = root
        self.launcher = launcher
        self.now = now
        self.initializeTimeout = initializeTimeout
    }

    /// State changes, starting with the current state.
    public var stateChanges: AsyncStream<ServerState> {
        let (stream, cont) = AsyncStream<ServerState>.makeStream()
        let id = UUID()
        subscribers[id] = cont
        cont.yield(state)
        cont.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func setState(_ new: ServerState) {
        guard new != state else { return }
        state = new
        for (_, c) in subscribers { c.yield(new) }
        if new != .starting {
            let all = waiters
            waiters = []
            for w in all { w.resume() }
        }
    }

    /// Launches the server and runs the handshake. Returns once the first attempt resolved (ready, failed
    /// or not installed). Later crashes are handled by the restart policy.
    public func start() async {
        // A start that was cancelled before it reached the actor must not launch a server that a shutdown
        // already walked past.
        guard !Task.isCancelled else { return }
        guard state != .starting, state != .ready else { return }
        stopping = false
        restartTimes = []
        setState(.starting)
        await launchAttempt()
    }

    /// The live connection. Waits while the server is (re)starting; throws when it is not ready.
    public func connection() async throws -> JSONRPCConnection {
        while state == .starting { await withCheckedContinuation { waiters.append($0) } }
        guard state == .ready, let rpc else { throw LanguageServerError.notReady(state) }
        return rpc
    }

    /// `shutdown`, `exit`, then ends the process (SIGTERM, SIGKILL after 2 s).
    public func shutdown() async {
        stopping = true
        generation += 1
        let rpc = self.rpc, channel = self.channel
        self.rpc = nil
        self.channel = nil
        var politeExit = true
        if let rpc, state == .ready {
            do { _ = try await rpc.request("shutdown", nil, timeout: .seconds(2)) } catch { politeExit = false }
            try? await rpc.notify("exit", nil, urgent: true)
        }
        if let channel {
            // Give the server a moment to leave on its own after `exit`, then signal it. Nothing here waits on
            // the stdin writer, which can be blocked on a full pipe.
            await Self.waitForExit(channel, limit: politeExit ? .seconds(2) : .seconds(1))
            await channel.stop(grace: .seconds(2))
        }
        // The process is gone, so any blocked write has failed and the writer can drain.
        await rpc?.close()
        capabilities = nil
        setState(.stopped)
    }

    private static func waitForExit(_ channel: Channel, limit: Duration) async {
        let exits = channel.exited
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in exits { return } }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Launch

    /// - Returns: the generation this attempt ran under.
    @discardableResult
    private func launchAttempt() async -> Int {
        generation += 1
        let gen = generation
        let channel: Channel
        do { channel = try launcher() } catch {
            if case ServerProcessError.notInstalled(let command) = error { setState(.notInstalled(command: command)) }
            else { setState(.failed(reason: "\(error)")) }
            return gen
        }
        let rpc = JSONRPCConnection(channel: channel)
        self.channel = channel
        self.rpc = rpc
        await rpc.start()
        let box = notificationBox
        await rpc.onNotification { method, params in box.call(method, params) }
        let root = self.root
        await rpc.onRequest { method, params in
            if method == Self.semanticRefreshMethod { box.call(method, params) }
            return Self.answer(method: method, params: params, root: root) }
        let exits = channel.exited
        Task { [weak self] in
            for await code in exits { await self?.processExited(generation: gen, code: code) }
        }

        do {
            let result = try await rpc.request("initialize", initializeParams(), timeout: initializeTimeout)
            guard gen == generation else { return gen }
            capabilities = ServerCapabilities(json: result["capabilities"] ?? .null)
            // A failed `initialized` means the connection already closed; the exit watcher takes over.
            try? await rpc.notify("initialized", .object([:]))
            guard gen == generation else { return gen }
            setState(.ready)
        } catch {
            guard gen == generation else { return gen }
            if (error as? JSONRPCError) == JSONRPCError.connectionClosed {
                // The process went away, or the connection broke (write failure, framing error). Either way the
                // exit watcher applies the restart policy once the process has ended.
                await channel.stop(grace: .seconds(1))
                return gen
            }
            let reason = "initialize failed: \(error)"
            generation += 1  // the exit watcher must not restart a server we gave up on
            self.rpc = nil
            self.channel = nil
            await rpc.close()
            await channel.stop(grace: .seconds(1))
            setState(.failed(reason: reason))
        }
        return gen
    }

    private func processExited(generation gen: Int, code: Int32) async {
        guard gen == generation, !stopping else { return }
        generation += 1  // claim this exit: anything still running for the old generation is now stale
        let claimed = generation
        let dead = rpc, deadChannel = channel
        rpc = nil
        channel = nil
        capabilities = nil
        let stderrLine = deadChannel?.stderrTail
            .split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }
        let closeReason = await dead?.closeReason
        await dead?.close()
        guard claimed == generation, !stopping else { return }

        let instant = now()
        restartTimes.removeAll { $0.duration(to: instant) >= Self.restartWindow }
        guard restartTimes.count < Self.maxRestarts else {
            generation += 1
            let reason = stderrLine.flatMap { $0.isEmpty ? nil : $0 } ?? closeReason ?? "server exited with status \(code)"
            setState(.failed(reason: reason))
            return
        }
        restartTimes.append(instant)
        setState(.starting)
        let attempt = await launchAttempt()
        // Only a restart that reached ready, and is still the live one, counts.
        guard !stopping, attempt == generation, state == .ready else { return }
        await onRestart?()
    }

    // MARK: - Protocol payloads

    private func initializeParams() -> JSONValue {
        let rootURI = root.absoluteString
        var params: [String: JSONValue] = [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(rootURI),
            "workspaceFolders": Self.workspaceFolders(root),
            "clientInfo": .object(["name": .string("Alloy")]),
            "capabilities": Self.clientCapabilities,
        ]
        if let options = config.initializationOptions { params["initializationOptions"] = options }
        return .object(params)
    }

    private static func workspaceFolders(_ root: URL) -> JSONValue {
        .array([.object(["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)])])
    }

    static let semanticRefreshMethod = "workspace/semanticTokens/refresh"
    static let semanticTokenTypes = [
        "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "variable",
        "property", "enumMember", "event", "function", "method", "macro", "keyword", "modifier", "comment",
        "string", "number", "regexp", "operator", "decorator",
    ]
    static let semanticTokenModifiers = [
        "declaration", "definition", "readonly", "static", "deprecated", "abstract", "async", "modification",
        "documentation", "defaultLibrary",
    ]

    static var clientCapabilities: JSONValue {
        .object([
            "general": .object(["positionEncodings": .array([.string("utf-8"), .string("utf-16")])]),
            "workspace": .object(["workspaceFolders": .bool(true), "configuration": .bool(true),
                                  "semanticTokens": .object(["refreshSupport": .bool(true)])]),
            "textDocument": .object([
                "synchronization": .object(["didSave": .bool(true)]),
                "publishDiagnostics": .object(["relatedInformation": .bool(false), "versionSupport": .bool(true)]),
                "definition": .object(["linkSupport": .bool(true)]),
                "semanticTokens": .object([
                    "requests": .object(["full": .object(["delta": .bool(true)])]),
                    "tokenTypes": .array(semanticTokenTypes.map { .string($0) }),
                    "tokenModifiers": .array(semanticTokenModifiers.map { .string($0) }),
                    "formats": .array([.string("relative")]),
                ]),
                "diagnostic": .object([:]),
            ]),
            "window": .object(["workDoneProgress": .bool(true)]),
        ])
    }

    /// Replies to the requests a server sends the client.
    static func answer(method: String, params: JSONValue?, root: URL) -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "workspace/configuration":
            let count = params?["items"]?.arrayValue?.count ?? 0
            return .success(.array(Array(repeating: .null, count: count)))
        case "window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability",
             semanticRefreshMethod:
            return .success(.null)
        case "workspace/workspaceFolders":
            return .success(workspaceFolders(root))
        default:
            return .failure(JSONRPCError(code: JSONRPCError.methodNotFoundCode, message: "Method not found: \(method)"))
        }
    }
}
