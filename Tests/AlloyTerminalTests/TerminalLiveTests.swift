#if !os(Windows)

import AlloyCore
import AlloyTestSupport
@testable import AlloyTerminal
import Foundation
import MetalUITerminal
import Testing

private final class Exits: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int32] = []
    func add(_ v: Int32) { lock.withLock { _values.append(v) } }
    var values: [Int32] { lock.withLock { _values } }
}

/// Wraps the live spawner and remembers every pid it started.
private final class TrackingSpawner: PtySpawner, @unchecked Sendable {
    private let lock = NSLock()
    private var _pids: [Int32] = []
    var pids: [Int32] { lock.withLock { _pids } }
    func spawn(_ request: PtySpawnRequest) throws(PseudoTerminalError) -> any PtyHandle {
        let pty = try LivePtySpawner().spawn(request)
        lock.withLock { _pids.append(pty.processID) }
        return pty
    }
}

private func settle(_ condition: @escaping @Sendable () async -> Bool, seconds: Double = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

private func tempDir() -> String {
    let url = TempFiles.url("alloy-live")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // Resolve symlinks (macOS /var -> /private/var) so `pwd` output matches.
    return url.resolvingSymlinksInPath().path
}

private func screen(_ session: TerminalSession, separator: String = "\n") async -> String {
    await session.withEmulator { e in
        (e.firstRow..<(e.firstRow + 60)).compactMap { e.rowText($0) }.joined(separator: separator)
    }
}

/// True when the process is gone or a zombie.
private func isDead(_ pid: Int32) -> Bool {
    if kill(pid, 0) != 0 { return true }
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-o", "stat=", "-p", String(pid)]
    let out = Pipe()
    ps.standardOutput = out
    ps.standardError = Pipe()
    do { try ps.run() } catch { return false }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    let state = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return state.isEmpty || state.hasPrefix("Z")
}

private func groupMembers(_ group: Int32) -> [Int32] {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    ps.arguments = ["-g", String(group)]
    let out = Pipe()
    ps.standardOutput = out
    ps.standardError = Pipe()
    do { try ps.run() } catch { return [] }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    ps.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
}

@MainActor private final class Live {
    let spawner = TrackingSpawner()
    let exits = Exits()
    let root = tempDir()
    let manager: TerminalManager
    let pane = UUID()

    init(shell: String = "/bin/sh", grace: Duration = .milliseconds(200)) {
        let exits = exits
        var settings = TerminalSettings()
        settings.shellPath = shell
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root]
        manager = TerminalManager(spawner: spawner, settings: { settings }, projectRoot: root,
                                  environment: environment, home: root, graceBeforeKill: grace,
                                  delegate: .init(exited: { _, s in exits.add(s) }))
    }

    func start(cwd: String? = nil) { manager.spawnIfNeeded([(pane, cwd)]) }

    /// Safety net: kills only what this fixture started, by pid and group.
    func cleanup(extra: [Int32] = []) {
        for pid in spawner.pids { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        for pid in extra { kill(pid, SIGKILL) }
    }
}

@MainActor struct TerminalLiveTests {
    @Test(.timeLimit(.minutes(1))) func liveShellRunsInTheRequestedCwdAndEchoes() async {
        let live = Live()
        defer { live.cleanup() }
        let cwd = tempDir()
        live.start(cwd: cwd)
        let session = live.manager.session(for: live.pane)!
        session.write(Array("pwd; exit 7\n".utf8))
        // A long path wraps at 80 columns, so join the rows.
        #expect(await settle { await screen(session, separator: "").contains(cwd) })
        #expect(await settle { live.exits.values == [7] })
    }

    @Test(.timeLimit(.minutes(1))) func liveShutdownKillsTheWholeGroup() async {
        let live = Live()
        defer { live.cleanup() }
        live.start()
        let session = live.manager.session(for: live.pane)!
        let shell = session.processID
        session.write(Array("set +m; trap '' HUP; sleep 600 & wait\n".utf8))
        #expect(await settle { groupMembers(shell).count >= 2 })
        let members = groupMembers(shell)
        defer { live.cleanup(extra: members) }
        await live.manager.shutdown()
        #expect(await settle { members.allSatisfy(isDead) })
        // Nothing respawns after shutdown, and a second shutdown returns.
        live.manager.spawnIfNeeded([(UUID(), nil)])
        await live.manager.shutdown()
        #expect(live.spawner.pids.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func liveChildSeesOnlyFds0To2() async {
        let live = Live()
        defer { live.cleanup() }
        live.start()
        let session = live.manager.session(for: live.pane)!
        // A grandchild probes descriptors 3...9: any that is open leaked through the shell.
        session.write(Array("sh -c 'for n in 3 4 5 6 7 8 9; do if (exec <&$n) 2>/dev/null; then echo OPEN$n; fi; done; echo PROBEDONE'\n".utf8))
        var lines: [Substring] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            lines = await screen(session).split(separator: "\n")
            if lines.contains("PROBEDONE") { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(lines.contains("PROBEDONE"))
        #expect(!lines.contains { $0.hasPrefix("OPEN") && $0.count <= 6 }, "leaked: \(lines)")
    }

    @Test(.timeLimit(.minutes(1))) func liveBusyTracksForegroundJob() async {
        let live = Live()
        defer { live.cleanup() }
        live.start()
        let session = live.manager.session(for: live.pane)!
        // Let the shell reach its prompt.
        session.write(Array("echo READY\n".utf8))
        #expect(await settle { (await screen(session)).split(separator: "\n").contains("READY") })
        #expect(live.manager.busyPanes().isEmpty)
        session.write(Array("sleep 600\n".utf8))
        #expect(await settle({ await live.manager.busyPanes() == [live.pane] }, seconds: 2))
        live.manager.write(live.pane, [0x03])
        #expect(await settle { await live.manager.busyPanes().isEmpty })
    }

    @Test(.timeLimit(.minutes(1))) func liveImmediateExitShowsExitedWithoutRespawn() async {
        let live = Live(shell: "/usr/bin/false")
        defer { live.cleanup() }
        live.start()
        #expect(await settle { live.exits.values == [1] })
        live.manager.spawnIfNeeded([(live.pane, nil)])
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(live.spawner.pids.count == 1)
        #expect(live.exits.values == [1])
    }
}

#endif
