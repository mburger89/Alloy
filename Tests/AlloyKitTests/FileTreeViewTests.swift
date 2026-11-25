@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct FileTreeViewTests {
    private func write(_ rig: Rig, _ paths: [String]) throws {
        for path in paths {
            let url = rig.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "text of \(path)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func treeWindow(_ paths: [String], expanded: Set<String> = []) async throws -> (Rig, TestWindow) {
        let rig = Rig()
        try write(rig, paths)
        await rig.workspace.restoreUIState()
        rig.workspace.expandedFolders = expanded
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { !rig.workspace.fileTree.snapshot.children(of: "").isEmpty }
        for _ in 0..<4 { window.tick(); await Task.yield() }
        return (rig, window)
    }

    private func settle(_ window: TestWindow) async { for _ in 0..<4 { window.tick(); await Task.yield() } }

    private func rows(_ window: TestWindow) -> [TestElement] {
        ((try? window.elements { ($0.identifier ?? "").hasPrefix("file-tree-row-") }) ?? []).sorted { $0.frame.minY.value < $1.frame.minY.value }
    }
    private func rowPaths(_ window: TestWindow) -> [String] { rows(window).compactMap { $0.identifier?.dropFirst("file-tree-row-".count).description } }
    private func center(_ window: TestWindow, _ path: String) throws -> Point<Pixels> {
        let f = try window.element(identifier: "file-tree-row-\(path)").frame
        return Point(x: Pixels((f.minX.value + f.maxX.value) / 2), y: Pixels((f.minY.value + f.maxY.value) / 2))
    }
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    @Test func treeShowsFoldersFirst() async throws {
        let (_, window) = try await treeWindow(["b.txt", "src/a.swift", "docs/x.md", "A.txt"])
        #expect(rowPaths(window) == ["docs", "src", "A.txt", "b.txt"])
        #expect(!exists(window, "file-tree-truncated"))
    }

    @Test func expandAndCollapseByKeyboard() async throws {
        let (_, window) = try await treeWindow(["src/a.swift", "src/lib/b.swift", "z.txt"])
        window.click(at: try center(window, "src"))
        await settle(window)
        #expect(rowPaths(window) == ["src", "z.txt"])
        window.typeKey(.rightArrow); await settle(window)
        #expect(rowPaths(window) == ["src", "src/lib", "src/a.swift", "z.txt"])
        window.typeKey(.downArrow); await settle(window)
        window.typeKey(.leftArrow); await settle(window)   // a collapsed folder's left goes to its parent
        window.typeKey(.leftArrow); await settle(window)
        #expect(rowPaths(window) == ["src", "z.txt"])
    }

    @Test func returnOpensInTheFocusedGroup() async throws {
        let (rig, window) = try await treeWindow(["a.swift", "b.swift"])
        window.click(at: try center(window, "b.swift")); await settle(window)
        #expect(rig.workspace.codeLayout.focusedGroup.tabs.isEmpty, "a click only selects")
        window.typeKey(.return)
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "b.swift" }
        #expect(rig.workspace.codeLayout.focusedGroup.tabs == ["b.swift"])
    }

    @Test func doubleClickOpensAsARealTab() async throws {
        let (rig, window) = try await treeWindow(["a.swift", "b.swift"])
        window.doubleClick(at: try center(window, "a.swift"))
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "a.swift" }
        #expect(rig.workspace.codeLayout.focusedGroup.tabs == ["a.swift"])
        window.doubleClick(at: try center(window, "b.swift"))
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "b.swift" }
        #expect(rig.workspace.codeLayout.focusedGroup.tabs == ["a.swift", "b.swift"], "the first tab stays")
    }

    @Test func marksShowForChangedFilesAndFolders() async throws {
        let (rig, window) = try await treeWindow(["src/a.swift", "src/b.swift", "z.txt"], expanded: ["src"])
        #expect(!exists(window, "file-tree-mark-src") && !exists(window, "file-tree-mark-z.txt"))
        rig.workspace.fileTree.setChanges([ChangedFile(path: "src/a.swift", authors: [.user]),
                                           ChangedFile(path: "src/b.swift", authors: [.outside])])
        await settle(window)
        #expect(exists(window, "file-tree-mark-src/a.swift") && exists(window, "file-tree-mark-src/b.swift"))
        #expect(exists(window, "file-tree-mark-src"), "a folder with mixed authors still shows a dot")
        #expect(!exists(window, "file-tree-mark-z.txt"))
        #expect(FileTreeLabel.color(.mixed, sessions: []) == .mutedInk)
        #expect(FileTreeLabel.color(.author(.user), sessions: []) == authorColor(.user, sessions: []))
    }

    @Test func expansionIsRemembered() async throws {
        let (rig, window) = try await treeWindow(["src/a.swift", "z.txt"], expanded: ["src"])
        #expect(rowPaths(window) == ["src", "src/a.swift", "z.txt"], "restored open folders show open")
        window.click(at: try center(window, "src")); await settle(window)
        window.typeKey(.leftArrow); await settle(window)
        #expect(rowPaths(window) == ["src", "z.txt"])
        #expect(rig.workspace.expandedFolders.isEmpty, "the collapse reached the saved set")
        window.typeKey(.rightArrow); await settle(window)
        #expect(rig.workspace.expandedFolders == ["src"])
    }

    @Test func revealSelectsTheActiveFile() async throws {
        let paths = (0..<40).map { "d\($0 < 10 ? "0" : "")\($0)/f.txt" } + ["zdeep/er/target.swift"]
        let (rig, window) = try await treeWindow(paths)
        await rig.workspace.open("zdeep/er/target.swift", in: rig.workspace.defaultPane)
        #expect(!exists(window, "file-tree-row-zdeep/er/target.swift"))
        rig.workspace.revealInTree()
        window.tick(); window.tick()
        #expect(rig.workspace.expandedFolders == ["zdeep", "zdeep/er"])
        let row = try window.element(identifier: "file-tree-row-zdeep/er/target.swift")
        #expect(rig.workspace.fileTreeSelection == "zdeep/er/target.swift")
        #expect(row.frame.minY.value >= 0 && row.frame.maxY.value <= 800)
        let tree = try window.element(identifier: "file-tree").frame
        #expect(row.frame.maxY.value <= tree.maxY.value + 0.5 && row.frame.minY.value >= tree.minY.value - 0.5, "in view")
    }

    @Test func revealMenuItemRevealsInCodeModeAndIsDisabledInChat() async throws {
        let paths = (0..<40).map { "d\($0 < 10 ? "0" : "")\($0)/f.txt" } + ["zdeep/er/target.swift"]
        let (rig, window) = try await treeWindow(paths)
        await rig.workspace.open("zdeep/er/target.swift", in: rig.workspace.defaultPane)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-reveal-in-tree")
        window.tick(); window.tick()
        #expect(rig.workspace.fileTreeSelection == "zdeep/er/target.swift")
        #expect(rig.workspace.expandedFolders == ["zdeep", "zdeep/er"])
        let row = try window.element(identifier: "file-tree-row-zdeep/er/target.swift").frame
        let tree = try window.element(identifier: "file-tree").frame
        #expect(row.minY.value >= tree.minY.value - 0.5 && row.maxY.value <= tree.maxY.value + 0.5, "in view")
        rig.workspace.setMode(.chat)
        rig.workspace.fileTreeSelection = nil
        _ = try? window.testApp.performMenuBarItem(accessibilityIdentifier: "view-reveal-in-tree")
        #expect(rig.workspace.fileTreeSelection == nil, "disabled in Chat mode")
    }

    @Test func collapsingTheChatColumnKeepsTheTreeActive() async throws {
        let (rig, window) = try await treeWindow(["a.swift"])
        #expect(rig.workspace.fileTreeActive)
        for _ in 0..<2 {
            try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-toggle-chat-column")
            await settle(window)
            #expect(rig.workspace.fileTreeActive, "the new tree appeared before the old one disappeared")
        }
        // Marks follow the ledger only while the tree is active.
        let computes = rig.workspace.fileTree.marksComputeCount
        rig.workspace.updateFileTreeMarks()
        rig.workspace.fileTree.setChanges([ChangedFile(path: "a.swift", authors: [.user])])
        #expect(rig.workspace.fileTree.marksComputeCount > computes)
    }

    @Test func foldersOpenNothing() async throws {
        let (rig, window) = try await treeWindow(["src/a.swift", "z.swift"])
        window.click(at: try center(window, "src")); await settle(window)
        window.typeKey(.return); await settle(window)
        window.doubleClick(at: try center(window, "src")); await settle(window)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.workspace.codeLayout.focusedGroup.tabs.isEmpty)
    }

    @Test func idsWithSpacesAndUnicodeWork() async throws {
        let (rig, window) = try await treeWindow(["my dir/näme é.swift"], expanded: ["my dir"])
        #expect(rowPaths(window) == ["my dir", "my dir/näme é.swift"])
        window.doubleClick(at: try center(window, "my dir/näme é.swift"))
        try await window.runUntil { rig.workspace.codeLayout.focusedGroup.activeTab == "my dir/näme é.swift" }
    }

    @Test func truncatedNoteAndDotColour() async throws {
        let (rig, window) = try await treeWindow(["a.swift"])
        #expect(!exists(window, "file-tree-truncated"))
        await rig.workspace.fileTree.update(paths: ["a.swift", "b.swift"], truncated: true)
        await settle(window)
        #expect(exists(window, "file-tree-truncated"))
        rig.workspace.fileTree.setChanges([ChangedFile(path: "a.swift", authors: [.user])])
        await settle(window)
        let dot = try window.element(identifier: "file-tree-mark-a.swift")
        #expect(dot.frame.size.width.value > 0)
    }

    @Test func selectionClearsWhenItsPathLeavesTheTree() async throws {
        let (rig, window) = try await treeWindow(["a.swift", "b.swift"])
        rig.workspace.fileTreeSelection = "b.swift"
        await rig.workspace.fileTree.update(paths: ["a.swift"], truncated: false)
        await settle(window)
        #expect(rig.workspace.fileTreeSelection == nil)
    }

    @Test func onlyExpandedRowsAreBuilt() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let paths = (0..<50).flatMap { d in (0..<200).map { "dir\(d < 10 ? "0" : "")\(d)/file\($0).txt" } }
        await rig.workspace.fileTree.update(paths: paths, truncated: false)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<4 { window.tick(); await Task.yield() }
        #expect(rig.workspace.fileTree.visibleRows().count == 50)
        #expect(rows(window).count <= 50 && !rows(window).isEmpty)
        #expect(rows(window).allSatisfy { !($0.identifier ?? "").contains("/file") })
    }

    // MARK: - the cached flatten (MetalUI #321)

    private func idle(_ window: TestWindow) { window.window.setNeedsRedraw(); window.tick() }
    private func sum(_ work: [FrameWork], _ key: KeyPath<FrameWork, Int>) -> Int { work.reduce(0) { $0 + $1[keyPath: key] } }

    private func bigTreeWindow() async throws -> (Rig, TestWindow) {
        let paths = (0..<12).flatMap { d in (0..<25).map { "dir\(d < 10 ? "0" : "")\(d)/file\($0).txt" } }
        return try await treeWindow(paths, expanded: ["dir00", "dir01", "dir02"])
    }

    /// An idle frame evaluates nothing and rebuilds nothing. In Alloy the unchanged `FileTreeView` is skipped above the
    /// `List`, so an idle frame does not even reach the cache (0 hits, 0 checks); the scroll test below, whose frames do
    /// reach it, proves the cache takes the path (1 hit; a refusal by a non-observable class, `@Environment` or a
    /// non-comparable `ForEach` would show as walks instead).
    @Test func anIdleFrameTakesTheCachedPath() async throws {
        let (_, window) = try await bigTreeWindow()
        #expect(rowPaths(window).count > 30, "\(rowPaths(window).count) rows")
        window.resetFrameWork()
        for _ in 0..<5 { idle(window) }
        let work = window.frameWork
        #expect(work.count == 5)
        #expect(work.allSatisfy { $0.outlineContentHits <= 1 }, "hits \(work.map(\.outlineContentHits))")
        #expect(sum(work, \.outlineContentEvaluations) == 0, "evaluations \(work.map(\.outlineContentEvaluations))")
        #expect(sum(work, \.outlineContentRebuilds) == 0, "rebuilds \(work.map(\.outlineContentRebuilds))")
    }

    @Test func aScrollFrameTakesTheCachedPath() async throws {
        let (_, window) = try await bigTreeWindow()
        let f = try window.element(identifier: "file-tree").frame
        let at = Point(x: Pixels((f.minX.value + f.maxX.value) / 2), y: Pixels((f.minY.value + f.maxY.value) / 2))
        window.resetFrameWork()
        window.scroll(at: at, byDeltaX: 0, deltaY: -120)
        await settle(window)
        window.scroll(at: at, byDeltaX: 0, deltaY: -120)
        await settle(window)
        let work = window.frameWork
        #expect(work.count >= 2 && work.allSatisfy { $0.outlineContentHits == 1 }, "hits \(work.map(\.outlineContentHits))")
        #expect(sum(work, \.outlineContentEvaluations) == 0, "evaluations \(work.map(\.outlineContentEvaluations))")
        #expect(sum(work, \.outlineContentRebuilds) == 0, "rebuilds \(work.map(\.outlineContentRebuilds))")
    }

    @Test func expandingAFolderWalksOnceThenCachesAgain() async throws {
        let (_, window) = try await bigTreeWindow()
        window.click(at: try center(window, "dir00"))
        window.typeKey(.leftArrow)
        await settle(window)
        #expect(!rowPaths(window).contains("dir00/file0.txt"))
        window.resetFrameWork()
        window.typeKey(.rightArrow)
        await settle(window)
        #expect(rowPaths(window).contains("dir00/file0.txt"))
        #expect(sum(window.frameWork, \.outlineContentRebuilds) == 1, "rebuilds \(window.frameWork.map(\.outlineContentRebuilds))")
        #expect(sum(window.frameWork, \.outlineContentEvaluations) > 0)
        window.resetFrameWork()
        for _ in 0..<4 { idle(window) }
        let work = window.frameWork
        #expect(work.allSatisfy { $0.outlineContentHits <= 1 }, "hits \(work.map(\.outlineContentHits))")
        #expect(sum(work, \.outlineContentEvaluations) == 0 && sum(work, \.outlineContentRebuilds) == 0,
                "\(work.map(\.outlineContentEvaluations)) \(work.map(\.outlineContentRebuilds))")
    }

    private func nameColors(_ window: TestWindow, _ path: String) throws -> [Hsla] {
        try window.drawnTextColors(in: window.element(identifier: "file-tree-row-\(path)"))
    }

    @Test func selectedUntrackedRowUsesTheSelectionTextColourNotTheGitColour() async throws {
        let rig = Rig()
        try write(rig, ["tracked.txt"])
        try git(rig.root, "init", "-q", "-b", "main")
        try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init")
        try write(rig, ["fresh.txt"])
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { rig.workspace.fileTree.snapshot.children(of: "").count == 2 }
        for _ in 0..<8 { window.tick(); await Task.yield() }
        let plain = try #require(try nameColors(window, "tracked.txt").last)   // no git status: the row's own text colour
        let git = try #require(try nameColors(window, "fresh.txt").last)
        #expect(git.toRgba() != plain.toRgba(), "an untracked row keeps its git colour while unselected")
        window.click(at: try center(window, "fresh.txt")); await settle(window)
        #expect(rig.workspace.fileTreeSelection == "fresh.txt")
        let selected = try #require(try nameColors(window, "fresh.txt").last)
        #expect(selected.toRgba() == plain.toRgba(), "the selected row's name is in the selection text colour")
        window.click(at: try center(window, "tracked.txt")); await settle(window)
        let after = try #require(try nameColors(window, "fresh.txt").last)
        #expect(after.toRgba() == git.toRgba(), "deselected, the git colour returns")
        withExtendedLifetime(coordinator) {}
    }

    /// A selection change re-runs the old and the new row's label and no other: the label reads the row's background
    /// prominence, not the workspace's selection. (Before: every visible label re-ran.)
    @Test func aSelectionChangeRerunsOnlyTheOldAndTheNewLabel() async throws {
        let paths = (0..<50).map { "f\($0 < 10 ? "0" : "")\($0).txt" }
        let (rig, window) = try await treeWindow(paths)
        let visible = rowPaths(window)
        #expect(visible.count >= 20, "a tree of \(visible.count) visible rows")
        window.click(at: try center(window, "f03.txt")); await settle(window)
        #expect(rig.workspace.fileTreeSelection == "f03.txt")
        let before = BodyProbe.count("FileTreeLabel")
        window.click(at: try center(window, "f07.txt")); await settle(window)
        #expect(rig.workspace.fileTreeSelection == "f07.txt")
        let reruns = BodyProbe.count("FileTreeLabel") - before
        #expect(reruns == 2, "\(reruns) labels re-ran for one selection change over \(visible.count) visible rows")
    }

    /// Divergence 244: a selected row reads `.increased` whether or not the list is focused, so its name keeps the
    /// selection text colour when focus is elsewhere.
    @Test func selectedButUnfocusedRowKeepsTheSelectionTextColour() async throws {
        let rig = Rig()
        try write(rig, ["tracked.txt"])
        try git(rig.root, "init", "-q", "-b", "main")
        try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init")
        try write(rig, ["fresh.txt"])
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { rig.workspace.fileTree.snapshot.children(of: "").count == 2 }
        for _ in 0..<8 { window.tick(); await Task.yield() }
        let plain = try #require(try nameColors(window, "tracked.txt").last)
        let git = try #require(try nameColors(window, "fresh.txt").last)
        rig.workspace.fileTreeSelection = "fresh.txt"; await settle(window)   // selected without a click: the list never took focus
        let selected = try #require(try nameColors(window, "fresh.txt").last)
        #expect(selected.toRgba() == plain.toRgba() && selected.toRgba() != git.toRgba(), "selected, not focused: selection text colour")
        withExtendedLifetime(coordinator) {}
    }
}
