import AlloyCore
import AlloyLSPTestSupport
@testable import AlloyRPC
import Foundation
import Testing

/// A channel whose `send` never returns, so the writer queue only fills.
private final class StuckChannel: RPCByteChannel, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    init() { (incoming, inbox) = AsyncStream.makeStream() }
    func send(_ data: Data) async throws { try await Task.sleep(for: .seconds(3600)) }
    func close() async { inbox.finish() }
    func feed(_ data: Data) { inbox.yield(data) }
}

/// Records what was sent.
private final class RecordingChannel: RPCByteChannel, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var sent = Data()
    init() { (incoming, inbox) = AsyncStream.makeStream() }
    func send(_ data: Data) async throws { lock.withLock { sent.append(data) } }
    func close() async { inbox.finish() }
    func feed(_ data: Data) { inbox.yield(data) }
    var written: Data { lock.withLock { sent } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ e: String) { lock.withLock { events.append(e) } }
    var all: [String] { lock.withLock { events } }
}

@Suite struct ConnectionOptionsTests {
    @Test func failPolicyThrowsQueueFull() async throws {
        let conn = JSONRPCConnection(channel: StuckChannel(), maxQueuedMessages: 2, overflow: .fail)
        await conn.start()
        try await conn.notify("a", nil)
        try await conn.notify("b", nil)
        await #expect(throws: JSONRPCError.queueFull) { try await conn.notify("c", nil) }
        // No close(): it would wait for the writer, which is stuck by design.
    }

    @Test func waitPolicyStillWaits() async throws {
        let conn = JSONRPCConnection(channel: StuckChannel(), maxQueuedMessages: 2, overflow: .wait)
        await conn.start()
        try await conn.notify("a", nil)
        try await conn.notify("b", nil)
        let third = Task { try await conn.notify("c", nil) }
        let finished = Counter()
        let watcher = Task { _ = await third.result; finished.add("done") }
        try await Task.sleep(for: .milliseconds(200))
        #expect(finished.all.isEmpty)
        third.cancel()
        _ = await watcher.value
    }

    @Test func encodedNotifyWritesTheSameFrame() async throws {
        let channel = RecordingChannel()
        let conn = JSONRPCConnection(channel: channel)
        await conn.start()
        let body = Data(#"{"jsonrpc":"2.0","method":"x","params":{}}"#.utf8)
        try await conn.notify(encodedBody: body)
        let expected = RPCFrame.encode(body)
        #expect(await waitUntil { channel.written == expected })
        await conn.close()
    }

    @Test func inboundGateRunsBeforeEachDispatch() async throws {
        let channel = RecordingChannel()
        let conn = JSONRPCConnection(channel: channel)
        let log = Counter()
        await conn.setInboundGate { log.add("gate") }
        await conn.onNotification { method, _ in log.add("handler:\(method)") }
        await conn.start()
        for name in ["a", "b", "c"] {
            channel.feed(RPCFrame.encode(Data(#"{"jsonrpc":"2.0","method":"\#(name)"}"#.utf8)))
        }
        #expect(await waitUntil { log.all.count == 6 })
        #expect(log.all == ["gate", "handler:a", "gate", "handler:b", "gate", "handler:c"])
        await conn.close()
    }
}
