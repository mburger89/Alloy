import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

/// Collects transports and launch configurations created by the workspace.
private final class Harness: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [ScriptedTransport] = []
    private var _configs: [LaunchConfiguration] = []
    var transports: [ScriptedTransport] { lock.withLock { _transports } }
    var configs: [LaunchConfiguration] { lock.withLock { _configs } }
    var factory: TransportFactory {
        { [self] cfg in
            let t = ScriptedTransport()
            lock.withLock { _transports.append(t); _configs.append(cfg) }
            return t
        }
    }
}

/// Temp directories created by one test; removed when the suite instance is released.
private final class DirBag: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func make() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ws-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        lock.withLock { urls.append(r) }
        return r
    }
    func cleanup() { lock.withLock { urls }.forEach { try? FileManager.default.removeItem(at: $0) } }
}

private let fakeClaude: @Sendable (String?) throws -> URL = { _ in URL(fileURLWithPath: "/fake/claude") }

@MainActor
private func makeWorkspace(root: URL, appSupport: URL, harness: Harness,
                           locate: @escaping @Sendable (String?) throws -> URL = fakeClaude,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           writer: @escaping @Sendable (Data, URL, () -> Bool) throws -> Bool = { d, u, _ in try d.write(to: u, options: .atomic); return false }) -> Workspace {
    Workspace(projectRoot: root, appSupport: appSupport, settings: AlloySettings(), locate: locate,
              makeTransport: harness.factory, now: Date.init, writeFile: writer, home: home)
}


/// edit-turn fixture lines with the probe's project path (the init line's `cwd`) rewritten to `root`.
private func editTurn(root: URL) -> [Data] {
    let lines = Fixture.lines("edit-turn")
    guard let first = lines.first,
          let obj = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
          let cwd = obj["cwd"] as? String else { Issue.record("fixture has no cwd"); return lines }
    return lines.map { Data(String(decoding: $0, as: UTF8.self).replacingOccurrences(of: cwd, with: root.path).utf8) }
}


/// A one-shot async gate: `wait()` suspends until `open()`.
private actor Gate {
    private(set) var entered = false
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
}

/// Wraps a `ScriptedTransport`; `start()` suspends on the gate.
private final class GatedTransport: SessionTransport, @unchecked Sendable {
    let inner = ScriptedTransport()
    let gate: Gate
    init(gate: Gate) { self.gate = gate }
    func start() async throws -> AsyncStream<ProcessEvent> { await gate.wait(); return try await inner.start() }
    func send(_ message: OutboundMessage) async throws { try await inner.send(message) }
    func terminate() async { await inner.terminate() }
    func stopAndWait(timeout: Duration) async { await inner.stopAndWait(timeout: timeout) }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}

private let edited = original.replacingOccurrences(of: "admin", with: "root")
private let original = "import Foundation\n\nfunc login(user: String, password: String) -> Bool {\n    // TODO: real auth\n    return user == \"admin\"\n}\n"

@MainActor
@Suite final class WorkspaceTests {
    private let dirs = DirBag()
    deinit { dirs.cleanup() }

    @Test func newSessionLaunchesWithOwnIDAndColor() async {
        let h = Harness(); let root = dirs.make()
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let b = await ws.newSession(name: "B")
        #expect(a.id != b.id)
        #expect(a.colorIndex == 0 && b.colorIndex == 1)
        #expect(h.configs.map(\.sessionID) == [a.id, b.id])
        #expect(h.configs.allSatisfy { !$0.resume && $0.projectDirectory == root })
        #expect(a.status == .idle)
    }

    @Test func editFlowsIntoLedgerAttributed() async throws {
        let h = Harness(); let root = dirs.make()
        try original.write(to: root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: editTurn(root: root))
        await waitUntil("idle") { a.status == .idle && !ws.changedFiles.isEmpty && a.model != nil }
        #expect(ws.changedFiles == [ChangedFile(path: "login.swift", authors: [.session(a.id)])])
        let ids = a.transcript.blocks.compactMap { b -> [UUID]? in
            if case .tool(let t) = b, !t.editIDs.isEmpty { return t.editIDs } else { return nil }
        }
        let recorded = ws.ledger.files["login.swift"]?.edits.map(\.id) ?? []
        #expect(ids.count == 1)
        #expect(ids.first == recorded)
        #expect(a.model != nil)
    }

    private func permissionRequest(_ rid: String) -> InboundMessage {
        .controlRequest(ControlRequest(requestID: rid, kind: .canUseTool(
            toolName: "Bash", input: .object(["command": .string("ls")]), description: "ls", toolUseID: "tu1", suggestions: [])))
    }

    @Test func approveSendsAllowWithOriginalInput() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(permissionRequest("r1"))
        await waitUntil("awaiting") { a.status == .awaitingPermission }
        await ws.answerPermission(session: a.id, requestID: "r1", allow: true)
        let sent = await h.transports[0].sent
        #expect(sent.last == .allow(requestID: "r1", updatedInput: .object(["command": .string("ls")])))
        let allowed = a.transcript.blocks.contains { if case .permission(let p) = $0 { return p.state == .allowed } else { return false } }
        #expect(allowed)
        #expect(a.status == .working)
    }

    @Test func denySendsDeniedInAlloy() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(permissionRequest("r1"))
        await waitUntil("awaiting") { a.status == .awaitingPermission }
        await ws.answerPermission(session: a.id, requestID: "r1", allow: false)
        #expect(await h.transports[0].sent.last == .deny(requestID: "r1", message: "Denied in Alloy"))
    }

    @Test func controlCancelReturnsToWorking() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(permissionRequest("r1"))
        await waitUntil("awaiting") { a.status == .awaitingPermission }
        await h.transports[0].emit(.controlCancel(requestID: "r1"))
        await waitUntil("working") { a.status == .working }
    }

    @Test func processExitShowsNoticeAndOthersContinue() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let b = await ws.newSession(name: "B")
        await h.transports[0].emit(permissionRequest("r1"))
        await waitUntil("awaiting") { a.status == .awaitingPermission }
        await h.transports[0].exit(status: 1, stderr: "auth expired")
        await waitUntil("exited") { if case .exited = a.status { return true } else { return false } }
        guard case .exited(let st, let msg) = a.status else { return }
        #expect(st == 1)
        #expect(msg.contains("auth expired"))
        let notice = a.transcript.blocks.contains { if case .notice(_, .exited, let t) = $0 { return t.contains("auth expired") } else { return false } }
        #expect(notice)
        let cancelled = a.transcript.blocks.contains { if case .permission(let p) = $0 { return p.state == .cancelled } else { return false } }
        #expect(cancelled)
        await h.transports[1].emit(.assistantBlock(messageID: "m", block: .text("hello")))
        await waitUntil("B message") { b.transcript.blocks.contains { if case .assistantText(_, "hello") = $0 { return true } else { return false } } }
        #expect(b.status == .working)
    }

    @Test func claudeNotFoundIsReadable() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h,
                               locate: { _ in throw ClaudeNotFound(tried: ["/x"]) })
        let a = await ws.newSession(name: "A")
        guard case .failedToLaunch(let msg) = a.status else { Issue.record("status \(a.status)"); return }
        #expect(msg.contains("/x"))
        #expect(msg.contains("ALLOY_CLAUDE_PATH"))
        #expect(h.transports.isEmpty)
    }

    @Test func sendAppendsUserBlockAndSendsLine() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.send("hi", to: a.id)
        guard case .user(let uuid, "hi", _, _)? = a.transcript.blocks.first else { Issue.record("no user block"); return }
        #expect(await h.transports[0].sentAfterInitialize == [.user(text: "hi", uuid: uuid, priority: nil)])
        await ws.interrupt(a.id)
        guard case .control(_, .interrupt)? = await h.transports[0].sent.last else { Issue.record("no interrupt"); return }
    }

    @Test func resultAddsCostAndTokens() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let r = TurnResult(subtype: "success", isError: false, costUSD: 0.5, inputTokens: 10, outputTokens: 5, sessionID: "s", terminalReason: nil,
                           cacheCreationTokens: 3, cacheReadTokens: 7)
        await h.transports[0].emit(.result(r))
        await h.transports[0].emit(.result(r))
        await waitUntil("two results") { a.inputTokens == 20 }
        // total_cost_usd is the process's running total, so two equal totals are not summed.
        #expect(a.costUSD == 0.5)
        #expect(a.outputTokens == 10 && a.status == .idle)
        #expect(a.totalTokens == 50)  // (10 + 3 + 7 + 5) per result, two results
    }

    @Test func revertWritesFileAndRecordsUserEdit() async throws {
        let h = Harness(); let root = dirs.make()
        let file = root.appendingPathComponent("login.swift")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: editTurn(root: root))
        await waitUntil("idle") { a.status == .idle && !ws.changedFiles.isEmpty }
        try edited.write(to: file, atomically: true, encoding: .utf8)   // the CLI has written the edit
        let editID = try #require(ws.ledger.files["login.swift"]?.edits.first?.id)
        let outcome = await ws.revert(edit: editID, path: "login.swift")
        #expect(outcome == .reverted(newText: original))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
        #expect(ws.ledger.files["login.swift"]?.edits.contains { $0.author == .user } == true)
    }

    @Test func keepFreezesTheEditsDiffSlice() async throws {
        let h = Harness(); let root = dirs.make()
        let file = root.appendingPathComponent("login.swift")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: editTurn(root: root))
        await waitUntil("idle") { a.status == .idle && !ws.changedFiles.isEmpty }
        let editID = try #require(ws.ledger.files["login.swift"]?.edits.first?.id)
        let before = try #require(ws.editDiffs[editID])
        #expect(!before.isEmpty)
        ws.keep(edit: editID, path: "login.swift")
        #expect(ws.editDiffs[editID] == before)
    }

    @Test func revertOutsideProjectRootIsRefused() async {
        let h = Harness(); let root = dirs.make()
        let wrote = Flag()
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h, writer: { _, _, _ in wrote.set(); return false })
        let outcome = await ws.revert(edit: UUID(), path: "../evil.txt")
        guard case .conflict = outcome else { Issue.record("expected conflict"); return }
        #expect(!wrote.value)
    }

    @Test func restoreResumesSessions() async throws {
        let root = dirs.make(); let support = dirs.make()
        try original.write(to: root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "Alpha")
        let b = await ws1.newSession(name: "Beta")
        await h1.transports[0].emit(fixture: editTurn(root: root))
        await waitUntil("idle") { a.status == .idle && !ws1.changedFiles.isEmpty }

        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        await ws2.restore()
        #expect(ws2.sessions.map(\.id) == [a.id, b.id])
        #expect(ws2.sessions.map(\.name) == ["Alpha", "Beta"])
        #expect(ws2.sessions.map(\.colorIndex) == [0, 1])
        // Restore is lazy: nothing is launched until a send or a wake.
        #expect(h2.configs.isEmpty)
        #expect(ws2.sessions.allSatisfy { $0.status == .dormant })
        await ws2.wake(a.id)
        await ws2.wake(b.id)
        #expect(h2.configs.map(\.resume) == [true, false])
        #expect(h2.configs.map(\.sessionID) == [a.id, b.id])
        #expect(ws2.ledger == ws1.ledger)
    }

    // MARK: History replay

    /// The real transcript fixture, copied to where the CLI would have written it for `session`.
    private func installTranscript(home: URL, root: URL, cliSessionID: String, transform: (String) -> String = { $0 }) throws {
        let url = TranscriptFile.url(cliSessionID: cliSessionID, projectRoot: root, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sample = try TranscriptFileTests.sample()
        try Data(transform(String(decoding: sample, as: UTF8.self)).utf8).write(to: url)
    }

    @Test func restoredSessionLoadsOnSelect() async throws {
        let root = dirs.make(); let support = dirs.make(); let home = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1, home: home)
        let a = await ws1.newSession(name: "Alpha")
        let quiet = await ws1.newSession(name: "Quiet")
        await h1.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("conversation") { a.hasConversation }
        try installTranscript(home: home, root: root, cliSessionID: a.cliSessionID)

        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == a.id })
        await ws2.loadHistory(a.id)
        let kinds = restored.transcript.blocks.map { b -> String in
            switch b { case .user: "user"; case .assistantText: "text"; case .tool: "tool"; case .thinking: "thinking"; default: "other" }
        }
        #expect(kinds == ["user", "tool", "thinking", "text", "user", "thinking", "text"])
        #expect(restored.status == .dormant)
        #expect(h2.configs.isEmpty && h2.transports.isEmpty)
        // Once per session: a second call adds nothing.
        await ws2.loadHistory(a.id)
        #expect(restored.transcript.blocks.count == 7)
        // A session that never talked has nothing to replay.
        let other = try #require(ws2.sessions.first { $0.id == quiet.id })
        await ws2.loadHistory(quiet.id)
        #expect(other.transcript.blocks.isEmpty)
    }

    @Test func historyKeepsTheLast2000Blocks() async throws {
        let root = dirs.make(); let support = dirs.make(); let home = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1, home: home)
        let a = await ws1.newSession(name: "Alpha")
        await h1.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("conversation") { a.hasConversation }
        let big = try TranscriptFileTests.largeTranscript()
        try installTranscript(home: home, root: root, cliSessionID: a.cliSessionID) { _ in big }
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: Harness(), home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        await ws2.loadHistory(a.id)
        #expect(restored.transcript.blocks.count == 2000)
        if case .assistantText(_, let t) = restored.transcript.blocks.last { #expect(t.hasPrefix("1\n2")) }
        else { Issue.record("tail is not text") }
    }

    @Test func missingFileAddsNotice() async throws {
        let root = dirs.make(); let support = dirs.make(); let home = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1, home: home)
        let a = await ws1.newSession(name: "Alpha")
        await h1.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("conversation") { a.hasConversation }
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: Harness(), home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        await ws2.loadHistory(a.id)
        #expect(restored.transcript.blocks.count == 1)
        if case .notice(_, _, let text) = restored.transcript.blocks[0] { #expect(text == "No earlier history found") }
        else { Issue.record("expected a notice") }
    }

    @Test func unreadableLinesAddOneNotice() async throws {
        let root = dirs.make(); let support = dirs.make(); let home = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1, home: home)
        let a = await ws1.newSession(name: "Alpha")
        await h1.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("conversation") { a.hasConversation }
        try installTranscript(home: home, root: root, cliSessionID: a.cliSessionID) { $0 + "{\"type\":\"assistant\",\"mess" }
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: Harness(), home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        await ws2.loadHistory(a.id)
        if case .notice(_, _, let text) = restored.transcript.blocks.first { #expect(text == "1 line of history could not be read") }
        else { Issue.record("expected a notice first") }
        #expect(restored.transcript.blocks.count == 8)
    }

    @Test func historyReattachesEdits() async throws {
        let root = dirs.make(); let support = dirs.make(); let home = dirs.make()
        try original.write(to: root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1, home: home)
        let a = await ws1.newSession(name: "Alpha")
        await h1.transports[0].emit(fixture: editTurn(root: root))
        await waitUntil("idle") { a.status == .idle && !ws1.changedFiles.isEmpty }
        let record = try #require(ws1.ledger.files["login.swift"]?.edits.first)
        let toolID = try #require(record.toolUseID)
        try installTranscript(home: home, root: root, cliSessionID: a.cliSessionID) {
            $0.replacingOccurrences(of: "toolu_01QkcadU6KBGp83dgayhLFcV", with: toolID)
        }
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: Harness(), home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first)
        await ws2.loadHistory(a.id)
        let tools = restored.transcript.blocks.compactMap { b -> ToolBlock? in if case .tool(let t) = b { return t } else { return nil } }
        #expect(tools.count == 1)
        #expect(tools.first?.editIDs == [record.id])
        #expect(ws2.editDiffs[record.id] != nil)
    }

    @Test func stopTerminatesTransport() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.stop(a.id)
        #expect(await h.transports[0].terminated)
        #expect(a.status == .exited(status: 0, message: "Stopped"))
    }

    @Test func settingsEnvOverrideIsNeverPersisted() throws {
        let support = dirs.make()
        #expect(AlloySettings.load(appSupport: support).claudePath == nil)
        try AlloySettings(claudePath: "/a/claude").save(appSupport: support)
        let loaded = AlloySettings.load(appSupport: support)
        #expect(loaded.effectiveClaudePath(environment: ["ALLOY_CLAUDE_PATH": "/env/claude"]) == "/env/claude")
        #expect(loaded.effectiveClaudePath(environment: [:]) == "/a/claude")
        try loaded.save(appSupport: support)
        #expect(AlloySettings.load(appSupport: support).claudePath == "/a/claude")
    }

    /// `ALLOY_DATA_DIR` moves everything Alloy keeps in Application Support (settings, ledgers, sessions), so the
    /// bench can launch Alloy without touching the real one.
    @Test func dataDirectoryEnvironmentOverridesApplicationSupport() {
        let real = URL(fileURLWithPath: "/real/Application Support")
        #expect(AlloySettings.appSupportDirectory(environment: [:], default: real) == real)
        #expect(AlloySettings.appSupportDirectory(environment: ["ALLOY_DATA_DIR": ""], default: real) == real)
        #expect(AlloySettings.appSupportDirectory(environment: ["ALLOY_DATA_DIR": "/tmp/bench-data"], default: real)
                == URL(fileURLWithPath: "/tmp/bench-data"))
        let store = ProjectLedger.storeURL(projectRoot: URL(fileURLWithPath: "/p"),
                                           appSupport: AlloySettings.appSupportDirectory(environment: ["ALLOY_DATA_DIR": "/tmp/bench-data"], default: real))
        #expect(store.path.hasPrefix("/tmp/bench-data/Alloy/Projects/"))
    }

    @Test func staleAnswerAfterCancelSendsNothing() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(permissionRequest("r1"))
        await waitUntil("awaiting") { a.status == .awaitingPermission }
        await h.transports[0].emit(.controlCancel(requestID: "r1"))
        await waitUntil("working") { a.status == .working }
        await ws.answerPermission(session: a.id, requestID: "r1", allow: true)
        #expect(await h.transports[0].sentAfterInitialize.isEmpty)
        let cancelled = a.transcript.blocks.contains { if case .permission(let p) = $0 { return p.state == .cancelled } else { return false } }
        #expect(cancelled)
    }

    @Test func answerAfterExitSendsNothingAndSendNoticesOnce() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(permissionRequest("r1"))
        await waitUntil("awaiting") { a.status == .awaitingPermission }
        await h.transports[0].exit(status: 1, stderr: "x")
        await waitUntil("exited") { if case .exited = a.status { return true } else { return false } }
        await ws.answerPermission(session: a.id, requestID: "r1", allow: true)
        await ws.send("one", to: a.id)
        await ws.send("two", to: a.id)
        #expect(await h.transports[0].sentAfterInitialize.isEmpty)
        let n = a.transcript.blocks.filter { if case .notice(_, .error, "Session has ended") = $0 { return true } else { return false } }.count
        #expect(n == 1)
        await ws.stop(a.id)
        guard case .exited(1, _) = a.status else { Issue.record("status changed: \(a.status)"); return }
    }

    @Test func stopAllStopsEverySession() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let b = await ws.newSession(name: "B")
        await ws.stopAll()
        let t0 = await h.transports[0].terminated
        let t1 = await h.transports[1].terminated
        #expect(t0 && t1)
        #expect(await h.transports[0].stopAndWaitCalls == 1)
        #expect(await h.transports[1].stopAndWaitCalls == 1)
        let stopped = SessionStatus.exited(status: 0, message: "Stopped")
        #expect(a.status == stopped)
        #expect(b.status == stopped)
    }


    // MARK: Shutdown

    @Test func stopAllAwaitsAnInFlightLaunchAndStopsItsTransport() async {
        let gate = Gate(); let made = Box<[GatedTransport]>([])
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(), locate: fakeClaude,
                           makeTransport: { _ in let t = GatedTransport(gate: gate); made.value.append(t); return t })
        let launch = Task { @MainActor in await ws.newSession(name: "A") }
        while !(await gate.entered) { await Task.yield() }
        let stopDone = Box(false)
        let stop = Task { @MainActor in await ws.stopAll(); stopDone.value = true }
        for _ in 0..<2000 { await Task.yield() }
        #expect(stopDone.value == false, "stopAll must wait for the launch in flight")
        await gate.open()
        let a = await launch.value
        await stop.value
        #expect(made.value.count == 1)
        #expect(await made.value[0].inner.stopAndWaitCalls == 1)
        #expect(await made.value[0].inner.terminated)
        #expect(a.status == .exited(status: 0, message: "Stopped"))
    }

    @Test func stopAllDuringExecutableLookupLeavesNothingRunning() async {
        let h = Harness()
        let entered = Box(false); let release = DispatchSemaphore(value: 0)
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(),
                           locate: { _ in entered.value = true; release.wait(); return URL(fileURLWithPath: "/fake/claude") },
                           makeTransport: h.factory)
        let launch = Task { @MainActor in await ws.newSession(name: "A") }
        while !entered.value { await Task.yield() }
        let stopDone = Box(false)
        let stop = Task { @MainActor in await ws.stopAll(); stopDone.value = true }
        for _ in 0..<2000 { await Task.yield() }
        #expect(stopDone.value == false)
        release.signal()
        let a = await launch.value
        await stop.value
        for t in h.transports { #expect(await t.terminated) }
        #expect(a.status == .exited(status: 0, message: "Stopped"))
    }

    @Test func nothingLaunchesOnceShutdownBegan() async throws {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "A")
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        #expect(ws2.sessions.first { $0.id == a.id }?.status == .dormant)
        await ws2.stopAll()
        #expect(ws2.isShuttingDown)
        await ws2.wake(a.id)
        await ws2.send("late", to: a.id)
        let b = await ws2.newSession(name: "B")
        #expect(h2.configs.isEmpty)
        #expect(h2.transports.isEmpty)
        if case .starting = b.status { Issue.record("new session must not be left starting") }
        let notices = ws2.sessions.first { $0.id == a.id }!.transcript.blocks.filter {
            if case .notice(_, .error, let t) = $0 { return t.hasPrefix("Message not sent") } else { return false }
        }
        #expect(notices.count == 1)
    }

    private func editedSetup() async throws -> (Workspace, Harness, Session, URL, UUID) {
        let h = Harness(); let root = dirs.make()
        let file = root.appendingPathComponent("login.swift")
        try original.write(to: file, atomically: true, encoding: .utf8)
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: editTurn(root: root))
        await waitUntil("idle") { a.status == .idle && !ws.changedFiles.isEmpty }
        try edited.write(to: file, atomically: true, encoding: .utf8)
        let id = try #require(ws.ledger.files["login.swift"]?.edits.first?.id)
        return (ws, h, a, file, id)
    }

    @Test func revertKeepsUnrelatedOutsideChange() async throws {
        let (ws, _, a, file, id) = try await editedSetup()
        // The turn ran a shell command a moment ago; with its session gone the change below cannot be its (Bash window).
        await ws.stop(a.id)
        let outside = edited.replacingOccurrences(of: "// TODO: real auth", with: "// changed elsewhere")
        try outside.write(to: file, atomically: true, encoding: .utf8)
        let outcome = await ws.revert(edit: id, path: "login.swift")
        let expected = original.replacingOccurrences(of: "// TODO: real auth", with: "// changed elsewhere")
        #expect(outcome == .reverted(newText: expected))
        #expect(try String(contentsOf: file, encoding: .utf8) == expected)
        #expect(ws.ledger.files["login.swift"]?.edits.contains { $0.author == .outside } == true)
    }

    @Test func revertConflictsWhenOutsideChangeTouchesEditedText() async throws {
        let (ws, _, _, file, id) = try await editedSetup()
        let outside = edited.replacingOccurrences(of: "return user == \"root\"", with: "return false")
        try outside.write(to: file, atomically: true, encoding: .utf8)
        let outcome = await ws.revert(edit: id, path: "login.swift")
        guard case .conflict = outcome else { Issue.record("expected conflict, got \(outcome)"); return }
        #expect(try String(contentsOf: file, encoding: .utf8) == outside)
    }

    @Test func corruptLedgerIsMovedAsideAndReported() async throws {
        let root = dirs.make(); let support = dirs.make()
        let url = ProjectLedger.storeURL(projectRoot: root, appSupport: support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let ws = makeWorkspace(root: root, appSupport: support, harness: Harness())
        await ws.restore()
        #expect(ws.errors.count == 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let corrupt = try #require(names.first { $0.hasPrefix("ledger.json.corrupt-") })
        _ = await ws.newSession(name: "A")
        #expect(try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(corrupt), encoding: .utf8) == "not json")
    }

    @Test func saveFailureIsReported() async throws {
        let support = dirs.make().appendingPathComponent("file")
        try Data().write(to: support)   // a file where a directory is needed
        let ws = makeWorkspace(root: dirs.make(), appSupport: support, harness: Harness())
        _ = await ws.newSession(name: "A")
        #expect(!ws.errors.isEmpty)
    }

    @Test func newSessionBeforeRestoreKeepsEarlierSessions() async {
        let root = dirs.make(); let support = dirs.make()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: Harness())
        let a = await ws1.newSession(name: "A")
        let b = await ws1.newSession(name: "B")
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        let c = await ws2.newSession(name: "C")
        await ws2.restore()
        let got = Set(ws2.sessions.map(\.id))
        #expect(got == Set([a.id, b.id, c.id]))
        #expect(c.colorIndex == 2)
        let ws3 = makeWorkspace(root: root, appSupport: support, harness: Harness())
        await ws3.restore()
        #expect(ws3.sessions.count == 3)
    }

    @Test func restoreResumesOnlySessionsWithAConversation() async {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "Talked")
        let b = await ws1.newSession(name: "Silent")
        await h1.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("idle") { a.hasConversation }
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        await ws2.wake(a.id)
        await ws2.wake(b.id)
        let byID = Dictionary(uniqueKeysWithValues: h2.configs.map { ($0.sessionID, $0.resume) })
        #expect(byID[a.id] == true)
        #expect(byID[b.id] == false)
    }

    // MARK: Final review: attribution and revert safety

    /// A whole-file edit result, as the CLI reports one.
    private func editResult(_ id: String, path: URL, old: String, new: String) -> [InboundMessage] {
        let o = TextLines(old).lines, n = TextLines(new).lines
        let hunk = PatchHunk(oldStart: 1, oldLines: o.count, newStart: 1, newLines: n.count,
                             lines: o.map { "-" + $0 } + n.map { "+" + $0 })
        return [.assistantBlock(messageID: "m-\(id)", block: .toolUse(id: id, name: "Edit", input: .object([:]))),
                .toolResult(ToolResultMessage(toolUseID: id, isError: false, text: "ok",
                                              result: .edit(filePath: path.path, originalFile: old, hunks: [hunk])))]
    }

    private func toolEditIDs(_ s: Session, _ id: String) -> [UUID]? {
        for b in s.transcript.blocks { if case .tool(let t) = b, t.toolUseID == id { return t.editIDs } }
        return nil
    }

    @Test func outsideDriftIsNotAttachedToTheSessionsToolBlock() async throws {
        let h = Harness(); let root = dirs.make()
        let file = root.appendingPathComponent("a.txt")
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let t = h.transports[0]
        for m in editResult("t1", path: file, old: "a\nb\nc\n", new: "a\nB\nc\n") { await t.emit(m) }
        await waitUntil("first edit") { toolEditIDs(a, "t1")?.count == 1 }
        // The user appended a line outside Alloy; the next edit reports the drifted text as its original.
        for m in editResult("t2", path: file, old: "a\nB\nc\nuser\n", new: "a\nZ\nc\nuser\n") { await t.emit(m) }
        await waitUntil("second edit") { toolEditIDs(a, "t2")?.isEmpty == false }
        let records = try #require(ws.ledger.files["a.txt"]).edits
        #expect(records.contains { $0.author == .outside })
        let mine = records.filter { $0.toolUseID == "t2" && $0.author == .session(a.id) }.map(\.id)
        #expect(mine.count == 1)
        #expect(toolEditIDs(a, "t2") == mine)
        let outside = try #require(records.first { $0.author == .outside })
        #expect(ws.editDiffs[outside.id] == nil)
    }

    @Test func revertThroughASymlinkWritesTheResolvedFileAndKeepsTheLink() async throws {
        let h = Harness(); let root = dirs.make()
        let real = root.appendingPathComponent("real.swift"), link = root.appendingPathComponent("link.swift")
        try edited.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let w = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await w.newSession(name: "A")
        for m in editResult("t1", path: link, old: original, new: edited) { await h.transports[0].emit(m) }
        await waitUntil("edit") { toolEditIDs(a, "t1")?.count == 1 }
        let id = try #require(w.ledger.files["link.swift"]?.edits.first?.id)
        let outcome = await w.revert(edit: id, path: "link.swift")
        #expect(outcome == .reverted(newText: original))
        #expect(try String(contentsOf: real, encoding: .utf8) == original)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == real.path)
    }

    @Test func revertThroughASymlinkOutsideTheProjectIsRefused() async throws {
        let h = Harness(); let root = dirs.make(); let elsewhere = dirs.make()
        let target = elsewhere.appendingPathComponent("secret.swift"), link = root.appendingPathComponent("link.swift")
        try edited.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let wrote = Flag()
        let w = makeWorkspace(root: root, appSupport: dirs.make(), harness: h, writer: { _, _, _ in wrote.set(); return false })
        let a = await w.newSession(name: "A")
        for m in editResult("t1", path: link, old: original, new: edited) { await h.transports[0].emit(m) }
        await waitUntil("edit") { toolEditIDs(a, "t1")?.count == 1 }
        let id = try #require(w.ledger.files["link.swift"]?.edits.first?.id)
        let outcome = await w.revert(edit: id, path: "link.swift")
        guard case .conflict(let reason) = outcome else { Issue.record("expected conflict, got \(outcome)"); return }
        #expect(reason.contains("outside the project"))
        #expect(!wrote.value)
        #expect(try String(contentsOf: target, encoding: .utf8) == edited)
    }

    @Test func revertOfANonUTF8FileWritesNothing() async throws {
        let (ws, _, _, file, id) = try await editedSetup()
        let bytes = Data([0xFF, 0xFE, 0x41, 0x0A])
        try bytes.write(to: file)
        let outcome = await ws.revert(edit: id, path: "login.swift")
        #expect(outcome == .conflict(reason: "File is not UTF-8 text"))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func revertOfAFileDeletedOutsideAlloyDoesNotRecreateIt() async throws {
        let (ws, _, _, file, id) = try await editedSetup()
        try FileManager.default.removeItem(at: file)
        let outcome = await ws.revert(edit: id, path: "login.swift")
        #expect(outcome == .conflict(reason: "File was deleted outside Alloy"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func revertConflictNamesTheSessionNotItsUUID() async throws {
        let h = Harness(); let root = dirs.make()
        let file = root.appendingPathComponent("a.txt")
        try "a\nZ\nc\n".write(to: file, atomically: true, encoding: .utf8)
        let ws = makeWorkspace(root: root, appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "Alpha")
        let b = await ws.newSession(name: "Beta")
        for m in editResult("t1", path: file, old: "a\nb\nc\n", new: "a\nY\nc\n") { await h.transports[0].emit(m) }
        await waitUntil("A edit") { toolEditIDs(a, "t1")?.count == 1 }
        for m in editResult("t2", path: file, old: "a\nY\nc\n", new: "a\nZ\nc\n") { await h.transports[1].emit(m) }
        await waitUntil("B edit") { toolEditIDs(b, "t2")?.count == 1 }
        let id = try #require(ws.ledger.files["a.txt"]?.edits.first { $0.author == .session(a.id) }?.id)
        let outcome = await ws.revert(edit: id, path: "a.txt")
        guard case .conflict(let reason) = outcome else { Issue.record("expected conflict, got \(outcome)"); return }
        #expect(reason == "A later edit by Beta changed the text this edit wrote.")
        #expect(!reason.contains(b.id.uuidString))
    }

    // MARK: Final review minors

    @Test func unsupportedControlRequestsGetAnErrorResponse() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(.controlRequest(ControlRequest(requestID: "hk1",
                                   kind: .other(subtype: "hook_callback", body: .object([:])))))
        var sent: [OutboundMessage] = []
        for _ in 0..<200_000 where sent.isEmpty { await Task.yield(); sent = await h.transports[0].sentAfterInitialize }
        #expect(sent == [.controlError(requestID: "hk1", message: "Unsupported by Alloy")])
        #expect(a.status != .awaitingPermission)
    }

    @Test func exitMidDrainGivesOneNoticeForTheQueuedMessages() async {
        let gate = SendGate()
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(),
                           locate: fakeClaude, makeTransport: { _ in gate })
        let launching = Task { await ws.newSession(name: "A") }
        await waitUntil("session added") { ws.sessions.count == 1 }
        let a = ws.sessions[0]
        for t in ["1", "2", "3"] { await ws.send(t, to: a.id) }
        await waitUntil("first delivery suspended") { gate.blocked }
        await gate.exit()
        await waitUntil("exit handled") { if case .exited = a.status { true } else { false } }
        gate.release()
        _ = await launching.value
        #expect(await gate.texts == ["1"])
        let notes = a.transcript.blocks.compactMap { b -> String? in
            if case .notice(_, .error, let t) = b { return t } else { return nil }
        }
        #expect(notes == ["Message not sent: session ended"])
    }

    // MARK: Final fix wave

    @Test func deferredModeGoesOutBeforeTheQueuedMessage() async throws {
        let root = dirs.make(); let support = dirs.make()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: Harness())
        let a = await ws1.newSession(name: "A")
        let gate = Gate()
        let gated = GatedTransport(gate: gate)
        let ws2 = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                            locate: fakeClaude, makeTransport: { _ in gated })
        await ws2.restore()
        let b = try #require(ws2.sessions.first { $0.id == a.id })
        let first = Task { await ws2.send("do X", to: b.id) }
        for _ in 0..<500_000 where !(await gate.entered) { await Task.yield() }
        #expect(b.status == .starting)
        await ws2.send("/plan", to: b.id)
        await gate.open()
        await first.value
        let sent = await gated.inner.sent
        guard sent.count == 3, case .control(_, .initialize) = sent[0], case .control(_, .setPermissionMode("plan")) = sent[1],
              case .user = sent[2] else { Issue.record("wrong wire order: \(sent)"); return }
    }

    @Test func sendDuringDeferredControlDrainIsDelivered() async throws {
        let root = dirs.make(); let support = dirs.make()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: Harness())
        let a = await ws1.newSession(name: "A")
        let transport = ModeGate()
        let ws2 = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                            locate: fakeClaude, makeTransport: { _ in transport })
        await ws2.restore()
        let b = try #require(ws2.sessions.first { $0.id == a.id })
        let waking = Task { await ws2.send("/plan", to: b.id) }
        await waitUntil("mode send suspended") { transport.blocked }
        await ws2.send("late", to: b.id)
        transport.release()
        await waking.value
        #expect(await transport.texts == ["late"])
    }

    private func busyWithQueued(_ h: Harness, _ ws: Workspace) async -> Session {
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(.assistantBlock(messageID: "m", block: .text("hi")))
        await waitUntil("working") { a.status == .working }
        await ws.send(OutgoingMessage(text: "one", images: [], priority: .later), to: a.id)
        await ws.send(OutgoingMessage(text: "two", images: [], priority: .next), to: a.id)
        #expect(a.queued.count == 2)
        return a
    }

    private func expectAbandoned(_ a: Session) {
        #expect(a.queued.isEmpty)
        let states = a.transcript.blocks.compactMap { b -> UserState? in if case .user(_, _, _, let s) = b { s } else { nil } }
        #expect(states == [.sent, .sent])
        #expect(noticeTexts(a, .error) == ["2 queued messages were not delivered"])
    }

    @Test func queuedMessagesAreAbandonedWhenTheProcessExits() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await busyWithQueued(h, ws)
        await h.transports[0].exit(status: 1, stderr: "")
        await waitUntil("exited") { if case .exited = a.status { true } else { false } }
        expectAbandoned(a)
    }

    @Test func queuedMessagesAreAbandonedOnStopAndStopAll() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await busyWithQueued(h, ws)
        await ws.stop(a.id)
        expectAbandoned(a)
        let h2 = Harness()
        let ws2 = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h2)
        let b = await busyWithQueued(h2, ws2)
        await ws2.stopAll()
        expectAbandoned(b)
    }

    @Test func controlOnAnExitedSessionSaysSessionHasEnded() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].exit(status: 1, stderr: "")
        await waitUntil("exited") { if case .exited = a.status { true } else { false } }
        await ws.setModel("opus", for: a.id)
        await ws.setPermissionMode(.plan, for: a.id)
        #expect(noticeTexts(a, .error) == ["Session has ended"])
        #expect(h.transports.count == 1)
    }

    @Test func slashCommandsSurviveRestoreSoSuggestionsWorkBeforeLaunch() async throws {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "A")
        let compact = SlashCommandInfo(name: "compact", description: "Compact the conversation", argumentHint: "[focus]")
        await h1.transports[0].emit(.commandsChanged([compact]))
        await waitUntil("commands") { !a.slashCommands.isEmpty }
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        let b = try #require(ws2.sessions.first { $0.id == a.id })
        #expect(b.status == .dormant && h2.transports.isEmpty)
        #expect(b.slashCommands == [compact,
            SlashCommandInfo(name: "fork", description: "Start a new session from this conversation", argumentHint: "[name]"),
            SlashCommandInfo(name: "theme", description: "Make a theme with Claude in a new session", argumentHint: "[description]")])
    }

    // MARK: Lazy restore, cost, PATH

    @Test func restoreLaunchesNothingAndSendWakesWithTheRightFlag() async throws {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "Talked")
        let b = await ws1.newSession(name: "Silent")
        await h1.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                       outputTokens: 0, sessionID: "s", terminalReason: nil)))
        await waitUntil("conversation") { a.hasConversation }
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        #expect(h2.configs.isEmpty)
        await ws2.send("hello again", to: a.id)
        #expect(h2.configs.map(\.resume) == [true])
        #expect(h2.configs.map(\.sessionID) == [a.id])
        #expect(await h2.transports[0].sentAfterInitialize.count == 1)
        if case .user(let c, _, _)? = await h2.transports[0].sentAfterInitialize.first { #expect(c == [.text("hello again")]) } else { Issue.record("not delivered") }
        await ws2.send("fresh", to: b.id)
        #expect(h2.configs.map(\.resume) == [true, false])
        #expect(ws2.sessions.first { $0.id == b.id }?.status == .idle)
    }

    @Test func costAddsEarlierProcessesToTheCurrentRunningTotal() async {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "A")
        func result(_ cost: Double) -> InboundMessage {
            .result(TurnResult(subtype: "success", isError: false, costUSD: cost, inputTokens: 0, outputTokens: 0,
                               sessionID: "s", terminalReason: nil))
        }
        await h1.transports[0].emit(result(0.30))
        await h1.transports[0].emit(result(0.50))
        await waitUntil("first process") { a.costUSD == 0.50 }
        // A second process of the same session starts its own total from zero.
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        let b = ws2.sessions[0]
        await ws2.wake(b.id)
        #expect(b.costUSD == 0) // not persisted across app runs
        await h2.transports[0].emit(result(0.10))
        await waitUntil("second process") { b.costUSD == 0.10 }
    }

    @Test func loginPATHReachesTheLaunchConfiguration() async {
        let h = Harness()
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(), locate: fakeClaude,
                           makeTransport: h.factory, loginPATH: { "/login/bin:/usr/bin" })
        _ = await ws.newSession(name: "A")
        #expect(h.configs.first?.loginPATH == "/login/bin:/usr/bin")
    }

    // MARK: Launch races (Task 9 review)

    @Test func sendWhileStartingQueuesAndDeliversOnceLive() async {
        let h = Harness()
        let gate = DispatchSemaphore(value: 0)
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h,
                               locate: { _ in gate.wait(); return URL(fileURLWithPath: "/fake/claude") })
        let launching = Task { await ws.newSession(name: "A") }
        await waitUntil("session added") { ws.sessions.count == 1 }
        let a = ws.sessions[0]
        #expect(a.status == .starting)
        await ws.send("early", to: a.id)
        let ended = a.transcript.blocks.contains { if case .notice(_, .error, _) = $0 { return true } else { return false } }
        #expect(!ended)
        gate.signal()
        _ = await launching.value
        guard case .user(let uuid, "early", _, _)? = a.transcript.blocks.first else { Issue.record("no user block"); return }
        #expect(await h.transports[0].sentAfterInitialize == [.user(text: "early", uuid: uuid, priority: nil)])
    }

    @Test func queuedSendWhenLaunchFailsAddsOneNotice() async {
        let h = Harness()
        let gate = DispatchSemaphore(value: 0)
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h,
                               locate: { _ in gate.wait(); throw ClaudeNotFound(tried: ["/x"]) })
        let launching = Task { await ws.newSession(name: "A") }
        await waitUntil("session added") { ws.sessions.count == 1 }
        let a = ws.sessions[0]
        await ws.send("one", to: a.id)
        await ws.send("two", to: a.id)
        gate.signal()
        _ = await launching.value
        guard case .failedToLaunch = a.status else { Issue.record("status \(a.status)"); return }
        let n = a.transcript.blocks.filter { if case .notice(_, .error, _) = $0 { return true } else { return false } }.count
        #expect(n == 1)
        #expect(h.transports.isEmpty)
    }

    @Test func stopDuringLaunchWins() async {
        let gate = StartGate()
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(),
                           locate: fakeClaude, makeTransport: { _ in gate })
        let launching = Task { await ws.newSession(name: "A") }
        await waitUntil("session added") { ws.sessions.count == 1 }
        let a = ws.sessions[0]
        await waitUntil("start called") { gate.started }
        await ws.stop(a.id)
        gate.release()
        _ = await launching.value
        #expect(a.status == .exited(status: 0, message: "Stopped"))
        #expect(await gate.terminated)
    }

    @Test func queuedSendsKeepOrderWhenSendArrivesDuringDrain() async {
        let gate = SendGate()
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(),
                           locate: fakeClaude, makeTransport: { _ in gate })
        let launching = Task { await ws.newSession(name: "A") }
        await waitUntil("session added") { ws.sessions.count == 1 }
        let a = ws.sessions[0]
        await ws.send("1", to: a.id)
        await ws.send("2", to: a.id)
        await waitUntil("first delivery suspended") { gate.blocked }
        await ws.send("3", to: a.id)
        gate.release()
        _ = await launching.value
        #expect(await gate.texts == ["1", "2", "3"])
    }

    @Test func stopDuringDrainDropsRestSilently() async {
        let gate = SendGate()
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(),
                           locate: fakeClaude, makeTransport: { _ in gate })
        let launching = Task { await ws.newSession(name: "A") }
        await waitUntil("session added") { ws.sessions.count == 1 }
        let a = ws.sessions[0]
        await ws.send("1", to: a.id)
        await ws.send("2", to: a.id)
        await waitUntil("first delivery suspended") { gate.blocked }
        await ws.stop(a.id)
        gate.release()
        _ = await launching.value
        #expect(await gate.texts == ["1"])
        let notices = a.transcript.blocks.filter { if case .notice(_, .error, _) = $0 { return true } else { return false } }
        #expect(notices.isEmpty)
        #expect(a.status == .exited(status: 0, message: "Stopped"))
    }

    // MARK: Control API (Plan 3)

    /// The request id of the last control message of the wanted kind, once the workspace has sent it.
    private func controlID(_ h: Harness, _ index: Int = 0, where match: (ControlSubtype) -> Bool) async -> String? {
        for _ in 0..<500_000 {
            for m in await h.transports[index].sent {
                if case .control(let rid, let sub) = m, match(sub) { return rid }
            }
            await Task.yield()
        }
        Issue.record("control request was never sent")
        return nil
    }

    private func noticeTexts(_ s: Session, _ kind: NoticeKind) -> [String] {
        s.transcript.blocks.compactMap { if case .notice(_, kind, let t) = $0 { return t } else { return nil } }
    }

    private func questionRequest(_ rid: String) -> InboundMessage {
        .controlRequest(ControlRequest(requestID: rid, kind: .canUseTool(
            toolName: "AskUserQuestion", input: questionInput, description: nil, toolUseID: "tuq", suggestions: [])))
    }

    private var questionInput: JSONValue {
        .object(["questions": .array([
            .object(["question": .string("Which language?"), "header": .string("Lang"), "multiSelect": .bool(false),
                     "options": .array([.object(["label": .string("Swift"), "description": .string("s")])])]),
            .object(["question": .string("Which toolchains?"), "header": .string("Tools"), "multiSelect": .bool(true),
                     "options": .array([.object(["label": .string("pytest"), "description": .string("p")]),
                                        .object(["label": .string("mypy"), "description": .string("m")])])]),
        ])])
    }

    private var planInput: JSONValue {
        .object(["plan": .string("Do it"), "planFilePath": .string("/tmp/p.md")])
    }

    private func planRequest(_ rid: String) -> InboundMessage {
        .controlRequest(ControlRequest(requestID: rid, kind: .canUseTool(
            toolName: "ExitPlanMode", input: planInput, description: nil, toolUseID: "tup", suggestions: [])))
    }

    @Test func setModelSendsControlAndUpdates() async throws {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.setModel("opus", for: a.id)
        let rid = try #require(await controlID(h) { $0 == .setModel("opus") })
        await h.transports[0].emit(.controlResponse(requestID: rid, result: .success(.object(["model": .string("claude-opus-5-5")]))))
        await waitUntil("model") { a.model == "claude-opus-5-5" }
        #expect(noticeTexts(a, .modelChanged) == ["Model: claude-opus-5-5"])
        // An unknown request id is ignored.
        await h.transports[0].emit(.controlResponse(requestID: "stranger", result: .success(.object(["model": .string("x")]))))
        // Error path.
        await ws.setModel("nope", for: a.id)
        let rid2 = try #require(await controlID(h) { $0 == .setModel("nope") })
        await h.transports[0].emit(.controlResponse(requestID: rid2, result: .error(message: "Model 'nope' not found", code: "not_found")))
        await waitUntil("error notice") { !self.noticeTexts(a, .error).isEmpty }
        #expect(noticeTexts(a, .error) == ["Model 'nope' not found"])
        #expect(a.model == "claude-opus-5-5")
    }

    @Test func setModeSendsControl() async throws {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.setPermissionMode(.plan, for: a.id)
        #expect(await controlID(h) { $0 == .setPermissionMode("plan") } != nil)
        await h.transports[0].emit(.statusChanged(permissionMode: "plan"))
        await waitUntil("mode") { a.permissionMode == "plan" }
        #expect(noticeTexts(a, .modeChanged) == ["Mode: Plan"])
        #expect(PermissionMode.allCases.map(\.displayName) == ["Default", "Accept edits", "Plan", "Auto", "Don't ask"])
    }

    @Test func answerQuestionSendsAnswers() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(questionRequest("q1"))
        await waitUntil("question") { a.status == .awaitingPermission }
        await ws.answerQuestion(session: a.id, requestID: "q1",
                                answers: ["Which language?": "Swift", "Which toolchains?": "pytest, mypy"])
        var expected = questionInput.objectValue!
        expected["answers"] = .object(["Which language?": .string("Swift"), "Which toolchains?": .string("pytest, mypy")])
        #expect(await h.transports[0].sent.last == .allow(requestID: "q1", updatedInput: .object(expected), updatedPermissions: nil))
        #expect(a.status == .working)
        let answered = a.transcript.blocks.contains { if case .question(let q) = $0 { return q.state == .answered } else { return false } }
        #expect(answered)
        // A second answer sends nothing.
        let count = await h.transports[0].sent.count
        await ws.answerQuestion(session: a.id, requestID: "q1", answers: [:])
        #expect(await h.transports[0].sent.count == count)
    }

    @Test func approvePlanSetsMode() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(planRequest("p1"))
        await waitUntil("plan") { a.status == .awaitingPermission }
        await ws.answerPlan(session: a.id, requestID: "p1", approve: true, modeAfter: .acceptEdits, feedback: nil)
        let perm = JSONValue.object(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")])
        #expect(await h.transports[0].sent.last == .allow(requestID: "p1", updatedInput: planInput, updatedPermissions: [perm]))
        #expect(a.status == .working)
    }

    @Test func sendBackPlanDenies() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(planRequest("p1"))
        await h.transports[0].emit(planRequest("p2"))
        await waitUntil("plans") { a.transcript.blocks.filter { if case .plan = $0 { return true } else { return false } }.count == 2 }
        await ws.answerPlan(session: a.id, requestID: "p1", approve: false, modeAfter: .default_, feedback: "use async")
        #expect(await h.transports[0].sent.last == .deny(requestID: "p1", message: "Revise: use async"))
        await ws.answerPlan(session: a.id, requestID: "p2", approve: false, modeAfter: .default_, feedback: "  ")
        #expect(await h.transports[0].sent.last == .deny(requestID: "p2", message: "Revise the plan."))
    }

    @Test func clearAdoptsNewSessionID() async {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "A")
        #expect(a.cliSessionID == a.id.uuidString.lowercased())
        func init_(_ sid: String) -> InboundMessage {
            .systemInit(SystemInit(model: "m", permissionMode: "default", sessionID: sid, tools: [], slashCommands: []))
        }
        await h1.transports[0].emit(.conversationReset(newSessionID: "x"))
        await h1.transports[0].emit(.userEcho(text: "sync", imageCount: 0, uuid: nil, isReplay: false))
        await waitUntil("reset") { !self.noticeTexts(a, .reset).isEmpty }
        // The reset's own id is not the transcript's id; only the init that follows names it.
        #expect(a.cliSessionID == a.id.uuidString.lowercased())
        await h1.transports[0].emit(init_("abc"))
        await waitUntil("adopt") { a.cliSessionID == "abc" }
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        let b = ws2.sessions[0]
        #expect(b.cliSessionID == "abc")
        await ws2.send("again", to: b.id)
        #expect(h2.configs.map(\.resumeID) == ["abc"])
        #expect(h2.configs.map(\.resume) == [true])
        let args = h2.configs[0].arguments()
        #expect(args.firstIndex(of: "--resume").map { args[$0 + 1] } == "abc")
    }

    @Test func initializeAfterStart() async throws {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        guard case .control(let rid, .initialize)? = await h.transports[0].sent.first else {
            Issue.record("initialize was not first"); return
        }
        await h.transports[0].emit(.systemInit(SystemInit(model: "m", permissionMode: "default", sessionID: "s", tools: [],
                                                          slashCommands: [], terminalSlashCommands: ["doctor"])))
        let cmds = JSONValue.array([
            .object(["name": .string("compact"), "description": .string("Compact"), "argumentHint": .string("[focus]")]),
            .object(["name": .string("doctor"), "description": .string("Diagnose"), "argumentHint": .string("")]),
        ])
        await h.transports[0].emit(.controlResponse(requestID: rid, result: .success(.object(["commands": cmds]))))
        await waitUntil("commands") { !a.slashCommands.isEmpty }
        #expect(a.slashCommands == [SlashCommandInfo(name: "compact", description: "Compact", argumentHint: "[focus]"),
            SlashCommandInfo(name: "fork", description: "Start a new session from this conversation", argumentHint: "[name]"),
            SlashCommandInfo(name: "theme", description: "Make a theme with Claude in a new session", argumentHint: "[description]")])
        #expect(a.terminalOnlyCommands == ["doctor"])
        await h.transports[0].emit(.commandsChanged([
            SlashCommandInfo(name: "cost", description: "Cost", argumentHint: nil),
            SlashCommandInfo(name: "doctor", description: "Diagnose", argumentHint: nil),
        ]))
        await waitUntil("replaced") { a.slashCommands.map(\.name) == ["cost", "fork", "theme"] }
    }

    @Test func helpListsCommandsLocally() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(.commandsChanged([
            SlashCommandInfo(name: "compact", description: "Compact the conversation", argumentHint: nil),
        ]))
        await waitUntil("commands") { !a.slashCommands.isEmpty }
        await ws.send("/help", to: a.id)
        #expect(await h.transports[0].sentAfterInitialize.isEmpty)
        let notes = a.transcript.blocks.compactMap { b -> String? in
            if case .notice(_, .commandOutput, let t) = b { return t } else { return nil }
        }
        #expect(notes.count == 1)
        #expect(notes.first?.contains("compact") == true)
        #expect(!a.transcript.blocks.contains { if case .user = $0 { return true } else { return false } })
    }

    @Test func modelAndPlanCommandsUseControlRequests() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.send("/model sonnet", to: a.id)
        await ws.send("/plan", to: a.id)
        let sent = await h.transports[0].sentAfterInitialize
        #expect(sent.count == 2)
        guard sent.count == 2, case .control(_, .setModel("sonnet")) = sent[0],
              case .control(_, .setPermissionMode("plan")) = sent[1] else { Issue.record("wrong sends: \(sent)"); return }
        #expect(!a.transcript.blocks.contains { if case .user = $0 { return true } else { return false } })
    }

    @Test func bareModelRequestsPickerAndSendsNothing() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        #expect(a.requestModelPicker == false)
        await ws.send("/model", to: a.id)
        #expect(a.requestModelPicker)
        #expect(await h.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func passThroughCommandIsSentAsUserMessage() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.send("/compact keep it short", to: a.id)
        guard case .user(let text, _, _)? = await h.transports[0].sentAfterInitialize.first else { Issue.record("not sent"); return }
        #expect(text == [.text("/compact keep it short")])
    }

    @Test func planOnDormantSessionLaunchesAndAppliesMode() async throws {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "A")
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        let b = try #require(ws2.sessions.first { $0.id == a.id })
        #expect(b.status == .dormant)
        await ws2.send("/plan", to: b.id)
        await waitUntil("launch") { !h2.transports.isEmpty }
        let sent = await h2.transports[0].sentAfterInitialize
        guard sent.count == 1, case .control(_, .setPermissionMode("plan")) = sent[0] else { Issue.record("wrong sends: \(sent)"); return }
    }

    @Test func modelOnDormantSessionLaunchesAndAppliesModel() async throws {
        let root = dirs.make(); let support = dirs.make()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: Harness())
        let a = await ws1.newSession(name: "A")
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        let b = try #require(ws2.sessions.first { $0.id == a.id })
        await ws2.send("/model opus", to: b.id)
        let sent = await h2.transports[0].sentAfterInitialize
        guard sent.count == 1, case .control(_, .setModel("opus")) = sent[0] else { Issue.record("wrong sends: \(sent)"); return }
    }

    @Test func commandWithImagesIsSentNotRouted() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await ws.send(OutgoingMessage(text: "/help", images: [ImageAttachment(mediaType: "image/png", base64: "AAAA", byteCount: 3)], priority: nil), to: a.id)
        guard case .user(let c, _, _)? = await h.transports[0].sentAfterInitialize.first else { Issue.record("not sent"); return }
        #expect(c == [.image(mediaType: "image/png", base64: "AAAA"), .text("/help")])
    }

    @Test func busySendUsesPriority() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        await h.transports[0].emit(.assistantBlock(messageID: "m", block: .text("hi")))
        await waitUntil("working") { a.status == .working }
        await ws.send(OutgoingMessage(text: "x", images: [], priority: .later), to: a.id)
        guard case .user(let c, let uuid, let p)? = await h.transports[0].sent.last else { Issue.record("not sent"); return }
        #expect(c == [.text("x")]); #expect(p == .later)
        guard case .user(let id, "x", _, let state)? = a.transcript.blocks.last else { Issue.record("no block"); return }
        #expect(id == uuid); #expect(state == .queued(.later))
        #expect(a.queued == [uuid])
    }

    @Test func imagesEncodeAsContent() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let img = ImageAttachment(mediaType: "image/png", base64: "AAAA", pixelSize: (2, 2), byteCount: 3)
        await ws.send(OutgoingMessage(text: "look", images: [img], priority: nil), to: a.id)
        guard case .user(let c, _, _)? = await h.transports[0].sent.last else { Issue.record("not sent"); return }
        #expect(c == [.image(mediaType: "image/png", base64: "AAAA"), .text("look")])
        guard case .user(_, _, let n, _)? = a.transcript.blocks.last else { Issue.record("no block"); return }
        #expect(n == 1)
    }

    @Test func plan1SessionsFileStillLoads() async throws {
        let root = dirs.make(); let support = dirs.make()
        let h1 = Harness()
        let ws1 = makeWorkspace(root: root, appSupport: support, harness: h1)
        let a = await ws1.newSession(name: "Old")
        let url = ProjectLedger.storeURL(projectRoot: root, appSupport: support).deletingLastPathComponent()
            .appendingPathComponent("sessions.json")
        let plan1 = "[{\"id\":\"\(a.id.uuidString)\",\"name\":\"Old\",\"colorIndex\":0,\"hasConversation\":true}]"
        try plan1.write(to: url, atomically: true, encoding: .utf8)
        let h2 = Harness()
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: h2)
        await ws2.restore()
        let b = try #require(ws2.sessions.first)
        #expect(b.name == "Old" && b.hasConversation)
        #expect(b.cliSessionID == a.id.uuidString.lowercased())
        #expect(b.model == nil && b.permissionMode == nil)
        #expect(ws2.errors.isEmpty)
    }

    @Test func renameWorks() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        ws.rename(a.id, to: "Renamed")
        #expect(a.name == "Renamed")
    }

    @Test func renamePersists() async {
        let h = Harness()
        let support = dirs.make()
        let root = dirs.make()
        let ws = makeWorkspace(root: root, appSupport: support, harness: h)
        let a = await ws.newSession(name: "A")
        ws.rename(a.id, to: "  Fresh name ")
        #expect(a.name == "Fresh name")
        let ws2 = makeWorkspace(root: root, appSupport: support, harness: Harness())
        await ws2.restore()
        #expect(ws2.sessions.first?.name == "Fresh name")
    }

    @Test func renameToBlankIsIgnored() async {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        ws.rename(a.id, to: "   ")
        #expect(a.name == "A")
    }

    @Test func settingsSaveAppliesToNextLaunch() async throws {
        let seen = Box<[String?]>([])
        let support = dirs.make()
        let ws = makeWorkspace(root: dirs.make(), appSupport: support, harness: Harness(),
                               locate: { seen.value.append($0); return URL(fileURLWithPath: "/fake/claude") })
        _ = await ws.newSession(name: "A")
        #expect(seen.value == [nil])
        try ws.updateSettings(AlloySettings(claudePath: "/custom/claude"))
        #expect(AlloySettings.load(appSupport: support).claudePath == "/custom/claude")
        _ = await ws.newSession(name: "B")
        #expect(seen.value == [nil, "/custom/claude"])
        try ws.updateSettings(AlloySettings())
        _ = await ws.newSession(name: "C")
        #expect(seen.value == [nil, "/custom/claude", nil])
    }

    @Test func settingsChangedDuringLocateDoesNotCacheStalePath() async throws {
        let seen = Box<[String?]>([])
        let gate = DispatchSemaphore(value: 0)
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: Harness(),
                               locate: { path in
                                   seen.value.append(path)
                                   if seen.value.count == 1 { gate.wait() }
                                   return URL(fileURLWithPath: path ?? "/auto/claude")
                               })
        let first = Task { await ws.newSession(name: "A") }
        await waitUntil("locate entered") { seen.value.count == 1 }
        try ws.updateSettings(AlloySettings(claudePath: "/new/claude"))
        gate.signal()
        _ = await first.value
        _ = await ws.newSession(name: "B")
        // The stale result for the old (nil) path was not cached, so B located again with the new path.
        #expect(seen.value == [nil, "/new/claude"])
    }

    @Test func controlCallsDoNothingWhileShuttingDown() async {
        let gate = Gate()
        let inner = ScriptedTransport()
        let ws = Workspace(projectRoot: dirs.make(), appSupport: dirs.make(), settings: AlloySettings(),
                           locate: fakeClaude, makeTransport: { _ in StopGatedTransport(inner: inner, gate: gate) })
        let a = await ws.newSession(name: "A")
        await inner.emit(questionRequest("q1"))
        await inner.emit(planRequest("p1"))
        await waitUntil("prompts") { a.transcript.blocks.filter { if case .question = $0 { return true } else if case .plan = $0 { return true } else { return false } }.count == 2 }
        let before = await inner.sent.count
        let stopping = Task { await ws.stopAll() }
        await waitUntil("shutdown began") { ws.isShuttingDown }
        await ws.setModel("opus", for: a.id)
        await ws.setPermissionMode(.plan, for: a.id)
        await ws.answerQuestion(session: a.id, requestID: "q1", answers: ["Which language?": "Swift"])
        await ws.answerPlan(session: a.id, requestID: "p1", approve: true, modeAfter: .default_, feedback: nil)
        #expect(await inner.sent.count == before)
        await gate.open()
        await stopping.value
        #expect(await inner.sent.count == before)
    }

    @Test func controlResponseForAnotherSessionIsIgnored() async throws {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        let b = await ws.newSession(name: "B")
        await ws.setModel("opus", for: a.id)
        let rid = try #require(await controlID(h, 0) { $0 == .setModel("opus") })
        let reply = InboundMessage.controlResponse(requestID: rid, result: .success(.object(["model": .string("claude-opus-5-5")])))
        await h.transports[1].emit(reply)
        await h.transports[1].emit(.statusChanged(permissionMode: "plan"))
        await waitUntil("sync") { b.permissionMode == "plan" }
        #expect(b.model == nil)
        #expect(noticeTexts(b, .modelChanged).isEmpty)
        await h.transports[0].emit(reply)
        await waitUntil("model") { a.model == "claude-opus-5-5" }
    }

    @Test func initializeResponseSetsTheModeBadgeBeforeTheFirstTurn() async throws {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        let a = await ws.newSession(name: "A")
        #expect(a.permissionMode == nil)
        let rid = try #require(await controlID(h) { $0 == .initialize })
        let body = JSONValue.object(["commands": .array([]), "current_permission_mode": .string("plan")])
        await h.transports[0].emit(.controlResponse(requestID: rid, result: .success(body)))
        await waitUntil("mode") { a.permissionMode == "plan" }
    }

    @Test func initializeErrorIsReported() async throws {
        let h = Harness()
        let ws = makeWorkspace(root: dirs.make(), appSupport: dirs.make(), harness: h)
        _ = await ws.newSession(name: "A")
        let rid = try #require(await controlID(h) { $0 == .initialize })
        await h.transports[0].emit(.controlResponse(requestID: rid, result: .error(message: "boom", code: nil)))
        await waitUntil("reported") { !ws.errors.isEmpty }
        #expect(ws.errors[0].contains("boom"))
    }
}

/// Wraps a `ScriptedTransport`; `stopAndWait` suspends on the gate, so shutdown stays in progress.
private final class StopGatedTransport: SessionTransport, @unchecked Sendable {
    let inner: ScriptedTransport; let gate: Gate
    init(inner: ScriptedTransport, gate: Gate) { self.inner = inner; self.gate = gate }
    func start() async throws -> AsyncStream<ProcessEvent> { try await inner.start() }
    func send(_ message: OutboundMessage) async throws { try await inner.send(message) }
    func terminate() async { await inner.terminate() }
    func stopAndWait(timeout: Duration) async { await gate.wait(); await inner.stopAndWait(timeout: timeout) }
}

/// A transport whose first `send` waits until the test releases it.
private actor SendGate: SessionTransport {
    private let flag = Flag()
    private var continuation: CheckedContinuation<Void, Never>?
    private var first = true
    private(set) var texts: [String] = []
    private let stream = AsyncStream<ProcessEvent>.makeStream()
    nonisolated var blocked: Bool { flag.value }
    func start() async throws -> AsyncStream<ProcessEvent> { stream.stream }
    func send(_ message: OutboundMessage) async throws {
        if case .user(let c, _, _) = message, case .text(let t)? = c.first { texts.append(t) }
        if first, case .user = message {
            first = false
            flag.set()
            await withCheckedContinuation { continuation = $0 }
        }
    }
    nonisolated func release() { Task { await resume() } }
    private func resume() { continuation?.resume(); continuation = nil }
    func exit() { stream.continuation.yield(.exited(status: 1, stderrTail: "")); stream.continuation.finish() }
    func terminate() async {}
}

/// A transport whose first `set_permission_mode` waits until the test releases it.
private actor ModeGate: SessionTransport {
    private let flag = Flag()
    private var continuation: CheckedContinuation<Void, Never>?
    private var first = true
    private(set) var texts: [String] = []
    private let stream = AsyncStream<ProcessEvent>.makeStream()
    nonisolated var blocked: Bool { flag.value }
    func start() async throws -> AsyncStream<ProcessEvent> { stream.stream }
    func send(_ message: OutboundMessage) async throws {
        if case .user(let c, _, _) = message, case .text(let t)? = c.first { texts.append(t) }
        if first, case .control(_, .setPermissionMode) = message {
            first = false
            flag.set()
            await withCheckedContinuation { continuation = $0 }
        }
    }
    nonisolated func release() { Task { await resume() } }
    private func resume() { continuation?.resume(); continuation = nil }
    func terminate() async {}
}

/// A transport whose `start` waits until the test releases it.
private actor StartGate: SessionTransport {
    private let flag = Flag()
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var terminated = false
    nonisolated var started: Bool { flag.value }
    private let stream = AsyncStream<ProcessEvent>.makeStream()
    func start() async throws -> AsyncStream<ProcessEvent> {
        flag.set()
        await withCheckedContinuation { continuation = $0 }
        return stream.stream
    }
    nonisolated func release() { Task { await resume() } }
    private func resume() { continuation?.resume(); continuation = nil }
    func send(_ message: OutboundMessage) async throws {}
    func terminate() async { terminated = true }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.withLock { v = true } }
    var value: Bool { lock.withLock { v } }
}

@Suite struct DiffSliceTests {
    private func lines(_ n: Int, changed: Set<Int>, edit: UUID) -> [DiffLine] {
        (0..<n).map { changed.contains($0) ? .added(text: "l\($0)", line: $0 + 1, edit: edit, runs: []) : .context(text: "l\($0)", line: $0 + 1) }
    }
    private func numbers(_ ls: [DiffLine]) -> [Int] {
        ls.map { if case .context(_, let n) = $0 { n } else if case .added(_, let n, _, _) = $0 { n } else { -1 } }
    }

    @Test func contextIsClampedAtFileStartAndEnd() {
        let e = UUID()
        #expect(numbers(DiffSlice.visible(lines(10, changed: [0], edit: e), editIDs: [e])) == [1, 2, 3])
        #expect(numbers(DiffSlice.visible(lines(10, changed: [9], edit: e), editIDs: [e])) == [8, 9, 10])
    }

    @Test func overlappingContextsMergeWithoutDuplicates() {
        let e = UUID()
        let out = DiffSlice.visible(lines(12, changed: [3, 5], edit: e), editIDs: [e])
        #expect(numbers(out) == [2, 3, 4, 5, 6, 7, 8])
    }

    /// Two edits in one region: the diff lists the first edit's inserted lines before the second edit's. The second
    /// edit's card must not borrow the first edit's added lines as "context".
    @Test func otherEditsChangedLinesNeverAppearAsContext() {
        let mine = UUID(), other = UUID()
        var ls: [DiffLine] = [.context(text: "a", line: 39), .context(text: "b", line: 40),
                              .removed(text: "func old()", edit: mine), .removed(text: "guard", edit: mine)]
        for k in 0..<6 { ls.append(.added(text: "other\(k)", line: 41 + k, edit: other, runs: [])) }
        ls.append(.added(text: "func new()", line: 47, edit: mine, runs: []))
        ls.append(.context(text: "z", line: 48))
        let out = DiffSlice.visible(ls, editIDs: [mine])
        for line in out {
            if case .added(_, _, let e, _) = line { #expect(e == mine) }
            if case .removed(_, let e) = line { #expect(e == mine) }
        }
        #expect(out.count == 6)  // a, b, 2 removed, new, z
    }

    @Test func otherEditsAreContextOnlyAndAbsentWhenNothingMatches() {
        let e = UUID(), other = UUID()
        #expect(DiffSlice.visible(lines(10, changed: [4], edit: other), editIDs: [e]).isEmpty)
        #expect(DiffSlice.visible([], editIDs: [e]).isEmpty)
    }
}
