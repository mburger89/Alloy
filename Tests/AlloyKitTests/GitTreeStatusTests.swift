@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

private final class Counter: @unchecked Sendable { var n = 0 }
private let none: GitDisplayStatus? = nil

@MainActor
@Suite struct GitTreeStatusTests {
    // MARK: Model

    @Test func applySetsOnlyChangedCells() {
        let tree = GitTreeStatus()
        let a = tree.cell(for: "a.swift"), b = tree.cell(for: "b.swift")
        tree.apply(["a.swift": .modified, "b.swift": .added])
        #expect(a.status == .modified && b.status == .added)
        // Same values again: nothing is written (the cell is observable, a write would re-run its row).
        let writes = Counter()
        withObservationTracking { _ = a.status; _ = b.status } onChange: { writes.n += 1 }
        tree.apply(["a.swift": .modified, "b.swift": .added])
        #expect(writes.n == 0)
        tree.apply(["a.swift": none])
        #expect(a.status == nil && b.status == .added)
    }

    @Test func cellCreatedLaterSeesEarlierStatus() {
        let tree = GitTreeStatus()
        tree.apply(["src/a.swift": .renamed])
        #expect(tree.cell(for: "src/a.swift").status == .renamed)
    }

    @Test func folderTakesStrongestChild() {
        let folders = GitStatusRollup.folders(["src/a.swift": .modified, "src/lib/b.swift": .conflicted, "docs/x.md": .untracked],
                                              ignoredFolders: [])
        let tree = GitTreeStatus()
        tree.apply(folders.mapValues { Optional($0) })
        #expect(tree.cell(for: "src").status == .conflicted)
        #expect(tree.cell(for: "src/lib").status == .conflicted)
        #expect(tree.cell(for: "docs").status == .untracked)
        #expect(tree.cell(for: "other").status == nil)
    }

    @Test func ignoredFolderIsDimmedFolderContentsToo() {
        let tree = GitTreeStatus()
        let early = tree.cell(for: "build/deep/x.o")
        tree.apply(["build/": .ignored])
        #expect(tree.cell(for: "build").status == .ignored)
        #expect(early.status == .ignored)
        #expect(tree.cell(for: "build/y.o").status == .ignored)
        #expect(tree.cell(for: "builder.swift").status == nil, "a name that only shares the prefix is not inside")
        tree.apply(["build/": none])
        #expect(early.status == nil && tree.cell(for: "build/y.o").status == nil)
    }

    @Test func untrackedDirectoryColoursItsContents() {
        let tree = GitTreeStatus()
        tree.apply(["newdir/": .untracked])
        #expect(tree.cell(for: "newdir/a/b.txt").status == .untracked)
        // A file with its own status wins over the directory's.
        tree.apply(["newdir/a/b.txt": .added])
        #expect(tree.cell(for: "newdir/a/b.txt").status == .added)
    }

    @Test func statusColoursSettingOffClearsCells() {
        let tree = GitTreeStatus()
        let a = tree.cell(for: "a.swift")
        tree.apply(["a.swift": .modified])
        tree.enabled = false
        #expect(a.status == nil && tree.cell(for: "other").status == nil)
        tree.apply(["b.swift": .added])
        #expect(tree.cell(for: "b.swift").status == nil)
        tree.enabled = true
        #expect(a.status == .modified && tree.cell(for: "b.swift").status == .added)
    }

    @Test func everyStatusHasADistinctAccessibilityName() {
        let all: [GitDisplayStatus] = [.modified, .added, .renamed, .untracked, .conflicted, .ignored]
        #expect(Set(all.map(\.accessibilityName)).count == 6)
        #expect(GitDisplayStatus.conflicted.accessibilityName == "git-status-conflicted")
    }

    // MARK: Rows in a window

    private func repoRig(_ files: [String]) throws -> Rig {
        let rig = Rig()
        try git(rig.root, "init", "-q", "-b", "main")
        for f in files { try writeFile(rig.root, f, "text of \(f)\n") }
        try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init")
        return rig
    }

    private func treeWindow(_ rig: Rig, expanded: Set<String> = []) async throws -> (GitCoordinator, TestWindow) {
        await rig.workspace.restoreUIState()
        rig.workspace.expandedFolders = expanded
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { !rig.workspace.fileTree.snapshot.children(of: "").isEmpty }
        for _ in 0..<6 { window.tick(); await Task.yield() }
        return (coordinator, window)
    }

    /// Feeds the coordinator's service result to the tree the way the update stream does, synchronously.
    private func pump(_ coordinator: GitCoordinator, _ window: TestWindow) async {
        for i in 0..<400 {
            window.tick(); await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
            if coordinator.panel.state == .ready, i > 20 { break }
        }
        for _ in 0..<4 { window.tick(); await Task.yield() }
    }

    private func value(_ window: TestWindow, _ path: String) -> String? {
        (try? window.element(identifier: "file-tree-row-\(path)"))?.value
    }

    @Test func accessibilityValueIsExposed() async throws {
        let rig = try repoRig(["a.swift", "b.swift", "src/c.swift"])
        try writeFile(rig.root, "a.swift", "changed\n")
        try writeFile(rig.root, "new.txt", "x\n")
        let (coordinator, window) = try await treeWindow(rig, expanded: ["src"])
        await pump(coordinator, window)
        #expect(value(window, "a.swift") == "git-status-modified")
        #expect(value(window, "new.txt") == "git-status-untracked")
        #expect((value(window, "b.swift") ?? "") == "")
        withExtendedLifetime(rig) {}
    }

    @Test func statusChangeReRunsOnlyChangedRows() async throws {
        let names = (0..<20).map { "f\(String(format: "%02d", $0)).swift" }
        let rig = try repoRig(names)
        let (coordinator, window) = try await treeWindow(rig)
        await pump(coordinator, window)
        let shown = names.filter { (try? window.element(identifier: "file-tree-row-\($0)")) != nil }
        #expect(shown.count >= 10)

        await pump(coordinator, window)
        let before = Dictionary(uniqueKeysWithValues: shown.map { ($0, BodyProbe.count("FileTreeLabel#\($0)")) })
        try writeFile(rig.root, "f03.swift", "edited\n")
        await coordinator.service.refreshNow()
        await pump(coordinator, window)
        #expect(value(window, "f03.swift") == "git-status-modified")
        let after = Dictionary(uniqueKeysWithValues: shown.map { ($0, BodyProbe.count("FileTreeLabel#\($0)")) })
        let changed = shown.filter { after[$0]! != before[$0]! }
        #expect(changed == ["f03.swift"], "re-ran \(changed)")
        #expect(after["f03.swift"]! - before["f03.swift"]! == 1)

        // A second identical refresh changes nothing.
        let mid = after
        await coordinator.service.refreshNow()
        await pump(coordinator, window)
        #expect(shown.allSatisfy { BodyProbe.count("FileTreeLabel#\($0)") == mid[$0]! })
        withExtendedLifetime(rig) {}
    }

    @Test func authorDotStillShowsAlongsideStatus() async throws {
        let rig = try repoRig(["a.swift"])
        try writeFile(rig.root, "a.swift", "changed\n")
        let (coordinator, window) = try await treeWindow(rig)
        rig.workspace.fileTree.setChanges([ChangedFile(path: "a.swift", authors: [.user])])
        await pump(coordinator, window)
        for _ in 0..<4 { window.tick(); await Task.yield() }
        #expect(value(window, "a.swift") == "git-status-modified")
        #expect((try? window.element(identifier: "file-tree-mark-a.swift")) != nil)
        withExtendedLifetime(rig) {}
    }
}
