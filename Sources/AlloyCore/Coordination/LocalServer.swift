import Foundation
import Network
import Security

/// A loopback-only HTTP/1.1 listener that serves the MCP endpoint `/mcp`.
/// Each Alloy session gets its own bearer token; the token identifies the caller of every tool.
public actor LocalServer {
    public static let maxBodyBytes = 4 * 1024 * 1024
    private static let maxHeadBytes = 16 * 1024
    private static let maxDrainBytes = 32 * 1024 * 1024

    /// Resource limits. Injectable so tests do not wait for the production values.
    public struct Limits: Sendable {
        public var maxConnections = 48
        /// Time allowed to read one request (head and body) once its first byte, or a new connection, arrives.
        public var requestDeadline: TimeInterval = 10
        /// How long a keep-alive connection may sit idle between requests.
        public var idleTimeout: TimeInterval = 60
        /// How long an error reply waits for the client to finish uploading before the connection is closed.
        public var drainDeadline: TimeInterval = 5
        /// How long a hook handler may take before the CLI is answered `{}` and proceeds.
        public var hookDeadline: Duration = .seconds(1)
        public init() {}
    }

    private let tools: [MCPTool]
    private let limits: Limits
    private let onListenerFailure: (@Sendable (Error) -> Void)?
    private let report: (@Sendable (String) -> Void)?
    public typealias HookHandler = @Sendable (HookRequest, MCPCaller) async -> HookReply
    private var hookHandler: HookHandler?
    private var hookProblemReported: Set<UUID> = []
    private let queue = DispatchQueue(label: "alloy.local-server")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var tokenToSession: [String: UUID] = [:]
    private var sessionToToken: [UUID: String] = [:]
    private struct OpenConnection {
        let connection: NWConnection
        let task: Task<Void, Never>
    }
    private var connections: [Int: OpenConnection] = [:]
    private var nextConnectionID = 0

    /// Tool names must be unique and every input schema must be a JSON Schema object.
    public init(tools: [MCPTool], limits: Limits = Limits(), onListenerFailure: (@Sendable (Error) -> Void)? = nil,
                report: (@Sendable (String) -> Void)? = nil) {
        self.report = report
        precondition(Set(tools.map(\.name)).count == tools.count, "MCP tool names must be unique")
        precondition(tools.allSatisfy { $0.inputSchema["type"]?.stringValue == "object" }, "MCP tool inputSchema must have type \"object\"")
        self.tools = tools
        self.limits = limits
        self.onListenerFailure = onListenerFailure
    }

    deinit { listener?.cancel() }

    public enum StartError: Error { case alreadyStarted, noPort, notReady }

    /// The address the listener is bound to, e.g. `127.0.0.1:52000`. Nil before `start()` and after `stop()`.
    public var listenerEndpoint: NWEndpoint? {
        guard let listener, let host = listener.parameters.requiredLocalEndpoint else { return nil }
        if case .hostPort(let h, _) = host, let p = listener.port { return .hostPort(host: h, port: p) }
        return nil
    }

    /// Connections currently open (for tests and diagnostics).
    public var openConnectionCount: Int { connections.count }

    /// Binds 127.0.0.1 on an ephemeral port and returns `http://127.0.0.1:<port>/mcp`.
    public func start() async throws -> URL {
        guard listener == nil else { throw StartError.alreadyStarted }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                guard let self else { connection.cancel(); return }
                await self.accept(connection)
            }
        }
        let report = onListenerFailure
        do {
            let assigned: UInt16 = try await withCheckedThrowingContinuation { cont in
                let gate = ResumeOnce(cont)
                listener.stateUpdateHandler = { [weak listener] state in
                    switch state {
                    case .ready:
                        if let p = listener?.port?.rawValue { _ = gate.resume(returning: p) } else { _ = gate.resume(throwing: StartError.noPort) }
                    case .waiting(let error):
                        _ = gate.resume(throwing: error)
                    case .failed(let error):
                        // Before ready this fails start(); afterwards it is reported.
                        if !gate.resume(throwing: error) { report?(error) }
                    case .cancelled:
                        _ = gate.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            port = assigned
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
        return URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    /// Cancels the listener and every open connection.
    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for (_, entry) in connections {
            entry.task.cancel()
            entry.connection.cancel()
        }
        connections.removeAll()
    }

    /// A random 32-byte, hex-encoded bearer token, stable for the session until revoked.
    public func token(for session: UUID) -> String {
        if let existing = sessionToToken[session] { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess { for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) } }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        sessionToToken[session] = token
        tokenToSession[token] = session
        return token
    }

    /// Sets the closure that answers hooks. Until one is set every hook is answered `{}`.
    public func setHookHandler(_ handler: @escaping HookHandler) { hookHandler = handler }

    public func revoke(session: UUID) {
        hookProblemReported.remove(session)
        if let token = sessionToToken.removeValue(forKey: session) { tokenToSession[token] = nil }
    }

    /// Constant-time lookup: compares against every token without an early exit.
    private func session(forBearer candidate: String) -> UUID? {
        let probe = Array(candidate.utf8)
        var found: UUID?
        for (token, session) in tokenToSession {
            let expected = Array(token.utf8)
            var diff = UInt(expected.count ^ probe.count)
            for i in 0..<expected.count { diff |= UInt(expected[i] ^ (i < probe.count ? probe[i] : 0)) }
            if diff == 0 { found = session }
        }
        return found
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < limits.maxConnections else { connection.cancel(); return }
        let id = nextConnectionID
        nextConnectionID += 1
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.serve(connection, id: id)
        }
        connections[id] = OpenConnection(connection: connection, task: task)
    }

    private struct Head {
        var method = ""
        var path = ""
        var http11 = true
        var headers: [String: String] = [:]
        var contentLength: Int?
    }

    private func serve(_ conn: NWConnection, id: Int) async {
        conn.start(queue: queue)
        var buffer = Data()
        defer {
            conn.cancel()
            connections[id] = nil
        }
        let terminator = Data("\r\n\r\n".utf8)
        var firstRequest = true

        while !Task.isCancelled {
            // A request's clock starts at its first byte (or at once for a new connection or buffered bytes).
            var started: ContinuousClock.Instant? = (buffer.isEmpty && !firstRequest) ? nil : ContinuousClock.now
            firstRequest = false

            // Read the request head.
            var headRange: Range<Int>?
            while headRange == nil {
                if let r = buffer.range(of: terminator) { headRange = r; break }
                if buffer.count > Self.maxHeadBytes {
                    await fail(conn, 400, declared: 0)
                    return
                }
                guard await readMore(conn, &buffer, &started) else { return }
            }
            guard let headRange, headRange.lowerBound <= Self.maxHeadBytes,
                  let head = Self.parseHead(buffer.subdata(in: 0..<headRange.lowerBound)) else {
                await fail(conn, 400, declared: 0)
                return
            }
            let bodyStart = headRange.upperBound
            let declared = head.contentLength
            let have = buffer.count - bodyStart

            // Host and Origin guard against DNS rebinding and browsers.
            let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
            guard let host = head.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
                await fail(conn, 403, declared: declared ?? 0, have: have); return
            }
            if let origin = head.headers["origin"], !allowedHosts.map({ "http://" + $0 }).contains(origin.lowercased()) {
                await fail(conn, 403, declared: declared ?? 0, have: have); return
            }
            // Bearer token.
            var caller: MCPCaller?
            if let auth = head.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
                let candidate = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                if let s = session(forBearer: candidate) { caller = MCPCaller(sessionID: s) }
            }
            guard let caller else {
                await fail(conn, 401, declared: declared ?? 0, have: have); return
            }
            let hookEvent: HookEvent? = [HookEvent.preToolUse, .postToolUse].first { $0.path == head.path }
            guard head.path == "/mcp" || hookEvent != nil else {
                await fail(conn, 404, declared: declared ?? 0, have: have); return
            }
            guard head.method == "POST" else {
                await fail(conn, 405, declared: declared ?? 0, have: have, extra: ["Allow": "POST"]); return
            }
            if head.headers["transfer-encoding"] != nil {
                await fail(conn, 411, declared: 0); return
            }
            guard let length = declared else {
                await fail(conn, 411, declared: 0); return
            }
            let connectionHeader = head.headers["connection"]?.lowercased()
            let keepAlive = head.http11 ? connectionHeader != "close" : connectionHeader == "keep-alive"
            if length > Self.maxBodyBytes {
                guard let hookEvent else { await fail(conn, 413, declared: length, have: have); return }
                // A hook never fails the CLI: discard the body within the drain limits and answer `{}`.
                noteHookProblem(hookEvent, "its body was over \(Self.maxBodyBytes / 1024 / 1024) MB", caller: caller)
                var drained = false
                if length <= Self.maxDrainBytes {
                    if have < length, head.headers["expect"]?.lowercased() == "100-continue" {
                        await send(conn, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
                    }
                    drained = await discard(conn, buffer: &buffer, from: bodyStart, length: length)
                }
                await send(conn, Self.response(200, body: HookReply.empty, close: !(drained && keepAlive)))
                if !(drained && keepAlive) { return }
                continue
            }

            // Read the body.
            if have < length, head.headers["expect"]?.lowercased() == "100-continue" {
                await send(conn, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
            while buffer.count - bodyStart < length {
                guard await readMore(conn, &buffer, &started) else { return }
            }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
            buffer = buffer.subdata(in: (bodyStart + length)..<buffer.count)

            // Hooks never fail the CLI: every outcome after auth is 200 with a JSON object.
            if let hookEvent {
                let out = await answerHook(hookEvent, body: body, caller: caller)
                await send(conn, Self.response(200, body: out, close: !keepAlive))
                if !keepAlive { return }
                continue
            }

            // Dispatch.
            let message = JSONValue.parse(body)
            let version = head.headers["mcp-protocol-version"] ?? MCPServer.defaultVersion
            // `server/discover` is a newer-spec probe the CLI sends first; answer it with -32601 so it falls back.
            let isDiscover = message?["method"]?.stringValue == "server/discover"
            if !isDiscover, !MCPServer.supportedVersions.contains(version) {
                await fail(conn, 400, declared: 0); return
            }
            let reply = await MCPServer.handle(message, tools: tools, caller: caller)
            switch reply {
            case .accepted:
                await send(conn, Self.response(202, body: nil, close: !keepAlive))
            case .json(let data):
                await send(conn, Self.response(200, body: data, close: !keepAlive))
            }
            if !keepAlive { return }
        }
    }

    /// Reports a hook problem once per session; the session proceeds without coordination.
    private func noteHookProblem(_ event: HookEvent, _ what: String, caller: MCPCaller) {
        if hookProblemReported.insert(caller.sessionID).inserted {
            report?("A \(event.rawValue) hook was ignored because \(what); the session proceeds without coordination.")
        }
    }

    /// Reads and drops `length` body bytes (some may already be buffered) within the request and drain deadlines.
    /// True when the whole body was consumed; `buffer` then holds only bytes after it.
    private func discard(_ conn: NWConnection, buffer: inout Data, from bodyStart: Int, length: Int) async -> Bool {
        var remaining = length - (buffer.count - bodyStart)
        if remaining <= 0 {
            buffer = buffer.subdata(in: (bodyStart + length)..<buffer.count)
            return true
        }
        buffer = Data()
        let started = ContinuousClock.now
        while remaining > 0 {
            let left = limits.requestDeadline - Self.seconds(started.duration(to: .now))
            guard left > 0, let chunk = await receive(conn, timeout: left) else { return false }
            if chunk.count > remaining {
                buffer = chunk.subdata(in: remaining..<chunk.count)
                remaining = 0
            } else {
                remaining -= chunk.count
            }
        }
        return true
    }

    /// Decodes the hook body, runs the handler against `limits.hookDeadline` and returns the reply body.
    private func answerHook(_ event: HookEvent, body: Data, caller: MCPCaller) async -> Data {
        guard let request = HookRequest(body: body), request.event == event else {
            noteHookProblem(event, "its body could not be read", caller: caller)
            return HookReply.empty
        }
        guard let handler = hookHandler else { return HookReply.empty }
        let reply = await Self.race(handler: { await handler(request, caller) }, deadline: limits.hookDeadline)
        return (reply ?? HookReply()).json(for: event)
    }

    /// The handler's reply, or nil when the deadline passes first. The handler is cancelled, not awaited.
    private static func race(handler: @escaping @Sendable () async -> HookReply, deadline: Duration) async -> HookReply? {
        await withCheckedContinuation { (cont: CheckedContinuation<HookReply?, Never>) in
            let gate = RaceGate(cont)
            let work = Task { gate.finish(await handler()) }
            let timer = Task {
                try? await Task.sleep(for: deadline, clock: ContinuousClock())
                gate.finish(nil)
            }
            gate.onFinish = { work.cancel(); timer.cancel() }
        }
    }

    /// Appends one read to `buffer`. A request's deadline runs from its first byte; before that the idle timeout applies.
    private func readMore(_ conn: NWConnection, _ buffer: inout Data, _ started: inout ContinuousClock.Instant?) async -> Bool {
        let timeout: TimeInterval
        if let started { timeout = limits.requestDeadline - Self.seconds(started.duration(to: .now)) } else { timeout = limits.idleTimeout }
        guard timeout > 0, let chunk = await receive(conn, timeout: timeout) else { return false }
        if started == nil { started = .now }
        buffer.append(chunk)
        return true
    }

    /// Sends an HTTP error, then waits (bounded by bytes and time) for the client to finish uploading so it can
    /// read the reply. The caller closes the connection afterwards.
    private func fail(_ conn: NWConnection, _ status: Int, declared: Int, have: Int = 0, extra: [String: String] = [:]) async {
        await send(conn, Self.response(status, body: nil, close: true, extra: extra))
        var remaining = min(declared, Self.maxDrainBytes) - have
        let started = ContinuousClock.now
        while remaining > 0 {
            let left = limits.drainDeadline - Self.seconds(started.duration(to: .now))
            guard left > 0, let chunk = await receive(conn, timeout: left) else { return }
            remaining -= chunk.count
        }
    }

    /// Wall-clock jumps and sleeps must not shorten or stretch a deadline, hence `ContinuousClock` above.
    private static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// One read; nil on EOF, error, or when `timeout` passes (the connection is then cancelled).
    private func receive(_ conn: NWConnection, timeout: TimeInterval) async -> Data? {
        let timer = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + max(timeout, 0), execute: timer)
        defer { timer.cancel() }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data, !data.isEmpty { cont.resume(returning: data) } else { cont.resume(returning: nil) }
            }
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    // MARK: HTTP helpers

    private static func parseHead(_ data: Data) -> Head? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2].hasPrefix("HTTP/1.") else { return nil }
        var head = Head()
        head.method = String(first[0])
        head.http11 = first[2] != "HTTP/1.0"
        let target = String(first[1])
        head.path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "host", head.headers["host"] != nil { return nil }
            if name == "content-length" {
                // Digits only: no sign, no whitespace; repeated headers must agree.
                guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(value) else { return nil }
                if let existing = head.contentLength, existing != n { return nil }
                head.contentLength = n
            }
            head.headers[name] = value
        }
        return head
    }

    private static func response(_ status: Int, body: Data?, close: Bool, extra: [String: String] = [:]) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += close ? "Connection: close\r\n" : "Connection: keep-alive\r\n"
        if status == 401 { head += "WWW-Authenticate: Bearer\r\n" }
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }
}

/// Resumes a continuation with the first outcome and runs a cleanup once.
private final class RaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<HookReply?, Never>?
    private var finished = false
    private var _onFinish: (@Sendable () -> Void)?
    init(_ cont: CheckedContinuation<HookReply?, Never>) { self.cont = cont }

    var onFinish: (@Sendable () -> Void)? {
        get { lock.withLock { _onFinish } }
        set {
            lock.lock()
            _onFinish = newValue
            let run = finished
            lock.unlock()
            if run { newValue?() }
        }
    }

    func finish(_ value: HookReply?) {
        lock.lock()
        guard let c = cont else { lock.unlock(); return }
        cont = nil
        finished = true
        let cleanup = _onFinish
        lock.unlock()
        c.resume(returning: value)
        cleanup?()
    }
}

/// Resumes a continuation at most once, from whichever listener state callback gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?
    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock(); defer { lock.unlock() }
        let c = cont
        cont = nil
        return c
    }
    /// True when this call resumed the continuation, false when an earlier call already had.
    func resume(returning value: T) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: value)
        return true
    }
    func resume(throwing error: Error) -> Bool {
        guard let c = take() else { return false }
        c.resume(throwing: error)
        return true
    }
}
