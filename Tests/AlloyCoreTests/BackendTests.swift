import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyCore

private final class BHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _claude: [ScriptedTransport] = []
    private var _acp: [ScriptedTransport] = []
    private var _acpConfigs: [ACPLaunchConfiguration] = []
    var claude: [ScriptedTransport] { lock.withLock { _claude } }
    var acp: [ScriptedTransport] { lock.withLock { _acp } }
    var acpConfigs: [ACPLaunchConfiguration] { lock.withLock { _acpConfigs } }
    var claudeFactory: TransportFactory {
        { [self] _ in let t = ScriptedTransport(); lock.withLock { _claude.append(t) }; return t }
    }
    var acpFactory: ACPTransportFactory {
        { [self] cfg in let t = ScriptedTransport(); lock.withLock { _acp.append(t); _acpConfigs.append(cfg) }; return t }
    }
}

private let fakeAgent = AgentDefinition(id: "fake", name: "Fake", command: "/abs/fake-agent", args: ["acp"],
                                        installHint: "brew install fake")

@Suite final class BackendTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-be-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        dirs.append(r)
        return r
    }

    @MainActor
    private func workspace(_ h: BHarness, installed: Bool = true, secrets: InMemorySecretStore = InMemorySecretStore(),
                           agent: AgentDefinition = fakeAgent) -> Workspace {
        Workspace(projectRoot: tempDir(), appSupport: tempDir(), settings: AlloySettings(),
                  locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                  makeTransport: h.claudeFactory, makeACPTransport: h.acpFactory,
                  agentDefinitions: { [agent] },
                  agentSecrets: secrets,
                  agentDetector: AgentDetector(resolve: { _ in [:] }, isExecutable: { _ in installed }, home: "/nohome",
                                               helpRunner: { _ in nil }),
                  now: Date.init, home: tempDir())
    }

    @Test func recordWithoutBackendDecodesAsClaude() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"A","colorIndex":1,"hasConversation":true}"#
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        #expect(r.backend == .claude)
        #expect(r.acpSessionID == nil)
    }

    @Test func claudeRecordIsWrittenWithoutBackendKeys() throws {
        let r = SessionRecord(id: UUID(), name: "A", colorIndex: 0, hasConversation: true, cliSessionID: "c")
        let text = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!text.contains("backend"))
        #expect(!text.contains("acpSessionID"))
    }

    @Test func acpRecordRoundTrips() throws {
        let r = SessionRecord(id: UUID(), name: "A", colorIndex: 0, hasConversation: true,
                              backend: .acp(agentID: "codex"), acpSessionID: "ses_1")
        let back = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(r))
        #expect(back.backend == .acp(agentID: "codex"))
        #expect(back.acpSessionID == "ses_1")
    }

    @MainActor @Test func claudeSessionUsesClaudeFactoryOnly() async {
        let h = BHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A")
        #expect(h.claude.count == 1)
        #expect(h.acp.isEmpty)
        #expect(s.backend == .claude)
        #expect(s.agentName == "Claude")
    }

    @MainActor @Test func acpSessionUsesAcpFactory() async {
        let h = BHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        #expect(h.claude.isEmpty)
        #expect(h.acp.count == 1)
        #expect(h.acpConfigs[0].agent.id == "fake")
        #expect(h.acpConfigs[0].executable.path == "/abs/fake-agent")
        #expect(h.acpConfigs[0].arguments == ["acp"])
        #expect(s.agentName == "Fake")
        #expect(s.status == .starting)
        await h.acp[0].emit(.systemInit(SystemInit(model: "", permissionMode: "", sessionID: "ses_9", tools: [], slashCommands: [])))
        await waitUntil("idle") { s.status == .idle }
        #expect(s.acpSessionID == "ses_9")
        #expect(s.cliSessionID == s.id.uuidString.lowercased())
        #expect(!s.hasConversation)
    }

    @MainActor @Test func acpExitNoticeNamesAgent() async {
        let h = BHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        await h.acp[0].exit(status: 3, stderr: "boom")
        await waitUntil("exited") { if case .exited = s.status { true } else { false } }
        #expect(s.transcript.blocks.contains { if case .notice(_, .exited, "Fake exited (status 3): boom") = $0 { true } else { false } })
    }

    @MainActor @Test func claudeExitNoticeUnchanged() async {
        let h = BHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A")
        await h.claude[0].exit(status: 3, stderr: "boom")
        await waitUntil("exited") { if case .exited = s.status { true } else { false } }
        #expect(s.transcript.blocks.contains { if case .notice(_, .exited, "Claude exited (status 3): boom") = $0 { true } else { false } })
        #expect(s.status == .exited(status: 3, message: "boom"))
    }

    @MainActor @Test func missingAgentFailsWithInstallHint() async {
        let h = BHarness()
        let ws = workspace(h, installed: false)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        guard case .failedToLaunch(let why) = s.status else { Issue.record("status \(s.status)"); return }
        #expect(why.contains("brew install fake"))
        #expect(h.acp.isEmpty)
        withExtendedLifetime(ws) {}
    }

    @MainActor @Test func missingSecretIsNamedAndTheAgentStillStarts() async {
        let h = BHarness()
        var agent = fakeAgent
        agent.secretNames = ["FAKE_API_KEY"]
        let ws = workspace(h, agent: agent)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        #expect(h.acp.count == 1)
        #expect(h.acpConfigs[0].env["FAKE_API_KEY"] == nil)
        #expect(s.transcript.blocks.contains { if case .notice(_, .warning, let t) = $0 { t.contains("FAKE_API_KEY") } else { false } })
    }

    @MainActor @Test func secretReachesTheLaunchEnvironmentOnly() async throws {
        let h = BHarness()
        var agent = fakeAgent
        agent.secretNames = ["FAKE_API_KEY"]
        let store = InMemorySecretStore()
        try store.set("s3cret", agent: "fake", variable: "FAKE_API_KEY")
        let ws = workspace(h, secrets: store, agent: agent)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        #expect(h.acpConfigs[0].env["FAKE_API_KEY"] == "s3cret")
        let all = s.transcript.blocks.map { "\($0)" }.joined()
        #expect(!all.contains("s3cret"))
    }

    @MainActor @Test func agentStateFillsTheSession() async {
        let h = BHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        let t = h.acp[0]
        await t.emit(.agentState(.usage(SessionUsage(used: 1200, size: 8000, cost: 0.5, currency: "USD"))))
        await t.emit(.agentState(.modes(current: "plan", available: [AgentChoice(id: "plan", name: "Plan"), AgentChoice(id: "build", name: "Build")])))
        await t.emit(.agentState(.models(current: "m1", available: [AgentChoice(id: "m1", name: "M1")])))
        await waitUntil("state") { s.usage?.used == 1200 && s.modes.count == 2 && s.model == "m1" }
        #expect(s.permissionMode == "plan")
        #expect(s.costUSD == 0.5)
        #expect(s.modelOptions.map(\.id) == ["m1"])
    }

    @MainActor @Test func acpCommandsHaveNoLocalForkOrTheme() async {
        let h = BHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        await h.acp[0].emit(.commandsChanged([SlashCommandInfo(name: "review", description: "Review", argumentHint: nil)]))
        await waitUntil("commands") { !s.slashCommands.isEmpty }
        #expect(s.slashCommands.map(\.name) == ["review"])
    }

    // MARK: launch failures are visible and retried by the next message

    /// A Claude workspace whose locator fails until `found.value` is set.
    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var _found = false
        private var _attempts = 0
        var found: Bool { get { lock.withLock { _found } } set { lock.withLock { _found = newValue } } }
        var attempts: Int { lock.withLock { _attempts } }
        func locate() throws -> URL {
            lock.withLock { _attempts += 1 }
            if found { return URL(fileURLWithPath: "/fake/claude") }
            throw ClaudeNotFound(tried: ["/a/claude", "/b/claude"])
        }
    }

    @MainActor private func switchable(_ h: BHarness, _ sw: Switch) -> Workspace {
        Workspace(projectRoot: tempDir(), appSupport: tempDir(), settings: AlloySettings(),
                  locate: { _ in try sw.locate() }, makeTransport: h.claudeFactory, now: Date.init, home: tempDir())
    }

    @MainActor private func errorNotices(_ s: Session) -> [String] {
        s.transcript.blocks.compactMap { if case .notice(_, .error, let text) = $0 { text } else { nil } }
    }

    @MainActor @Test func failedClaudeLaunchLeavesAnErrorNoticeWithTheTriedPathsAndTheHint() async {
        let h = BHarness(), sw = Switch()
        let ws = switchable(h, sw)
        let s = await ws.newSession(name: "A")
        guard case .failedToLaunch(let why) = s.status else { Issue.record("status \(s.status)"); return }
        #expect(why.contains("Tried:") && why.contains(Workspace.claudeInstallHint))
        let notices = errorNotices(s)
        #expect(notices.count == 1)
        #expect(notices.first?.contains("Tried:") == true && notices.first?.contains(Workspace.claudeInstallHint) == true)
    }

    @MainActor @Test func failedACPLaunchShowsThePresetInstallHint() async {
        let h = BHarness()
        let ws = workspace(h, installed: false)
        let s = await ws.newSession(name: "A", backend: .acp(agentID: "fake"))
        #expect(errorNotices(s).contains { $0.contains("brew install fake") })
    }

    @MainActor @Test func failLaunchWithEmptyOrHugeMessageStillShowsHint() async {
        let ws = switchable(BHarness(), Switch())
        let a = await ws.newSession(name: "A")
        let b = await ws.newSession(name: "B")
        ws.failLaunch(a, "", hint: Workspace.claudeInstallHint)
        ws.failLaunch(b, String(repeating: "x", count: 5000), hint: Workspace.claudeInstallHint)
        guard case .failedToLaunch(let ea) = a.status, case .failedToLaunch(let eb) = b.status else { Issue.record("not failed"); return }
        #expect(ea == Workspace.claudeInstallHint)
        #expect(eb.hasSuffix(Workspace.claudeInstallHint) && eb.count > 5000)
        #expect(errorNotices(a).last == ea)
    }

    @MainActor @Test func sendingOnAFailedSessionLaunchesAgain() async {
        let h = BHarness(), sw = Switch()
        let ws = switchable(h, sw)
        let s = await ws.newSession(name: "A")
        #expect(sw.attempts == 1)
        sw.found = true
        await ws.send("hi", to: s.id)
        #expect(sw.attempts == 2)
        #expect(h.claude.count == 1)
        if case .failedToLaunch = s.status { Issue.record("still failed") }
        let sent = await h.claude[0].sentAfterInitialize
        #expect(sent.contains { if case .user = $0 { true } else { false } })
    }

    @MainActor @Test func sendingTwiceWhileRelaunchingStartsOneLaunch() async {
        let h = BHarness(), sw = Switch()
        let ws = switchable(h, sw)
        let s = await ws.newSession(name: "A")
        sw.found = true
        async let first: Void = ws.send("one", to: s.id)
        async let second: Void = ws.send("two", to: s.id)
        _ = await (first, second)
        await ws.settle()
        #expect(sw.attempts == 2)
        #expect(h.claude.count == 1)
        #expect(errorNotices(s).count == 1)
    }

    @MainActor @Test func sendingDuringShutdownDoesNotRelaunch() async {
        let h = BHarness(), sw = Switch()
        let ws = switchable(h, sw)
        let s = await ws.newSession(name: "A")
        await ws.stopAll()
        sw.found = true
        await ws.send("hi", to: s.id)
        #expect(sw.attempts == 1)
        #expect(h.claude.isEmpty)
    }

    @MainActor @Test func aRelaunchThatFailsAgainSaysTheMessageWasNotSent() async {
        let h = BHarness(), sw = Switch()
        let ws = switchable(h, sw)
        let s = await ws.newSession(name: "A")
        await ws.send("hi", to: s.id)
        #expect(sw.attempts == 2)
        #expect(errorNotices(s).contains { $0.hasPrefix("Message not sent") })
        guard case .failedToLaunch = s.status else { Issue.record("status \(s.status)"); return }
    }
}
