import AlloyLSPTestSupport
@testable import AlloyRPC
import Foundation
import Testing

@Suite struct ProcessGroupTests {
    private func launch(_ script: String, group: Bool) throws -> ServerProcess {
        try ServerProcess(executable: "/bin/sh", arguments: ["-c", script],
                          environment: ["PATH": "/usr/bin:/bin"],
                          currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory()), processGroup: group)
    }

    @Test func groupLeaderHasItsOwnGroup() async throws {
        let p = try launch("sleep 600", group: true)
        defer { kill(p.processIdentifier, SIGKILL) }
        #expect(getpgid(p.processIdentifier) == p.processIdentifier)
        #expect(p.processGroupID == p.processIdentifier)
        await p.stop(grace: .seconds(2))
    }

    /// Foundation's `Process` already puts a child in a group of its own on macOS, so the observable difference of the
    /// default path is that `ServerProcess` reports no group and signals only the pid.
    @Test func defaultSpawnReportsNoGroup() async throws {
        let p = try launch("sleep 600", group: false)
        defer { kill(p.processIdentifier, SIGKILL) }
        #expect(p.processGroupID == nil)
        #expect(p.isRunning)
        await p.stop(grace: .seconds(2))
    }

    @Test func stopKillsTheWholeGroup() async throws {
        let p = try launch("sleep 600 & echo $!; wait", group: true)
        defer { kill(p.processIdentifier, SIGKILL) }
        var text = ""
        for await chunk in p.incoming {
            text += String(decoding: chunk, as: UTF8.self)
            if text.contains("\n") { break }
        }
        let child = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(child, 0) == 0)
        await p.stop(grace: .seconds(2))
        let gone = await waitUntil(.seconds(3)) { kill(child, 0) == -1 && errno == ESRCH }
        if !gone { kill(child, SIGKILL) }
        #expect(gone)
    }

    @Test func ignoringSigtermIsKilledAfterGrace() async throws {
        let p = try launch("trap '' TERM; sleep 600", group: true)
        defer { kill(-p.processIdentifier, SIGKILL) }
        // Let the shell install its trap before the first signal.
        try await Task.sleep(for: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        await p.stop(grace: .seconds(2))
        let took = clock.now - start
        #expect(took >= .seconds(2))
        #expect(took < .seconds(4))
        #expect(!p.isRunning)
    }
}
