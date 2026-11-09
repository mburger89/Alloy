import Foundation
import Testing
@testable import AlloyCore

@Suite struct DiffDecorationTests {
    private let e1 = UUID(), e2 = UUID()
    private let s1 = UUID(), s2 = UUID()

    private func authorOf(_ id: UUID) -> Author { id == e1 ? .session(s1) : .session(s2) }

    @Test func addedRowsBecomeBars() {
        let lines: [DiffLine] = [
            .context(text: "a", line: 1),
            .added(text: "b", line: 2, edit: e1, runs: [AttributedRun(text: "b", edit: e1)]),
            .added(text: "c", line: 3, edit: e1, runs: [AttributedRun(text: "c", edit: e1)]),
            .context(text: "d", line: 4),
            .added(text: "e", line: 5, edit: e2, runs: [AttributedRun(text: "e", edit: e2)]),
        ]
        let model = DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\n")
        #expect(model.lineBars.map(\.rows) == [1..<3, 4..<5])
        #expect(model.lineBars.map(\.author) == [.session(s1), .session(s2)])
        #expect(model.lineBars.map(\.edit) == [e1, e2])
        #expect(model.tags.count == 2 && model.tags[model.tagOf[e1]!] == e1)
        #expect(model.authorRuns.isEmpty)
    }

    @Test func removedGroupAnchorsBeforeNextRow() {
        let lines: [DiffLine] = [
            .context(text: "a", line: 1),
            .removed(text: "old1", edit: e1),
            .removed(text: "old2", edit: e1),
            .added(text: "new", line: 2, edit: e1, runs: []),
            .context(text: "c", line: 3),
        ]
        let model = DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\n")
        #expect(model.removedGroups.count == 1)
        #expect(model.removedGroups[0].beforeRow == 1)
        #expect(model.removedGroups[0].lines == ["old1", "old2"])
        #expect(model.removedGroups[0].edit == e1)
        #expect(model.removedGroups[0].author == .session(s1))
        #expect(model.lineBars.map(\.rows) == [1..<2])
    }

    @Test func removedAtEndAnchorsAfterLast() {
        let lines: [DiffLine] = [
            .context(text: "a", line: 1),
            .context(text: "b", line: 2),
            .removed(text: "gone", edit: e2),
        ]
        let model = DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\n")
        #expect(model.removedGroups.map(\.beforeRow) == [2])
        #expect(model.lineBars.isEmpty)
    }

    @Test func differentEditsDoNotMerge() {
        let lines: [DiffLine] = [
            .removed(text: "x", edit: e1), .removed(text: "y", edit: e2),
            .added(text: "p", line: 1, edit: e1, runs: []), .added(text: "q", line: 2, edit: e2, runs: []),
        ]
        let model = DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\n")
        #expect(model.removedGroups.count == 2)
        #expect(model.lineBars.count == 2)
    }

    @Test func crlfOffsets() {
        // Line 1 is "ab" (2 bytes + CRLF), so line 2 starts at byte 4; its two authors' runs follow from there.
        let lines: [DiffLine] = [
            .context(text: "ab", line: 1),
            .added(text: "xyZW", line: 2, edit: e1, runs: [AttributedRun(text: "xy", edit: e1), AttributedRun(text: "ZW", edit: e2)]),
        ]
        let model = DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\r\n")
        #expect(model.authorRuns.map(\.byteRange) == [4..<6, 6..<8])
        #expect(model.authorRuns.map(\.author) == [.session(s1), .session(s2)])
    }

    @Test func emojiLineRuns() {
        let text = "a\u{1F642}b!"
        let lines: [DiffLine] = [
            .context(text: "first", line: 1),
            .added(text: text, line: 2, edit: e1, runs: [
                AttributedRun(text: "a\u{1F642}", edit: e1), AttributedRun(text: "b", edit: nil), AttributedRun(text: "!", edit: e2)]),
        ]
        let model = DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\n")
        let start = "first\n".utf8.count
        #expect(model.authorRuns.map(\.byteRange) == [start..<(start + 5), (start + 6)..<(start + 7)])
        #expect(model.authorRuns.map(\.author) == [.session(s1), .session(s2)])
    }

    @Test func singleAuthorLineHasNoRuns() {
        let lines: [DiffLine] = [.added(text: "ab", line: 1, edit: e1, runs: [AttributedRun(text: "a", edit: e1), AttributedRun(text: "b", edit: nil)])]
        #expect(DiffDecorationModel.build(lines, authorOf: authorOf, lineEnding: "\n").authorRuns.isEmpty)
    }

    @Test func mixedLineEndingsKeepExactOffsets() {
        // "ab\r\n" (4 bytes), "cd\n" (3 bytes), then the added line starts at byte 7.
        let lines: [DiffLine] = [
            .context(text: "ab", line: 1), .context(text: "cd", line: 2),
            .added(text: "xyZW", line: 3, edit: e1, runs: [AttributedRun(text: "xy", edit: e1), AttributedRun(text: "ZW", edit: e2)]),
        ]
        let model = DiffDecorationModel.build(lines, terminators: [2, 1, 1], authorOf: authorOf, lineEnding: "\n")
        #expect(model.authorRuns.map(\.byteRange) == [7..<9, 9..<11])
    }

    @Test func ledgerReportsEachLinesOwnTerminator() {
        var ledger = FileLedger(path: "m.txt", baseline: "ab\r\ncd\nef")
        let edit = ledger.applyFullText(author: .user, newText: "ab\r\ncd\nef\ngh\r\n", toolUseID: nil, date: Date())
        #expect(edit != nil)
        let entries = ledger.diffEntries()
        // ab, cd, the removed unterminated "ef" (0), the added "ef\n", then "gh\r\n".
        #expect(entries.map(\.terminator) == [2, 1, 0, 1, 2])
        #expect(entries.map(\.line) == ledger.diffLines())
    }
}
