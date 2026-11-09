import AlloyCore
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyCore

private final class FHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [ScriptedTransport] = []
    private var _configs: [LaunchConfiguration] = []
    private var _gate: DispatchSemaphore?
    private var _armed = false
    var transports: [ScriptedTransport] { lock.withLock { _transports } }
    var configs: [LaunchConfiguration] { lock.withLock { _configs } }
    /// The next executable lookup blocks until `release()`; lets a test hold a launch in its starting window.
    /// `release()` may come before the lookup reaches the gate: a semaphore remembers the signal.
    func hold() { lock.withLock { _gate = DispatchSemaphore(value: 0); _armed = true } }
    func release() { lock.withLock { _gate }?.signal() }
    func waitIfHeld() {
        let g = lock.withLock { () -> DispatchSemaphore? in defer { _armed = false }; return _armed ? _gate : nil }
        g?.wait()
    }
    var factory: TransportFactory {
        { [self] cfg in
            let t = ScriptedTransport()
            lock.withLock { _transports.append(t); _configs.append(cfg) }
            return t
        }
    }
}

/// The text parts of the n-th user message a transport got after `initialize`.
private func userTexts(_ t: ScriptedTransport, at index: Int = 0) async -> [String] {
    let users = await t.sentAfterInitialize.compactMap { m -> [UserContent]? in
        if case .user(let c, _, _) = m { c } else { nil }
    }
    guard users.indices.contains(index) else { return [] }
    return users[index].compactMap { if case .text(let s) = $0 { s } else { nil } }
}


@Suite final class ForkTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-fk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let r = u.resolvingSymlinksInPath()
        dirs.append(r)
        return r
    }

    @MainActor
    private func workspace(_ h: FHarness, settings: AlloySettings = AlloySettings(),
                           root: URL? = nil, support: URL? = nil, home: URL? = nil) -> Workspace {
        Workspace(projectRoot: root ?? tempDir(), appSupport: support ?? tempDir(), settings: settings,
                  locate: { _ in h.waitIfHeld(); return URL(fileURLWithPath: "/fake/claude") },
                  makeTransport: h.factory, now: Date.init, home: home ?? tempDir())
    }

    /// The real transcript fixture, where the CLI would have written it for `cliSessionID`.
    private func installTranscript(home: URL, root: URL, cliSessionID: String) throws {
        let url = TranscriptFile.url(cliSessionID: cliSessionID, projectRoot: root, home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TranscriptFileTests.sample().write(to: url)
    }

    @MainActor private func kinds(_ s: Session) -> [String] {
        s.transcript.blocks.map { b -> String in
            switch b { case .user: "user"; case .assistantText: "text"; case .tool: "tool"; case .thinking: "thinking"; default: "other" }
        }
    }

    private let result = InboundMessage.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                          outputTokens: 0, sessionID: "s", terminalReason: nil))

    /// A session with a finished turn: idle, with a conversation.
    @MainActor
    private func talked(_ ws: Workspace, _ h: FHarness, name: String = "A") async -> Session {
        let s = await ws.newSession(name: name)
        await h.transports[h.transports.count - 1].emit(result)
        await waitUntil("idle with conversation") { s.status == .idle && s.hasConversation }
        return s
    }

    @MainActor private func hasNotice(_ s: Session, _ text: String) -> Bool {
        s.transcript.blocks.contains { if case .notice(_, _, let t) = $0 { t == text } else { false } }
    }

    @Test @MainActor func forkLaunchesWithResumeAndForkSession() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let source = await talked(ws, h)
        let fork = try #require(await ws.fork(source.id, name: nil))
        await ws.settle()
        #expect(fork.id != source.id)
        #expect(fork.name == "A (fork)")
        #expect(fork.status == .idle)
        #expect(ws.sessions.map(\.id) == [source.id, fork.id])
        let c = try #require(h.configs.last)
        #expect(c.resume && c.forkSession && c.resumeID == source.cliSessionID)
        let args = c.arguments()
        let i = try #require(args.firstIndex(of: "--resume"))
        #expect(args[i + 1] == source.cliSessionID)
        #expect(args.contains("--fork-session"))
        // Nothing is sent until the user writes.
        #expect(await h.transports[1].sentAfterInitialize.isEmpty)
        // The fork's own conversation id comes with its first init.
        await h.transports[1].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("adopted") { fork.cliSessionID == "129f2805-bc01-450e-8564-7881aede1a69" }
        #expect(fork.forkSource == nil)
        #expect(source.cliSessionID == source.id.uuidString.lowercased())
        // Persisted: a second workspace over the same store restores both.
        let data = try Data(contentsOf: ws.storeDirectory.appendingPathComponent("sessions.json"))
        #expect(String(decoding: data, as: UTF8.self).contains(fork.id.uuidString))
        await ws.stopAll()
    }

    @Test @MainActor func forkNamedByArgument() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let source = await talked(ws, h)
        await ws.send("/fork  try again ", to: source.id)
        await ws.settle()
        #expect(ws.sessions.count == 2)
        #expect(ws.sessions[1].name == "try again")
        await ws.stopAll()
    }

    @Test @MainActor func forkCopiesReadsAndTold() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let source = await talked(ws, h)
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 10)
        ws.compactionGeneration[source.id] = 3
        // An entry from before the source's last compaction is not in its context any more: it is not copied.
        ws.readIndex.record(ReadEntry(session: source.id, path: "old.swift", lines: nil, stamp: stamp,
                                      date: Date(timeIntervalSince1970: 1), generation: 2))
        ws.readIndex.record(ReadEntry(session: source.id, path: "a.swift", lines: 1...5, stamp: stamp,
                                      date: Date(timeIntervalSince1970: 2), generation: 3))
        let entry = ToldEntry(stamp: stamp, note: UUID(), generation: 3)
        ws.told[source.id] = ["a.swift": entry, "old.swift": ToldEntry(stamp: stamp, note: nil, generation: 2)]
        let fork = try #require(await ws.fork(source.id, name: "b"))
        let copied = ws.readIndex.entries(of: fork.id)
        #expect(copied.count == 1 && copied[0].path == "a.swift" && copied[0].generation == 0 && copied[0].lines == 1...5)
        #expect(ws.readIndex.entries(of: source.id).count == 2)
        #expect(ws.told[fork.id] == ["a.swift": ToldEntry(stamp: stamp, note: entry.note, generation: 0)])
        #expect(ws.told[source.id]?.count == 2)
        await ws.settle()
        await ws.stopAll()
    }

    /// A forked source that read `a.swift` before the fork.
    @MainActor
    private func forkAfterRead(_ h: FHarness) async throws -> (ws: Workspace, source: Session, fork: Session) {
        let root = tempDir()
        try "one\ntwo\n".write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        let ws = workspace(h, root: root)
        let source = await talked(ws, h)
        let stamp = try #require(FileStamp.read(root.appendingPathComponent("a.swift").path))
        ws.readIndex.record(ReadEntry(session: source.id, path: "a.swift", lines: nil, stamp: stamp, date: Date(), generation: 0))
        let fork = try #require(await ws.fork(source.id, name: nil))
        await ws.settle()
        return (ws, source, fork)
    }

    @Test @MainActor func sourceIsNeverToldItsOwnReadsAsTheForks() async throws {
        let h = FHarness()
        let (ws, source, _) = try await forkAfterRead(h)
        await ws.send("what is in @a.swift ?", to: source.id)
        await ws.settle()
        let parts = await userTexts(h.transports[0])
        #expect(parts == ["what is in @a.swift ?"])
        #expect(!parts.contains { $0.contains("(fork)") || $0.contains(AlreadyRead.header) })
        await ws.stopAll()
    }

    @Test @MainActor func forksFirstMessageHasNoLinesForFilesItAlreadyHas() async throws {
        let h = FHarness()
        let (ws, _, fork) = try await forkAfterRead(h)
        await ws.send("what is in @a.swift ?", to: fork.id)
        await ws.settle()
        #expect(await userTexts(h.transports[1]) == ["what is in @a.swift ?"])
        await ws.stopAll()
    }

    @Test @MainActor func forkOfFreshSessionIsRefused() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let fresh = await ws.newSession(name: "A")
        #expect(!fresh.hasConversation)
        let fork = await ws.fork(fresh.id, name: nil)
        #expect(fork == nil)
        #expect(ws.sessions.count == 1 && h.transports.count == 1)
        #expect(hasNotice(fresh, "Nothing to fork yet"))
        await ws.stopAll()
    }

    @Test @MainActor func forkWaitsForIdle() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let source = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: Fixture.lines("fork-init"))   // an init: the turn is running
        await waitUntil("working") { source.status == .working && source.hasConversation }
        let task = Task { @MainActor in await ws.fork(source.id, name: nil) }
        await waitUntil("notice") { self.hasNotice(source, "Forking when idle\u{2026}") }
        for _ in 0..<50 { await Task.yield() }
        #expect(ws.sessions.count == 1 && h.transports.count == 1)
        await h.transports[0].emit(result)
        let fork = try #require(await task.value)
        #expect(ws.sessions.count == 2 && fork.status == .idle)
        #expect(h.configs.last?.forkSession == true)
        await ws.settle()
        await ws.stopAll()
    }

    @Test @MainActor func forkWaitingWhenSourceIsStoppedIsCancelled() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let source = await ws.newSession(name: "A")
        await h.transports[0].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("working") { source.status == .working }
        let task = Task { @MainActor in await ws.fork(source.id, name: nil) }
        await waitUntil("notice") { self.hasNotice(source, "Forking when idle\u{2026}") }
        await ws.stop(source.id)
        #expect(await task.value == nil)
        #expect(ws.sessions.count == 1 && h.transports.count == 1)
        #expect(hasNotice(source, "Fork cancelled"))
        await ws.stopAll()
    }

    @Test @MainActor func forkSelectsTheNewSessionAndInheritsMode() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let source = await ws.newSession(name: "A")
        await h.transports[0].emit(.systemInit(SystemInit(model: "m", permissionMode: "plan", sessionID: "s", tools: [], slashCommands: [])))
        await h.transports[0].emit(result)
        await waitUntil("idle") { source.status == .idle && source.permissionMode == "plan" }
        let fork = try #require(await ws.fork(source.id, name: nil))
        await ws.settle()
        #expect(ws.selectedSessionID == fork.id)
        // The CLI keeps the model on a fork but not the permission mode (probed), so Alloy sets it.
        let sent = await h.transports[1].sentAfterInitialize
        #expect(sent.contains { if case .control(_, .setPermissionMode("plan")) = $0 { true } else { false } })
        await ws.stopAll()
    }

    @Test @MainActor func freshForkReplaysTheSourcesHistory() async throws {
        let root = tempDir(), home = tempDir()
        let h = FHarness()
        let ws = workspace(h, root: root, home: home)
        let source = await talked(ws, h)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws.fork(source.id, name: nil))
        // Selecting the fork loads its history; nothing here asks for it.
        await waitUntil("history") { fork.transcript.blocks.count >= 7 }
        #expect(kinds(fork) == ["user", "tool", "thinking", "text", "user", "thinking", "text"])
        await ws.settle()
        await ws.stopAll()
    }

    @Test @MainActor func forkThatAlreadyTalkedStillReplaysTheSourceOnce() async throws {
        let root = tempDir(), home = tempDir()
        let h = FHarness()
        let ws = workspace(h, root: root, home: home)
        let source = await talked(ws, h)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws.fork(source.id, name: nil))
        await h.transports[1].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("adopted") { fork.cliSessionID == "129f2805-bc01-450e-8564-7881aede1a69" }
        await waitUntil("history") { fork.transcript.blocks.count >= 7 }
        // The fork's own file (not installed here) would repeat its first turn; the source's lines come once.
        #expect(kinds(fork).prefix(7) == ["user", "tool", "thinking", "text", "user", "thinking", "text"])
        #expect(!fork.transcript.blocks.contains { if case .notice(_, _, "No earlier history found") = $0 { true } else { false } })
        await ws.stopAll()
    }

    @Test @MainActor func restoredUnsentForkReplaysTheSourcesHistory() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await talked(ws1, h1)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws1.fork(source.id, name: nil))
        await ws1.settle()
        await ws1.stopAll()
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == fork.id })
        #expect(restored.status == .dormant && restored.forkSource == source.cliSessionID)
        await ws2.loadHistory(fork.id)
        #expect(kinds(restored) == ["user", "tool", "thinking", "text", "user", "thinking", "text"])
    }

    @Test @MainActor func restoredUnsentForkWakesWithForkSessionThenResumesPlainly() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await talked(ws1, h1)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws1.fork(source.id, name: nil))
        await ws1.settle()
        await ws1.stopAll()
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == fork.id })
        await ws2.wake(fork.id)
        let c = try #require(h2.configs.first)
        #expect(c.resume && c.forkSession && c.resumeID == source.cliSessionID)
        // The first init names the fork's own conversation; from then on a relaunch is a plain resume of it.
        await h2.transports[0].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("adopted") { restored.cliSessionID == "129f2805-bc01-450e-8564-7881aede1a69" }
        await h2.transports[0].emit(result)
        await waitUntil("idle") { restored.status == .idle }
        ws2.relaunchWhenIdle(fork.id)
        await ws2.settle()
        let again = try #require(h2.configs.last)
        #expect(h2.configs.count == 2 && again.resume && !again.forkSession)
        #expect(again.resumeID == "129f2805-bc01-450e-8564-7881aede1a69")
        await ws2.stopAll()
    }

    @Test @MainActor func restoredUnsentForkKeepsTheSourcesModeOnWake() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await ws1.newSession(name: "A")
        await h1.transports[0].emit(.systemInit(SystemInit(model: "m", permissionMode: "plan", sessionID: "s", tools: [], slashCommands: [])))
        await h1.transports[0].emit(result)
        await waitUntil("idle") { source.status == .idle && source.permissionMode == "plan" }
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws1.fork(source.id, name: nil))
        await ws1.settle()
        await ws1.stopAll()
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        await ws2.wake(fork.id)
        await ws2.settle()
        let sent = await h2.transports[0].sentAfterInitialize
        #expect(sent.contains { if case .control(_, .setPermissionMode("plan")) = $0 { true } else { false } })
        await ws2.stopAll()
    }

    // MARK: Fork point (--resume-session-at)

    private let samplePoint = "f77492c0-3a77-401e-b23f-56ffba3b23ac"

    /// Appends one more assistant record, as the source conversation moving on would.
    private func sourceMovesOn(home: URL, root: URL, cliSessionID: String) throws {
        let url = TranscriptFile.url(cliSessionID: cliSessionID, projectRoot: root, home: home)
        let line = "{\"type\":\"assistant\",\"uuid\":\"11111111-2222-3333-4444-555555555555\",\"isSidechain\":false,"
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"later turn\"}]}}\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
    }

    @Test @MainActor func forkRecordsTheSourcesLastMessageAndPassesItOnLaunch() async throws {
        let root = tempDir(), home = tempDir()
        let h = FHarness()
        let ws = workspace(h, root: root, home: home)
        let source = await talked(ws, h)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws.fork(source.id, name: nil))
        await ws.settle()
        #expect(fork.forkPoint == samplePoint)
        let c = try #require(h.configs.last)
        #expect(c.resumeSessionAt == samplePoint)
        let args = c.arguments()
        let i = try #require(args.firstIndex(of: "--resume-session-at"))
        #expect(args[i + 1] == samplePoint && args.contains("--fork-session"))
        // The fork's own conversation starts with its first init; the point is then spent.
        await h.transports[1].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("adopted") { fork.cliSessionID == "129f2805-bc01-450e-8564-7881aede1a69" }
        #expect(fork.forkPoint == nil)
        await ws.stopAll()
    }

    @Test @MainActor func unsentForkRelaunchKeepsTheForkPointWhileTheSourceMovesOn() async throws {
        let root = tempDir(), home = tempDir()
        let h = FHarness()
        let ws = workspace(h, root: root, home: home)
        let source = await talked(ws, h)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws.fork(source.id, name: nil))
        await ws.settle()
        try sourceMovesOn(home: home, root: root, cliSessionID: source.cliSessionID)
        try ws.updateSettings(AlloySettings(shareKnowledge: false))
        await ws.settle()
        let again = try #require(h.configs.dropFirst(2).last { $0.forkSession })
        #expect(again.forkSession && again.resumeID == source.cliSessionID && again.resumeSessionAt == samplePoint)
        #expect(fork.forkPoint == samplePoint)
        await ws.stopAll()
    }

    @Test @MainActor func restoredUnsentForkWakesAtItsPointAndShowsHistoryOnlyToIt() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await talked(ws1, h1)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws1.fork(source.id, name: nil))
        await ws1.settle()
        await ws1.stopAll()
        try sourceMovesOn(home: home, root: root, cliSessionID: source.cliSessionID)
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == fork.id })
        #expect(restored.forkPoint == samplePoint)
        await ws2.loadHistory(fork.id)
        #expect(kinds(restored) == ["user", "tool", "thinking", "text", "user", "thinking", "text"])
        await ws2.wake(fork.id)
        #expect(h2.configs.first?.resumeSessionAt == samplePoint)
        await ws2.stopAll()
    }

    @Test @MainActor func forkPointMissingFromTheSourceFallsBackWithANotice() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await talked(ws1, h1)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws1.fork(source.id, name: nil))
        await ws1.settle()
        await ws1.stopAll()
        // The CLI refuses an unknown uuid ("No message found with message.uuid of: ..."), so it must not be passed.
        let url = TranscriptFile.url(cliSessionID: source.cliSessionID, projectRoot: root, home: home)
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: samplePoint, with: "deadbeef-0000-0000-0000-000000000000")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == fork.id })
        await ws2.wake(fork.id)
        let c = try #require(h2.configs.first)
        #expect(c.forkSession && c.resumeSessionAt == nil)
        #expect(hasNotice(restored, "This fork's source has moved on; the fork now starts from its latest point."))
        await ws2.stopAll()
    }

    @Test @MainActor func cliRejectingTheForkPointFallsBackOnceToTheLatestPoint() async throws {
        let rejections = ["error: unknown option '--resume-session-at'", "No message found with message.uuid of: deadbeef",
                          "Error: unknown option", "bad --resume-session-at value"]
        for stderr in rejections {
            let root = tempDir(), home = tempDir(), support = tempDir()
            let h = FHarness()
            let ws = workspace(h, root: root, support: support, home: home)
            let source = await talked(ws, h)
            try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
            let fork = try #require(await ws.fork(source.id, name: nil))
            await ws.settle()
            #expect(h.configs.last?.resumeSessionAt == samplePoint)
            await h.transports[1].exit(status: 1, stderr: stderr)
            await waitUntil("retry \(stderr)") { h.configs.count == 3 }
            await ws.settle()
            let again = try #require(h.configs.last)
            #expect(again.forkSession && again.resumeID == source.cliSessionID && again.resumeSessionAt == nil)
            #expect(!again.arguments().contains("--resume-session-at"))
            #expect(fork.forkPoint == nil)
            #expect(hasNotice(fork, "Couldn't fork at the exact point; the fork starts from the source's latest point."))
            let saved = try String(contentsOf: ws.storeDirectory.appendingPathComponent("sessions.json"), encoding: .utf8)
            #expect(!saved.contains(samplePoint), "persisted: \(stderr)")
            // Exactly once: a second failure of the retry is not retried again.
            await h.transports[2].exit(status: 1, stderr: stderr)
            for _ in 0..<100 { await Task.yield() }
            await ws.settle()
            #expect(h.configs.count == 3, "\(stderr)")
            await ws.stopAll()
        }
    }

    @Test @MainActor func anUnrelatedExitOfAnUnsentForkIsNotRetried() async throws {
        let root = tempDir(), home = tempDir()
        let h = FHarness()
        let ws = workspace(h, root: root, home: home)
        let source = await talked(ws, h)
        try installTranscript(home: home, root: root, cliSessionID: source.cliSessionID)
        let fork = try #require(await ws.fork(source.id, name: nil))
        await ws.settle()
        await h.transports[1].exit(status: 1, stderr: "network unreachable")
        for _ in 0..<100 { await Task.yield() }
        await ws.settle()
        #expect(h.configs.count == 2 && fork.forkPoint == samplePoint)
        await ws.stopAll()
    }

    @Test @MainActor func missingForkSourceFailsTheLaunchAndTellsQueuedMessages() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await talked(ws1, h1)
        let fork = try #require(await ws1.fork(source.id, name: nil))
        await ws1.settle()
        await ws1.stopAll()
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == fork.id })
        await ws2.send("hello", to: fork.id)
        #expect(h2.transports.isEmpty)
        #expect(restored.status == .failedToLaunch("Fork source no longer exists"))
        #expect(restored.transcript.blocks.contains { if case .notice(_, .error, "Message not sent: Claude could not start") = $0 { true } else { false } })
    }

    @Test @MainActor func relaunchWaitsForADrainedTurnToFinish() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let a = await talked(ws1, h1)
        await ws1.settle()
        await ws1.stopAll()
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let s = try #require(ws2.sessions.first { $0.id == a.id })
        h2.hold()
        let sending = Task { @MainActor in await ws2.send("queued while dormant", to: s.id) }
        await waitUntil("starting") { s.status == .starting }
        try ws2.updateSettings(AlloySettings(shareKnowledge: false))
        h2.release()
        await sending.value
        await ws2.settle()
        for _ in 0..<50 { await Task.yield() }
        #expect(h2.transports.count == 1)
        let calls = await h2.transports[0].stopAndWaitCalls
        #expect(calls == 0)
        #expect((await h2.transports[0].sentAfterInitialize).count == 1)
        await h2.transports[0].emit(fixture: Fixture.lines("fork-init"))
        await h2.transports[0].emit(result)
        await waitUntil("relaunched") { h2.transports.count == 2 }
        await ws2.settle()
        await ws2.stopAll()
    }

    @Test @MainActor func unsentForkWhoseSourceIsGoneSaysSoInsteadOfLaunching() async throws {
        let root = tempDir(), home = tempDir(), support = tempDir()
        let h1 = FHarness()
        let ws1 = workspace(h1, root: root, support: support, home: home)
        let source = await talked(ws1, h1)
        let fork = try #require(await ws1.fork(source.id, name: nil))   // no transcript file was ever installed
        await ws1.settle()
        await ws1.stopAll()
        let h2 = FHarness()
        let ws2 = workspace(h2, root: root, support: support, home: home)
        await ws2.restore()
        let restored = try #require(ws2.sessions.first { $0.id == fork.id })
        await ws2.loadHistory(fork.id)
        #expect(hasNotice(restored, "Fork source no longer exists"))
        await ws2.wake(fork.id)
        #expect(h2.transports.isEmpty)
        #expect(restored.status == .failedToLaunch("Fork source no longer exists"))
    }

    @Test func slashForkRoutes() {
        #expect(SlashCommands.route("/fork") == .fork(name: nil))
        #expect(SlashCommands.route("  /fork  my name ") == .fork(name: "my name"))
        #expect(SlashCommands.route("/forked") == .passThrough)
    }

    @Test @MainActor func slashForkAppearsInSuggestions() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A")
        await h.transports[0].emit(.commandsChanged([SlashCommandInfo(name: "compact", description: "Compact", argumentHint: nil)]))
        await waitUntil("commands") { s.slashCommands.contains { $0.name == "compact" } }
        let fork = try #require(s.slashCommands.first { $0.name == "fork" })
        #expect(fork.description == "Start a new session from this conversation")
        await ws.stopAll()
    }

    @Test @MainActor func settingChangeAppliesAtIdleNotMidTurn() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let s = await ws.newSession(name: "A")
        #expect(h.configs[0].mcpConfigJSON != nil)
        await h.transports[0].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("working") { s.status == .working }
        try ws.updateSettings(AlloySettings(shareKnowledge: false))
        for _ in 0..<50 { await Task.yield() }
        // Mid-turn: nothing is cut off.
        #expect(h.transports.count == 1)
        #expect(await h.transports[0].terminated == false)
        #expect(s.status == .working)
        // Hold the relaunch in its starting window and send into it.
        h.hold()
        await h.transports[0].emit(result)
        await waitUntil("relaunch under way") { s.status == .starting }
        await ws.send("kept message", to: s.id)
        h.release()
        await ws.settle()
        #expect(await h.transports[0].terminated)
        #expect(h.transports.count == 2)
        let c = h.configs[1]
        #expect(c.resume && c.resumeID == s.cliSessionID && !c.forkSession)
        #expect(c.mcpConfigJSON == nil && c.appendSystemPrompt == nil && c.allowedTools.isEmpty)
        let sent = await h.transports[1].sentAfterInitialize
        #expect(sent.count == 1)
        if case .user(let content, _, _)? = sent.first {
            #expect(content.contains { if case .text("kept message") = $0 { true } else { false } })
        } else { Issue.record("queued message not delivered: \(sent)") }
        #expect(hasNotice(s, "Settings applied"))
        #expect(s.status == .idle)
        // The old process is waited for, not just signalled, before the new one resumes its conversation.
        #expect(await h.transports[0].stopAndWaitCalls == 1)
        await ws.stopAll()
    }

    @Test @MainActor func relaunchWaitsForADeliveredTurnToFinish() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let s = await talked(ws, h)
        // Delivered, but the CLI has not yet answered with an init: the session still reads as idle.
        await ws.send("do the thing", to: s.id)
        #expect(s.status == .idle)
        try ws.updateSettings(AlloySettings(shareKnowledge: false))
        await ws.settle()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.transports.count == 1)
        let calls = await h.transports[0].stopAndWaitCalls, gone = await h.transports[0].terminated
        #expect(calls == 0 && !gone)
        await h.transports[0].emit(fixture: Fixture.lines("fork-init"))
        await waitUntil("working") { s.status == .working }
        #expect(h.transports.count == 1)
        await h.transports[0].emit(result)
        await waitUntil("relaunched") { h.transports.count == 2 }
        await ws.settle()
        #expect(await h.transports[0].terminated)
        #expect(h.configs[1].mcpConfigJSON == nil)
        await ws.stopAll()
    }

    @Test @MainActor func settingChangeOnIdleSessionRelaunchesAtOnce() async throws {
        let h = FHarness()
        let ws = workspace(h)
        let s = await talked(ws, h)
        try ws.updateSettings(AlloySettings(askBeforeSharedNotes: true))
        await ws.settle()
        #expect(h.transports.count == 2)
        #expect(await h.transports[0].terminated)
        #expect(hasNotice(s, "Settings applied"))
        #expect(h.configs[1].allowedTools.isEmpty && h.configs[1].mcpConfigJSON != nil)
        // A setting that does not change launch options relaunches nothing.
        try ws.updateSettings(AlloySettings(claudePath: "/other", askBeforeSharedNotes: true))
        await ws.settle()
        #expect(h.transports.count == 2)
        await ws.stopAll()
    }
}
