import AlloyCore
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyACP

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ProcessEvent] = []
    private var done = false
    var events: [ProcessEvent] { lock.withLock { items } }
    var isDone: Bool { lock.withLock { done } }
    var messages: [InboundMessage] { events.compactMap { if case .message(let m) = $0 { m } else { nil } } }
    func add(_ e: ProcessEvent) { lock.withLock { items.append(e) } }
    func finish() { lock.withLock { done = true } }
    var exit: (status: Int32, tail: String)? {
        for e in events { if case .exited(let s, let t) = e { return (s, t) } }
        return nil
    }
    /// All streamed text, coalesced.
    var text: String {
        messages.compactMap { if case .delta(.text(_, let s)) = $0 { s } else { nil } }.joined()
    }
}

private let initReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true}},"authMethods":[]}}}"#
private let newReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"sessionId":"s1","models":{"currentModelId":"m1","availableModels":[{"modelId":"m1","name":"Model One"}]},"modes":{"currentModeId":"build","availableModes":[{"id":"build","name":"Build"},{"id":"plan","name":"Plan"}]}}}}"#
private let handshake = [#"{"expect":"initialize"}"#, initReply, #"{"expect":"session/new"}"#, newReply]

private func update(_ body: String) -> String {
    #"{"send":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":"# + body + "}}}"
}
private let promptDone = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"end_turn","usage":{"inputTokens":7,"outputTokens":9}}}}"#

@Suite struct TransportTests {
    private func make(_ s: Scratch, _ steps: [String], clock: any AutosaveClock = SystemAutosaveClock(),
                      watchdog: Double = ACPTransport.defaultWatchdog, log: String? = nil)
        -> (ACPTransport, ScriptPaths) {
        var env = ["FAKE_ACP_SCRIPT": s.script(steps)]
        if let log { env["FAKE_ACP_LOG"] = log }
        let def = AgentDefinition(id: "fake", name: "Fake", command: fakeAgentPath)
        let config = ACPLaunchConfiguration(agent: def, executable: URL(fileURLWithPath: fakeAgentPath), arguments: [],
                                            projectDirectory: s.url, sessionID: UUID(), env: env)
        return (ACPTransport(configuration: config, clock: clock, watchdog: watchdog), ScriptPaths())
    }
    struct ScriptPaths {}

    private func run(_ t: ACPTransport) async throws -> Collected {
        let stream = try await t.start()
        let c = Collected()
        Task { for await e in stream { c.add(e) }; c.finish() }
        return c
    }

    private func user(_ text: String) -> OutboundMessage { .user(text: text, uuid: UUID(), priority: nil) }

    @Test func handshakeSynthesizesSystemInit() async throws {
        let s = Scratch()
        let (t, _) = make(s, handshake + [#"{"sleep":3000}"#])
        let c = try await run(t)
        #expect(await waitUntil { c.messages.contains { if case .systemInit = $0 { true } else { false } } })
        guard case .systemInit(let i)? = c.messages.first(where: { if case .systemInit = $0 { true } else { false } }) else { return }
        #expect(i.sessionID == "s1" && i.model == "m1" && i.permissionMode == "build")
        #expect(await waitUntil { c.messages.contains { $0 == .agentState(.modes(current: "build", available: [AgentChoice(id: "build", name: "Build"), AgentChoice(id: "plan", name: "Plan")])) } })
        await t.stopAndWait(timeout: .seconds(3))
        #expect(await waitUntil { c.exit != nil })
    }

    @Test func promptStreamsAndEndsWithResult() async throws {
        let s = Scratch()
        let log = s.url.appendingPathComponent("log.txt").path
        let (t, _) = make(s, handshake + [
            #"{"expect":"session/prompt"}"#,
            update(#"{"sessionUpdate":"agent_message_chunk","messageId":"a","content":{"type":"text","text":"Hel"}}"#),
            update(#"{"sessionUpdate":"agent_message_chunk","messageId":"a","content":{"type":"text","text":"lo"}}"#),
            promptDone, #"{"sleep":3000}"#,
        ], log: log)
        let c = try await run(t)
        let id = UUID()
        try await t.send(.user(text: "hi", uuid: id, priority: nil))
        #expect(await waitUntil { c.messages.contains { if case .result = $0 { true } else { false } } })
        #expect(c.text == "Hello")
        let echo = c.messages.first { if case .userEcho = $0 { true } else { false } }
        #expect(echo == .userEcho(text: "hi", imageCount: 0, uuid: id.uuidString.lowercased(), isReplay: false))
        // The echo comes before anything the agent said; the result is last.
        let kinds = c.messages.map { m -> String in
            switch m { case .userEcho: "echo"; case .delta: "delta"; case .result: "result"; default: "other" }
        }.filter { $0 != "other" }
        #expect(kinds.first == "echo" && kinds.last == "result", "\(kinds)")
        if case .result(let r)? = c.messages.last(where: { if case .result = $0 { true } else { false } }) {
            #expect(r.inputTokens == 7 && r.outputTokens == 9)
        }
        let sent = try String(contentsOfFile: log, encoding: .utf8)
        #expect(sent.contains(#""protocolVersion":1"#))
        #expect(sent.contains(#""method":"session\/prompt""#) && sent.contains(#""sessionId":"s1""#))
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func permissionRoundTripReturnsChosenOptionId() async throws {
        for (allow, expected) in [(true, "yes"), (false, "no")] {
            let s = Scratch()
            let log = s.url.appendingPathComponent("log.txt").path
            let (t, _) = make(s, handshake + [
                #"{"expect":"session/prompt"}"#,
                #"{"send":{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit a.txt","kind":"edit","status":"pending"},"options":[{"optionId":"yes","name":"Yes","kind":"allow_once"},{"optionId":"always","name":"Always","kind":"allow_always"},{"optionId":"no","name":"No","kind":"reject_once"}]}}}"#,
                #"{"expectResponse":0}"#,
                promptDone, #"{"sleep":3000}"#,
            ], log: log)
            let c = try await run(t)
            try await t.send(user("go"))
            #expect(await waitUntil { c.messages.contains { if case .controlRequest = $0 { true } else { false } } })
            guard case .controlRequest(let req)? = c.messages.first(where: { if case .controlRequest = $0 { true } else { false } }),
                  case .canUseTool(let name, _, _, let toolID, let suggestions) = req.kind else { Issue.record("no request"); return }
            #expect(name == "Edit a.txt" && toolID == "t1" && suggestions.count == 3)
            // The tool the request names was announced first.
            #expect(c.messages.contains { if case .assistantBlock(_, .toolUse("t1", _, _, _)) = $0 { true } else { false } })
            try await t.send(allow ? .allow(requestID: req.requestID, updatedInput: .null)
                                   : .deny(requestID: req.requestID, message: "no"))
            #expect(await waitUntil { c.messages.contains { if case .result = $0 { true } else { false } } })
            let sent = try String(contentsOfFile: log, encoding: .utf8)
            #expect(sent.contains(#""optionId":"\#(expected)""#))
            await t.stopAndWait(timeout: .seconds(3))
        }
    }

    @Test func chosenOptionFromTheCardWins() async throws {
        let s = Scratch()
        let log = s.url.appendingPathComponent("log.txt").path
        let (t, _) = make(s, handshake + [
            #"{"expect":"session/prompt"}"#,
            #"{"send":{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"Edit"},"options":[{"optionId":"yes","kind":"allow_once"},{"optionId":"always","kind":"allow_always"}]}}}"#,
            #"{"expectResponse":0}"#, promptDone, #"{"sleep":3000}"#,
        ], log: log)
        let c = try await run(t)
        try await t.send(user("go"))
        #expect(await waitUntil { c.messages.contains { if case .controlRequest = $0 { true } else { false } } })
        guard case .controlRequest(let req)? = c.messages.first(where: { if case .controlRequest = $0 { true } else { false } }) else { return }
        try await t.send(.allow(requestID: req.requestID, updatedInput: .null,
                                updatedPermissions: [.object(["optionId": .string("always")])]))
        #expect(await waitUntil { c.messages.contains { if case .result = $0 { true } else { false } } })
        #expect(try String(contentsOfFile: log, encoding: .utf8).contains(#""optionId":"always""#))
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func cancelAnswersPendingPermissionsCancelledAndLateUpdatesStillApply() async throws {
        let s = Scratch()
        let log = s.url.appendingPathComponent("log.txt").path
        let (t, _) = make(s, handshake + [
            #"{"expect":"session/prompt"}"#,
            update(#"{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Run tests","kind":"execute","status":"in_progress"}"#),
            #"{"send":{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1"},"options":[{"optionId":"yes","kind":"allow_once"}]}}}"#,
            #"{"expect":"session/cancel"}"#,
            #"{"expectResponse":0}"#,
            // A request after Stop, and a late completion of the tool.
            #"{"send":{"jsonrpc":"2.0","id":1,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t2","title":"Other"},"options":[{"optionId":"yes","kind":"allow_once"}]}}}"#,
            #"{"expectResponse":1}"#,
            update(#"{"sessionUpdate":"tool_call_update","toolCallId":"t1","status":"completed"}"#),
            #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"stopReason":"cancelled"}}}"#,
            #"{"sleep":3000}"#,
        ], log: log)
        let c = try await run(t)
        try await t.send(user("go"))
        #expect(await waitUntil { c.messages.contains { if case .controlRequest = $0 { true } else { false } } })
        try await t.send(.control(requestID: "x", .interrupt))
        #expect(await waitUntil { c.messages.contains { if case .result = $0 { true } else { false } } })
        let msgs = c.messages
        #expect(msgs.contains { if case .controlCancel = $0 { true } else { false } })
        let requests = msgs.filter { if case .controlRequest = $0 { true } else { false } }
        #expect(requests.count == 1)   // the request after Stop never got a card
        #expect(msgs.contains { if case .toolResult(let r) = $0 { r.toolUseID == "t1" } else { false } })
        if case .result(let r)? = msgs.last(where: { if case .result = $0 { true } else { false } }) {
            #expect(r.terminalReason == "aborted_streaming")
        }
        let sent = try String(contentsOfFile: log, encoding: .utf8)
        #expect(sent.components(separatedBy: #""outcome":"cancelled""#).count - 1 == 2)
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func crashYieldsExitedWithStderrTail() async throws {
        let s = Scratch()
        let (t, _) = make(s, [#"{"expect":"initialize"}"#, #"{"stderr":"it broke badly"}"#, #"{"exit":3}"#])
        let c = try await run(t)
        #expect(await waitUntil { c.isDone })
        #expect(c.exit?.status == 3)
        #expect(c.exit?.tail.contains("it broke badly") == true)
        #expect(c.events.count >= 1)
        if case .exited? = c.events.last {} else { Issue.record("exit is not last") }
    }

    @Test func closingStdoutMidTurnEndsInAnExit() async throws {
        let s = Scratch()
        let (t, _) = make(s, handshake + [#"{"expect":"session/prompt"}"#, #"{"closeStdout":true}"#, #"{"hang":true}"#])
        let c = try await run(t)
        try await t.send(user("go"))
        #expect(await waitUntil(.seconds(15)) { c.isDone })
        #expect(c.exit != nil)
    }

    @Test func strayLinesAndHugeLinesSurvive() async throws {
        let s = Scratch()
        let (t, _) = make(s, [#"{"expect":"initialize"}"#, #"{"stray":"npm warn something"}"#, initReply,
                              #"{"expect":"session/new"}"#, #"{"bigline":3000000}"#, #"{"stray":"{not json"}"#, newReply,
                              #"{"expect":"session/prompt"}"#,
                              update(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fine"}}"#),
                              promptDone, #"{"sleep":3000}"#])
        let c = try await run(t)
        try await t.send(user("go"))
        #expect(await waitUntil(.seconds(20)) { c.messages.contains { if case .result = $0 { true } else { false } } })
        #expect(c.text == "fine")
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func watchdogFiresAfterTenMinutesWithManualClock() async throws {
        let s = Scratch()
        let clock = ManualClock()
        let (t, _) = make(s, handshake + [#"{"expect":"session/prompt"}"#, #"{"hang":true}"#], clock: clock)
        let c = try await run(t)
        try await t.send(user("go"))
        #expect(await waitUntil { clock.pendingSleepers >= 1 })
        clock.advance(by: 599)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!c.messages.contains { if case .result = $0 { true } else { false } })
        clock.advance(by: 2)
        #expect(await waitUntil { c.messages.contains { if case .result = $0 { true } else { false } } })
        #expect(c.messages.contains { if case .notice(.error, let text) = $0 { text.contains("stopped responding") } else { false } })
        await t.stopAndWait(timeout: .seconds(3))
    }

    @Test func quitKillsAgentWithinStopAndWaitBudget() async throws {
        let s = Scratch()
        let (t, _) = make(s, handshake + [#"{"ignoreSignals":true}"#, #"{"hang":true}"#])
        let c = try await run(t)
        #expect(await waitUntil { c.messages.contains { if case .systemInit = $0 { true } else { false } } })
        let start = ContinuousClock.now
        await t.stopAndWait(timeout: .seconds(3))
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(await waitUntil { c.exit != nil })
    }
}
