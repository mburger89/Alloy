#if !os(Windows)

import AlloyTerminal
import AlloyTestSupport
import Dispatch
import Foundation
import MetalUITerminal
import Testing

struct PtyHandleTests {
    private func request(_ script: String, cwd: String) -> PtySpawnRequest {
        PtySpawnRequest(executable: "/bin/sh", argv: ["sh", "-c", script], env: ["PATH": "/usr/bin:/bin"],
                        cwd: cwd, size: TerminalSize(cols: 80, rows: 24))
    }

    @Test func scriptedPtyDeliversFedBytesOnItsQueue() async {
        let pty = ScriptedPty()
        let queue = DispatchQueue(label: "test.pty")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            pty.onReadable(queue: queue) { if once.set() { done.resume() } }
            pty.feed([1, 2, 3])
        }
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = buffer.withUnsafeMutableBytes { pty.read(into: $0) }
        let again = buffer.withUnsafeMutableBytes { pty.read(into: $0) }
        #expect(n == 3)
        #expect(Array(buffer.prefix(3)) == [1, 2, 3])
        #expect(again == 0)
        #expect(pty.readCalls == [16, 16])
    }

    @Test func scriptedPtyReportsEndOfFileAfterFinish() async {
        let pty = ScriptedPty()
        pty.feed([9])
        pty.finish(.exited(3))
        var buffer = [UInt8](repeating: 0, count: 4)
        let first = buffer.withUnsafeMutableBytes { pty.read(into: $0) }
        let second = buffer.withUnsafeMutableBytes { pty.read(into: $0) }
        #expect(first == 1)
        #expect(second == -1)
        #expect(await pty.exitStatus == .exited(3))
    }

    @Test func scriptedHangupIgnoredButKillEnds() async {
        let pty = ScriptedPty()
        pty.ignoresHangup = true
        pty.signalGroup(.hangup)
        pty.signalGroup(.kill)
        #expect(pty.signals == [.hangup, .kill])
        #expect(await pty.exitStatus == .signaled(9))
    }

    @Test func scriptedSpawnerRecordsRequestAndCanFail() throws {
        let spawner = ScriptedPtySpawner()
        let req = request("true", cwd: NSTemporaryDirectory())
        let pty = try spawner.spawn(req)
        #expect(spawner.requests == [req])
        #expect(spawner.spawned.count == 1)
        #expect(pty.processID == spawner.spawned[0].processID)
        spawner.failure = .spawnFailed(code: 2)
        #expect(throws: PseudoTerminalError.spawnFailed(code: 2)) { try spawner.spawn(req) }
    }

    @Test func livePtyConformanceRunsASubprocess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alloy-pty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pty = try LivePtySpawner().spawn(request("printf hi; exit 5", cwd: dir.path))
        let collected = Collected()
        let queue = DispatchQueue(label: "test.live.pty")
        pty.onReadable(queue: queue) { [pty] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { pty.read(into: $0) }
                if n <= 0 { break }
                collected.append(Array(buffer.prefix(n)))
            }
        }
        let status = await pty.exitStatus
        // Output may arrive just after the exit; give the reader a moment.
        for _ in 0..<100 where !String(decoding: collected.bytes, as: UTF8.self).contains("hi") {
            try await Task.sleep(for: .milliseconds(20))
        }
        pty.close()
        #expect(status == .exited(5))
        #expect(String(decoding: collected.bytes, as: UTF8.self).contains("hi"))
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [UInt8] = []
    func append(_ more: [UInt8]) { lock.withLock { data.append(contentsOf: more) } }
    var bytes: [UInt8] { lock.withLock { data } }
}

#endif
