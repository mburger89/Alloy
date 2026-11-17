@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The title island's branch menu, the branch picker and the new-branch field.
@MainActor
@Suite struct BranchMenuTests {
    private func rig(branches: [String] = [], worktree: [String: String] = [:]) async throws -> MarkRig {
        let m = try await MarkRig.make(worktree: worktree)
        for b in branches { try git(m.rig.root, "branch", b) }
        m.workspace.baselineEventSeen()
        await m.quiesce(5)
        return m
    }

    private func exists(_ m: MarkRig, _ id: String) -> Bool { (try? m.window.element(identifier: id)) != nil }

    private func texts(_ m: MarkRig, _ id: String) -> [String] {
        guard let e = try? m.window.element(identifier: id) else { return [] }
        return ([e] + descendants(of: e, in: m.window)).compactMap { $0.value ?? $0.label }
    }

    private func openMenu(_ m: MarkRig) async throws -> PlatformMenu {
        try m.window.click(m.window.element(identifier: "title-branch"))
        try await m.window.runUntil { m.window.presentedMenu != nil }
        return try #require(m.window.presentedMenu)
    }

    private func items(_ menu: PlatformMenu) -> [String] {
        menu.items.compactMap { $0.kind == .action ? $0.accessibilityIdentifier : nil }
    }

    private func waitFor(_ m: MarkRig, _ what: String, _ condition: () -> Bool) async {
        await m.settle(what, condition)
    }

    /// The branch git reports (spawns git: poll with `until`, which stops at the first true).
    private func current(_ m: MarkRig) -> String {
        ((try? git(m.rig.root, "branch", "--show-current")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ticks until `condition` holds, stopping at once (MarkRig.settle evaluates its condition on every iteration).
    private func until(_ m: MarkRig, _ what: String, _ condition: () -> Bool) async {
        var ok = condition()
        for _ in 0..<3000 where !ok {
            m.window.tick()
            try? await Task.sleep(nanoseconds: 5_000_000)
            ok = condition()
        }
        #expect(ok, Comment(rawValue: "never became true: \(what)"))
    }

    @Test func menuListsEightMostRecentBranches() async throws {
        let m = try await rig(branches: (1...11).map { "b\($0)" })
        let menu = try await openMenu(m)
        let branches = items(menu).filter { $0.hasPrefix("git-branch-item-") }
        #expect(branches.count == 8)
        #expect(!branches.contains("git-branch-item-main"), "the current branch is not offered")
        #expect(items(menu).suffix(2) == ["git-branch-picker", "git-branch-new"])
    }

    @Test func branchesReadOnlyWhenMenuOpens() async throws {
        let m = try await rig(branches: ["topic"])
        await m.quiesce(30)
        let before = m.coordinator.spawnCount
        await m.quiesce(30)
        #expect(m.coordinator.spawnCount == before, "a closed menu spawns nothing")
        _ = try await openMenu(m)
        #expect(m.coordinator.spawnCount > before)
        #expect(m.coordinator.branchPicker.recent == ["topic"])
    }

    @Test func detachedHeadShowsShortHash() async throws {
        let m = try await MarkRig.make()
        try git(m.rig.root, "checkout", "-q", "--detach")
        m.workspace.baselineEventSeen()
        let short = String(try git(m.rig.root, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines).prefix(7))
        await m.settle("short hash") { self.texts(m, "title-branch").contains { $0.contains(short) } }
    }

    @Test func switchSavesDirtyDocumentsFirst() async throws {
        let m = try await rig(branches: ["topic"])
        let end = m.doc.buffer.snapshot().utf8Count
        m.doc.buffer.replace(end..<end, with: "tail\n")
        #expect(m.doc.isDirty)
        m.coordinator.switchBranch("topic")
        await waitFor(m, "switched") { m.workspace.branchName == "topic" || !m.doc.isDirty }
        await until(m, "on topic") { self.current(m) == "topic" }
        let disk = String(decoding: try Data(contentsOf: m.rig.root.appendingPathComponent("a.txt")), as: UTF8.self)
        #expect(disk.hasSuffix("tail\n"))
        #expect(m.workspace.ledger.files["a.txt"]?.edits.last?.author == .user)
    }

    @Test func switchRefusedShowsGitMessageAndKeepsFiles() async throws {
        let m = try await rig()
        try git(m.rig.root, "switch", "-q", "-c", "other")
        try writeFile(m.rig.root, "a.txt", "other branch\n")
        try git(m.rig.root, "commit", "-qam", "other")
        try git(m.rig.root, "switch", "-q", "main")
        let end = m.doc.buffer.snapshot().utf8Count
        m.doc.buffer.replace(end..<end, with: "mine\n")
        m.coordinator.switchBranch("other")
        await m.settle("error shown") { self.exists(m, "git-branch-error") }
        #expect(texts(m, "git-branch-error").joined().contains("overwritten"))
        #expect(try git(m.rig.root, "branch", "--show-current").contains("main"))
        #expect(try git(m.rig.root, "stash", "list").isEmpty)
        #expect(m.text.hasSuffix("mine\n"))
    }

    @Test func switchedFilesReloadThroughOutsideChange() async throws {
        let m = try await rig()
        try git(m.rig.root, "switch", "-q", "-c", "other")
        try writeFile(m.rig.root, "a.txt", "other branch\n")
        try git(m.rig.root, "commit", "-qam", "other")
        try git(m.rig.root, "switch", "-q", "main")
        m.workspace.startWatching()
        m.coordinator.switchBranch("other")
        await until(m, "switched") { self.current(m) == "other" }
        m.rig.changes.send([m.rig.root.appendingPathComponent("a.txt").path, m.rig.root.appendingPathComponent(".git/HEAD").path])
        await m.settle("buffer reloaded") { m.text == "other branch\n" }
        await m.settle("title follows") { m.workspace.branchName == "other" }
    }

    @Test func newBranchCreatesAndSwitches() async throws {
        let m = try await rig()
        _ = try await openMenu(m)
        try m.window.chooseMenuItem(accessibilityIdentifier: "git-branch-new")
        try await m.window.runUntil { self.exists(m, "git-branch-name") }
        m.window.typeText("feature-x")
        m.window.typeKey(.return)
        await until(m, "created") { self.current(m) == "feature-x" }
        await m.settle("panel closed") { !self.exists(m, "git-branch-name") }
    }

    @Test func invalidNewBranchShowsError() async throws {
        let m = try await rig()
        m.coordinator.showNewBranch()
        try await m.window.runUntil { self.exists(m, "git-branch-name") }
        m.window.typeKey(.return)   // empty name
        await m.settle("empty error") { self.exists(m, "git-branch-error") }
        m.window.typeText("bad name~")
        m.window.typeKey(.return)
        await m.settle("git's message") { self.texts(m, "git-branch-error").joined().contains("not a valid branch name") }
        #expect(try git(m.rig.root, "branch", "--show-current").contains("main"))
    }

    @Test func pickerFiltersAndPicks() async throws {
        let m = try await rig(branches: ["alpha", "beta", "gamma"])
        let menu = try await openMenu(m)
        _ = menu
        try m.window.chooseMenuItem(accessibilityIdentifier: "git-branch-picker")
        try await m.window.runUntil { self.exists(m, "git-branch-picker-field") }
        await m.settle("rows") { self.exists(m, "branch-row-3") }
        m.window.typeText("bet")
        await m.settle("filtered") { self.texts(m, "branch-row-0").contains("beta") && !self.exists(m, "branch-row-1") }
        m.window.typeKey(.return)
        await until(m, "switched to beta") { self.current(m) == "beta" }
    }

    @Test func pickerArrowKeysMoveSelection() async throws {
        let m = try await rig(branches: ["alpha", "beta"])
        m.coordinator.showBranchPicker()
        await m.settle("rows") { m.coordinator.branchPicker.rows.count == 3 }
        try await m.window.runUntil { self.exists(m, "git-branch-picker-field") }
        m.window.typeKey(.downArrow)
        #expect(m.coordinator.branchPicker.selected == 1)
        m.window.typeKey(.escape)
        #expect(!m.coordinator.branchPicker.isShowing)
    }

    @Test func menuAbsentWithoutCoordinatorKeepsTextBranch() async throws {
        let r = Rig(branch: "main")
        let window = try alloyWindow(r.workspace)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let e = try window.element(identifier: "title-branch")
        #expect(([e] + descendants(of: e, in: window)).contains { ($0.value ?? $0.label ?? "").contains("main") })
        try window.click(e)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(window.presentedMenu == nil)
    }

    @Test func titleIslandRerunsOnlyOnBranchChange() async throws {
        let m = try await rig(branches: ["topic"])
        await m.quiesce(20)
        let title = BodyProbe.count("TitleIsland"), menu = BodyProbe.count("BranchMenu")
        await m.quiesce(20)
        for _ in 0..<10 { m.window.typeText("a"); m.window.tick() }
        #expect(BodyProbe.count("TitleIsland") == title)
        #expect(BodyProbe.count("BranchMenu") == menu)
        try git(m.rig.root, "switch", "-q", "topic")
        m.workspace.baselineEventSeen()
        await m.quiesce(5)
        #expect(BodyProbe.count("TitleIsland") > title)
    }
}
