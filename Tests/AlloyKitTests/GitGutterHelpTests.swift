@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

@MainActor
@Suite struct GitGutterHelpTests {
    private func hunk(old: Int, new: Int, kind: GitHunk.Kind) -> GitHunk {
        GitHunk(oldStart: 1, oldCount: old, newStart: 1, newCount: new, kind: kind, oldLines: [], newLines: [])
    }

    private func run(hash: String = String(repeating: "a", count: 40)) -> GitBlameRun {
        GitBlameRun(startLine: 0, count: 2, hash: hash, author: "Ann Lee", authorTime: Date(timeIntervalSince1970: 1_700_000_000),
                    summary: "Fix the thing")
    }

    @Test func hunkTextSummarises() {
        #expect(GitGutterHelp.hunkText(hunk(old: 1, new: 3, kind: .modified)) == "+3 \u{2212}1")
        #expect(GitGutterHelp.hunkText(hunk(old: 0, new: 3, kind: .added)) == "+3")
        #expect(GitGutterHelp.hunkText(hunk(old: 2, new: 0, kind: .deleted)) == "\u{2212}2")
    }

    @Test func blameTextNamesAuthorDateHashSummary() {
        let r = run()
        #expect(GitGutterHelp.blameText(r) == "Ann Lee\n\(GitBlameMarks.dateText(r.authorTime))  aaaaaaa\nFix the thing")
        #expect(GitGutterHelp.blameText(run(hash: String(repeating: "0", count: 40))) == "Not committed yet")
    }

    @Test func helpTextIsNilForOtherHitsAndStaleTags() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: "l1\nL2\nl3\nl4\nl5\nl6\nl7\nl8\n")
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        let view = m.view
        func hit(_ source: CodeGutterHit.Source, tag: UInt64?, owner: CodeDecorationOwner?) -> CodeGutterHit {
            CodeGutterHit(lines: 1..<2, tag: tag, source: source, displayRow: 1, owner: owner)
        }
        #expect(view.gutterHelpText(for: hit(.changeBar, tag: 1, owner: GitGutterMarks.owner)) == "+1 \u{2212}1")
        #expect(view.gutterHelpText(for: hit(.changeBar, tag: 99, owner: GitGutterMarks.owner)) == nil, "stale tag")
        #expect(view.gutterHelpText(for: hit(.changeBar, tag: nil, owner: GitGutterMarks.owner)) == nil)
        #expect(view.gutterHelpText(for: hit(.gutterMarker, tag: OpenDocumentView.lightbulbTag, owner: nil)) == nil, "lightbulb")
        #expect(view.gutterHelpText(for: hit(.lineDecoration, tag: 1, owner: nil)) == nil, "author bar")
        #expect(view.gutterHelpText(for: hit(.gutterMarker, tag: 1, owner: GitBlameMarks.owner)) == nil, "no blame runs")
        #expect(view.gutterHelpText(for: hit(.changeBar, tag: 1, owner: nil)) == nil, "not git's")
    }

    @Test func helpClosureNotCalledWithoutHover() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: "l1\nL2\nl3\nl4\nl5\nl6\nl7\nl8\n")
        await m.settle("hunk") { m.marks.hunks.count == 1 }
        let before = m.view.gutterHelpCalls
        for _ in 0..<30 { m.window.tick(); await Task.yield() }
        for _ in 0..<10 { m.window.typeText("x"); m.window.tick(); await Task.yield() }
        #expect(m.view.gutterHelpCalls == before, "idle and typing frames never ask for hover text")
    }

    /// The count of drawn glyphs outside the code and gutter columns' reach is not stable, so the tooltip is told by its
    /// text length: a tooltip adds at least its visible characters to the window's glyphs.
    @Test func hoverOverChangeBarShowsHunkSummary() async throws {
        let m = try await MarkRig.make()
        await m.quiesce(30)
        try await m.edit(to: "l1\nL2\nl3\nl4\nl5\nl6\nl7\nl8\n")
        await m.settle("hunk bar", advance: 0) { m.marks.hunks.count == 1 && !m.changeBars().isEmpty }
        let bar = try #require(m.changeBars().first)
        let glyphsBefore = m.window.allGlyphs.count
        let calls = m.view.gutterHelpCalls
        m.window.hover(at: Point(x: Pixels(bar.bounds.origin.x + 1.5), y: Pixels(bar.bounds.origin.y + bar.bounds.size.height / 2)))
        m.window.advance(by: 1.5)
        m.window.tick(); await Task.yield()
        #expect(m.view.gutterHelpCalls > calls, "asked on hover")
        #expect(m.window.allGlyphs.count >= glyphsBefore + 4, "the tooltip \"+1 \u{2212}1\" is drawn")
    }

    @Test func hoverOverBlameMarkerShowsCommit() async throws {
        let rig = Rig()
        try git(rig.root, "init", "-q", "-b", "main")
        try writeFile(rig.root, "a.txt", MarkRig.base)
        try git(rig.root, "add", "-A")
        try git(rig.root, "-c", "user.name=Ann Lee", "-c", "user.email=a@x.test", "commit", "-qm", "first commit summary")
        let m = try await MarkRig.make(files: [:], commit: false, rig: rig, initRepo: false)
        m.coordinator.toggleFileBlame(in: m.view)
        await m.settle("runs") { m.view.blame.runs.count == 1 }
        await m.quiesce(20)
        let textX = try #require(m.codeTextX())
        let code = m.window.allGlyphs.filter { $0.bounds.origin.x == textX && $0.bounds.origin.y > 100 }.sorted { $0.bounds.origin.y < $1.bounds.origin.y }
        let row = try #require(code.first)
        let y = row.bounds.origin.y + row.bounds.size.height / 2
        let marker = try #require(m.window.allGlyphs.filter { $0.bounds.origin.x < textX && abs($0.bounds.origin.y + $0.bounds.size.height / 2 - y) < 3 }
            .min { $0.bounds.origin.x < $1.bounds.origin.x })
        let glyphsBefore = m.window.allGlyphs.count
        let calls = m.view.gutterHelpCalls
        m.window.hover(at: Point(x: Pixels(marker.bounds.origin.x + marker.bounds.size.width / 2), y: Pixels(y)))
        m.window.advance(by: 1.5)
        m.window.tick(); await Task.yield()
        #expect(m.view.gutterHelpCalls > calls, "asked on hover")
        #expect(m.window.allGlyphs.count >= glyphsBefore + 20, "the commit tooltip is drawn")
    }
}
