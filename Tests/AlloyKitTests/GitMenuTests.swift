@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct GitMenuTests {
    static let ids = ["git-compare-head", "git-stage-file", "git-unstage-file", "git-commit-menu", "git-branch-picker-menu",
                      "git-blame-line", "git-blame-file", "git-next-change", "git-prev-change", "git-refresh-menu"]
    static let editorIDs = ["git-compare-head", "git-stage-file", "git-unstage-file", "git-blame-line", "git-blame-file",
                            "git-next-change", "git-prev-change"]

    private func items(_ window: TestWindow) throws -> [PlatformMenuItem] {
        let menu = try #require(window.testApp.menuBar.first { $0.title == "Git" })
        return menu.items
    }

    private func enabled(_ window: TestWindow, _ id: String) throws -> Bool {
        window.tick()
        return try #require(try items(window).first { $0.accessibilityIdentifier == id }).isEnabled
    }

    @Test func menuHasTheTenItems() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect(try items(window).compactMap(\.accessibilityIdentifier) == Self.ids)
    }

    @Test func everythingIsDisabledWithoutACoordinator() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        for id in Self.ids { #expect(try !enabled(window, id), "\(id)") }
    }

    @Test func everythingIsDisabledOutsideARepo() async throws {
        let rig = Rig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        try writeFile(rig.root, "a.txt", "x\n")
        await rig.workspace.open("a.txt", in: rig.workspace.defaultPane)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<50 { window.tick(); await Task.yield() }
        for id in Self.ids { #expect(try !enabled(window, id), "\(id)") }
    }

    @Test func editorItemsNeedCodeModeAndRepoItemsDoNot() async throws {
        let m = try await MarkRig.make(mode: .chat)
        m.rig.workspace.setMode(.chat)
        let window = m.window
        for _ in 0..<20 { window.tick(); await Task.yield() }
        for id in Self.editorIDs { #expect(try !enabled(window, id), "chat \(id)") }
        for id in ["git-commit-menu", "git-branch-picker-menu", "git-refresh-menu"] { #expect(try enabled(window, id), "chat \(id)") }
        m.rig.workspace.setMode(.code)
        for _ in 0..<20 { window.tick(); await Task.yield() }
        for id in Self.ids { #expect(try enabled(window, id), "code \(id)") }
    }

    @Test func editorItemsNeedAnActiveDocument() async throws {
        let rig = Rig()
        try git(rig.root, "init", "-q", "-b", "main")
        try writeFile(rig.root, "a.txt", "x\n")
        try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init")
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<20 { window.tick(); await Task.yield() }
        for id in Self.editorIDs { #expect(try !enabled(window, id), "\(id)") }
        #expect(try enabled(window, "git-commit-menu"))
    }

    @Test func compareHeadItemSetsPresentation() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": MarkRig.base + "more\n"])
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-compare-head")
        #expect(m.workspace.presentation(of: m.path, in: m.pane) == .compareHead)
    }

    @Test func nextChangeItemMovesCaret() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": "l1\nl2\nL3\nl4\nl5\nl6\nL7\nl8\n"])
        await m.settle("shown") { m.marks.isShowing }
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-next-change")
        let snap = m.doc.buffer.snapshot()
        let first = snap.point(at: m.view.selection().primarySelection.head).row
        #expect(first == 2)
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-next-change")
        #expect(m.doc.buffer.snapshot().point(at: m.view.selection().primarySelection.head).row == 6)
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-prev-change")
        #expect(m.doc.buffer.snapshot().point(at: m.view.selection().primarySelection.head).row == 2)
    }

    @Test func commitItemOpensGitTab() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": MarkRig.base + "more\n"])
        #expect(m.coordinator.sidebar.tab == .files)
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-commit-menu")
        #expect(m.coordinator.sidebar.tab == .git)
        #expect(m.coordinator.sidebar.focusRequest == 1)
        try await m.window.runUntil { (try? m.window.element(identifier: "git-commit-message")) != nil }
    }

    @Test func stageAndUnstageFileItems() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": MarkRig.base + "more\n"])
        await m.settle("changed") { m.coordinator.panel.changes.map(\.path) == ["a.txt"] }
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-stage-file")
        await m.settle("staged") { m.coordinator.panel.staged.map(\.path) == ["a.txt"] }
        try m.window.testApp.performMenuBarItem(accessibilityIdentifier: "git-unstage-file")
        await m.settle("unstaged") { m.coordinator.panel.staged.isEmpty && !m.coordinator.panel.changes.isEmpty }
    }
}
