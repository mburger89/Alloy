import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@Suite struct QueueTests {
    @Test func midTurnMessageIsQueuedAndNoEchoUntilSent() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInitPlain, #"{"expect":"session/new"}"#, hsNew,
            #"{"expect":"session/prompt"}"#, #"{"sleep":700}"#, turnDone,
            #"{"expect":"session/prompt"}"#, turnDone, #"{"sleep":3000}"#,
        ])
        #expect(await waitUntil { r.events.hasSystemInit })
        let a = UUID(), b = UUID()
        try await r.transport.send(user("one", id: a))
        try await r.transport.send(user("two", id: b, priority: .later))
        try await Task.sleep(for: .milliseconds(300))
        // The second is held: no echo, no second prompt on the wire.
        #expect(r.events.echoes == ["one"])
        #expect(r.lines("session/prompt").count == 1)
        #expect(await waitUntil { r.events.results == 2 })
        #expect(r.events.echoes == ["two"] || r.events.echoes == ["one", "two"])
        #expect(r.events.echoes == ["one", "two"])
        #expect(r.lines("session/prompt").count == 2)
        // Each echo carries the id of the message actually sent.
        let ids = r.events.messages.compactMap { if case .userEcho(_, _, let u, _) = $0 { u } else { nil } }
        #expect(ids == [a.uuidString.lowercased(), b.uuidString.lowercased()])
        await r.stop()
    }

    @Test func sendNowCancelsThenPrompts() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInitPlain, #"{"expect":"session/new"}"#, hsNew,
            #"{"expect":"session/prompt"}"#,
            #"{"expect":"session/cancel"}"#,
            #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"cancelled"}}}"#,
            #"{"expect":"session/prompt"}"#, turnDone, #"{"sleep":3000}"#,
        ])
        #expect(await waitUntil { r.events.hasSystemInit })
        let a = UUID(), b = UUID(), c = UUID()
        try await r.transport.send(user("running", id: a))
        try await r.transport.send(user("later", id: b, priority: .later))
        try await r.transport.send(user("urgent", id: c, priority: .later))
        try await Task.sleep(for: .milliseconds(150))
        #expect(r.lines("session/cancel").isEmpty)
        // Send now on the third: the turn is cancelled and that message goes before the other queued one.
        try await r.transport.send(.user(content: [], uuid: c, priority: .now))
        #expect(await waitUntil { r.events.echoes.count >= 2 })
        #expect(Array(r.events.echoes.prefix(2)) == ["running", "urgent"])
        let log = r.logText.split(separator: "\n").map(String.init)
        let methods = log.compactMap { l -> String? in
            for m in ["session\\/prompt", "session\\/cancel"] where l.contains("\"method\":\"\(m)\"") { return m }
            return nil
        }
        #expect(Array(methods.prefix(3)) == ["session\\/prompt", "session\\/cancel", "session\\/prompt"])
        #expect(r.lines("session/prompt")[1].contains("urgent"))
        await r.stop()
    }

    @Test func stopDropsWhatWaited() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInitPlain, #"{"expect":"session/new"}"#, hsNew,
            #"{"expect":"session/prompt"}"#, #"{"expect":"session/cancel"}"#,
            #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"cancelled"}}}"#, #"{"sleep":1500}"#,
        ])
        #expect(await waitUntil { r.events.hasSystemInit })
        try await r.transport.send(user("running"))
        try await r.transport.send(user("waiting", priority: .later))
        try await r.transport.send(.control(requestID: "x", .interrupt))
        #expect(await waitUntil { r.events.results == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(r.events.echoes == ["running"])
        #expect(r.lines("session/prompt").count == 1)
        await r.stop()
    }

    @Test func crossSessionNoticesLeadNextPromptBlock() async throws {
        let counter = Counter()
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInitPlain, #"{"expect":"session/new"}"#, hsNew,
            #"{"expect":"session/prompt"}"#, turnDone,
            #"{"expect":"session/prompt"}"#, turnDone, #"{"sleep":3000}"#,
        ], configure: { c in
            c.leadingContext = { counter.next() == 1 ? nil : "OVERLAP-NOTICE" }
        })
        #expect(await waitUntil { r.events.hasSystemInit })
        try await r.transport.send(user("first"))
        #expect(await waitUntil { r.events.results == 1 })
        try await r.transport.send(user("second"))
        #expect(await waitUntil { r.events.results == 2 })
        let prompts = r.lines("session/prompt")
        #expect(!prompts[0].contains("OVERLAP-NOTICE"))
        let n = try #require(prompts[1].range(of: "OVERLAP-NOTICE")), s = try #require(prompts[1].range(of: "second"))
        #expect(n.lowerBound < s.lowerBound)
        #expect(r.events.echoes == ["first", "second"])
        await r.stop()
    }
}
