import AlloyCore
import Foundation

public struct ACPError: Error, Equatable, CustomStringConvertible, Sendable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }

    /// ACP's "authentication required" error.
    public var isAuthRequired: Bool { code == -32000 }
    public var description: String { "ACP error \(code): \(message)" }

    /// Pending requests fail with this when the agent's stdout ends.
    public static let connectionClosed = ACPError(code: -32099, message: "The agent closed the connection.")
}

/// Something the agent sent that is not a response to one of our requests.
public enum ACPIncoming: Sendable, Equatable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
}

extension JSONValue {
    /// Decodes this tree into `T` (re-encoding through JSON; unknown keys are ignored by the models).
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        if T.self == JSONValue.self, let me = self as? T { return me }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

/// JSON-RPC 2.0 over newline-delimited messages: request/response correlation, notifications, agent-to-client
/// requests and `$/cancel_request`. One consumer reads `incoming`.
public actor ACPConnection {
    public nonisolated let incoming: AsyncStream<ACPIncoming>

    /// Outgoing messages in order; one writer task drains it so concurrent senders never reorder lines.
    private let outgoing: AsyncStream<Data>.Continuation
    private let onStray: @Sendable (String) -> Void
    private let incomingCont: AsyncStream<ACPIncoming>.Continuation
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false
    private var yielded = 0

    /// - Parameters:
    ///   - input: the agent's stdout chunks.
    ///   - output: writes one framed message to the agent's stdin.
    ///   - onStray: called with each non-JSON line (logged by the owner; the line is skipped).
    public init(input: AsyncStream<Data>,
                output: @escaping @Sendable (Data) async -> Void,
                onStray: @escaping @Sendable (String) -> Void = { _ in }) {
        let (out, outCont) = AsyncStream<Data>.makeStream()
        outgoing = outCont
        Task { for await data in out { await output(data) } }
        self.onStray = onStray
        (incoming, incomingCont) = AsyncStream<ACPIncoming>.makeStream()
        Task { [weak self] in
            var reader = ACPLineReader()
            for await chunk in input {
                for line in reader.feed(chunk) { await self?.handle(line) }
            }
            if let rest = reader.finish() { await self?.handle(rest) }
            await self?.inputEnded()
        }
    }

    deinit { outgoing.finish(); incomingCont.finish() }

    /// How many notifications and requests have been put on `incoming` so far. A consumer that has handled this many
    /// has seen everything that arrived before now (a response can overtake the updates before it in the consumer's task).
    public func incomingCount() -> Int { yielded }

    // MARK: sending

    /// Sends a request and awaits its result. `onID` receives the request id before it is sent (for `cancel`).
    public func request<R: Decodable>(_ method: String, _ params: some Encodable, as: R.Type = R.self,
                                      onID: (@Sendable (Int) -> Void)? = nil) async throws -> R {
        guard !closed else { throw ACPError.connectionClosed }
        let id = nextID
        nextID += 1
        onID?(id)
        let body = try Self.encode(Envelope(id: id, method: method, params: params))
        let result = try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
            pending[id] = c
            outgoing.yield(ACPFraming.encode(body))
        }
        return try result.decode(R.self)
    }

    public func notify(_ method: String, _ params: some Encodable) async {
        guard !closed, let body = try? Self.encode(Envelope(id: nil, method: method, params: params)) else { return }
        outgoing.yield(ACPFraming.encode(body))
    }

    /// Answers an agent-to-client request.
    public func respond(id: JSONValue, result: JSONValue) async {
        await send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    public func respondError(id: JSONValue, code: Int, message: String) async {
        await send(.object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }

    /// Tells the agent to abandon request `requestID` (`$/cancel_request`). The request still completes when the
    /// agent answers it.
    public func cancel(requestID: Int) async {
        await notify("$/cancel_request", ["requestId": requestID])
    }

    private func send(_ value: JSONValue) async {
        guard !closed, let body = try? JSONEncoder().encode(value) else { return }
        outgoing.yield(ACPFraming.encode(body))
    }

    private struct Envelope<P: Encodable>: Encodable {
        var jsonrpc = "2.0"
        var id: Int?
        var method: String
        var params: P
    }

    private static func encode(_ e: some Encodable) throws -> Data { try JSONEncoder().encode(e) }

    // MARK: receiving

    private func handle(_ line: Data) {
        guard let value = JSONValue.parse(line), case .object(let obj) = value else {
            onStray(String(decoding: line.prefix(512), as: UTF8.self))
            return
        }
        if let method = obj["method"]?.stringValue {
            let params = obj["params"] ?? .null
            if let id = obj["id"], id != .null {
                yielded += 1
                incomingCont.yield(.request(id: id, method: method, params: params))
            } else {
                yielded += 1
                incomingCont.yield(.notification(method: method, params: params))
            }
            return
        }
        guard let id = obj["id"]?.intValue, let waiter = pending.removeValue(forKey: id) else {
            onStray(String(decoding: line.prefix(512), as: UTF8.self))
            return
        }
        if case .object(let err)? = obj["error"] {
            waiter.resume(throwing: ACPError(code: err["code"]?.intValue ?? -32603,
                                             message: err["message"]?.stringValue ?? "Unknown error"))
        } else {
            waiter.resume(returning: obj["result"] ?? .null)
        }
    }

    private func inputEnded() {
        closed = true
        let waiters = pending
        pending = [:]
        for (_, w) in waiters { w.resume(throwing: ACPError.connectionClosed) }
        outgoing.finish()
        incomingCont.finish()
    }
}
