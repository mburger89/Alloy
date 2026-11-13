import AlloyCore
import Foundation

public protocol LSPByteChannel: Sendable {
    func send(_ data: Data) async throws
    var incoming: AsyncStream<Data> { get }
    func close() async
}

public struct JSONRPCError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let requestCancelled = -32800
    public static let methodNotFoundCode = -32601
    /// Local: the request got no response in time.
    public static let timedOut = JSONRPCError(code: -32001, message: "Request timed out")
    /// Local: the connection closed before a response arrived.
    public static let connectionClosed = JSONRPCError(code: -32099, message: "Connection closed")
}

public actor JSONRPCConnection {
    private struct Pending {
        var continuation: CheckedContinuation<JSONValue, Error>
        var timeoutTask: Task<Void, Never>
    }

    private let channel: any LSPByteChannel
    private let requestTimeout: Duration
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var notificationHandler: (@Sendable (String, JSONValue?) -> Void)?
    private var requestHandler: (@Sendable (String, JSONValue?) async -> Result<JSONValue, JSONRPCError>)?
    private var readTask: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private let outgoing: AsyncStream<Data>
    private let outgoingContinuation: AsyncStream<Data>.Continuation
    private var started = false
    private var closed = false

    /// Backpressure: bytes and messages handed to the writer but not yet written. While either is at its limit, `notify`
    /// and `request` wait (and so does the document sync's pump, which then coalesces what piles up behind it). A server
    /// that stops reading its stdin therefore cannot make this queue grow.
    private let maxQueuedBytes: Int
    private let maxQueuedMessages: Int
    private var queuedBytes = 0
    private var queuedMessages = 0
    private var roomWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(channel: any LSPByteChannel, requestTimeout: Duration = .seconds(10),
                maxQueuedBytes: Int = 1 << 20, maxQueuedMessages: Int = 256) {
        self.channel = channel
        self.requestTimeout = requestTimeout
        self.maxQueuedBytes = maxQueuedBytes
        self.maxQueuedMessages = maxQueuedMessages
        (outgoing, outgoingContinuation) = AsyncStream.makeStream()
    }

    public func start() {
        guard !started, !closed else { return }
        started = true
        let channel = channel
        let outgoing = outgoing
        writeTask = Task { [weak self] in
            for await data in outgoing {
                do { try await channel.send(data) } catch {
                    await self?.shutdown(reason: "send failed: \(error)", drainWriter: false)
                    return
                }
                await self?.written(data.count)
            }
        }
        let incoming = channel.incoming
        readTask = Task { [weak self] in
            var decoder = LSPFrameDecoder()
            for await chunk in incoming {
                do {
                    for body in try decoder.append(chunk) { await self?.handle(body) }
                } catch {
                    await self?.shutdown(reason: "framing error: \(error)", drainWriter: true)
                    return
                }
            }
            await self?.close()
        }
    }

    public func onNotification(_ handler: @escaping @Sendable (String, JSONValue?) -> Void) {
        notificationHandler = handler
    }

    public func onRequest(_ handler: @escaping @Sendable (String, JSONValue?) async -> Result<JSONValue, JSONRPCError>) {
        requestHandler = handler
    }

    public func request(_ method: String, _ params: JSONValue?, timeout: Duration? = nil) async throws -> JSONValue {
        if closed { throw JSONRPCError.connectionClosed }
        if Task.isCancelled { throw CancellationError() }
        // A request is as impatient as its own timeout: a server that has stopped reading cannot hold it up longer.
        try await waitForRoom(timeout: timeout ?? requestTimeout)
        if closed { throw JSONRPCError.connectionClosed }
        let id = nextID
        nextID += 1
        let limit = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(id: id)
                }
                pending[id] = Pending(continuation: continuation, timeoutTask: timeoutTask)
                enqueue(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params ?? .null],
                        omitNullParams: params == nil)
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// - Parameter urgent: skips the backpressure wait (for the `exit` of a server that may have stopped reading).
    public func notify(_ method: String, _ params: JSONValue?, urgent: Bool = false) async throws {
        if closed { throw JSONRPCError.connectionClosed }
        if !urgent { try await waitForRoom() }
        if closed { throw JSONRPCError.connectionClosed }
        enqueue(["jsonrpc": .string("2.0"), "method": .string(method), "params": params ?? .null], omitNullParams: params == nil)
    }

    /// Fails the pending request with `CancellationError` and tells the server to abandon it.
    public func cancel(id: Int) async {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeoutTask.cancel()
        enqueue(["jsonrpc": .string("2.0"), "method": .string("$/cancelRequest"), "params": .object(["id": .number(Double(id))])])
        entry.continuation.resume(throwing: CancellationError())
    }

    /// Why the connection closed on its own (framing error or send failure); nil after a normal close.
    public private(set) var closeReason: String?

    public func close() async {
        await shutdown(reason: nil, drainWriter: true)
    }

    private func shutdown(reason: String?, drainWriter: Bool) async {
        guard !closed else { return }
        closed = true
        closeReason = reason
        let all = pending
        pending = [:]
        for (_, entry) in all {
            entry.timeoutTask.cancel()
            entry.continuation.resume(throwing: JSONRPCError.connectionClosed)
        }
        outgoingContinuation.finish()
        let waiting = roomWaiters
        roomWaiters = []
        for waiter in waiting { waiter.continuation.resume(throwing: JSONRPCError.connectionClosed) }
        readTask?.cancel()
        // Let queued writes drain before the channel goes away.
        // The writer itself must not await its own task (a failed send shuts down from inside it).
        if drainWriter { await writeTask?.value }
        writeTask = nil
        await channel.close()
    }

    /// Test observability: what the writer has not written yet.
    var queuedByteCount: Int { queuedBytes }
    var queuedMessageCount: Int { queuedMessages }

    // MARK: - Internals

    private var hasRoom: Bool { queuedBytes < maxQueuedBytes && queuedMessages < maxQueuedMessages }

    /// Returns once the writer is below its limits; throws when the connection closes, the task is cancelled or `timeout`
    /// passes meanwhile.
    private func waitForRoom(timeout: Duration? = nil) async throws {
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
        while !hasRoom {
            if closed { throw JSONRPCError.connectionClosed }
            if let deadline, ContinuousClock.now >= deadline { throw JSONRPCError.timedOut }
            let id = UUID()
            let timer = deadline.map { deadline in
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    guard !Task.isCancelled else { return }
                    await self?.failRoomWaiter(id, JSONRPCError.timedOut)
                }
            }
            defer { timer?.cancel() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    roomWaiters.append((id, continuation))
                }
            } onCancel: {
                Task { await self.failRoomWaiter(id, CancellationError()) }
            }
        }
    }

    private func failRoomWaiter(_ id: UUID, _ error: any Error) {
        guard let index = roomWaiters.firstIndex(where: { $0.id == id }) else { return }
        roomWaiters.remove(at: index).continuation.resume(throwing: error)
    }

    /// The writer finished one message.
    private func written(_ count: Int) {
        queuedBytes -= count
        queuedMessages -= 1
        guard hasRoom, !roomWaiters.isEmpty else { return }
        let waiting = roomWaiters
        roomWaiters = []
        for waiter in waiting { waiter.continuation.resume() }
    }

    private func timeOut(id: Int) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        enqueue(["jsonrpc": .string("2.0"), "method": .string("$/cancelRequest"), "params": .object(["id": .number(Double(id))])])
        entry.continuation.resume(throwing: JSONRPCError.timedOut)
    }

    private func enqueue(_ message: [String: JSONValue], omitNullParams: Bool = false) {
        var message = message
        if omitNullParams { message["params"] = nil }
        guard let body = Self.encode(.object(message)) else { return }
        let frame = LSPFrame.encode(body)
        queuedBytes += frame.count
        queuedMessages += 1
        outgoingContinuation.yield(frame)
    }

    private static func encode(_ value: JSONValue) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return try? encoder.encode(value)
    }

    private func handle(_ body: Data) async {
        guard let message = JSONValue.parse(body), message.objectValue != nil else { return }
        let id = message["id"]
        if let method = message["method"]?.stringValue {
            let params = message["params"]
            if let id {
                guard let handler = requestHandler else {
                    reply(id: id, result: .failure(JSONRPCError(code: JSONRPCError.methodNotFoundCode, message: "Method not found: \(method)")))
                    return
                }
                Task { [weak self] in
                    let result = await handler(method, params)
                    await self?.reply(id: id, result: result)
                }
            } else {
                notificationHandler?(method, params)
            }
            return
        }
        guard let requestID = id?.intValue, let entry = pending.removeValue(forKey: requestID) else { return }
        entry.timeoutTask.cancel()
        if let error = message["error"], error.objectValue != nil {
            entry.continuation.resume(throwing: JSONRPCError(
                code: error["code"]?.intValue ?? -32603,
                message: error["message"]?.stringValue ?? "",
                data: error["data"]))
        } else {
            entry.continuation.resume(returning: message["result"] ?? .null)
        }
    }

    private func reply(id: JSONValue, result: Result<JSONValue, JSONRPCError>) {
        guard !closed else { return }
        var message: [String: JSONValue] = ["jsonrpc": .string("2.0"), "id": id]
        switch result {
        case .success(let value): message["result"] = value
        case .failure(let error):
            var e: [String: JSONValue] = ["code": .number(Double(error.code)), "message": .string(error.message)]
            if let data = error.data { e["data"] = data }
            message["error"] = .object(e)
        }
        enqueue(message)
    }
}
