#if !os(Windows)

import AlloyCore
@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUITerminal
import Testing

private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var _titles: [UUID] = []
    private var _exits: [(UUID, Int32)] = []
    private var _notices: [String] = []
    func title(_ id: UUID) { lock.withLock { _titles.append(id) } }
    func exit(_ id: UUID, _ status: Int32) { lock.withLock { _exits.append((id, status)) } }
    func notice(_ text: String) { lock.withLock { _notices.append(text) } }
    var titles: [UUID] { lock.withLock { _titles } }
    var exits: [(UUID, Int32)] { lock.withLock { _exits } }
    var notices: [String] { lock.withLock { _notices } }
}

private func settle(_ condition: @escaping @Sendable () -> Bool, seconds: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

private func tempDir() -> String {
    let url = TempFiles.url("alloy-mgr")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

@MainActor private struct Fixture {
    let spawner = ScriptedPtySpawner()
    let log = Log()
    let root = tempDir()
    let home = tempDir()
    let manager: TerminalManager

    init(grace: Duration = .seconds(1), environment: [String: String] = ["SHELL": "/bin/sh", "ALLOY_SECRET": "x"]) {
        let log = log
        let spawner = spawner
        manager = TerminalManager(
            spawner: spawner, settings: { TerminalSettings() }, projectRoot: root, environment: environment,
            home: home, graceBeforeKill: grace,
            delegate: .init(title: { id, _ in log.title(id) }, exited: { id, s in log.exit(id, s) },
                            notice: { _, text in log.notice(text) }))
    }
}

@MainActor struct TerminalManagerTests {
    @Test func spawnsOnlyRequestedPanesOnce() {
        let f = Fixture()
        let a = UUID(), b = UUID()
        f.manager.spawnIfNeeded([(a, nil)])
        f.manager.spawnIfNeeded([(a, nil)])
        #expect(f.spawner.spawned.count == 1)
        #expect(f.manager.session(for: b) == nil)
        f.manager.spawnIfNeeded([(a, nil), (b, nil)])
        #expect(f.spawner.spawned.count == 2)
    }

    @Test func managerExposesTheLiveSessionsSource() {
        let f = Fixture()
        let a = UUID()
        #expect(f.manager.snapshotSource(for: a) == nil)
        f.manager.spawnIfNeeded([(a, nil)])
        let source = f.manager.snapshotSource(for: a)
        #expect(source != nil)
        #expect(source === f.manager.session(for: a)?.snapshotSource)
        f.manager.retain(only: [])
        #expect(f.manager.snapshotSource(for: a) == nil)
    }

    @Test func requestUsesPlannerEnvAndCwd() {
        let f = Fixture()
        f.manager.spawnIfNeeded([(UUID(), f.root)])
        let request = f.spawner.requests[0]
        #expect(request.env["TERM"] == "xterm-256color")
        #expect(!request.env.keys.contains { $0.hasPrefix("ALLOY_") })
        #expect(request.cwd == f.root)
        #expect(request.size == TerminalSize(cols: 80, rows: 24))
        #expect(request.argv[0].hasPrefix("-"))
    }

    @Test func missingCwdSpawnsInHomeAndNotices() {
        let f = Fixture()
        // Neither the pane directory nor the project root exists.
        let missing = f.root + "/gone"
        let manager = TerminalManager(spawner: f.spawner, settings: { TerminalSettings() }, projectRoot: missing,
                                      environment: ["SHELL": "/bin/sh"], home: f.home, delegate: .init(notice: { [log = f.log] _, t in log.notice(t) }))
        manager.spawnIfNeeded([(UUID(), missing + "/sub")])
        #expect(f.spawner.requests[0].cwd == f.home)
        #expect(f.log.notices.count == 1)
        #expect(f.log.notices[0].contains("not found"))
    }

    @Test func spawnFailureReportsExit127AndNoSession() async {
        let f = Fixture()
        f.spawner.failure = .openFailed(code: 1)
        let pane = UUID()
        f.manager.spawnIfNeeded([(pane, nil)])
        #expect(f.log.exits.map(\.1) == [127])
        #expect(f.log.notices.count == 1)
        #expect(f.manager.session(for: pane) == nil)
        f.manager.spawnIfNeeded([(pane, nil)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.spawner.requests.count == 1)
        // The user-driven restart does retry.
        f.manager.restart(pane, cwd: nil)
        #expect(f.spawner.requests.count == 2)
    }

    @Test func immediateExitReportsExitedAndNeverRespawns() async {
        let f = Fixture()
        let pane = UUID()
        f.manager.spawnIfNeeded([(pane, nil)])
        f.spawner.spawned[0].finish(.exited(1))
        #expect(await settle { f.log.exits.count == 1 })
        #expect(f.log.exits[0].0 == pane && f.log.exits[0].1 == 1)
        f.manager.spawnIfNeeded([(pane, nil)])
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.spawner.spawned.count == 1)
        #expect(f.log.exits.count == 1)
    }

    @Test func restartReplacesTheSessionAndIgnoresStaleCallbacks() async {
        let f = Fixture()
        let pane = UUID()
        f.manager.spawnIfNeeded([(pane, nil)])
        let old = f.spawner.spawned[0]
        f.manager.restart(pane, cwd: nil)
        #expect(f.spawner.spawned.count == 2)
        // The old pty ends (hangup was sent by the retire) and its session reports nothing.
        old.finish(.exited(5))
        let oldSession = f.manager.session(for: pane)
        #expect(oldSession?.processID == f.spawner.spawned[1].processID)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(f.log.exits.isEmpty)
        #expect(f.log.titles.isEmpty)
        f.spawner.spawned[1].finish(.exited(2))
        #expect(await settle { f.log.exits.count == 1 })
        #expect(f.log.exits[0].1 == 2)
    }

    @Test func retainOnlyTerminatesRemovedPanes() async {
        let f = Fixture()
        let a = UUID(), b = UUID()
        f.manager.spawnIfNeeded([(a, nil), (b, nil)])
        f.manager.retain(only: [a])
        #expect(f.manager.session(for: a) != nil)
        #expect(f.manager.session(for: b) == nil)
        #expect(await settle { f.spawner.spawned[1].signals.first == .hangup })
        #expect(f.spawner.spawned[0].signals.isEmpty)
        // A retired pane's exit is not reported.
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(f.log.exits.isEmpty)
    }

    @Test func writeAndResizeReachTheRightPty() async {
        let f = Fixture()
        let a = UUID(), b = UUID()
        f.manager.spawnIfNeeded([(a, nil), (b, nil)])
        f.manager.write(b, [0x41])
        f.manager.resize(b, cols: 100, rows: 30)
        #expect(await settle { f.spawner.spawned[1].resizes.count == 1 })
        #expect(f.spawner.spawned[1].written == [0x41])
        #expect(f.spawner.spawned[1].resizes[0] == TerminalSize(cols: 100, rows: 30))
        #expect(f.spawner.spawned[0].written.isEmpty && f.spawner.spawned[0].resizes.isEmpty)
    }

    @Test func busyPanesReportsForegroundJobs() {
        let f = Fixture()
        let a = UUID(), b = UUID()
        f.manager.spawnIfNeeded([(a, nil), (b, nil)])
        #expect(f.manager.busyPanes().isEmpty)
        f.spawner.spawned[1].foreground = 4242
        #expect(f.manager.busyPanes() == [b])
    }

    @Test func shutdownTerminatesEverySessionConcurrently() async {
        let f = Fixture()
        f.manager.spawnIfNeeded([(UUID(), nil), (UUID(), nil)])
        await f.manager.shutdown()
        for pty in f.spawner.spawned { #expect(pty.signals == [.hangup]) }
    }

    @Test func shutdownKillsAHangupIgnoringShellAfterGrace() async {
        let f = Fixture(grace: .milliseconds(50))
        f.manager.spawnIfNeeded([(UUID(), nil)])
        f.spawner.spawned[0].ignoresHangup = true
        await f.manager.shutdown()
        #expect(f.spawner.spawned[0].signals == [.hangup, .kill])
    }

    @Test func shutdownTwiceAndSpawnAfterShutdownAreNoOps() async {
        let f = Fixture(grace: .milliseconds(50))
        let pane = UUID()
        f.manager.spawnIfNeeded([(pane, nil)])
        f.spawner.spawned[0].ignoresHangup = true
        await f.manager.shutdown()
        await f.manager.shutdown()
        f.manager.spawnIfNeeded([(UUID(), nil)])
        f.manager.restart(pane, cwd: nil)
        #expect(f.spawner.spawned.count == 1)
        #expect(f.spawner.spawned[0].signals == [.hangup, .kill])
    }

    @Test func shutdownWithNoSessionsReturnsImmediately() async {
        let f = Fixture()
        await f.manager.shutdown()
        #expect(f.spawner.spawned.isEmpty)
    }
}

#endif
