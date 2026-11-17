@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@Suite struct GitProcessTests {
    private func repo() throws -> URL { try makeRepo(files: ["a.txt": "one\n"]) }

    @Test func exitStatusAndStderrAreReturned() async throws {
        let root = try repo(); defer { try? FileManager.default.removeItem(at: root) }
        let r = await GitProcess.run(["rev-parse", "--verify", "nope"], in: root, readOnly: true)
        #expect(r.status != 0)
        #expect(!r.stderr.isEmpty)
        #expect(!r.timedOut)
    }

    @Test func stdinIsWrittenThenClosed() async throws {
        let root = try repo(); defer { try? FileManager.default.removeItem(at: root) }
        let r = await GitProcess.run(["hash-object", "--stdin"], in: root, stdin: Data("abc".utf8), readOnly: true)
        #expect(r.status == 0)
        #expect(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f")
    }

    @Test func stdinWriteToExitedGitDoesNotRaiseSigpipe() async throws {
        let root = try repo(); defer { try? FileManager.default.removeItem(at: root) }
        let big = Data(repeating: 0x61, count: 1_000_000)
        let r = await GitProcess.run(["-c", "alias.x=!true", "x"], in: root, stdin: big, readOnly: true)
        #expect(r.status == 0)
    }

    @Test func hungProcessIsKilled() async throws {
        let root = try repo(); defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        let r = await GitProcess.run(["-c", "alias.x=!sleep 30", "x"], in: root, readOnly: true, terminateAfter: 0.2, killAfter: 0.5)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func readOnlyControlsOptionalLocks() async throws {
        let root = try repo(); defer { try? FileManager.default.removeItem(at: root) }
        let ro = await GitProcess.run(["-c", "alias.e=!env", "e"], in: root, readOnly: true)
        let rw = await GitProcess.run(["-c", "alias.e=!env", "e"], in: root, readOnly: false)
        let roEnv = String(decoding: ro.stdout, as: UTF8.self), rwEnv = String(decoding: rw.stdout, as: UTF8.self)
        #expect(roEnv.contains("GIT_OPTIONAL_LOCKS=0"))
        #expect(!rwEnv.contains("GIT_OPTIONAL_LOCKS"))
        for env in [roEnv, rwEnv] {
            #expect(env.contains("GIT_TERMINAL_PROMPT=0"))
            #expect(env.contains("GIT_LITERAL_PATHSPECS=1"))
        }
    }

    @Test func stderrIsCapped() async throws {
        let root = try repo(); defer { try? FileManager.default.removeItem(at: root) }
        let r = await GitProcess.run(["-c", "alias.e=!head -c 200000 /dev/zero | tr '\\0' x >&2", "e"], in: root, readOnly: true)
        #expect(r.stderr.count == GitProcess.stderrCap)
    }
}
