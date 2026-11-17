@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct CodeSidebarTabTests {
    @Test func filesTabIsDefaultAndGitTabSwitches() async throws {
        let t = try await TabRig.make(showGit: false)
        #expect(t.has("code-sidebar-tab-files") && t.has("code-sidebar-tab-git"))
        #expect(t.has("file-tree") && !t.has("git-tab"))
        try t.click("code-sidebar-tab-git")
        try await t.window.runUntil { t.has("git-tab") && !t.has("file-tree") }
        #expect(t.coordinator.sidebar.tab == .git)
        try t.click("code-sidebar-tab-files")
        try await t.window.runUntil { t.has("file-tree") && !t.has("git-tab") }
        #expect(t.coordinator.sidebar.tab == .files)
    }

    @Test func tabPersistsInUIState() async throws {
        let t = try await TabRig.make(showGit: true)
        let state = t.workspace.currentUIState()
        #expect(state.sidebarTab == .git)
        let rig2 = Rig()
        try git(rig2.root, "init", "-q", "-b", "main")
        rig2.workspace.apply(state)
        rig2.workspace.codeLayout.sidebarTab = state.sidebarTab   // restoreUIState applies the one sidebar tab (SearchTabTests)
        let coordinator = GitCoordinator.install(on: rig2.workspace)
        #expect(coordinator.sidebar.tab == .git)
    }

    @Test func gitTabNotInTreeWhileFilesShows() async throws {
        let t = try await TabRig.make(showGit: false, prepare: { _ in })
        for _ in 0..<5 { t.window.tick(); await Task.yield() }
        let before = BodyProbe.count("GitTab"), rows = BodyProbe.count("GitFileRow")
        try writeFile(t.root, "a.txt", "changed\n")
        t.rig.workspace.onSaved?("a.txt")
        await t.settle("status moved") { t.panel.changes.map(\.path) == ["a.txt"] }
        for _ in 0..<10 { t.window.tick(); await Task.yield() }
        #expect(BodyProbe.count("GitTab") == before)
        #expect(BodyProbe.count("GitFileRow") == rows)
        #expect(!t.has("git-tab"))
    }

    @Test func noCoordinatorShowsFilesOnly() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "file-tree")) != nil }
        #expect((try? window.element(identifier: "code-sidebar-tab-files")) != nil)
        #expect((try? window.element(identifier: "code-sidebar-tab-git")) == nil)
    }
}
