import AlloyCore
import AlloyLSPTestSupport
import Foundation
import Testing
@testable import AlloyLSP

/// One end of an in-memory pipe. Bytes sent here come out of the peer's `incoming`.
final class PairChannel: LSPByteChannel, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    nonisolated(unsafe) private var peer: PairChannel?

    init() { (incoming, inbox) = AsyncStream.makeStream() }

    static func pair() -> (PairChannel, PairChannel) {
        let a = PairChannel(), b = PairChannel()
        a.peer = b; b.peer = a
        return (a, b)
    }

    func send(_ data: Data) async throws { peer?.inbox.yield(data) }
    func close() async { inbox.finish(); peer?.inbox.finish() }
}

/// A scripted fake server on the far end of a pair.
final class FakeServer: @unchecked Sendable {
    let channel: PairChannel
    private let lock = NSLock()
    private var decoder = LSPFrameDecoder()
    private var messages: [JSONValue] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var task: Task<Void, Never>?

    init(_ channel: PairChannel) {
        self.channel = channel
        task = Task { [self] in
            for await chunk in channel.incoming {
                let bodies = (try? decode(chunk)) ?? []
                for body in bodies { if let v = JSONValue.parse(body) { append(v) } }
            }
        }
    }

    private func decode(_ chunk: Data) throws -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return try decoder.append(chunk)
    }

    private func append(_ v: JSONValue) {
        lock.lock()
        messages.append(v)
        let ready = waiters.filter { messages.count >= $0.0 }
        waiters.removeAll { messages.count >= $0.0 }
        lock.unlock()
        for (_, c) in ready { c.resume() }
    }

    private func takeWaiters(_ n: Int) -> [CheckedContinuation<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        let ready = waiters.filter { $0.0 == n }.map(\.1)
        waiters.removeAll { $0.0 == n }
        return ready
    }

    /// Waits for `n` messages; records an issue (rather than hanging) after 5 s.
    func waitForMessages(_ n: Int) async {
        let watchdog = Task { [self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            Issue.record("timed out waiting for \(n) messages")
            for c in takeWaiters(n) { c.resume() }
        }
        await withCheckedContinuation { c in
            lock.lock()
            if messages.count >= n { lock.unlock(); c.resume() } else { waiters.append((n, c)); lock.unlock() }
        }
        watchdog.cancel()
    }

    var received: [JSONValue] { lock.lock(); defer { lock.unlock() }; return messages }

    func reply(_ json: String) async throws { try await channel.send(LSPFrame.encode(Data(json.utf8))) }
}

/// A channel whose `send` always throws and which reports `close()`.
final class FailingChannel: LSPByteChannel, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    let closed: AsyncStream<Void>
    private let closedCont: AsyncStream<Void>.Continuation
    struct SendFailure: Error {}

    init() {
        (incoming, inbox) = AsyncStream.makeStream()
        (closed, closedCont) = AsyncStream.makeStream()
    }

    func send(_ data: Data) async throws { throw SendFailure() }
    func close() async { inbox.finish(); closedCont.yield(); closedCont.finish() }
    func push(_ data: Data) { inbox.yield(data) }
}

/// A channel whose writes block until `open()`: a server that has stopped reading its stdin.
final class StalledChannel: LSPByteChannel, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var written = 0

    init() { (incoming, inbox) = AsyncStream.makeStream() }

    var writtenCount: Int { lock.withLock { written } }

    func send(_ data: Data) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume() } else { gate = c; lock.unlock() }
        }
        lock.withLock { written += 1 }
    }

    func open() {
        lock.lock()
        isOpen = true
        let g = gate
        gate = nil
        lock.unlock()
        g?.resume()
    }

    func close() async { open(); inbox.finish() }
}

@Suite struct JSONRPCConnectionTests {
    @Test func stalledWriterAppliesBackpressure() async throws {
        let channel = StalledChannel()
        let conn = JSONRPCConnection(channel: channel, maxQueuedBytes: 1 << 20, maxQueuedMessages: 4)
        await conn.start()
        let sender = Task {
            for i in 0..<100 { try await conn.notify("note", .object(["i": .number(Double(i))])) }
        }
        // The writer is stuck on the first message: four more queue up and the sender then waits.
        #expect(await waitUntil { await conn.queuedMessageCount >= 4 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await conn.queuedMessageCount <= 5)
        #expect(await conn.queuedByteCount < 4096)
        // A request waits for room as well, and gives up when its task is cancelled.
        let request = Task { try await conn.request("slow", nil) }
        try await Task.sleep(for: .milliseconds(100))
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        // Without a cancel it gives up after its own timeout.
        let impatient = Task { try await conn.request("slow", nil, timeout: .milliseconds(150)) }
        await #expect(throws: JSONRPCError.timedOut) { _ = try await impatient.value }
        // Once the server reads again, everything goes out and the sender finishes.
        channel.open()
        try await sender.value
        #expect(await waitUntil { await conn.queuedMessageCount == 0 })
        #expect(channel.writtenCount == 100)
        await conn.close()
    }

    @Test func closingReleasesBlockedSenders() async throws {
        let channel = StalledChannel()
        let conn = JSONRPCConnection(channel: channel, maxQueuedBytes: 1 << 20, maxQueuedMessages: 2)
        await conn.start()
        let sender = Task {
            for _ in 0..<50 { try await conn.notify("note", nil) }
        }
        #expect(await waitUntil { await conn.queuedMessageCount >= 2 })
        try await Task.sleep(for: .milliseconds(100))
        // `close` drains the writer, which is stuck until the "server" reads again; blocked senders are released at once.
        let closing = Task { await conn.close() }
        await #expect(throws: JSONRPCError.connectionClosed) { try await sender.value }
        channel.open()
        await closing.value
    }

    @Test func sendFailureClosesChannelAndFailsPending() async throws {
        let channel = FailingChannel()
        let conn = JSONRPCConnection(channel: channel)
        await conn.start()
        await #expect(throws: JSONRPCError.connectionClosed) { _ = try await conn.request("x", nil) }
        let closedCalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { var it = channel.closed.makeAsyncIterator(); return await it.next() != nil }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(closedCalled)
        #expect(await conn.closeReason?.hasPrefix("send failed") == true)
    }

    @Test func badHeaderClosesWithReason() async throws {
        let (client, server) = PairChannel.pair()
        let conn = JSONRPCConnection(channel: client)
        await conn.start()
        let task = Task { try await conn.request("hang", nil) }
        try await server.send(Data("Content-Type: x\r\n\r\n".utf8))
        await #expect(throws: JSONRPCError.connectionClosed) { try await task.value }
        #expect(await conn.closeReason != nil)
    }

    @Test func normalCloseHasNoReason() async {
        let (conn, _) = await make()
        await conn.close()
        #expect(await conn.closeReason == nil)
    }

    func make(timeout: Duration = .seconds(10)) async -> (JSONRPCConnection, FakeServer) {
        let (client, server) = PairChannel.pair()
        let conn = JSONRPCConnection(channel: client, requestTimeout: timeout)
        await conn.start()
        return (conn, FakeServer(server))
    }

    @Test func requestGetsMatchingResponse() async throws {
        let (conn, server) = await make()
        async let first = conn.request("a", nil)
        await server.waitForMessages(1)
        async let second = conn.request("b", .object(["x": .number(1)]))
        await server.waitForMessages(2)
        #expect(server.received[0]["id"]?.intValue == 1)
        #expect(server.received[1]["id"]?.intValue == 2)
        try await server.reply(#"{"jsonrpc":"2.0","id":2,"result":"two"}"#)
        try await server.reply(#"{"jsonrpc":"2.0","id":99,"result":"stray"}"#)
        try await server.reply(#"{"jsonrpc":"2.0","id":1,"result":"one"}"#)
        #expect(try await first == .string("one"))
        #expect(try await second == .string("two"))
        await conn.close()
    }

    @Test func errorResponseThrows() async throws {
        let (conn, server) = await make()
        let r = Task { try await conn.request("a", nil) }
        await server.waitForMessages(1)
        try await server.reply(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad"}}"#)
        await #expect(throws: JSONRPCError(code: -32602, message: "bad")) { try await r.value }
        await conn.close()
    }

    @Test func timeoutThrowsTimedOut() async throws {
        let (conn, _) = await make()
        await #expect(throws: JSONRPCError.timedOut) {
            _ = try await conn.request("slow", nil, timeout: .milliseconds(50))
        }
        await conn.close()
    }

    @Test func cancelSendsCancelRequest() async throws {
        let (conn, server) = await make()
        let task = Task { try await conn.request("slow", nil) }
        await server.waitForMessages(1)
        task.cancel()
        await server.waitForMessages(2)
        let m = server.received[1]
        #expect(m["method"]?.stringValue == "$/cancelRequest")
        #expect(m["params"]?["id"]?.intValue == 1)
        await #expect(throws: CancellationError.self) { try await task.value }
        await conn.close()
    }

    @Test func serverRequestWithoutHandlerGetsMethodNotFound() async throws {
        let (conn, server) = await make()
        try await server.reply(#"{"jsonrpc":"2.0","id":7,"method":"workspace/foo","params":{}}"#)
        await server.waitForMessages(1)
        let m = server.received[0]
        #expect(m["id"]?.intValue == 7)
        #expect(m["error"]?["code"]?.intValue == -32601)
        await conn.close()
    }

    @Test func serverRequestHandlerAndNotifications() async throws {
        let (conn, server) = await make()
        await conn.onRequest { method, _ in .success(.string("ok:\(method)")) }
        let (stream, cont) = AsyncStream<String>.makeStream()
        await conn.onNotification { method, _ in cont.yield(method) }
        try await server.reply(#"{"jsonrpc":"2.0","method":"window/logMessage","params":{}}"#)
        try await server.reply(#"{"jsonrpc":"2.0","id":"s","method":"ping"}"#)
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == "window/logMessage")
        await server.waitForMessages(1)
        #expect(server.received[0]["result"]?.stringValue == "ok:ping")
        #expect(server.received[0]["id"]?.stringValue == "s")
        await conn.close()
    }

    @Test func closeFailsPendingRequests() async throws {
        let (conn, server) = await make()
        let task = Task { try await conn.request("hang", nil) }
        await server.waitForMessages(1)
        await conn.close()
        await #expect(throws: JSONRPCError.connectionClosed) { try await task.value }
        await #expect(throws: JSONRPCError.connectionClosed) { try await conn.notify("x", nil) }
    }
}
