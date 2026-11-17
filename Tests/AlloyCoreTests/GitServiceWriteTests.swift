@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@Suite struct GitServiceWriteTests {
    private func cleanup(_ urls: URL...) { for u in urls { try? FileManager.default.removeItem(at: u) } }
    private func repo(_ files: [String: String], commit: Bool = true) throws -> URL {
        let root = try makeRepo(files: files, commit: commit)
        try git(root, "config", "user.name", "Tester"); try git(root, "config", "user.email", "t@t")
        try git(root, "config", "commit.gpgsign", "false")
        return root
    }
    private func staged(_ root: URL) throws -> [String] {
        try git(root, "diff", "--cached", "--name-only").split(separator: "\n").map(String.init)
    }

    @Test func stageAndUnstageFile() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        try writeFile(root, "a.txt", "two\n")
        let service = GitService(root: root, clock: ManualClock())
        #expect((await service.stage(["a.txt"])).ok)
        #expect(try staged(root) == ["a.txt"])
        #expect((await service.unstage(["a.txt"])).ok)
        #expect(try staged(root).isEmpty)
    }

    @Test func unstageOnUnbornBranch() async throws {
        let root = try repo(["a.txt": "one\n"], commit: false); defer { cleanup(root) }
        let service = GitService(root: root, clock: ManualClock())
        #expect((await service.stage(["a.txt"])).ok)
        await service.refreshNow()
        #expect((await service.unstage(["a.txt"])).ok)
        #expect(try staged(root).isEmpty)
    }

    @Test func oddNamesStageExactlyThatFile() async throws {
        let names = ["-dash.txt", "has space.txt", ":(glob)x.txt", "ünï.txt"]
        let root = try repo(["other.txt": "o\n", "x.txt": "x\n"]); defer { cleanup(root) }
        for n in names { try writeFile(root, n, "1\n") }
        try writeFile(root, "x.txt", "changed\n")
        let service = GitService(root: root, clock: ManualClock())
        for n in names {
            #expect((await service.stage([n])).ok, Comment(rawValue: n))
        }
        #expect(Set(try staged(root).map { $0.hasPrefix("\"") ? "quoted" : $0 }).isDisjoint(with: ["x.txt"]))
        #expect(try git(root, "ls-files", "-z").split(separator: "\0").map(String.init).sorted()
                == (names + ["other.txt", "x.txt"]).sorted())
        #expect(try staged(root).count == names.count)
        // Discarding the glob-named file only touches that one.
        try git(root, "commit", "-qm", "names")
        try writeFile(root, ":(glob)x.txt", "2\n"); try writeFile(root, "x.txt", "keep\n")
        #expect((await service.discard([":(glob)x.txt"])).ok)
        #expect(try String(contentsOf: root.appendingPathComponent(":(glob)x.txt"), encoding: .utf8) == "1\n")
        #expect(try String(contentsOf: root.appendingPathComponent("x.txt"), encoding: .utf8) == "keep\n")
    }

    private func hunkOf(base: String, buffer: String) throws -> GitHunk { try #require(GitHunks.compute(base: base, buffer: buffer).first) }

    @Test func stageHunkFromUnsavedBufferText() async throws {
        let base = "a\nb\nc\nd\ne\nf\ng\nh\n"
        let root = try repo(["f.txt": base]); defer { cleanup(root) }
        // The buffer was never saved: the file on disk is untouched.
        let buffer = "a\nB\nc\nd\ne\nf\nG\nh\n"
        let hunks = GitHunks.compute(base: base, buffer: buffer)
        #expect(hunks.count == 2)
        let service = GitService(root: root, clock: ManualClock())
        let r = await service.stageHunk(path: "f.txt", hunk: hunks[0])
        #expect(r.ok, Comment(rawValue: r.stderr))
        let cached = try git(root, "diff", "--cached")
        #expect(cached.contains("-b") && cached.contains("+B"))
        #expect(!cached.contains("+G"))
    }

    @Test func unstageHunk() async throws {
        let base = "a\nb\nc\n"
        let root = try repo(["f.txt": base]); defer { cleanup(root) }
        try writeFile(root, "f.txt", "a\nB\nc\n"); try git(root, "add", "f.txt")
        let service = GitService(root: root, clock: ManualClock())
        let hunk = try hunkOf(base: base, buffer: "a\nB\nc\n")
        let r = await service.unstageHunk(path: "f.txt", hunk: hunk)
        #expect(r.ok, Comment(rawValue: r.stderr))
        #expect(try staged(root).isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("f.txt"), encoding: .utf8) == "a\nB\nc\n")
    }

    @Test func partiallyStagedFileStageSecondHunk() async throws {
        let base = "a\nb\nc\nd\ne\nf\ng\nh\n"
        let root = try repo(["f.txt": base]); defer { cleanup(root) }
        let first = "a\nB\nc\nd\ne\nf\ng\nh\n", second = "a\nB\nc\nd\ne\nf\nG\nh\n"
        try writeFile(root, "f.txt", first); try git(root, "add", "f.txt")
        let service = GitService(root: root, clock: ManualClock())
        // The index holds `first`; the buffer is `second`: the one hunk against the index is the second change.
        let hunk = try hunkOf(base: first, buffer: second)
        let r = await service.stageHunk(path: "f.txt", hunk: hunk)
        #expect(r.ok, Comment(rawValue: r.stderr))
        let blob = try git(root, "show", ":f.txt")
        #expect(blob == second)
    }

    @Test func commitWithMessageOnStdinAndAmend() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        try writeFile(root, "a.txt", "two\n"); try git(root, "add", "a.txt")
        let service = GitService(root: root, clock: ManualClock())
        let message = "# not a comment\n\nsecond paragraph\n"
        #expect((await service.commit(message: message)).ok)
        #expect(try git(root, "log", "-1", "--format=%B") .trimmingCharacters(in: .whitespacesAndNewlines)
                == message.trimmingCharacters(in: .whitespacesAndNewlines))
        let count = try git(root, "rev-list", "--count", "HEAD")
        #expect((await service.commit(message: "amended", amend: true)).ok)
        #expect(try git(root, "rev-list", "--count", "HEAD") == count)
        #expect(try git(root, "log", "-1", "--format=%s") == "amended\n")
    }

    @Test func commitHookFailureReturnsStderr() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'lint says no' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try writeFile(root, "a.txt", "two\n"); try git(root, "add", "a.txt")
        let service = GitService(root: root, clock: ManualClock())
        let r = await service.commit(message: "x")
        #expect(!r.ok)
        #expect(r.stderr.contains("lint says no"))
    }

    @Test func hookReadingStdinGetsEOF() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ncat >/dev/null\nexit 0\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try writeFile(root, "a.txt", "two\n"); try git(root, "add", "a.txt")
        let service = GitService(root: root, clock: ManualClock())
        let r = await service.commit(message: "x")
        #expect(r.ok, Comment(rawValue: r.stderr))
    }

    @Test func indexLockHeldGivesGitsMessageAndNoRetry() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        try writeFile(root, "a.txt", "two\n")
        let probe = RunnerProbe()
        let service = GitService(root: root, clock: ManualClock(), runner: probe.runner)
        await service.refreshNow()
        try "".write(to: root.appendingPathComponent(".git/index.lock"), atomically: true, encoding: .utf8)
        let before = service.spawnCount
        let r = await service.stage(["a.txt"])
        #expect(!r.ok)
        #expect(r.stderr.contains("index.lock"))
        #expect(service.spawnCount - before == 1)
    }

    @Test func staleLockOnlyRemovedWhenOlderThan60s() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        let lock = root.appendingPathComponent(".git/index.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        let service = GitService(root: root, clock: ManualClock())
        #expect(await service.removeStaleLock() == false)
        #expect(FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: lock.path)
        #expect(await service.removeStaleLock())
        #expect(!FileManager.default.fileExists(atPath: lock.path))
    }

    @Test func discardTrackedRestoresFile() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        try writeFile(root, "a.txt", "two\n")
        let service = GitService(root: root, clock: ManualClock())
        #expect((await service.discard(["a.txt"])).ok)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
    }

    @Test func switchRefusedByDirtyTreeShowsGitsMessage() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        try git(root, "switch", "-q", "-c", "other")
        try writeFile(root, "a.txt", "other\n"); try git(root, "commit", "-qam", "o")
        try git(root, "switch", "-q", "main")
        try writeFile(root, "a.txt", "dirty\n")
        let service = GitService(root: root, clock: ManualClock())
        let r = await service.switchBranch("other")
        #expect(!r.ok)
        #expect(!r.stderr.isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8) == "dirty\n")
        #expect(try git(root, "stash", "list").isEmpty)
        #expect(try git(root, "branch", "--show-current") == "main\n")
    }

    @Test func createBranchAndRejectDashNames() async throws {
        let root = try repo(["a.txt": "one\n"]); defer { cleanup(root) }
        let service = GitService(root: root, clock: ManualClock())
        #expect((await service.createBranch("feature/x")).ok)
        #expect(try git(root, "branch", "--show-current") == "feature/x\n")
        #expect(!(await service.createBranch("-bad")).ok)
        #expect((await service.switchBranch("main")).ok)
    }

    @Test func branchesSortedByRecentCommitAndCapped() async throws {
        let root = try repo(["a.txt": "0\n"]); defer { cleanup(root) }
        for i in 1...10 {
            try git(root, "switch", "-q", "-c", "b\(i)")
            try writeFile(root, "a.txt", "\(i)\n")
            // Distinct commit dates, oldest first.
            let date = "2020-01-\(String(format: "%02d", i))T00:00:00"
            try git(root, "-c", "core.hooksPath=/dev/null", "commit", "-qam", "c\(i)", "--date=\(date)")
            try git(root, "commit", "-q", "--amend", "--no-edit", "--date=\(date)")
        }
        let service = GitService(root: root, clock: ManualClock())
        let all = await service.branches()
        #expect(all.count == 11)
        #expect(all.first(where: \.isCurrent)?.name == "b10")
        let recent = Array(all.prefix(8))
        #expect(recent.count == 8)
        #expect(recent == recent.sorted { $0.lastCommit > $1.lastCommit })
    }

    @Test func blameCachedUntilInvalidated() async throws {
        let root = try repo(["a.txt": "one\ntwo\n"]); defer { cleanup(root) }
        let probe = RunnerProbe()
        let service = GitService(root: root, clock: ManualClock(), runner: probe.runner)
        let runs = await service.blame(path: "a.txt")
        #expect(runs.first?.author == "t")
        #expect(runs.reduce(0) { $0 + $1.count } == 2)
        _ = await service.blame(path: "a.txt", lines: 2...2)
        #expect(probe.count("blame") == 1)
        await service.invalidateBlame(path: "a.txt")
        _ = await service.blame(path: "a.txt")
        #expect(probe.count("blame") == 2)
    }
}
