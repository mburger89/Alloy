@testable import AlloyCore
import AlloyTestSupport
import Foundation
import Testing

private final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
}

@MainActor
@Suite struct FileTreeModelTests {
    private func names(_ entries: [FileTreeEntry]) -> [String] { entries.map(\.name) }

    @Test func foldersFirstThenFilesCaseInsensitive() {
        let snap = FileTreeSnapshot.build(paths: ["b.txt", "A.txt", "src/z.swift", "Docs/x.md", "a/y"], truncated: false)
        #expect(names(snap.children(of: "")) == ["a", "Docs", "src", "A.txt", "b.txt"])
        #expect(snap.children(of: "").map(\.isFolder) == [true, true, true, false, false])
        #expect(snap.children(of: "src").map(\.path) == ["src/z.swift"])
        #expect(snap.parent(of: "src/z.swift") == "src")
        #expect(snap.parent(of: "src") == "")
        #expect(snap.parent(of: "") == nil)
    }

    @Test func onlyExpandedFoldersAreLaidOut() async {
        let model = FileTreeModel()
        await model.update(paths: ["a/b/c.txt", "a/d.txt", "z.txt"], truncated: false)
        #expect(model.visibleRows().map(\.entry.path) == ["a", "z.txt"])
        model.expandedPaths = ["a"]
        let rows = model.visibleRows()
        #expect(rows.map(\.entry.path) == ["a", "a/b", "a/d.txt", "z.txt"])
        #expect(rows.map(\.depth) == [0, 1, 1, 0])
    }

    @Test func revealExpandsAncestors() async {
        let model = FileTreeModel()
        await model.update(paths: ["a/b/c.txt", "a/d.txt", "z.txt"], truncated: false)
        #expect(model.reveal("a/b/c.txt") == 2)
        #expect(model.expandedPaths == ["a", "a/b"])
        #expect(model.reveal("nope/x") == nil)
    }

    @Test func folderMarkedWhenADescendantChanged() {
        let s = Author.session(UUID())
        let marks = ChangeMark.marks(for: [ChangedFile(path: "src/deep/x.swift", authors: [.user, s])])
        #expect(marks["src"] == .author(s))
        #expect(marks["src/deep"] == .author(s))
        #expect(marks["src/deep/x.swift"] == .author(s))
        #expect(marks["y"] == nil)
    }

    @Test func mixedAuthorsMarkTheFolderMixed() {
        let marks = ChangeMark.marks(for: [ChangedFile(path: "src/a", authors: [.user]), ChangedFile(path: "src/c/d", authors: [.outside]),
                                ChangedFile(path: "src/b", authors: [.user])])
        #expect(marks["src"] == .mixed)
        #expect(marks["src/c"] == .author(.outside))
        #expect(marks["src/a"] == .author(.user))
    }

    @Test func truncationIsReported() async {
        let model = FileTreeModel()
        await model.update(paths: ["a"], truncated: true)
        #expect(model.snapshot.truncated)
        #expect(!FileTreeSnapshot.build(paths: ["a"], truncated: false).truncated)
    }

    @Test func aHundredThousandPathsBuildOffMain() async {
        let paths = (0..<100_000).map { "dir\($0 % 300)/sub\($0 % 17)/file\($0).swift" }
        let model = FileTreeModel()
        var ticks = 0; let done = Flag()
        // The main actor must stay free while the build runs: a build on main would starve this loop.
        let heartbeat = Task { @MainActor in while !done.value { ticks += 1; await Task.yield() } }
        let start = ContinuousClock.now
        await model.update(paths: paths, truncated: false)
        done.set()
        await heartbeat.value
        #expect(ticks > 20)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(model.visibleRows().count == 300)
        #expect(model.visibleRows().count == model.snapshot.children(of: "").count)
    }

    @Test func refreshIsDebounced300ms() async {
        let env = Env()
        defer { env.cleanup() }
        env.ws.fileTreeActive = true
        env.ws.enqueueOutside([env.url("a.txt").path])
        env.clock.advance(by: 0.2)
        env.ws.enqueueOutside([env.url("b.txt").path])
        env.clock.advance(by: 0.2)
        env.ws.enqueueOutside([env.url("c.txt").path])
        env.clock.advance(by: 0.29)
        for _ in 0..<50 { await Task.yield() }   // not settle(): the pending timer would never finish
        #expect(env.ws.fileTreeRefreshCount == 0)
        env.clock.advance(by: 0.02)
        await waitUntil("refresh fired") { env.ws.fileTreeRefreshCount == 1 }
        await env.ws.settle()
        #expect(env.ws.fileTreeRefreshCount == 1)
    }

    @Test func noRefreshInChatMode() async {
        let env = Env()
        defer { env.cleanup() }
        env.ws.enqueueOutside([env.url("a.txt").path])
        env.clock.advance(by: 1)
        await env.ws.settle()
        #expect(env.ws.fileTreeRefreshCount == 0)
    }

    @Test func switchingToCodeStartsNoScanWithoutATreeView() async {
        let env = Env()
        defer { env.cleanup() }
        env.write("a.txt", "x")
        env.ws.setMode(.code)
        await env.ws.settle()
        #expect(!env.ws.fileTreeActive)
        #expect(env.ws.fileTreeRefreshCount == 0)
        env.ws.setMode(.chat)
        #expect(!env.ws.fileTreeActive)
    }

    @Test func treeViewAppearingActivatesAndScansOnceDisappearingStops() async {
        let env = Env()
        defer { env.cleanup() }
        env.write("a.txt", "x")
        env.ws.fileTreeViewAppeared()
        #expect(env.ws.fileTreeActive)
        await env.ws.settle()
        #expect(env.ws.fileTreeRefreshCount == 1)
        env.ws.fileTreeViewDisappeared()
        #expect(!env.ws.fileTreeActive)
        env.ws.enqueueOutside([env.url("new.txt").path])
        env.clock.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }
        #expect(env.ws.fileTreeRefreshCount == 1)
    }

    @Test func contentSaveOfAKnownFileSchedulesNoRefresh() async {
        let env = Env()
        defer { env.cleanup() }
        env.write("a.txt", "x")
        await env.ws.refreshFileTreeNow()
        env.ws.eventRoots = [env.url("").path]
        env.ws.fileTreeActive = true
        #expect(env.ws.fileTreeRefreshCount == 1)
        env.write("a.txt", "changed")
        env.ws.enqueueOutside([env.url("a.txt").path])
        env.clock.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }
        #expect(env.ws.fileTreeRefreshCount == 1, "only creates, removals and renames change the tree")
        // A removal of the known file does.
        try? FileManager.default.removeItem(at: env.url("a.txt"))
        env.ws.enqueueOutside([env.url("a.txt").path])
        env.clock.advance(by: 1)
        await waitUntil("refresh fired") { env.ws.fileTreeRefreshCount == 2 }
    }

    @Test func gitDirectoryEventsDoNotRefresh() async {
        let env = Env()
        defer { env.cleanup() }
        env.ws.fileTreeActive = true
        env.ws.enqueueOutside([env.url(".git/index").path])
        env.clock.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }   // not settle(): git events start their own timer
        #expect(env.ws.fileTreeRefreshCount == 0)
    }

    @Test func refreshNowFillsTheTree() async throws {
        let env = Env()
        defer { env.cleanup() }
        env.write("src.txt", "x")
        await env.ws.refreshFileTreeNow()
        #expect(env.ws.fileTreeRefreshCount == 1)
        #expect(names(env.ws.fileTree.snapshot.children(of: "")) == ["src.txt"])
    }

    @Test func marksAreStoredAndIndependentOfTheSnapshot() async {
        let model = FileTreeModel()
        let files = [ChangedFile(path: "a/b", authors: [.user])]
        model.setChanges(files)
        model.setChanges(files)
        #expect(model.marksComputeCount == 1)
        #expect(model.marks["a"] == .author(.user))
        let fired = Flag()
        withObservationTracking { _ = model.marks } onChange: { fired.set() }
        await model.update(paths: ["a/b", "c"], truncated: false)
        #expect(!fired.value)
        model.setChanges([])
        #expect(fired.value)
        #expect(model.marksComputeCount == 2)
    }

    @Test func samePathsDoNotBuildAgain() async {
        let model = FileTreeModel()
        await model.update(paths: ["a/b", "c"], truncated: false)
        await model.update(paths: ["a/b", "c"], truncated: false)
        #expect(model.buildCount == 1)
        await model.update(paths: ["a/b", "c"], truncated: true)
        #expect(model.buildCount == 2)
        await model.update(paths: ["c"], truncated: true)
        #expect(model.buildCount == 3)
    }

    @Test func togglingOneFolderDoesNotWakeAnother() async {
        let model = FileTreeModel()
        await model.update(paths: ["a/x", "b/y"], truncated: false)
        let firedB = Flag(), firedA = Flag()
        withObservationTracking { _ = model.expansion(for: "b").isExpanded } onChange: { firedB.set() }
        withObservationTracking { _ = model.expansion(for: "a").isExpanded } onChange: { firedA.set() }
        model.expansion(for: "a").isExpanded = true
        #expect(firedA.value)
        #expect(!firedB.value)
        #expect(model.expandedPaths == ["a"])
    }

    @Test func gitAndSkippedDirectoryEventsDoNotRefresh() async {
        let env = Env()
        defer { env.cleanup() }
        env.ws.fileTreeActive = true
        env.ws.enqueueOutside([env.url("node_modules/x/y.js").path, env.url(".build/z").path])
        env.clock.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }
        #expect(env.ws.fileTreeDebounceTask == nil)
        env.ws.enqueueOutside([env.url("src/a.swift").path])
        #expect(env.ws.fileTreeDebounceTask != nil)
        env.ws.stopWatching()
        #expect(env.ws.fileTreeDebounceTask?.isCancelled == true)
    }
}
