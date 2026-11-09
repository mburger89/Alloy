@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

@MainActor @Suite struct GitBaselineTests {
    /// A session edit of `name` to `new`, waited for until the ledger holds the new text.
    private func edit(_ e: Env, _ name: String = "a.txt", old: String, new: String, id: String = "t1") async throws {
        try await e.sessionEdit(name, old: old, new: new, id: id)
        await waitUntil("ledger has the edit") { e.ws.ledger.files[name]?.text.text == new }
        await e.ws.settle()
    }

    /// A repository with `a.txt` committed as "one\n", and a session that edits it to "one\ntwo\n".
    private func editedRepo(_ e: Env) async throws -> Session {
        e.write("a.txt", "one\n")
        try git(e.root, "init", "-q")
        try git(e.root, "add", "a.txt")
        try git(e.root, "commit", "-q", "-m", "init")
        let s = await e.ws.newSession(name: "A")
        try await edit(e, "a.txt", old: "one\n", new: "one\ntwo\n")
        #expect(e.ws.changedFiles.map(\.path) == ["a.txt"])
        return s
    }

    /// Delivers git events, passes the 150 ms and 500 ms windows, and waits for the check.
    private func gitEvent(_ e: Env, _ names: [String] = [".git/HEAD"], via source: ScriptedChangeSource? = nil, paths: [String]? = nil) async {
        e.ws.startWatching()
        (source ?? e.changes).send(paths ?? names.map { e.url($0).path })
        await waitUntil("batch queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await waitUntil("git window open") { e.clock.pendingSleepers == 1 && e.ws.gitDebounce != nil }
        e.clock.advance(by: 0.5)
        await e.ws.settle()
    }

    @Test func commitKeepsMatchingFile() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await editedRepo(e)
        try git(e.root, "commit", "-q", "-am", "work")
        await gitEvent(e)
        #expect(e.ws.changedFiles.isEmpty)
        #expect(e.ws.ledger.files["a.txt"]?.edits.allSatisfy { $0.state != .live } == true)
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "one\ntwo\n")
    }

    @Test func partialCommitKeepsNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await editedRepo(e)
        try git(e.root, "commit", "-q", "-am", "work")
        // More work after the commit: HEAD no longer equals the current text.
        try await edit(e, "a.txt", old: "one\ntwo\n", new: "one\ntwo\nthree\n", id: "t2")
        await gitEvent(e)
        #expect(e.ws.changedFiles.map(\.path) == ["a.txt"])
    }

    @Test func fileNotInHeadKeepsNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await editedRepo(e)
        e.write("b.txt", "new\n")
        try git(e.root, "add", "b.txt")
        try git(e.root, "commit", "-q", "-m", "other")
        try await e.sessionEdit("b.txt", old: "", new: "new\n", id: "t3")
        try FileManager.default.removeItem(at: e.url("b.txt"))
        try git(e.root, "rm", "-q", "--cached", "b.txt")
        try git(e.root, "commit", "-q", "-m", "drop b")
        await gitEvent(e)
        #expect(e.ws.changedFiles.map(\.path).contains("b.txt"))
    }

    /// A repository whose only ledger file has no live edits (a session edit, kept), with the edit committed.
    private func keptRepo(_ e: Env) async throws {
        _ = try await editedRepo(e)
        for r in try #require(e.ws.ledger.files["a.txt"]).edits { e.ws.keep(edit: r.id, path: "a.txt") }
        #expect(e.ws.changedFiles.isEmpty)
        try git(e.root, "commit", "-q", "-am", "work")
    }

    @Test func gitEventBeforeTheOutsideRecordStillKeeps() async throws {
        let e = Env(); defer { e.cleanup() }
        try await keptRepo(e)
        e.ws.startWatching()
        e.changes.send([e.url(".git/HEAD").path])
        await waitUntil("batch queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await waitUntil("git timer") { e.ws.gitDebounce != nil }
        #expect(e.ws.gitSpawnCount == 0)
        // The outside edit arrives in a later batch, before the 500 ms are over.
        e.write("a.txt", "one\ntwo\nthree\n")
        try git(e.root, "commit", "-q", "-am", "more")
        e.changes.send([e.url("a.txt").path])
        await waitUntil("second batch queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await waitUntil("outside recorded") { !e.ws.changedFiles.isEmpty }
        e.clock.advance(by: 0.4)
        await e.ws.settle()
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func outsideRecordShortlyAfterTheCheckRearms() async throws {
        let e = Env(); defer { e.cleanup() }
        try await keptRepo(e)
        e.ws.startWatching()
        e.changes.send([e.url(".git/HEAD").path])
        await waitUntil("batch queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await waitUntil("git timer") { e.ws.gitDebounce != nil }
        e.clock.advance(by: 0.5)
        await e.ws.settle()                      // the check ran with nothing to compare
        #expect(e.ws.gitSpawnCount == 0)
        e.write("a.txt", "one\ntwo\nthree\n")
        try git(e.root, "commit", "-q", "-am", "more")
        e.changes.send([e.url("a.txt").path])
        await waitUntil("second batch queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await waitUntil("re-armed") { !e.ws.changedFiles.isEmpty && e.ws.gitDebounce != nil }
        e.clock.advance(by: 0.5)
        await e.ws.settle()
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func noLiveEditsSpawnsNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        try await keptRepo(e)
        await gitEvent(e)
        #expect(e.ws.gitSpawnCount == 0)
    }

    @Test func noRepoNoop() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        _ = await e.ws.newSession(name: "A")
        try await edit(e, "a.txt", old: "one\n", new: "one\ntwo\n")
        await gitEvent(e)
        #expect(e.ws.changedFiles.map(\.path) == ["a.txt"])
        #expect(await GitBaseline.isRepo(e.root) == false)
        #expect(await GitBaseline.headText(root: e.root, path: "a.txt") == nil)
    }

    @Test func detachedHeadWorks() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await editedRepo(e)
        try git(e.root, "commit", "-q", "-am", "work")
        try git(e.root, "checkout", "-q", "--detach")
        #expect(await GitBaseline.isRepo(e.root))
        #expect(await GitBaseline.headText(root: e.root, path: "a.txt") == "one\ntwo\n")
        await gitEvent(e)
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func checkoutRewritesRecordedOutside() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\n")
        try git(e.root, "init", "-q"); try git(e.root, "add", "a.txt"); try git(e.root, "commit", "-q", "-m", "init")
        try git(e.root, "checkout", "-q", "-b", "other")
        e.write("a.txt", "one\nother\n")
        try git(e.root, "commit", "-q", "-am", "other")
        try git(e.root, "checkout", "-q", "-")
        // The ledger holds an edit on the first branch: a user edit of a.txt, saved.
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        try await e.ws.save("a.txt")
        await e.ws.close("a.txt")
        #expect(e.ws.changedFiles.map(\.path) == ["a.txt"])
        // The checkout rewrites the file; no session is running, so the write is an outside edit.
        try git(e.root, "checkout", "-q", "-f", "other")
        e.ws.startWatching()
        e.changes.send([e.url("a.txt").path, e.url(".git/HEAD").path])
        await waitUntil("batch queued") { e.ws.pendingOutside.count == 2 }
        e.clock.advance(by: 0.15)
        await waitUntil("git window open") { e.clock.pendingSleepers == 1 && e.ws.gitDebounce != nil }
        #expect(e.ws.ledger.files["a.txt"]?.edits.last?.author == .outside)
        e.clock.advance(by: 0.5)
        await e.ws.settle()
        #expect(e.ws.ledger.files["a.txt"]?.text.text == "one\nother\n")
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func restoreChecksOnce() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await editedRepo(e)
        await e.ws.settle()
        try git(e.root, "commit", "-q", "-am", "work")
        // A fresh workspace over the same project and ledger, as after a restart.
        let f = Env(base: e.root.deletingLastPathComponent(), project: "p")
        await f.ws.restore()
        await f.ws.settle()
        #expect(f.ws.changedFiles.isEmpty)
        #expect(f.ws.gitSpawnCount == 2)     // one isRepo, one HEAD read for the one changed file
    }

    @Test func worktreeWatchesItsGitDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-wt-\(UUID().uuidString)")
        let main = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "one\n".write(to: main.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(main, "init", "-q"); try git(main, "add", "a.txt"); try git(main, "commit", "-q", "-m", "init")
        try git(main, "worktree", "add", "-q", "-b", "wt", base.appendingPathComponent("p").path)
        let realBase = base.resolvingSymlinksInPath()
        let gitSource = ScriptedChangeSource()
        let rootPath = realBase.appendingPathComponent("p").path
        let e = Env(base: base, project: "p", factory: { url, root in url.path == rootPath ? root : gitSource })
        #expect(FileManager.default.fileExists(atPath: e.url(".git").path))   // a file here, not a directory
        _ = await e.ws.newSession(name: "A")
        try await edit(e, "a.txt", old: "one\n", new: "one\ntwo\n")
        #expect(e.ws.changedFiles.map(\.path) == ["a.txt"])
        try git(e.root, "commit", "-q", "-am", "work")
        e.ws.startWatching()
        await e.ws.settle()
        let gitDir = try #require(e.ws.externalGitDir)
        #expect(gitDir.hasPrefix(FSEventsSource.realPath(base) + "/main/.git/worktrees/"))
        await gitEvent(e, via: gitSource, paths: [gitDir + "/index"])
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func projectBelowRepositoryTopWatchesTheRepositoryGitDirectory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-sub-\(UUID().uuidString)")
        let sub = base.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "one\n".write(to: sub.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(base, "init", "-q"); try git(base, "add", "."); try git(base, "commit", "-q", "-m", "init")
        let realBase = base.resolvingSymlinksInPath()
        let gitSource = ScriptedChangeSource()
        let rootPath = realBase.appendingPathComponent("sub").path
        let e = Env(base: base, project: "sub", factory: { url, root in url.path == rootPath ? root : gitSource })
        _ = await e.ws.newSession(name: "A")
        try await edit(e, "a.txt", old: "one\n", new: "one\ntwo\n")
        try git(e.root, "commit", "-q", "-am", "work")
        e.ws.startWatching()
        await e.ws.settle()
        #expect(e.ws.externalGitDir == FSEventsSource.realPath(base) + "/.git")
        await gitEvent(e, via: gitSource, paths: [FSEventsSource.realPath(base) + "/.git/refs/heads/main"])
        #expect(e.ws.changedFiles.isEmpty)
    }

    @Test func gitDirectoryInsideRootNeedsNoSecondSource() async throws {
        let e = Env(); defer { e.cleanup() }
        _ = try await editedRepo(e)
        e.ws.startWatching()
        await e.ws.settle()
        #expect(e.ws.externalGitDir == nil)
    }
}
