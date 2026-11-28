@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class WRig: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [ScriptedTransport] = []
    private var _configs: [ACPLaunchConfiguration] = []
    var transports: [ScriptedTransport] { lock.withLock { _transports } }
    var configs: [ACPLaunchConfiguration] { lock.withLock { _configs } }
    var factory: ACPTransportFactory {
        { [self] c in let t = ScriptedTransport(); lock.withLock { _transports.append(t); _configs.append(c) }; return t }
    }
}

private let agent = AgentDefinition(id: "fake", name: "Fake", command: "/abs/fake-agent", args: ["acp"],
                                    secretNames: ["FAKE_API_KEY"])

/// Two workspaces over one project and one data directory stand for a quit and a relaunch.
@MainActor
private final class WEnv {
    let base: URL, project: URL, support: URL
    let secrets = InMemorySecretStore()
    init() {
        base = TempFiles.url("alloy-acpw")
        project = base.appendingPathComponent("p"); support = base.appendingPathComponent("s")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func workspace(_ rig: WRig, settings: AlloySettings = AlloySettings(), clock: any AutosaveClock = SystemAutosaveClock()) -> Workspace {
        Workspace(projectRoot: project.resolvingSymlinksInPath(), appSupport: support, settings: settings,
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                  makeTransport: { _ in ScriptedTransport() }, makeACPTransport: rig.factory,
                  agentDefinitions: { [agent] }, agentSecrets: secrets,
                  agentDetector: AgentDetector(resolve: { _ in [:] }, isExecutable: { _ in true }, home: "/nohome",
                                               helpRunner: { _ in nil }),
                  now: Date.init, home: base.appendingPathComponent("home"), autosaveClock: clock,
                  changes: { _ in ScriptedChangeSource() })
    }

    /// An ACP session that is up and idle on the rig's latest transport.
    func start(_ ws: Workspace, _ rig: WRig, id: String = "ses_1") async -> (Session, ScriptedTransport) {
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        let t = rig.transports[rig.transports.count - 1]
        await t.emit(.systemInit(SystemInit(model: "", permissionMode: "", sessionID: id, tools: [], slashCommands: [])))
        await waitUntil("idle") { s.status == .idle }
        return (s, t)
    }
}

private func msg(_ text: String, _ id: UUID) -> OutgoingMessage {
    var m = OutgoingMessage(text: text, images: [], priority: nil)
    m.uuid = id
    return m
}

@MainActor @Suite struct ACPWorkspaceTests {
    private func echo(_ t: ScriptedTransport, _ text: String, _ id: UUID) async {
        await t.emit(.userEcho(text: text, imageCount: 0, uuid: id.uuidString.lowercased(), isReplay: false))
    }

    // MARK: slow start

    private func stillStarting(_ s: Session) -> Bool {
        s.transcript.blocks.contains { if case .notice(_, _, let text) = $0 { text.contains("still starting") } else { false } }
    }

    /// An agent's first launch can take minutes (OpenCode sets itself up): after ten seconds the session says so, once,
    /// from one timer on the injected clock.
    @Test func slowStartIsSaidAfterTenSeconds() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig(), clock = ManualClock()
        let ws = env.workspace(rig, clock: clock)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        #expect(s.status == .starting)
        await waitUntil("timer") { clock.pendingSleepers == 1 }
        clock.advance(by: 9)
        for _ in 0..<50 { await Task.yield() }
        #expect(!stillStarting(s))
        clock.advance(by: 1)
        await waitUntil("notice") { self.stillStarting(s) }
        let text = s.transcript.blocks.compactMap { b -> String? in
            if case .notice(_, _, let t) = b, t.contains("still starting") { t } else { nil }
        }
        #expect(text == ["Fake is still starting \u{2014} the first launch can take a few minutes."])
        #expect(clock.pendingSleepers == 0)
    }

    /// Once the agent has started, the notice goes: it only said what was going on at that moment.
    @Test func slowStartNoticeIsRemovedWhenTheAgentStarts() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig(), clock = ManualClock()
        let ws = env.workspace(rig, clock: clock)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        await waitUntil("timer") { clock.pendingSleepers == 1 }
        clock.advance(by: 10)
        await waitUntil("notice") { self.stillStarting(s) }
        s.status = .idle
        #expect(!stillStarting(s))
    }

    @Test func fastStartSaysNothing() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig(), clock = ManualClock()
        let ws = env.workspace(rig, clock: clock)
        let (s, _) = await env.start(ws, rig)
        clock.advance(by: 60)
        for _ in 0..<50 { await Task.yield() }
        #expect(!stillStarting(s))
    }

    // MARK: history and restore

    @Test func historyAppendsAndRestoresDormantWithoutProcess() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig1 = WRig()
        let ws1 = env.workspace(rig1)
        let (s, t) = await env.start(ws1, rig1)
        // What the transport writes for one turn (the transport itself is covered in AlloyACPTests).
        let history = ACPHistory(directory: ws1.acpHistoryDirectory, sessionID: s.id)
        for m in [InboundMessage.userEcho(text: "how are you", imageCount: 0, uuid: UUID().uuidString.lowercased(), isReplay: false),
                  .assistantBlock(messageID: "m1", block: .text("Fine, thanks")),
                  .assistantBlock(messageID: "tool-1", block: .toolUse(id: "c1", name: "Run ls", input: .object([:]))),
                  .toolResult(ToolResultMessage(toolUseID: "c1", isError: false, text: "a.txt", result: .none))] {
            history.append(ACPHistory.encode(m)!)
        }
        // The app died while writing the next line.
        let handle = try FileHandle(forWritingTo: history.url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"type":"assistant","message":{"id":"x","con"#.utf8)); try handle.close()
        await t.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1,
                                        sessionID: "ses_1", terminalReason: nil)))
        await waitUntil("persisted") { s.hasConversation }
        try await Task.sleep(for: .milliseconds(200))

        // Relaunch.
        let rig2 = WRig()
        let ws2 = env.workspace(rig2)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        #expect(restored.status == .dormant && restored.backend == .acp(agentID: "fake") && restored.acpSessionID == "ses_1")
        #expect(ws2.isHistoryPending(restored.id))
        await ws2.loadHistory(restored.id)
        #expect(rig2.transports.isEmpty)   // showing history starts no process
        let blocks = restored.transcript.blocks
        #expect(blocks.contains { if case .user(_, "how are you", _, _) = $0 { true } else { false } })
        #expect(blocks.contains { if case .assistantText(_, "Fine, thanks") = $0 { true } else { false } })
        #expect(blocks.contains { if case .tool(let tb) = $0 { tb.toolUseID == "c1" } else { false } })
        #expect(ws2.ledger.files.isEmpty)   // no ledger, overlap or read-index effects
    }

    @Test func missingHistoryFileShowsEmptyDormant() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig1 = WRig()
        let ws1 = env.workspace(rig1)
        let (s, t) = await env.start(ws1, rig1)
        await t.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1,
                                        sessionID: "ses_1", terminalReason: nil)))
        await waitUntil("persisted") { s.hasConversation }
        try await Task.sleep(for: .milliseconds(200))
        let rig2 = WRig()
        let ws2 = env.workspace(rig2)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        await ws2.loadHistory(restored.id)
        #expect(restored.status == .dormant && rig2.transports.isEmpty)
        #expect(restored.transcript.blocks.count == 1)
        #expect(restored.transcript.blocks.contains { if case .notice(_, .history, "No earlier history found") = $0 { true } else { false } })
    }

    @Test func firstSendWakesARestoredSessionWithItsSavedIdAndResume() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig1 = WRig()
        let ws1 = env.workspace(rig1)
        let (s, t) = await env.start(ws1, rig1, id: "saved-7")
        await t.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1,
                                        sessionID: "saved-7", terminalReason: nil)))
        await waitUntil("persisted") { s.hasConversation }
        try await Task.sleep(for: .milliseconds(200))
        let rig2 = WRig()
        let ws2 = env.workspace(rig2)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        await ws2.send("continue", to: restored.id)
        #expect(rig2.configs.count == 1)
        #expect(rig2.configs[0].acpSessionID == "saved-7" && rig2.configs[0].resume == .resume)
        #expect(rig2.configs[0].history != nil)
    }

    @Test func restartAfterWatchdogFollowsSameOrder() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, t) = await env.start(ws, rig, id: "ses_9")
        #expect(rig.configs[0].acpSessionID == nil && rig.configs[0].resume == .new)
        await ws.restartACP(s.id)
        #expect(rig.configs.count == 2)
        #expect(rig.configs[1].acpSessionID == "ses_9" && rig.configs[1].resume == .resume)
        #expect(await t.terminated)
        // A relaunch for changed settings takes the same path.
        let t2 = rig.transports[1]
        await t2.emit(.systemInit(SystemInit(model: "", permissionMode: "", sessionID: "ses_9", tools: [], slashCommands: [])))
        await waitUntil("idle") { s.status == .idle }
        await ws.restartACP(s.id)
        #expect(rig.configs.count == 3 && rig.configs[2].resume == .resume)
    }

    @Test func costSumsUsageUpdates() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, t) = await env.start(ws, rig)
        await t.emit(.agentState(.usage(SessionUsage(used: 10, size: 100, cost: 0.01, currency: "USD"))))
        await waitUntil("first") { s.costUSD == 0.01 }
        await t.emit(.agentState(.usage(SessionUsage(used: 20, size: 100, cost: 0.03, currency: "USD"))))
        await waitUntil("second") { s.costUSD == 0.03 }
        // A new process counts from zero again; the session's total keeps what came before.
        await ws.restartACP(s.id)
        let t2 = rig.transports[1]
        await t2.emit(.agentState(.usage(SessionUsage(used: 5, size: 100, cost: 0.02, currency: "USD"))))
        await waitUntil("third") { abs(s.costUSD - 0.05) < 1e-9 }
    }

    // MARK: shared notes, secrets

    @Test func launchOffersTheLocalServerGuidanceAndAutoAllow() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        _ = await env.start(ws, rig)
        let c = rig.configs[0]
        #expect(c.mcp?.name == "alloy" && c.mcp?.url.hasPrefix("http://127.0.0.1") == true && c.mcp?.token.isEmpty == false)
        #expect(c.systemPrompt?.isEmpty == false)
        #expect(c.autoAllowAlloyTools)   // askBeforeSharedNotes is off by default
        await ws.stopAll()

        var settings = AlloySettings()
        settings.askBeforeSharedNotes = true
        let rig2 = WRig()
        let ws2 = env.workspace(rig2, settings: settings)
        _ = await env.start(ws2, rig2)
        #expect(!rig2.configs[0].autoAllowAlloyTools)
        await ws2.stopAll()

        var off = AlloySettings()
        off.shareKnowledge = false
        let rig3 = WRig()
        let ws3 = env.workspace(rig3, settings: off)
        _ = await env.start(ws3, rig3)
        #expect(rig3.configs[0].mcp == nil && rig3.configs[0].systemPrompt == nil)
        await ws3.stopAll()
    }

    @Test func missingKeychainSecretNamedInChatAndNeverWrittenToFile() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, _) = await env.start(ws, rig)
        #expect(s.transcript.blocks.contains { if case .notice(_, .warning, let t) = $0 { t.contains("FAKE_API_KEY") } else { false } })
        #expect(rig.configs[0].env["FAKE_API_KEY"] == nil)

        // With the secret present it reaches the environment only: nothing under the data directory holds it.
        try env.secrets.set("s3cret-value-123", agent: "fake", variable: "FAKE_API_KEY")
        let rig2 = WRig()
        let ws2 = env.workspace(rig2)
        let (s2, t2) = await env.start(ws2, rig2)
        #expect(rig2.configs[0].env["FAKE_API_KEY"] == "s3cret-value-123")
        let history = ACPHistory(directory: ws2.acpHistoryDirectory, sessionID: s2.id)
        history.append(ACPHistory.encode(.notice(kind: .warning, text: "Fake starts without a key"))!)
        await t2.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1,
                                         sessionID: "ses_1", terminalReason: nil)))
        try await Task.sleep(for: .milliseconds(300))
        let needle = Data("s3cret-value-123".utf8)
        let walker = FileManager.default.enumerator(at: env.base, includingPropertiesForKeys: [.isRegularFileKey])
        var scanned = 0
        while let url = walker?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            scanned += 1
            #expect(data.range(of: needle) == nil, "secret found in \(url.lastPathComponent)")
        }
        #expect(scanned > 0)
        await ws.stopAll(); await ws2.stopAll()
    }

    // MARK: queued messages

    @Test func midTurnMessageShowsQueuedAndSendNowPromotesIt() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, t) = await env.start(ws, rig)
        let first = UUID()
        await ws.send(msg("one", first), to: s.id)
        await echo(t, "one", first)
        await waitUntil("working") { s.status == .working }
        let second = UUID()
        await ws.send(msg("two", second), to: s.id)
        // It shows as waiting until the transport actually sends it (which echoes it).
        #expect(s.queued == [second])
        let sent = await t.sentAfterInitialize
        #expect(sent.count == 2)
        await ws.sendNow(second, in: s.id)
        let after = await t.sentAfterInitialize
        #expect(after.last == .user(content: [], uuid: second, priority: .now))
        await echo(t, "two", second)
        await waitUntil("settled") { s.queued.isEmpty }
        // Nothing else queued: another send-now is a no-op.
        await ws.sendNow(second, in: s.id)
        #expect(await t.sentAfterInitialize.count == after.count)
    }

    @Test func stopDropsQueuedBubbles() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, t) = await env.start(ws, rig)
        let first = UUID(), second = UUID()
        await ws.send(msg("one", first), to: s.id)
        await echo(t, "one", first)
        await waitUntil("working") { s.status == .working }
        await ws.send(msg("two", second), to: s.id)
        #expect(s.queued == [second])
        await ws.interrupt(s.id)
        #expect(s.queued.isEmpty)
    }

    @Test func noticesGatheredMidTurnLeadTheNextPrompt() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, t) = await env.start(ws, rig)
        let first = UUID()
        await ws.send(msg("one", first), to: s.id)
        await echo(t, "one", first)
        await waitUntil("working") { s.status == .working }
        ws.acpOverlapContext[s.id] = ["NOTICE: B is editing a.swift"]
        await ws.send("two", to: s.id)
        // Held for the transport to ask for it when the prompt goes out.
        #expect(ws.acpOverlapContext[s.id]?.count == 1)
        let lead = await rig.configs[0].leadingContext?()
        #expect(lead?.contains("B is editing a.swift") == true)
        #expect(await rig.configs[0].leadingContext?() == nil)
    }

    // MARK: login

    @Test func terminalAuthOpensATabAndReinitializes() async throws {
        let env = WEnv(); defer { env.cleanup() }
        let rig = WRig()
        let ws = env.workspace(rig)
        let (s, t) = await env.start(ws, rig, id: "ses_3")
        let body: JSONValue = .object(["command": .array([.string("/abs/fake-agent"), .string("login")]),
                                       "env": .object(["AGENT_HOME": .string("it's here")])])
        await t.emit(.controlRequest(ControlRequest(requestID: "acp-auth-terminal-1",
                                                    kind: .other(subtype: "acp_auth_terminal", body: body))))
        await waitUntil("tab") { ws.terminalLayout.tabs.count == 1 }
        let pane = try #require(ws.terminalLayout.tabs.first?.focusedPane)
        let line = try #require(ws.takeTerminalStartupInput(pane))
        #expect(line == "AGENT_HOME='it'\\''s here' '/abs/fake-agent' 'login'\n")
        #expect(ws.takeTerminalStartupInput(pane) == nil)
        #expect(ws.terminalLayout.visible && ws.mode == .code)
        // Not answered "unsupported": the transport waits for the user, not for an error.
        #expect(!(await t.sentAfterInitialize).contains { if case .controlError = $0 { true } else { false } })

        await t.emit(.controlRequest(ControlRequest(requestID: "acp-reinit-2", kind: .other(subtype: "acp_reinitialize", body: .object([:])))))
        await waitUntil("relaunched") { rig.configs.count == 2 }
        #expect(rig.configs[1].acpSessionID == "ses_3" && rig.configs[1].resume == .resume)
        _ = s
    }
}
