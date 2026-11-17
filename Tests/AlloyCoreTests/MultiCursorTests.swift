@testable import AlloyCore
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor @Suite struct MultiCursorTests {
    private func open(_ e: Env, _ text: String) async throws -> CodeSelectionState {
        e.write("a.txt", text)
        await e.ws.open("a.txt", in: .chat)
        return try #require(e.ws.selectionState(for: "a.txt", in: .chat))
    }
    private func ranges(_ s: CodeSelectionState) -> [Range<Int>] { s.selections.map { min($0.anchor, $0.head)..<max($0.anchor, $0.head) } }
    private let capText = "Stopped at 10,000 cursors"
    private func capNotices(_ e: Env) -> [Notice] { e.ws.notices.filter { $0.text == capText } }

    @Test func addNextOccurrenceOnCaretSelectsWord() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "alpha beta alpha")
        s.setSelections([CodeSelection(caret: 2)], primary: 0)
        #expect(e.ws.runMultiCursor(.addNextOccurrence))
        #expect(ranges(s) == [0..<5])
        e.ws.runMultiCursor(.addNextOccurrence)
        #expect(ranges(s) == [0..<5, 11..<16])
        #expect(s.primaryIndex == 1)
        e.ws.runMultiCursor(.addNextOccurrence)
        #expect(ranges(s).count == 2)
    }

    @Test func addNextOccurrenceWithMultilineSelectionMatchesExactText() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "a\nb xa\nbx a\nb")
        s.setSelections([CodeSelection(anchor: 0, head: 3)], primary: 0)
        e.ws.runMultiCursor(.addNextOccurrence)
        #expect(ranges(s) == [0..<3, 5..<8])
    }

    @Test func skipReplacesPrimaryWithNextMatch() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "ab ab ab ab")
        s.setSelections([CodeSelection(caret: 0)], primary: 0)
        e.ws.runMultiCursor(.addNextOccurrence)
        e.ws.runMultiCursor(.addNextOccurrence)
        #expect(ranges(s) == [0..<2, 3..<5])
        e.ws.runMultiCursor(.skipToNextOccurrence)
        #expect(ranges(s) == [0..<2, 6..<8])
        #expect(s.primaryIndex == 1)
    }

    @Test func selectAllOccurrencesSelectsEveryWholeWordMatch() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "cat concat cat\ncat")
        s.setSelections([CodeSelection(caret: 1)], primary: 0)
        e.ws.runMultiCursor(.selectAllOccurrences)
        #expect(ranges(s) == [0..<3, 11..<14, 15..<18])
    }

    @Test func addCaretBelowKeepsGoalColumn() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "abcdef\nab\nabcdef")
        s.setSelections([CodeSelection(caret: 4)], primary: 0)
        e.ws.runMultiCursor(.addCaretBelow)
        e.ws.runMultiCursor(.addCaretBelow)
        #expect(ranges(s) == [4..<4, 9..<9, 14..<14])
    }

    @Test func addCaretAboveOnFirstLineIsNoOp() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "abc\ndef")
        s.setSelections([CodeSelection(caret: 1)], primary: 0)
        #expect(e.ws.runMultiCursor(.addCaretAbove))
        #expect(ranges(s) == [1..<1])
        s.setSelections([CodeSelection(caret: 5)], primary: 0)
        e.ws.runMultiCursor(.addCaretAbove)
        #expect(ranges(s) == [1..<1, 5..<5].sorted { $0.lowerBound < $1.lowerBound })
    }

    @Test func commandsOnBlankLineAreNoOps() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "x\n\ny")
        s.setSelections([CodeSelection(caret: 2)], primary: 0)
        for c in [MultiCursorCommand.addNextOccurrence, .selectAllOccurrences, .skipToNextOccurrence] {
            #expect(e.ws.runMultiCursor(c))
            #expect(ranges(s) == [2..<2])
        }
        #expect(e.ws.notices.isEmpty)
        let e2 = Env(); defer { e2.cleanup() }
        let empty = try await open(e2, "")
        for c in [MultiCursorCommand.addNextOccurrence, .selectAllOccurrences, .skipToNextOccurrence] {
            #expect(e2.ws.runMultiCursor(c))
        }
        #expect(ranges(empty) == [0..<0])
        #expect(e2.ws.notices.isEmpty)
    }

    @Test func capStopsAtLimitWithNotice() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "x x x x x")
        s.setSelections([CodeSelection(caret: 0)], primary: 0)
        #expect(e.ws.runMultiCursor(.selectAllOccurrences, limit: 3))
        #expect(s.selections.count == 3)
        #expect(e.ws.notices.last == Notice(path: "a.txt", kind: .warning, text: capText))
    }

    @Test func defaultLimitIsTenThousand() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, String(repeating: "x\n", count: 10_001))
        s.setSelections([CodeSelection(caret: 0)], primary: 0)
        e.ws.runMultiCursor(.selectAllOccurrences)
        #expect(s.selections.count == 10_000)
        #expect(capNotices(e).count == 1)
    }

    @Test func capNoticeIsNotDuplicatedAndClearsOnNextSelectionChange() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "x x x x x")
        s.setSelections([CodeSelection(caret: 0)], primary: 0)
        e.ws.runMultiCursor(.selectAllOccurrences, limit: 3)
        e.ws.runMultiCursor(.selectAllOccurrences, limit: 3)
        await Task.yield(); await Task.yield()
        #expect(capNotices(e).count == 1)
        s.setSelections([CodeSelection(caret: 0)], primary: 0)
        for _ in 0..<50 where !capNotices(e).isEmpty { await Task.yield() }
        #expect(capNotices(e).isEmpty)
        #expect(e.ws.capNotices.isEmpty)
    }

    @Test func disabledWithoutAnEditor() async throws {
        let e = Env(); defer { e.cleanup() }
        #expect(!e.ws.canRunMultiCursor())
        #expect(!e.ws.runMultiCursor(.addNextOccurrence))
        #expect(e.ws.notices.isEmpty)
        let s = try await open(e, "a a")
        #expect(e.ws.canRunMultiCursor())
        _ = s
    }

    // MARK: Workspace paths with several selections

    @Test func findSeedsFromThePrimarySelectionWithSeveralCarets() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "alpha beta alpha")
        s.setSelections([CodeSelection(anchor: 0, head: 5), CodeSelection(anchor: 11, head: 16)], primary: 1)
        e.ws.showSearch(replace: false)
        #expect(e.ws.search.query.text == "alpha")
    }

    @Test func findIgnoresACaretOnlyPrimaryEvenWhenAnotherSelectionHasText() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "alpha beta alpha")
        s.setSelections([CodeSelection(anchor: 6, head: 10), CodeSelection(caret: 0)], primary: 1)
        e.ws.showSearch(replace: false)
        #expect(e.ws.search.query.text.isEmpty)
    }

    @Test func findDoesNotSeedFromAMultiLinePrimary() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "ab\ncd ab")
        s.setSelections([CodeSelection(anchor: 0, head: 5), CodeSelection(anchor: 6, head: 8)], primary: 0)
        e.ws.showSearch(replace: false)
        #expect(e.ws.search.query.text.isEmpty)
    }

    @Test func splitCopiesCaretsAndPanesStayIndependent() async throws {
        let e = Env(); defer { e.cleanup() }
        e.ws.setMode(.code)
        e.write("a.txt", "one two three four")
        let g0 = e.ws.codeLayout.focusedGroupID
        await e.ws.open("a.txt", in: .group(g0))
        let source = try #require(e.ws.selectionState(for: "a.txt", in: .group(g0)))
        source.setSelections([CodeSelection(caret: 1), CodeSelection(caret: 5), CodeSelection(caret: 9)], primary: 1)
        e.ws.splitFocused(.horizontal)
        let g1 = e.ws.codeLayout.focusedGroupID
        let copy = try #require(e.ws.selectionState(for: "a.txt", in: .group(g1)))
        #expect(copy !== source)
        #expect(copy.selections.map(\.head) == [1, 5, 9])
        copy.setSelections(copy.selections + [CodeSelection(caret: 14)], primary: 3)
        #expect(copy.selections.count == 4)
        #expect(source.selections.map(\.head) == [1, 5, 9])
    }

    @Test func closingTheTabDropsTheState() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = try await open(e, "alpha beta")
        s.setSelections([CodeSelection(caret: 1), CodeSelection(caret: 4)], primary: 0)
        await e.ws.close("a.txt", in: .chat)
        #expect(e.ws.selectionState(for: "a.txt", in: .chat) == nil)
        await e.ws.open("a.txt", in: .chat)
        let fresh = try #require(e.ws.selectionState(for: "a.txt", in: .chat))
        #expect(fresh.selections.count == 1)
    }
}
