import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

/// What an open, idle, bursting, crashed or stuck agent costs the app. The per-frame request counts are guarded in
/// `ACPFrameGuardTests` (AlloyKitTests); here the transport side: idle means no events, bursts coalesce, quitting
/// never waits beyond the stop budget.
@Suite struct ACPMemoryAndIdleTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ProcessEvent] = []
        func add(_ e: ProcessEvent) { lock.withLock { items.append(e) } }
        var events: [ProcessEvent] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
        var messages: [InboundMessage] { events.compactMap { if case .message(let m) = $0 { m } else { nil } } }
        var exit: (status: Int32, tail: String)? {
            for e in events { if case .exited(let s, let t) = e { return (s, t) } }
            return nil
        }
    }

    private static let initReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}}"#
    private static let newReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"sessionId":"s1"}}}"#
    private static let handshake = [#"{"expect":"initialize"}"#, initReply, #"{"expect":"session/new"}"#, newReply]
    private static func chunk(_ text: String) -> String {
        #"{"send":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","messageId":"a","content":{"type":"text","text":""# + text + #""}}}}}"#
    }

    private func start(_ s: Scratch, _ steps: [String]) async throws -> (ACPTransport, Sink) {
        let def = AgentDefinition(id: "fake", name: "Fake", command: fakeAgentPath)
        let config = ACPLaunchConfiguration(agent: def, executable: URL(fileURLWithPath: fakeAgentPath), arguments: [],
                                            projectDirectory: s.url, sessionID: UUID(),
                                            env: ["FAKE_ACP_SCRIPT": s.script(steps)])
        let t = ACPTransport(configuration: config)
        let stream = try await t.start()
        let sink = Sink()
        Task { for await e in stream { sink.add(e) } }
        return (t, sink)
    }

    @Test func idleACPSessionWithOpenAgentCostsNoFrames() async throws {
        let s = Scratch()
        let (t, sink) = try await start(s, Self.handshake + [#"{"sleep":8000}"#])
        #expect(await waitUntil { sink.messages.contains { if case .systemInit = $0 { true } else { false } } })
        try await Task.sleep(for: .milliseconds(300))
        let settled = sink.count
        // An open agent with nothing to say produces no events at all, hence no frame is ever requested.
        try await Task.sleep(for: .seconds(1.5))
        #expect(sink.count == settled, "idle transport emitted \(sink.count - settled) event(s)")
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func agentOutputBurstCoalescesToOneTranscriptUpdatePerFrame() async throws {
        let s = Scratch()
        let n = 400
        let chunks = (0..<n).map { Self.chunk("w\($0) ") }
        let done = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"end_turn"}}}"#
        let (t, sink) = try await start(s, Self.handshake + [#"{"expect":"session/prompt"}"#] + chunks + [done, #"{"sleep":4000}"#])
        #expect(await waitUntil { sink.messages.contains { if case .systemInit = $0 { true } else { false } } })
        try await t.send(.user(content: [.text("go")], uuid: UUID(), priority: nil))
        #expect(await waitUntil(.seconds(15)) { sink.messages.contains { if case .result = $0 { true } else { false } } })
        let deltas = sink.messages.compactMap { m -> String? in if case .delta(.text(_, let x)) = m { x } else { nil } }
        #expect(deltas.joined() == (0..<n).map { "w\($0) " }.joined(), "no chunk may be lost")
        #expect(deltas.count <= n / 4, "\(n) chunks became \(deltas.count) transcript updates")
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func crashedAgentDoesNotBlockQuitBeyondStopAndWaitBudget() async throws {
        let s = Scratch()
        let (t, sink) = try await start(s, Self.handshake + [#"{"expect":"session/prompt"}"#, #"{"exit":7}"#])
        #expect(await waitUntil { sink.messages.contains { if case .systemInit = $0 { true } else { false } } })
        try await t.send(.user(content: [.text("go")], uuid: UUID(), priority: nil))
        #expect(await waitUntil { sink.exit != nil })
        let start = ContinuousClock.now
        await t.stopAndWait(timeout: .seconds(3))
        #expect(ContinuousClock.now - start < .seconds(1), "quit after a crash took \(ContinuousClock.now - start)")
        #expect(sink.exit?.status == 7)
    }

    @Test func stuckAgentKilledOnQuit() async throws {
        let s = Scratch()
        let (t, sink) = try await start(s, Self.handshake + [#"{"ignoreSignals":true}"#, #"{"expect":"session/prompt"}"#, #"{"hang":true}"#])
        #expect(await waitUntil { sink.messages.contains { if case .systemInit = $0 { true } else { false } } })
        try await t.send(.user(content: [.text("go")], uuid: UUID(), priority: nil))
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        await t.stopAndWait(timeout: .seconds(3))
        #expect(ContinuousClock.now - start < .seconds(5))
        // The agent ignored SIGINT and SIGTERM; only the kill ends it, and the exit is reported.
        #expect(await waitUntil { sink.exit != nil })
        #expect(sink.exit?.status != 0)
    }
}
