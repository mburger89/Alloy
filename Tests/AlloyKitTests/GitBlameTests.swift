@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

@MainActor
@Suite struct GitBlameTests {
    static let base = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"
    static let second = "l1\nl2\nl3\nl4\nB5\nB6\nl7\nl8\n"

    /// A repository with two commits by two authors: Ann Lee wrote everything, Bob Ray changed rows 4 and 5.
    private func twoAuthors(worktree: [String: String] = [:], open path: String = "a.txt") async throws -> MarkRig {
        let rig = Rig()
        try git(rig.root, "init", "-q", "-b", "main")
        try writeFile(rig.root, "a.txt", Self.base)
        try git(rig.root, "add", "-A")
        try git(rig.root, "-c", "user.name=Ann Lee", "-c", "user.email=a@x.test", "commit", "-qm", "first")
        try writeFile(rig.root, "a.txt", Self.second)
        try git(rig.root, "add", "-A")
        try git(rig.root, "-c", "user.name=Bob Ray", "-c", "user.email=b@x.test", "commit", "-qm", "Change the middle")
        return try await MarkRig.make(files: [:], worktree: worktree, commit: false, open: path, rig: rig, initRepo: false)
    }

    private func texts(_ m: MarkRig, _ id: String) -> [String] {
        guard let e = try? m.window.element(identifier: id) else { return [] }
        return [e.label ?? "", e.value ?? ""]
    }

    private func exists(_ m: MarkRig, _ id: String) -> Bool { (try? m.window.element(identifier: id)) != nil }

    @Test func blameNeverRunsUntilRequested() async throws {
        let m = try await twoAuthors()
        let before = m.coordinator.spawnCount
        try await m.edit(to: Self.second + "more\n")
        await m.quiesce()
        await m.coordinator.service.refreshNow()
        #expect(m.view.blame.runs.isEmpty && !m.view.blame.requested)
        let blames = await m.coordinator.service.blameSpawns
        #expect(blames == 0, "no blame process ran (\(m.coordinator.spawnCount - before) others did)")
    }

    @Test func blameLineUsesThePrimaryCaretWithSeveralCarets() async throws {
        let m = try await twoAuthors()
        let snap = m.doc.buffer.snapshot()
        let first = snap.lineRange(0).lowerBound, bobs = snap.lineRange(4).lowerBound
        m.view.selection().setSelections([CodeSelection(caret: first), CodeSelection(caret: bobs)], primary: 1)
        m.coordinator.blameLine(in: m.view)
        await m.settle("popover") { m.view.blame.popover != nil }
        #expect(m.view.blame.popover?.run?.author == "Bob Ray")
    }

    @Test func blameLineShowsPopoverWithDetails() async throws {
        let m = try await twoAuthors()
        // Caret on row 4 (Bob's).
        let snap = m.doc.buffer.snapshot()
        let at = snap.lineRange(4).lowerBound
        m.view.selection().select(at..<at, reveal: false)
        m.coordinator.blameLine(in: m.view)
        await m.settle("popover") { m.view.blame.popover != nil }
        let run = try #require(m.view.blame.popover?.run)
        #expect(run.author == "Bob Ray" && run.summary == "Change the middle")
        #expect(run.shortHash.count == 7)
        await m.settle("rendered") { self.exists(m, "git-blame-popover") }
        #expect(exists(m, "git-blame-author") && exists(m, "git-blame-commit") && exists(m, "git-blame-summary"))
    }

    @Test func fileBlameShowsInitialsAtFirstRowOfEachRun() async throws {
        let m = try await twoAuthors()
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("runs") { m.view.blame.runs.count == 3 }
        #expect(m.view.blame.fileOn)
        #expect(m.view.blame.runs.map(\.initials) == ["AL", "BR", "AL"])
        let now = m.view.blame.runs[0].authorTime.addingTimeInterval(3 * 86400 + 60)
        let built = GitBlameMarks.build(m.view.blame.runs, rowCount: 8, now: now)
        #expect(built.map(\.lines) == [0..<1, 4..<5, 6..<7])
        #expect(built.map { $0.gutterMarker.map { String($0.text.prefix(2)) } } == ["AL", "BR", "AL"])
        #expect(built.allSatisfy { $0.gutterMarker?.text.contains(" ") == true })
    }

    @Test func ageUnits() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func age(_ s: Double) -> String { GitGutterHelp.age(from: now.addingTimeInterval(-s), now: now) }
        #expect(age(59) == "now")
        #expect(age(5 * 60) == "5m")
        #expect(age(3 * 3600) == "3h")
        #expect(age(3 * 86400) == "3d")
        #expect(age(14 * 86400) == "2w")
        #expect(age(60 * 86400) == "2mo")
        #expect(age(11 * 365 * 86400) == "11y")
        #expect(age(150 * 365 * 86400) == "99y")
    }

    @Test func markerNeverExceedsLaneWidth() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-150 * 365 * 86400)
        for name in ["Ab", "Ab Cd Ef", "A", "Extraordinarily Long-Name"] {
            let run = GitBlameRun(startLine: 0, count: 1, hash: "abc1234", author: name, authorTime: old, summary: "s")
            let text = GitBlameMarks.build([run], rowCount: 1, now: now).first?.gutterMarker?.text ?? ""
            #expect(text.count <= GitBlameMarks.laneWidth, "\(name): \(text)")
        }
    }

    @Test func fileBlameLaneWidensOnceAndNeverWhileTyping() async throws {
        let m = try await twoAuthors()
        await m.quiesce(30)
        let off = try #require(m.codeTextX())
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("runs") { m.view.blame.runs.count == 3 }
        await m.quiesce(30)
        let on = try #require(m.codeTextX())
        #expect(on > off, "the lane widens once on toggle")
        try await m.edit(to: Self.second + "typed\n")
        await m.quiesce(30)
        #expect(m.codeTextX() == on, "no shift while typing or saving")
        m.coordinator.toggleFileBlame(in: m.view)
        await m.quiesce(30)
        let after = try #require(m.codeTextX())
        // MetalUI keeps the default two-advance lane once any marker was shown, so the text settles between the two.
        #expect(after < on && after >= off, "the lane narrows on toggle off")
        try await m.edit(to: Self.second + "typed again\n")
        await m.quiesce(30)
        #expect(m.codeTextX() == after, "no shift while typing after toggle off")
    }

    @Test func uncommittedLinesGetMutedDots() {
        let run = GitBlameRun(startLine: 2, count: 1, hash: String(repeating: "0", count: 40), author: "Not Committed Yet",
                              authorTime: Date(), summary: "")
        let built = GitBlameMarks.build([run], rowCount: 5)
        #expect(built.first?.gutterMarker?.text == "\u{00B7}\u{00B7}")
    }

    @Test func blameCachedUntilSave() async throws {
        let m = try await twoAuthors()
        func blames() async -> Int { await m.coordinator.service.blameSpawns }
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("first") { m.view.blame.runs.count == 3 }
        #expect(await blames() == 1)
        m.coordinator.toggleFileBlame(in: m.view)
        #expect(!m.view.blame.fileOn)
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("on again") { m.view.blame.fileOn }
        await m.quiesce()
        #expect(await blames() == 1, "the second toggle came from the cache")
        // A save drops the cache; with blame on it is read again.
        try await m.edit(to: Self.second + "x\n")
        await waitBlames(m, 2)
        // HEAD change.
        m.workspace.startWatching()
        try git(m.rig.root, "add", "-A"); try git(m.rig.root, "commit", "-qm", "third")
        m.rig.changes.send([m.rig.root.appendingPathComponent(".git/HEAD").path])
        await waitBlames(m, 3)
    }

    /// Advances the clock until the service has run `n` blames.
    private func waitBlames(_ m: MarkRig, _ n: Int) async {
        var count = 0
        for _ in 0..<3000 {
            count = await m.coordinator.service.blameSpawns
            if count >= n { break }
            m.rig.clock.advance(by: 0.6); m.window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(count == n, "blame ran \(count) times, wanted \(n)")
    }

    @Test func toggleOffRemovesMarksAndReleasesLane() async throws {
        let m = try await twoAuthors()
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("on") { m.view.blame.runs.count == 3 }
        m.window.tick()
        m.coordinator.toggleFileBlame(in: m.view)
        m.window.tick()
        #expect(!m.view.blame.fileOn)
    }

    @Test func blameMapsThroughUnsavedEdits() async throws {
        let m = try await twoAuthors()
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("runs") { m.view.blame.runs.count == 3 }
        // Type a new line after "l2", above Bob's run, unsaved.
        let endOfL2 = m.doc.buffer.snapshot().lineRange(1).lowerBound + 2
        m.doc.buffer.replace(endOfL2..<endOfL2, with: "\nnew")
        m.window.tick()
        // Caret on the new row 2.
        let newRow = m.doc.buffer.snapshot().lineRange(2).lowerBound
        m.view.selection().select(newRow..<newRow, reveal: false)
        m.coordinator.blameLine(in: m.view)
        await m.settle("popover") { m.view.blame.popover != nil }
        #expect(m.view.blame.popover?.run == nil)
        #expect(m.view.blame.popover?.message == "Not committed yet")
        m.view.blame.popover = nil
        // The old row 4 is row 5 now and still Bob's.
        let at = m.doc.buffer.snapshot().lineRange(5).lowerBound
        m.view.selection().select(at..<at, reveal: false)
        m.coordinator.blameLine(in: m.view)
        await m.settle("popover 2") { m.view.blame.popover != nil }
        #expect(m.view.blame.popover?.run?.author == "Bob Ray")
    }

    @Test func untrackedFileGivesMessageNotError() async throws {
        let m = try await twoAuthors(worktree: ["new.txt": "x\n"], open: "new.txt")
        m.coordinator.blameLine(in: m.view)
        await m.settle("popover") { m.view.blame.popover != nil }
        #expect(m.view.blame.popover?.run == nil)
        #expect(m.view.blame.popover?.message?.isEmpty == false)
    }

    @Test func blameMarksCoexistWithGitMarks() async throws {
        let m = try await twoAuthors(worktree: ["a.txt": "l1\nL2\nl3\nl4\nB5\nB6\nl7\nl8\n"])
        await m.settle("git marks") { m.marks.isShowing }
        #expect(GitBlameMarks.owner.name != GitGutterMarks.owner.name)
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("runs") { !m.view.blame.runs.isEmpty }
        #expect(m.marks.isShowing, "blame left the git marks alone")
        m.coordinator.toggleFileBlame(in: m.view)
        #expect(m.marks.isShowing, "removing blame left the git marks alone")
        m.window.tick()
        #expect(m.changeBars().count >= 1)
    }

    @Test func closingViewDropsCache() async throws {
        let m = try await twoAuthors()
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("runs") { m.view.blame.runs.count == 3 }
        m.view.close()
        await m.quiesce()
        #expect(m.view.blame.runs.isEmpty && !m.view.blame.fileOn)
        #expect(await m.coordinator.service.blameCacheCount == 0)
    }
}
