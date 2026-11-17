@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

/// Wraps the live runner: records every call, counts concurrent `cat-file`s, and lets a test answer a command itself.
final class RunnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    private var active = 0
    private(set) var maxCat = 0
    var override: (@Sendable ([String]) -> GitResult?)?
    var catDelay: UInt64 = 0

    var runner: GitRunner {
        { [self] args, dir, stdin, readOnly, t, k in
            lock.withLock { calls.append(args) }
            if let r = override?(args) { return r }
            let isCat = args.first == "cat-file"
            if isCat {
                lock.withLock { active += 1; maxCat = max(maxCat, active) }
                if catDelay > 0 { try? await Task.sleep(nanoseconds: catDelay) }
            }
            let r = await GitService.liveRunner(args, dir, stdin, readOnly, t, k)
            if isCat { lock.withLock { active -= 1 } }
            return r
        }
    }
    func count(_ first: String) -> Int { lock.withLock { calls.filter { $0.contains(first) }.count } }
}

func collectUpdates(_ service: GitService) async -> UpdateBox {
    let box = UpdateBox()
    await service.setUpdateHandler { box.add($0) }
    return box
}

final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GitUpdate] = []
    func add(_ u: GitUpdate) { lock.withLock { items.append(u) } }
    var all: [GitUpdate] { lock.withLock { items } }
}

@Suite struct GitServiceTests {
    private func cleanup(_ urls: URL...) { for u in urls { try? FileManager.default.removeItem(at: u) } }

    @Test func firstRefreshReadsBranchAndEntries() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n", "b.txt": "two\n"]); defer { cleanup(root) }
        try writeFile(root, "a.txt", "changed\n"); try writeFile(root, "new.txt", "n\n")
        let service = GitService(root: root, clock: ManualClock())
        let updates = await collectUpdates(service)
        await service.refreshNow()
        let status = try #require(await service.status)
        #expect(status.branch == "main")
        #expect(status.entries["a.txt"]?.display == .modified)
        #expect(status.entries["new.txt"]?.display == .untracked)
        #expect(await service.state == .ready)
        let first = try #require(updates.all.first)
        #expect(first.changedDisplay["a.txt"] == .some(.modified))
        #expect(first.changedFolders.isEmpty)
        #expect(!first.headChanged)
    }

    @Test func updateReportsOnlyChangedPathsAndHeadChange() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n", "d/b.txt": "two\n"]); defer { cleanup(root) }
        let service = GitService(root: root, clock: ManualClock())
        let updates = await collectUpdates(service)
        try writeFile(root, "a.txt", "x\n")
        await service.refreshNow()
        try writeFile(root, "d/b.txt", "y\n")
        await service.refreshNow()
        let second = try #require(updates.all.last)
        #expect(second.changedDisplay.keys.sorted() == ["d/b.txt"])
        #expect(second.changedFolders["d"] == .some(.modified))
        try git(root, "commit", "-qam", "all")
        await service.refreshNow()
        #expect(try #require(updates.all.last).headChanged)
        #expect(try #require(updates.all.last).changedDisplay["a.txt"] == .some(nil))
    }

    @Test func hundredIndexEventsMakeAtMostTwoStatusRuns() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"]); defer { cleanup(root) }
        let clock = ManualClock(), probe = RunnerProbe()
        let service = GitService(root: root, clock: clock, runner: probe.runner)
        await service.refreshNow()
        let baseline = service.spawnCount
        for _ in 0..<100 { await service.requestRefresh() }
        clock.advance(by: 0.6)
        await service.idle()
        #expect(service.spawnCount - baseline <= 2)
        #expect(service.spawnCount - baseline >= 1)
    }

    @Test func requestDuringRunGivesExactlyOneFollowUp() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"]); defer { cleanup(root) }
        let clock = ManualClock(), probe = RunnerProbe()
        let service = GitService(root: root, clock: clock, runner: probe.runner)
        await service.refreshNow()
        let baseline = probe.count("status")
        await service.requestRefresh()
        clock.advance(by: 0.6)
        for _ in 0..<5 { await service.requestRefresh() }
        await service.idle()
        let runs = probe.count("status") - baseline
        #expect(runs >= 1 && runs <= 2)
    }

    @Test func statusRunNeverWritesIndex() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"]); defer { cleanup(root) }
        let index = root.appendingPathComponent(".git/index")
        // Make the cached stat data stale so a plain `git status` would want to refresh the index.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-100)], ofItemAtPath: root.appendingPathComponent("a.txt").path)
        let before = try Data(contentsOf: index)
        let mtime = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let service = GitService(root: root, clock: ManualClock())
        for _ in 0..<3 { await service.refreshNow(); try writeFile(root, "a.txt", "one\n") }
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == mtime)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/index.lock").path))
    }

    @Test func ignoredPathsDoNotRequestRefresh() async throws {
        let root = try makeRepo(files: [".gitignore": "dist/\n", "src/a.swift": "x\n"]); defer { cleanup(root) }
        try writeFile(root, "dist/a.js", "1\n")
        let service = GitService(root: root, clock: ManualClock())
        await service.refreshNow()
        #expect(await service.shouldRefresh(forWorktreePaths: ["dist/a.js"]) == false)
        #expect(await service.shouldRefresh(forWorktreePaths: ["src/a.swift"]))
        #expect(await service.shouldRefresh(forWorktreePaths: ["dist/a.js", ".gitignore"]))
    }

    @Test func projectBelowRepoTopStripsPrefix() async throws {
        let repo = try makeRepo(files: ["app/a.txt": "one\n", "other/b.txt": "two\n"]); defer { cleanup(repo) }
        try writeFile(repo, "app/a.txt", "x\n"); try writeFile(repo, "other/b.txt", "y\n")
        let service = GitService(root: repo.appendingPathComponent("app"), clock: ManualClock())
        await service.refreshNow()
        let status = try #require(await service.status)
        #expect(status.entries.keys.sorted() == ["a.txt"])
        // Writes use the repository-relative path.
        let r = await service.stage(["a.txt"])
        #expect(r.ok, Comment(rawValue: r.stderr))
        #expect(try git(repo, "diff", "--cached", "--name-only") == "app/a.txt\n")
    }

    @Test func linkedWorktreeWorks() async throws {
        let repo = try makeRepo(files: ["a.txt": "one\n"]); defer { cleanup(repo) }
        let wt = repo.deletingLastPathComponent().appendingPathComponent("wt-" + UUID().uuidString); defer { cleanup(wt) }
        try git(repo, "worktree", "add", "-q", wt.path, "-b", "side")
        try writeFile(wt, "a.txt", "changed\n")
        let service = GitService(root: wt, clock: ManualClock())
        await service.refreshNow()
        let status = try #require(await service.status)
        #expect(status.branch == "side")
        #expect(status.entries["a.txt"]?.display == .modified)
        #expect((await service.stage(["a.txt"])).ok)
    }

    @Test func unbornBranch() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"], commit: false); defer { cleanup(root) }
        let service = GitService(root: root, clock: ManualClock())
        await service.refreshNow()
        let status = try #require(await service.status)
        #expect(status.isUnborn)
        #expect(status.entries["a.txt"]?.display == .untracked)
    }

    @Test func notARepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-norepo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { cleanup(dir) }
        let probe = RunnerProbe()
        let service = GitService(root: dir, clock: ManualClock(), runner: probe.runner)
        await service.refreshNow()
        #expect(await service.state == .notARepo)
        #expect(await service.status == nil)
        // Further requests spawn nothing until a git event.
        let n = service.spawnCount
        await service.requestRefresh()
        #expect(await service.shouldRefresh(forWorktreePaths: ["x"]) == false)
        #expect(service.spawnCount == n)
        try git(dir, "init", "-q", "-b", "main")
        await service.gitEvent()
        await service.refreshNow()
        #expect(await service.state == .ready)
    }

    @Test func timeoutPausesUntilManualRefresh() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"]); defer { cleanup(root) }
        let clock = ManualClock(), probe = RunnerProbe()
        let service = GitService(root: root, clock: clock, runner: probe.runner)
        let updates = await collectUpdates(service)
        await service.refreshNow()
        probe.override = { args in args.contains("status") ? GitResult(status: -1, timedOut: true) : nil }
        await service.requestRefresh(); clock.advance(by: 0.6); await service.idle()
        #expect(updates.all.last?.timedOut == true)
        let n = probe.count("status")
        await service.requestRefresh(); clock.advance(by: 0.6); await service.idle()
        #expect(probe.count("status") == n)
        probe.override = nil
        await service.refreshNow()
        #expect(probe.count("status") == n + 1)
        #expect(updates.all.last?.timedOut == false)
    }

    @Test func blobCacheFetchesOncePerOid() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n"]); defer { cleanup(root) }
        let probe = RunnerProbe()
        let service = GitService(root: root, clock: ManualClock(), runner: probe.runner)
        await service.refreshNow()
        let oid = try #require(await service.status?.entries["a.txt"]?.headOID ?? (try git(root, "rev-parse", "HEAD:a.txt")).trimmingCharacters(in: .whitespacesAndNewlines))
        async let a = service.headText(oid: oid), b = service.headText(oid: oid), c = service.indexText(oid: oid)
        #expect(await a == "one\n"); #expect(await b == "one\n"); #expect(await c == "one\n")
        _ = await service.headText(oid: oid)
        #expect(probe.count("cat-file") == 1)
    }

    @Test func atMostTwoConcurrentCatFiles() async throws {
        let root = try makeRepo(files: (0..<6).reduce(into: [:]) { $0["f\($1).txt"] = "content \($1)\n" }); defer { cleanup(root) }
        let probe = RunnerProbe(); probe.catDelay = 50_000_000
        let service = GitService(root: root, clock: ManualClock(), runner: probe.runner)
        await service.refreshNow()
        let oids = try (0..<6).map { try git(root, "rev-parse", "HEAD:f\($0).txt").trimmingCharacters(in: .whitespacesAndNewlines) }
        await withTaskGroup(of: Void.self) { group in
            for oid in oids { group.addTask { _ = await service.headText(oid: oid) } }
        }
        #expect(probe.count("cat-file") == 6)
        #expect(probe.maxCat <= 2)
        #expect(probe.maxCat >= 1)
    }

    @Test func blobsEvictedWhenNotRetained() async throws {
        let root = try makeRepo(files: ["a.txt": "one\n", "b.txt": "two\n"]); defer { cleanup(root) }
        let service = GitService(root: root, clock: ManualClock())
        await service.refreshNow()
        let a = try git(root, "rev-parse", "HEAD:a.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = try git(root, "rev-parse", "HEAD:b.txt").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await service.headText(oid: a); _ = await service.headText(oid: b)
        await service.retainBlobs(for: [a])
        #expect(await service.hasBlob(a)); #expect(await service.hasBlob(b) == false)
    }
}
