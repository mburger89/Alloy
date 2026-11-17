@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

@MainActor
@Suite struct GitRevertHunkTests {
    static let modified = "l1\nL2\nl3\nl4\nl5\nl6\nl7\nl8\n"

    /// A repository whose committed login.swift is `panelOldText` while the worktree (and the ledger, through one
    /// session edit) holds `panelNewText`: line 2 differs from HEAD and is Claude's pending edit.
    private func claudeRig(extra: String? = nil) async throws -> MarkRig {
        let (rig, _) = try await editedRig()
        try writeFile(rig.root, "login.swift", panelOldText)
        try git(rig.root, "init", "-q", "-b", "main")
        try git(rig.root, "add", "login.swift"); try git(rig.root, "commit", "-qm", "init")
        try writeFile(rig.root, "login.swift", extra ?? panelNewText)
        let m = try await MarkRig.make(files: [:], commit: false, open: "login.swift", rig: rig, initRepo: false)
        await m.settle("hunk") { !m.marks.hunks.isEmpty }
        return m
    }

    @Test func revertRestoresHeadLinesAndIsUndoable() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        #expect(await m.marks.revert(m.marks.hunks[0], confirmed: false) == .reverted)
        #expect(m.text == MarkRig.base)
        #expect(m.doc.buffer.undo())
        #expect(m.text == Self.modified)
    }

    @Test func revertOverPendingClaudeEditAsksFirst() async throws {
        let m = try await claudeRig()
        let hunk = try #require(m.marks.hunks.first)
        #expect(await m.marks.revert(hunk, confirmed: false) == .needsConfirmation)
        #expect(m.text == panelNewText, "nothing changes before the confirmation")
        #expect(await m.marks.revert(hunk, confirmed: true) == .reverted)
        #expect(m.text == panelOldText)
        #expect(m.doc.buffer.undo())
        #expect(m.text == panelNewText)
    }

    @Test func revertWithoutOverlapNeverAsks() async throws {
        let m = try await claudeRig()
        // Unsaved typing at the end of the file, away from Claude's edit on line 2.
        let end = m.doc.buffer.snapshot().utf8Count
        m.doc.buffer.replace(end..<end, with: "tail\n")
        let hunks = GitHunks.compute(base: panelOldText, buffer: m.text)
        #expect(hunks.count == 2)
        let tail = try #require(hunks.last)
        #expect(await m.marks.revert(tail, confirmed: false) == .reverted)
        #expect(m.text == panelNewText)
    }

    @Test func revertReachesLedgerAsUserOnSave() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        try await m.workspace.save("a.txt")
        #expect(await m.marks.revert(m.marks.hunks[0], confirmed: false) == .reverted)
        try await m.workspace.save("a.txt")
        let file = try #require(m.workspace.ledger.files["a.txt"])
        #expect(file.edits.last?.author == .user)
        #expect(String(decoding: try Data(contentsOf: m.rig.root.appendingPathComponent("a.txt")), as: UTF8.self) == MarkRig.base)
    }

    @Test func hunkStageStagesBufferTextWithoutSaving() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(20)
        // An unsaved edit: the file on disk still has the committed text.
        m.doc.buffer.replace(m.doc.buffer.snapshot().lineRange(1), with: "L2 typed")
        #expect(m.doc.isDirty)
        let hunk = try #require(GitHunks.compute(base: MarkRig.base, buffer: m.text).first)
        let result = await m.marks.stage(hunk)
        #expect(result.ok, Comment(rawValue: result.stderr))
        #expect(try git(m.rig.root, "show", ":a.txt").contains("L2 typed"))
        #expect(try String(contentsOf: m.rig.root.appendingPathComponent("a.txt"), encoding: .utf8) == MarkRig.base, "the file on disk is untouched")
        // Staged already: staging again says so, unstaging works.
        #expect(await m.marks.stage(hunk).ok == false)
        let unstaged = await m.marks.unstage(hunk)
        #expect(unstaged.ok, Comment(rawValue: unstaged.stderr))
        #expect(try git(m.rig.root, "diff", "--cached").isEmpty)
    }

    @Test func popoverOpensOnBarClickAndAnchorsAtFirstRow() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: Self.modified)
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        await m.settle("bar drawn", advance: 0) { !m.bars().isEmpty }
        let bar = try #require(m.bars().first)
        m.window.click(at: Point(x: Pixels(bar.bounds.origin.x + 1.5), y: Pixels(bar.bounds.origin.y + bar.bounds.size.height / 2)))
        try await m.window.runUntil { (try? m.window.element(identifier: "code-git-hunk-popover")) != nil }
        let selection = try #require(m.view.selectedGitHunk)
        #expect(selection.anchor == m.doc.buffer.snapshot().lineRange(1))
        for id in ["git-hunk-stage", "git-hunk-unstage", "git-hunk-revert"] { _ = try m.window.element(identifier: id) }
    }

    @Test func popoverRevertButtonRevertsAndCloses() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: Self.modified)
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        await m.settle("bar drawn", advance: 0) { !m.bars().isEmpty }
        let bar = try #require(m.bars().first)
        m.window.click(at: Point(x: Pixels(bar.bounds.origin.x + 1.5), y: Pixels(bar.bounds.origin.y + bar.bounds.size.height / 2)))
        try await m.window.runUntil { (try? m.window.element(identifier: "git-hunk-revert")) != nil }
        try m.window.click(m.window.element(identifier: "git-hunk-revert"))
        try await m.window.runUntil { m.text == MarkRig.base }
        try await m.window.runUntil { (try? m.window.element(identifier: "code-git-hunk-popover")) == nil }
        #expect(m.view.selectedGitHunk == nil)
    }

    @Test func nextAndPreviousChangeWrapAndSelect() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": "l1\nL2\nl3\nl4\nl5\nL6\nl7\nL8\n"])
        await m.settle("three hunks") { m.marks.hunks.count == 3 }
        let snapshot = m.doc.buffer.snapshot()
        func caretRow() -> Int { m.doc.buffer.snapshot().point(at: m.view.selection().primarySelection.head).row }
        m.view.selection().select(0..<0)
        #expect(m.coordinator.nextChange(in: m.view, direction: 1)); #expect(caretRow() == 1)
        _ = m.coordinator.nextChange(in: m.view, direction: 1); #expect(caretRow() == 5)
        _ = m.coordinator.nextChange(in: m.view, direction: 1); #expect(caretRow() == 7)
        _ = m.coordinator.nextChange(in: m.view, direction: 1); #expect(caretRow() == 1, "wraps to the first")
        _ = m.coordinator.nextChange(in: m.view, direction: -1); #expect(caretRow() == 7, "wraps to the last")
        _ = m.coordinator.nextChange(in: m.view, direction: -1); #expect(caretRow() == 5)
        _ = snapshot
    }

    // MARK: Edge rows

    private func revert(base: String, buffer: String) throws -> String {
        let hunks = GitHunks.compute(base: base, buffer: buffer)
        let buf = CodeBuffer(buffer)
        for hunk in hunks.reversed() {
            let (range, text) = GitDocumentMarks.reversion(of: hunk, base: base, snapshot: buf.snapshot(), ending: "\n")
            buf.replace(range, with: text)
        }
        return buf.snapshot().text
    }

    @Test func revertingEveryKindOfEdgeHunkRestoresTheBase() throws {
        let cases: [(String, String)] = [
            ("a\nb\nc\n", "A\nb\nc\n"),            // first line
            ("a\nb\nc\n", "a\nb\nC\n"),            // last line
            ("a\nb\nc", "a\nb\nC"),                // last line, no final newline
            ("a\nb\nc\n", "a\nb\nc"),              // final newline removed
            ("a\nb\nc", "a\nb\nc\n"),              // final newline added
            ("a\nb\nc\n", "a\nb\n"),               // deletion at the end
            ("a\nb\nc\n", "b\nc\n"),               // deletion at the start
            ("a\nb\nc\n", ""),                     // everything deleted
            ("", "a\nb\n"),                        // empty file filled
            ("a\nb\nc\n", "a\nb\nc\nd\n"),         // appended
            ("a\nb\nc\n", "z\na\nb\nc\n"),         // prepended
            ("a\nb\nc\nd\ne\n", "a\nX\nc\nd\nY\nnew\n"),
        ]
        for (base, buffer) in cases { #expect(try revert(base: base, buffer: buffer) == base, "\(base.debugDescription) <- \(buffer.debugDescription)") }
    }
}
