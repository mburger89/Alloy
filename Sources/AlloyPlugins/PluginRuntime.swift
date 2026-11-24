import AlloyCore
import AlloyRPC
import Foundation

/// What the host needs to run one enabled plugin.
public struct PluginRuntimeConfig: Sendable, Equatable {
    public var manifest: PluginManifest
    public var folder: URL
    public var grants: Set<PluginPermission>
    public var values: [String: JSONValue]
    /// Secret settings as environment variables (filled by the Keychain task). Never logged or sent.
    public var secretEnvironment: [String: String]

    public init(manifest: PluginManifest, folder: URL, grants: Set<PluginPermission> = [], values: [String: JSONValue] = [:],
                secretEnvironment: [String: String] = [:]) {
        self.manifest = manifest
        self.folder = folder
        self.grants = grants
        self.values = values
        self.secretEnvironment = secretEnvironment
    }
}

public enum ActivationReason: Sendable, Equatable {
    case startup, command, language, panel, mcpTool, document

    /// A plugin started for anything but startup serves one project and stops when the workspace changes.
    public var isProjectBound: Bool { self != .startup }
}

public enum PluginRunState: Sendable, Equatable {
    case notStarted, starting, running, stopped
    /// The crashes counted inside the crash window.
    case crashed(Int)
    case disabledAfterCrashes
    case needsAPI(Int)
    case sandboxUnavailable(String)
    case failedToStart(String)
}

public enum PluginHostEvent: Sendable {
    case state(id: String, PluginRunState)
    case started(id: String)
    case notification(id: String, method: String, params: JSONValue?)
    /// The plugin's latest decorations for `uri`, at most one per uri per `decorationHop` and only when they changed.
    case decorations(id: String, uri: String, set: PluginDecorationSet)
    /// The plugin's newest tree for one of its panels.
    case panel(id: String, panelID: String, tree: PluginPanelTree)
    /// A `panel/render` whose tree was refused (the reason goes to the plugin's log).
    case panelRejected(id: String, panelID: String, reason: String)
    /// A `window/showMessage` of the plugin; `type` is `info`, `warning` or `error`.
    case showMessage(id: String, type: String, message: String)
}

/// Holds a plugin's newest `decorations/set` per uri between the connection's callback (any thread, in arrival order) and the
/// host actor's next hop. `put` says whether a drain still has to be scheduled.
final class PluginDecorationInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: PluginDecorationSet] = [:]
    private var scheduled = false

    func put(uri: String, _ set: PluginDecorationSet) -> Bool {
        lock.withLock {
            pending[uri] = set
            if scheduled { return false }
            scheduled = true
            return true
        }
    }

    func take() -> [String: PluginDecorationSet] {
        lock.withLock {
            defer { pending = [:]; scheduled = false }
            return pending
        }
    }
}

/// How the app answers a plugin's requests. Called only for methods the plugin holds the grant for.
public struct PluginHostServices: Sendable {
    public var answer: @Sendable (_ id: String, _ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError>

    public init(answer: @escaping @Sendable (_ id: String, _ method: String, _ params: JSONValue?) async -> Result<JSONValue, JSONRPCError>) {
        self.answer = answer
    }

    public init() {
        self.init { _, method, _ in
            .failure(JSONRPCError(code: JSONRPCError.methodNotFoundCode, message: "Method not found: \(method)"))
        }
    }
}

/// One running plugin process and its connection.
final class PluginRuntime: @unchecked Sendable {
    let id: String
    let generation: Int
    let process: ServerProcess
    let connection: JSONRPCConnection
    var lastActivation: ActivationReason
    var startTime: Double?
    /// Clock time the process was started.
    let startedAt: Double
    let gate = PluginInboundGate()
    /// Touched only on the host actor.
    var idleTask: Task<Void, Never>?
    var cpuSamples: [(time: Double, cpu: Double)] = []

    private let lock = NSLock()
    private var message: Double
    private var sampled: Double

    /// The latest `decorations/set` per uri, written from the connection's callback and drained by the host's hop.
    let decorationInbox = PluginDecorationInbox()

    init(id: String, generation: Int, process: ServerProcess, connection: JSONRPCConnection, lastActivation: ActivationReason,
         now: Double) {
        self.id = id
        self.generation = generation
        self.process = process
        self.connection = connection
        self.lastActivation = lastActivation
        startedAt = now
        message = now
        sampled = now
    }

    /// Clock time of the last request, event or message.
    var lastMessage: Double { lock.withLock { message } }
    func touch(_ now: Double) { lock.withLock { message = max(message, now) } }
    func forceTouch(_ now: Double) { lock.withLock { message = now } }

    /// True (and records it) when a message-triggered sample is due: at most one per `interval`.
    func claimSample(_ now: Double, interval: Double) -> Bool {
        lock.withLock {
            guard now - sampled >= interval else { return false }
            sampled = now
            return true
        }
    }
}

/// Paces a plugin's inbound messages: past `perSecond` in one clock second the reader waits for the next second, and a
/// plugin that overflows in `seconds` different seconds within `window` is reported as chatty.
final class PluginInboundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var bucket = Int.min
    private var count = 0
    private var flagged = false
    private var chatty: [Double] = []

    /// Waits while the second's budget is spent. `onChatty` runs as soon as the chatty budget is spent, before the wait.
    func admit(clock: any AutosaveClock, perSecond: Int, seconds: Int, window: Double, onChatty: @Sendable () -> Void) async {
        while true {
            var tripped = false
            let now = clock.now
            let current = Int(now.rounded(.down))
            let wake: Double? = lock.withLock {
                if current != bucket { bucket = current; count = 0; flagged = false }
                if count < perSecond { count += 1; return nil }
                if !flagged {
                    flagged = true
                    chatty.append(now)
                    chatty.removeAll { $0 < now - window }
                    if chatty.count >= seconds { tripped = true; chatty = [] }
                }
                return Double(current + 1)
            }
            if tripped { onChatty() }
            guard let wake else { return }
            do { try await clock.sleep(until: wake) } catch { return }
        }
    }
}

/// Answers a plugin's request exactly once: with the app's answer, or with `-32800` when the request is cancelled first.
final class PluginInflightRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result<JSONValue, JSONRPCError>, Never>?
    let pluginID: String

    init(pluginID: String, continuation: CheckedContinuation<Result<JSONValue, JSONRPCError>, Never>) {
        self.pluginID = pluginID
        self.continuation = continuation
    }

    func resolve(_ result: Result<JSONValue, JSONRPCError>) {
        let c = lock.withLock { () -> CheckedContinuation<Result<JSONValue, JSONRPCError>, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: result)
    }
}
