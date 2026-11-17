@testable import AlloyCore
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct FoldCommandTests {
    /// Lines: 0 a / 1 b / 2 c / 3 d / 4 e / 5 f / 6 g / 7 h; outer 1..<7 (lines 1-6), inner 2..<5.
    private let text = "a\nb\nc\nd\ne\nf\ng\nh\n"
    private func open(_ e: Env, _ text: String, ranges: [Range<Int>]) async throws -> (CodeSelectionState, CodeFoldState) {
        e.write("a.txt", text)
        await e.ws.open("a.txt", in: .chat)
        let s = try #require(e.ws.selectionState(for: "a.txt", in: .chat))
        let f = try #require(e.ws.foldState(for: "a.txt", in: .chat))
        f.foldableRanges = ranges
        return (s, f)
    }
    private func caret(_ s: CodeSelectionState, line: Int) {
        let offset = s.buffer.snapshot().offset(of: CodePoint(row: line, column: 0))
        s.setSelections([CodeSelection(caret: offset)], primary: 0)
    }

    @Test func foldFoldsTheInnermostRangeAtTheCaret() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [1..<7, 2..<5])
        caret(s, line: 3)
        #expect(e.ws.runFold(.fold))
        #expect(f.folded == [2..<5])
    }

    @Test func foldTwiceTakesTheEnclosingRange() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [1..<7, 2..<5])
        caret(s, line: 3)
        e.ws.runFold(.fold)
        e.ws.runFold(.fold)
        #expect(f.folded == [1..<7, 2..<5])
    }

    @Test func foldOnALineWithNoRangeChangesNothing() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [2..<5])
        caret(s, line: 7)
        #expect(e.ws.runFold(.fold))
        #expect(f.folded.isEmpty)
    }

    @Test func unfoldOpensTheHeaderRange() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [1..<7, 2..<5])
        f.folded = [1..<7, 2..<5]
        caret(s, line: 1)
        e.ws.runFold(.unfold)
        #expect(f.folded == [2..<5])
    }

    @Test func unfoldWithTheCaretEvictedToTheHeaderOpensTheFold() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [2..<5])
        caret(s, line: 3)
        e.ws.runFold(.fold)
        #expect(f.folded == [2..<5])
        e.ws.runFold(.unfold)
        #expect(f.folded.isEmpty)
    }

    @Test func foldAllFoldsEveryFoldableRangeAndEvictsCarets() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [1..<7, 2..<5])
        caret(s, line: 3)
        e.ws.runFold(.foldAll)
        #expect(f.folded == [1..<7, 2..<5])
        let snap = s.buffer.snapshot()
        #expect(snap.point(at: s.primarySelection.head).row == 1)
    }

    @Test func unfoldAllOpensEverything() async throws {
        let e = Env(); defer { e.cleanup() }
        let (_, f) = try await open(e, text, ranges: [1..<7, 2..<5])
        e.ws.runFold(.foldAll)
        e.ws.runFold(.unfoldAll)
        #expect(f.folded.isEmpty)
    }

    @Test func severalCaretsFoldTheirOwnRanges() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", ranges: [0..<3, 5..<9])
        let snap = s.buffer.snapshot()
        s.setSelections([CodeSelection(caret: snap.offset(of: CodePoint(row: 1, column: 0))), CodeSelection(caret: snap.offset(of: CodePoint(row: 6, column: 0)))], primary: 0)
        e.ws.runFold(.fold)
        #expect(f.folded == [0..<3, 5..<9])
    }

    @Test func disabledWithoutADocument() async {
        let e = Env(); defer { e.cleanup() }
        #expect(!e.ws.canRunFold())
        #expect(!e.ws.runFold(.fold))
        #expect(!e.ws.runFold(.foldAll))
    }

    @Test func twoCaretsInOneRangeFoldOnlyTheInnermost() async throws {
        let e = Env(); defer { e.cleanup() }
        let (s, f) = try await open(e, text, ranges: [1..<7, 2..<5])
        let snap = s.buffer.snapshot()
        s.setSelections([CodeSelection(caret: snap.offset(of: CodePoint(row: 3, column: 0))), CodeSelection(caret: snap.offset(of: CodePoint(row: 4, column: 0)))], primary: 0)
        e.ws.runFold(.fold)
        #expect(f.folded == [2..<5])
    }

    @Test func noWriteWhenNothingChanged() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", text)
        await e.ws.restoreUIState()
        await e.ws.open("a.txt", in: .chat)
        let s = try #require(e.ws.selectionState(for: "a.txt", in: .chat))
        let f = try #require(e.ws.foldState(for: "a.txt", in: .chat))
        f.foldableRanges = [1..<7, 2..<5]
        await e.ws.flushUIState()
        let base = e.ws.uiStateWriteCount
        let sleepers = e.clock.pendingSleepers
        caret(s, line: 0)
        #expect(e.ws.runFold(.fold))
        #expect(e.ws.runFold(.unfold))
        #expect(e.ws.runFold(.unfoldAll))
        #expect(e.clock.pendingSleepers == sleepers)
        #expect(e.ws.uiStateWriteCount == base)
        caret(s, line: 3)
        e.ws.runFold(.fold)
        #expect(!f.folded.isEmpty)
        await waitUntil("timer armed") { e.clock.pendingSleepers == sleepers + 1 }
        e.clock.advance(by: 0.5)
        for _ in 0..<50 { await Task.yield() }
        await waitUntil("written") { e.ws.uiStateWriteCount == base + 1 }
    }

    @Test func emptyAndOneLineFilesAreNoOps() async throws {
        let e = Env(); defer { e.cleanup() }
        let (_, f) = try await open(e, "", ranges: [])
        for c in [FoldCommand.fold, .unfold, .foldAll, .unfoldAll] { #expect(e.ws.runFold(c)) }
        #expect(f.folded.isEmpty)
    }
}
