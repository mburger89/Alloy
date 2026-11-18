@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

@MainActor
@Suite struct GitCompareTests {
    static let base = (1...20).map { "l\($0)" }.joined(separator: "\n") + "\n"
    /// Three separate changes: l2 modified, a line added after l10, l18 deleted.
    static let threeHunks = (1...20).map { n -> String? in
        switch n {
        case 2: "L2"
        case 10: "l10\nnew"
        case 18: nil
        default: "l\(n)"
        }
    }.compactMap { $0 }.joined(separator: "\n") + "\n"

    private func open(_ m: MarkRig, _ base: GitCompare.Base) async {
        m.coordinator.openCompare(path: m.path, against: base, in: m.pane)
        await m.settle("compare built") { m.view.compare?.base == base }
    }

    private func suffix(_ m: MarkRig) -> String { CodePanel.sideBySideSuffix(m.pane) }

    @Test func compareHeadShowsBaseOnLeft() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        #expect(m.view.left?.buffer.snapshot().text == Self.base)
        #expect(m.text == Self.threeHunks)
        m.window.tick()
        _ = try m.window.element(identifier: "sbs-left" + suffix(m))
        _ = try m.window.element(identifier: "sbs-right" + suffix(m))
        _ = try m.window.element(identifier: "git-hunk-bar")
        // Level panes: the added line gives the left a filler, the deleted line gives the right one.
        let built = GitCompareDecorations.build(try #require(m.view.compare), leftRowCount: 20, rightRowCount: 20)
        #expect(built.leftRows.count == 1 && built.rightRows.count == 1)
        // The gutter marks of the plain view are gone.
        #expect(!m.marks.isShowing)
    }

    @Test func rightPaneMarksAreChangeBars() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        let built = GitCompareDecorations.build(try #require(m.view.compare), leftRowCount: 20, rightRowCount: 21)
        let bars = built.rightLines.compactMap(\.changeBar)
        #expect(built.rightLines.count == 3 && bars.count == 3)
        #expect(built.rightLines.allSatisfy { $0.gutterBar == nil && $0.gutterMarker == nil })
        if case .modified = bars[0] {} else { Issue.record("first is modified") }
        if case .added = bars[1] {} else { Issue.record("second is added") }
        // The left pane keeps gutter bars: HEAD-side rows are not changes to the file.
        #expect(built.leftLines.allSatisfy { $0.gutterBar != nil && $0.changeBar == nil })
    }

    @Test func deletionIsDeletedAboveOnRightPane() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        let built = GitCompareDecorations.build(try #require(m.view.compare), leftRowCount: 20, rightRowCount: 20)
        let last = try #require(built.rightLines.last)
        if case .deletedAbove = last.changeBar {} else { Issue.record("deletion is deletedAbove") }
        #expect(last.lines.count == 1 && last.lines.upperBound <= 20)
    }

    @Test func clickingRightChangeBarFocusesHunk() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        let tag = try #require(m.view.compareTags.first { $0.value == 2 }?.key)
        m.view.focusCompareHunk(tag: tag)
        #expect(m.view.compareFocus == 2)
    }

    @Test func compareIndexUsesIndexText() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        try git(m.rig.root, "add", "a.txt")
        await m.coordinator.service.refreshNow()
        // An unsaved edit on top of the staged text.
        m.doc.buffer.replace(m.doc.buffer.snapshot().lineRange(4), with: "l5 edited\n")
        await open(m, .index)
        #expect(m.view.left?.buffer.snapshot().text == Self.threeHunks)
        #expect(m.view.compare?.hunks.count == 1)
        m.view.toggleCompareBase()
        await m.settle("head compare") { m.view.compare?.base == .head }
        #expect(m.view.compare?.hunks.count == 2, "l2, the edited l5 and the added line are close enough to share a hunk")
        #expect(m.view.compare?.parts.map(\.count) == [3, 1])
    }

    @Test func toggleAgainstSwitchesBase() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        m.view.toggleCompareBase()
        await m.settle("index compare") { m.view.compare?.base == .index }
        #expect(m.workspace.presentation(of: m.path, in: m.pane) == .compareIndex)
        m.view.toggleCompareBase()
        await m.settle("head compare") { m.view.compare?.base == .head }
    }

    @Test func hunkBarCountsAndSteps() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        #expect(m.view.compare?.hunks.count == 3)
        #expect(GitHunkBar.counter(focus: m.view.compareFocus, count: 3) == "1 of 3")
        m.view.stepCompare(1); m.view.stepCompare(1)
        #expect(m.view.compareFocus == 2)
        m.view.stepCompare(1)
        #expect(m.view.compareFocus == 0, "next wraps")
        m.view.stepCompare(-1)
        #expect(m.view.compareFocus == 2, "previous wraps")
        m.window.tick()
        _ = try m.window.element(identifier: "git-hunk-counter")
        #expect(GitHunkBar.counter(focus: 0, count: 0) == "No changes")
    }

    @Test func stageHunkFromCompareUpdatesIndexAndRefreshes() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .index)
        #expect(m.view.compare?.hunks.count == 3)
        m.view.compareFocus = 1   // the added line
        m.view.compareStage()
        await m.settle("one fewer hunk") { m.view.compare?.hunks.count == 2 }
        let staged = try git(m.rig.root, "diff", "--cached", "--numstat")
        #expect(staged.hasPrefix("1\t0\ta.txt"), Comment(rawValue: staged))
        #expect(try git(m.rig.root, "show", ":a.txt").contains("l10\nnew\n"))
    }

    @Test func unstageHunk() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        try git(m.rig.root, "add", "a.txt")
        await m.coordinator.service.refreshNow()
        await open(m, .head)
        #expect(m.view.compare?.hunks.count == 3)
        m.view.compareFocus = 1
        m.view.compareUnstage()
        await m.settle("unstage finished") { m.view.compareBusy == false && m.view.compare?.hunks.count == 3 }
        #expect(m.view.compareMessage == nil)
        #expect(try !git(m.rig.root, "show", ":a.txt").contains("l10\nnew\n"))
        #expect(try git(m.rig.root, "show", ":a.txt").contains("L2"), "the other hunks stay staged")
    }

    @Test func revertFromCompareIsOneUndo() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        m.view.compareFocus = 0
        m.view.compareRevert(confirmed: false)
        await m.settle("reverted") { m.view.compare?.hunks.count == 2 }
        #expect(m.text.hasPrefix("l1\nl2\n"))
        #expect(m.doc.buffer.undo())
        #expect(m.text == Self.threeHunks)
    }

    @Test func ledgerSideBySideUnchanged() async throws {
        let (rig, _) = try await editedRig()
        await rig.workspace.open("login.swift", mode: .sideBySide)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "sbs-left")) != nil }
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        #expect(view.compare == nil)
        #expect(throws: (any Error).self) { try window.element(identifier: "git-hunk-bar") }
    }

    @Test func compareUnavailableForUntrackedShowsMessage() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["u.txt": "new\n"], open: "u.txt")
        m.coordinator.openCompare(path: "u.txt", against: .head, in: m.pane)
        await m.settle("message") { m.view.compareUnavailable != nil }
        m.window.tick()
        _ = try m.window.element(identifier: "git-compare-unavailable")
        #expect(m.view.compare == nil)
    }

    @Test func comparePresentationIsNotPersisted() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base], worktree: ["a.txt": Self.threeHunks])
        await open(m, .head)
        let data = try JSONEncoder().encode(m.workspace.currentUIState())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("compareHead"))
    }

    @Test func contextIsThreeLines() async throws {
        // Two changes five lines apart merge in one compare hunk (3 + 3 context covers the gap), two marks stay apart.
        let near = Self.base.replacingOccurrences(of: "l5\n", with: "X5\n").replacingOccurrences(of: "l10\n", with: "X10\n")
        #expect(GitHunks.compute(base: Self.base, buffer: near).count == 2)
        let compare = GitCompare.build(base: .head, baseText: Self.base, snapshot: CodeBuffer(utf8: Array(near.utf8)).snapshot())
        #expect(compare.hunks.count == 1)
        #expect(compare.hunks[0].context == 3)
        #expect(compare.parts[0].count == 2)
        #expect(compare.parts[0].map(\.newStart) == [5, 10])
        // Far apart changes stay separate.
        let far = GitCompare.build(base: .head, baseText: Self.base, snapshot: CodeBuffer(utf8: Array(Self.threeHunks.utf8)).snapshot())
        #expect(far.hunks.count == 3 && far.parts.map(\.count) == [1, 1, 1])
    }

    @Test func compareOfUnsavedBufferStagesBufferText() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.base])
        m.doc.buffer.replace(m.doc.buffer.snapshot().lineRange(1), with: "L2 typed\n")
        #expect(m.doc.isDirty)
        await open(m, .index)
        #expect(m.view.compare?.hunks.count == 1)
        m.view.compareStage()
        await m.settle("staged") { m.view.compare?.hunks.isEmpty == true }
        #expect(try git(m.rig.root, "show", ":a.txt").contains("L2 typed"))
        #expect(try String(contentsOf: m.rig.root.appendingPathComponent("a.txt"), encoding: .utf8) == Self.base)
    }
}
