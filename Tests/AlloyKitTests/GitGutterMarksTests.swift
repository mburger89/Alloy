@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

@MainActor
@Suite struct GitGutterMarksTests {
    static let modified = "l1\nL2\nl3\nl4\nl5\nl6\nl7\nl8\n"

    @Test func addedModifiedDeletedMarksAppearAfterSave() async throws {
        let m = try await MarkRig.make()
        #expect(m.marks.hunks.isEmpty)
        // l2 modified, "new" added after l4, l7 deleted.
        try await m.edit(to: "l1\nL2\nl3\nl4\nnew\nl5\nl6\nl8\n")
        await m.settle("three hunks") { m.marks.hunks.count == 3 }
        #expect(m.marks.hunks.map(\.kind) == [.modified, .added, .deleted])
        #expect(m.marks.isShowing)
        let built = GitGutterMarks.build(m.marks.hunks, rowCount: m.doc.buffer.snapshot().lineCount)
        #expect(built.lines.count == 3)
        #expect(built.lines[0].changeBar != nil && built.lines[2].changeBar != nil)
        // The deletion's triangle is on the row after it (l8 is row 7 of the new text).
        #expect(built.lines[2].lines == 7..<8)
        #expect(Set(built.tags.keys) == Set(built.lines.compactMap(\.tag)))
        // Two bars are drawn in the change lane (the deletion is a triangle, not a bar).
        m.window.tick()
        #expect(m.changeBars().count >= 2)
    }

    @Test func buildEmitsChangeBarsOnly() {
        let red = Color(red: 1, green: 0, blue: 0)
        _ = red
        // l2 modified, "new" added after l4, l7 deleted.
        let hunks = GitHunks.compute(base: MarkRig.base, buffer: "l1\nL2\nl3\nl4\nnew\nl5\nl6\nl8\n")
        #expect(hunks.map(\.kind) == [.modified, .added, .deleted])
        let built = GitGutterMarks.build(hunks, rowCount: 8)
        #expect(built.lines.count == 3)
        #expect(built.lines.map(\.changeBar) == [.modified(.gitBarModified), .added(.gitBarAdded), .deletedAbove(.gitBarDeleted)])
        #expect(built.lines.allSatisfy { $0.gutterBar == nil && $0.gutterMarker == nil })
        #expect(built.lines[2].lines.count == 1)
    }

    @Test func deletionAtFirstAndLastRowAnchorsDeletedAbove() {
        // Deleted first line: the mark sits on row 0, which exists.
        let first = GitGutterMarks.build(GitHunks.compute(base: "a\nb\nc\n", buffer: "b\nc\n"), rowCount: 3)
        #expect(first.lines.map(\.lines) == [0..<1])
        #expect(first.lines.map(\.changeBar) == [.deletedAbove(.gitBarDeleted)])
        // Deleted last line: no row follows, so the mark clamps to the last row.
        let last = GitGutterMarks.build(GitHunks.compute(base: "a\nb\nc\n", buffer: "a\nb\n"), rowCount: 3)
        #expect(last.lines.map(\.lines) == [2..<3])
        #expect(last.lines.map(\.changeBar) == [.deletedAbove(.gitBarDeleted)])
        // Everything deleted: one empty row.
        let all = GitGutterMarks.build(GitHunks.compute(base: "a\nb\n", buffer: ""), rowCount: 1)
        #expect(all.lines.map(\.lines) == [0..<1])
    }

    @Test func deletionAtTheEndAndFirstLineHunks() async throws {
        let first = GitGutterMarks.build(GitHunks.compute(base: "a\nb\n", buffer: "A\nb\n"), rowCount: 3)
        #expect(first.lines.map(\.lines) == [0..<1])
        let tail = GitGutterMarks.build(GitHunks.compute(base: "a\nb\n", buffer: "a\n"), rowCount: 2)
        #expect(tail.lines.map(\.lines) == [1..<2], "a deletion at the end marks the last row")
        let all = GitGutterMarks.build(GitHunks.compute(base: "a\nb\n", buffer: ""), rowCount: 1)
        #expect(all.lines.map(\.lines) == [0..<1])
        let noNewline = GitGutterMarks.build(GitHunks.compute(base: "a\nb", buffer: "a\nb\nc"), rowCount: 3)
        #expect(!noNewline.lines.isEmpty)
    }

    @Test func marksFollowTypingWithoutSpawn() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        #expect(m.marks.currentMarkRows() == [1])
        let spawned = m.coordinator.spawnCount, recomputes = m.marks.recomputeCount
        m.doc.buffer.replace(0..<0, with: "top\nmore\n")
        m.window.tick()
        #expect(m.marks.currentMarkRows() == [3], "the mark moved with the two lines typed above it")
        for _ in 0..<20 { m.window.tick(); await Task.yield() }
        #expect(m.coordinator.spawnCount == spawned)
        #expect(m.marks.recomputeCount == recomputes)
    }

    @Test func marksRecomputeOnOutsideChange() async throws {
        let m = try await MarkRig.make()
        m.workspace.startWatching()
        try writeFile(m.rig.root, "a.txt", Self.modified)
        m.rig.changes.send([m.rig.root.appendingPathComponent("a.txt").path])
        await m.settle("mark from the outside change", advance: 0.2) { m.marks.hunks.count == 1 }
        #expect(m.text == Self.modified)
    }

    @Test func marksVanishOnHeadChange() async throws {
        let m = try await MarkRig.make()
        m.workspace.startWatching()
        try await m.edit(to: Self.modified)
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        try git(m.rig.root, "add", "-A"); try git(m.rig.root, "commit", "-qm", "second")
        m.rig.changes.send([m.rig.root.appendingPathComponent(".git/HEAD").path])
        await m.settle("marks gone after the commit", advance: 0.6) { m.marks.hunks.isEmpty && !m.marks.isShowing }
    }

    @Test func plainOnlyNotInlineNotSideBySide() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("shown") { m.marks.isShowing }
        for mode in [Presentation.inline, .sideBySide] {
            m.workspace.setPresentation(mode, of: m.path, in: m.pane)
            await m.settle("cleared in \(mode)") { !m.marks.isShowing }
        }
        m.workspace.setPresentation(.plain, of: m.path, in: m.pane)
        await m.settle("reapplied") { m.marks.isShowing }
    }

    @Test func chatModeFilePanelHasNoMarks() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified], mode: .chat)
        await m.quiesce()
        #expect(!m.marks.isShowing && m.marks.hunks.isEmpty)
    }

    @Test func untrackedFileHasNoMarks() async throws {
        let m = try await MarkRig.make(files: ["a.txt": "x\n"], worktree: ["b.txt": "one\ntwo\n"], open: "b.txt")
        await m.quiesce()
        #expect(!m.marks.isShowing && m.marks.hunks.isEmpty)
    }

    @Test func unbornHeadHasNoMarks() async throws {
        let m = try await MarkRig.make(files: ["a.txt": Self.modified], commit: false)
        await m.quiesce()
        #expect(!m.marks.isShowing)
        #expect(await m.coordinator.service.headBlobOID(path: "a.txt") == nil)
    }

    @Test func symlinkHasNoMarks() async throws {
        let rig = Rig()
        try writeFile(rig.root, "target.txt", "t\n")
        try FileManager.default.createSymbolicLink(atPath: rig.root.appendingPathComponent("link.txt").path, withDestinationPath: "target.txt")
        let m = try await MarkRig.make(files: [:], open: "target.txt", rig: rig)
        #expect(await m.coordinator.service.headBlobOID(path: "link.txt") == nil)
        #expect(await m.coordinator.service.headBlobOID(path: "target.txt") != nil)
    }

    @Test func lfsPointerAndBinaryHaveNoMarks() async throws {
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n"
        let m = try await MarkRig.make(files: ["a.txt": pointer], worktree: ["a.txt": pointer + "extra\n"])
        await m.quiesce()
        #expect(!m.marks.isShowing)
        let service = m.coordinator.service
        let oid = try #require(await service.headBlobOID(path: "a.txt"))
        #expect(await service.headText(oid: oid) == nil)
    }

    @Test func bufferOver2MiBHasNoMarks() async throws {
        let line = String(repeating: "x", count: 99) + "\n"
        let big = String(repeating: line, count: 21_500)
        #expect(big.utf8.count > GitGutterMarks.sizeLimit)
        let m = try await MarkRig.make(files: ["a.txt": big], worktree: ["a.txt": "changed\n" + big])
        await m.quiesce()
        #expect(!m.marks.isShowing && m.marks.hunks.isEmpty)
    }

    @Test func crlfBufferAgainstLFBlob() async throws {
        let crlf = MarkRig.base.replacingOccurrences(of: "\n", with: "\r\n")
        let m = try await MarkRig.make(worktree: ["a.txt": crlf])
        await m.quiesce()
        #expect(m.doc.buffer.lineEnding == .crlf)
        #expect(!m.marks.isShowing && m.marks.hunks.isEmpty, "every line is not marked")
        try await m.edit(to: crlf.replacingOccurrences(of: "l3", with: "X3"))
        await m.settle("one hunk") { m.marks.hunks.count == 1 }
        #expect(m.marks.hunks[0].newStart == 3)
    }

    @Test func gitAndAuthorBarsShareARow() async throws {
        // The window settles first, then the marks arrive with a save.
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: "l1\nL2\nl3\nl4\nl5\nL6\nl7\nl8\n")
        await m.settle("two hunks") { m.marks.hunks.count == 2 }
        await m.settle("change bars drawn", advance: 0) { m.changeBars().count >= 2 }
        let before = m.changeBars().map { [$0.bounds.origin.y, $0.bounds.size.height] }
        let red = Color(red: 1, green: 0, blue: 0)
        // A default-owner bar on the first hunk's row (an author's, a diagnostic's).
        m.view.decorations.setLineDecorations([CodeLineDecoration(lines: 1..<2, gutterBar: red)], asOf: m.doc.buffer.version)
        await m.settle("both drawn", advance: 0) { !m.gutterBars().isEmpty }
        let after = m.changeBars().map { [$0.bounds.origin.y, $0.bounds.size.height] }
        #expect(after == before, "the git bar still shows on every row")
        let authorBar = try #require(m.gutterBars().first)
        let gitBar = try #require(m.changeBars().first)
        #expect(authorBar.bounds.origin.y == gitBar.bounds.origin.y, "both marks are on the same row")
        #expect(authorBar.bounds.origin.x > gitBar.bounds.origin.x)
    }

    @Test func settingGutterMarksOffRemovesAndStops() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("shown") { m.marks.isShowing }
        var settings = m.workspace.settings
        settings.git.gutterMarks = false
        try m.workspace.updateSettings(settings, persist: false)
        await m.settle("removed") { !m.marks.isShowing }
        let n = m.marks.recomputeCount, spawned = m.coordinator.spawnCount
        try await m.edit(to: "l1\nL2\nl3\nl4\nl5\nL6\nl7\nl8\n")
        await m.quiesce()
        #expect(m.marks.recomputeCount == n && !m.marks.isShowing)
        #expect(m.coordinator.spawnCount >= spawned)   // the status refresh after the save is the tree's, not the marks'
        settings.git.gutterMarks = true
        try m.workspace.updateSettings(settings, persist: false)
        await m.settle("back") { m.marks.isShowing }
    }

    @Test func liveMarksRecomputeAfter750msIdleOnly() async throws {
        var settings = AlloySettings()
        settings.followEdits = false
        settings.git.liveMarks = true
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified]) { _ in }
        try m.workspace.updateSettings(settings, persist: false)
        await m.settle("shown") { m.marks.isShowing }
        await m.quiesce()
        let n = m.marks.recomputeCount
        m.doc.buffer.replace(m.doc.buffer.snapshot().utf8Count..<m.doc.buffer.snapshot().utf8Count, with: "tail\n")
        await m.quiesce(20)
        m.rig.clock.advance(by: 0.5)
        await m.quiesce(20)
        #expect(m.marks.recomputeCount == n, "no recompute before 750 ms")
        m.rig.clock.advance(by: 0.3)
        await m.settle("recomputed once idle", advance: 0) { m.marks.recomputeCount == n + 1 }
        await m.settle("tail hunk", advance: 0) { m.marks.hunks.count == 2 }
    }

    @Test func liveMarksOffByDefaultChangesNothing() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("shown") { m.marks.isShowing }
        await m.quiesce()
        let n = m.marks.recomputeCount, spawned = m.coordinator.spawnCount
        m.doc.buffer.replace(0..<0, with: "typed\n")
        await m.quiesce(20)
        m.rig.clock.advance(by: 0.9)
        await m.quiesce(40)
        #expect(m.marks.recomputeCount == n)
        #expect(m.coordinator.spawnCount == spawned)
    }

    @Test func diffRunsOffMainActor() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("shown") { m.marks.isShowing }
        #expect(m.marks.lastDiffOffMain == true)
    }
}

/// The change lane is reserved while git marks can show, and clicks on its bars reach git's popover.
@MainActor
@Suite struct GitChangeLaneTests {
    static let modified = "l1\nL2\nl3\nl4\nl5\nl6\nl7\nl8\n"

    @Test func laneReservedForTrackedCleanFileBeforeAnyHunk() async throws {
        let m = try await MarkRig.make()
        await m.settle("lane reserved") { m.marks.laneReserved }
        #expect(m.view.gitLaneReserved)
        #expect(m.marks.hunks.isEmpty)
        await m.quiesce(30)
        let before = try #require(m.codeTextX())
        try await m.edit(to: Self.modified)
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        await m.settle("bar drawn", advance: 0) { !m.changeBars().isEmpty }
        m.window.tick()
        #expect(m.codeTextX() == before, "the first hunk after a save moves no text")
        #expect(m.marks.laneReserved)
    }

    @Test func noLaneForUntrackedChatInlineAndSideBySide() async throws {
        let u = try await MarkRig.make(files: ["a.txt": "x\n"], worktree: ["b.txt": "one\ntwo\n"], open: "b.txt")
        await u.quiesce()
        #expect(!u.marks.laneReserved && !u.view.gitLaneReserved)
        let c = try await MarkRig.make(worktree: ["a.txt": Self.modified], mode: .chat)
        await c.quiesce()
        #expect(!c.marks.laneReserved && !c.view.gitLaneReserved)
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("reserved") { m.marks.laneReserved }
        for mode in [Presentation.inline, .sideBySide] {
            m.workspace.setPresentation(mode, of: m.path, in: m.pane)
            await m.settle("lane released in \(mode)") { !m.marks.laneReserved && !m.view.gitLaneReserved }
        }
        m.workspace.setPresentation(.plain, of: m.path, in: m.pane)
        await m.settle("lane back") { m.marks.laneReserved && m.view.gitLaneReserved }
    }

    @Test func changeBarClickOpensHunkPopover() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        // l2 modified and an author bar on the same row.
        try await m.edit(to: Self.modified)
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        let red = Color(red: 1, green: 0, blue: 0)
        m.view.decorations.setLineDecorations([CodeLineDecoration(lines: 1..<2, gutterBar: red)], asOf: m.doc.buffer.version)
        await m.settle("both bars drawn", advance: 0) { !m.changeBars().isEmpty && !m.gutterBars().isEmpty }
        let git = try #require(m.changeBars().first)
        m.window.click(at: Point(x: Pixels(git.bounds.origin.x + 1.5), y: Pixels(git.bounds.origin.y + git.bounds.size.height / 2)))
        try await m.window.runUntil { m.view.selectedGitHunk != nil }
        #expect(m.view.selectedEdit == nil, "the git bar click does not select an author edit")
    }

    @Test func changeBarContextMenuDoesNotCrash() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: Self.modified)
        await m.settle("hunk bar", advance: 0) { m.marks.hunks.count == 1 && !m.changeBars().isEmpty }
        let git = try #require(m.changeBars().first)
        m.window.rightClick(at: Point(x: Pixels(git.bounds.origin.x + 1.5), y: Pixels(git.bounds.origin.y + git.bounds.size.height / 2)))
        await m.quiesce(10)
        #expect(m.view.selectedEdit == nil)
    }

    @Test func deletionTriangleClickOpensHunkPopover() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        // l2 modified (its bar tells the lane's x) and l7 deleted: the triangle is on the row of l8.
        try await m.edit(to: "l1\nL2\nl3\nl4\nl5\nl6\nl8\n")
        await m.settle("two hunks", advance: 0) { m.marks.hunks.count == 2 && !m.changeBars().isEmpty }
        let bar = try #require(m.changeBars().first)
        let textX = try #require(m.codeTextX())
        let code = m.window.allGlyphs.filter { $0.bounds.origin.x == textX && $0.bounds.origin.y > 100 }.sorted { $0.bounds.origin.y < $1.bounds.origin.y }
        let row = try #require(code.count > 6 ? code[6] : nil)
        m.window.click(at: Point(x: Pixels(bar.bounds.origin.x + 1.5), y: Pixels(row.bounds.origin.y + row.bounds.size.height / 2)))
        try await m.window.runUntil { m.view.selectedGitHunk != nil }
        #expect(m.view.selectedGitHunk?.hunk.kind == .deleted)
    }
}
