@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class Bag: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScriptedTransport] = []
    var list: [ScriptedTransport] { lock.withLock { all } }
    var factory: TransportFactory {
        { [self] _ in let t = ScriptedTransport(); lock.withLock { all.append(t) }; return t }
    }
    var acpFactory: ACPTransportFactory {
        { [self] _ in let t = ScriptedTransport(); lock.withLock { all.append(t) }; return t }
    }
}

@MainActor
private final class Events {
    var list: [SessionPluginEvent] = []
}

@MainActor
@Suite struct PluginHookForwardTests {
    private struct Env {
        let ws: Workspace
        let root: URL
        let bag: Bag
        let events: Events
    }

    private func env() -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-hookfwd-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bag = Bag()
        let agent = AgentDefinition(id: "gemini", name: "Gemini", command: "/abs/gemini", args: ["acp"])
        let ws = Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: bag.factory,
                           makeACPTransport: bag.acpFactory, agentDefinitions: { [agent] },
                           agentDetector: AgentDetector(resolve: { _ in [:] }, isExecutable: { _ in true }, home: "/nohome",
                                                        helpRunner: { _ in nil }))
        let events = Events()
        ws.onSessionEvent = { events.list.append($0) }
        return Env(ws: ws, root: root, bag: bag, events: events)
    }

    private func hook(_ e: Env, _ event: HookEvent, session: Session, tool: String = "Edit", file: String = "login.swift") async -> HookReply {
        let input: JSONValue = .object(["file_path": .string(e.root.appendingPathComponent(file).path),
                                        "old_string": .string("a"), "new_string": .string("b")])
        let req = HookRequest(event: event, toolName: tool, toolUseID: "t1", toolInput: input, cliSessionID: "cli")
        return await e.ws.answerHook(req, MCPCaller(sessionID: session.id))
    }

    private func result(isError: Bool = false) -> InboundMessage {
        .result(TurnResult(subtype: "success", isError: isError, costUSD: 0, inputTokens: 1, outputTokens: 1,
                           sessionID: "x", terminalReason: nil))
    }

    @Test func postToolUseFiresToolUsedAfterOverlapHandler() async {
        let e = env()
        let s = await e.ws.newSession(name: "Ada")
        let pre = await hook(e, .preToolUse, session: s)
        #expect(e.events.list.isEmpty)
        let reply = await hook(e, .postToolUse, session: s)
        #expect(reply == HookReply() && pre == HookReply())
        #expect(e.events.list == [.toolUsed(sessionID: s.id, toolName: "Edit", paths: ["login.swift"])])
    }

    @Test func preToolUseFiresNothing() async {
        let e = env()
        let s = await e.ws.newSession(name: "Ada")
        _ = await hook(e, .preToolUse, session: s)
        #expect(e.events.list.isEmpty)
    }

    @Test func slowSubscriberDoesNotDelayHookReply() async {
        let e = env()
        let s = await e.ws.newSession(name: "Ada")
        var sleepers: [Task<Void, Never>] = []
        e.ws.onSessionEvent = { _ in sleepers.append(Task { try? await Task.sleep(for: .seconds(3)) }) }
        let started = ContinuousClock.now
        _ = await hook(e, .postToolUse, session: s)
        #expect(started.duration(to: .now) < LocalServer.Limits().hookDeadline)
        #expect(sleepers.count == 1)
        for t in sleepers { t.cancel() }
    }

    @Test func resultFiresTurnEndedForClaudeAndACP() async {
        let e = env()
        let claude = await e.ws.newSession(name: "Ada")
        let acp = await e.ws.newSession(name: "Bea", backend: .acp(agentID: "gemini"))
        await e.bag.list[0].emit(result(isError: true))
        await waitUntil("claude result") { e.events.list.count == 1 }
        await e.bag.list[1].emit(result())
        await waitUntil("acp result") { e.events.list.count == 2 }
        #expect(e.events.list == [.turnEnded(sessionID: claude.id, isError: true, agent: "claude"),
                                  .turnEnded(sessionID: acp.id, isError: false, agent: "gemini")])
    }

    @Test func stopFiresEndedOnce() async {
        let e = env()
        let s = await e.ws.newSession(name: "Ada")
        await e.ws.stop(s.id)
        await e.bag.list[0].exit(status: 0, stderr: "")
        for _ in 0..<200 { await Task.yield() }
        #expect(e.events.list == [.ended(sessionID: s.id, agent: "claude")])
    }
}
