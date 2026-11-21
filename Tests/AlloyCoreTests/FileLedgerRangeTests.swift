import Foundation
import Testing
@testable import AlloyCore

private func hunks(_ old: String, _ new: String) -> [PatchHunk] {
    Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines)
}

private let t0 = Date(timeIntervalSince1970: 1_000)
private let base = "l1\nl2\nl3\nl4\nl5\nl6\n"
private let agentText = "l1\nA2\nl3\nl4\nA5\nl6\n"

@Suite struct FileLedgerRangeTests {
    let a = UUID()
    var A: Author { .session(a) }

    private func agentLedger() -> (FileLedger, UUID) {
        var l = FileLedger(path: "f.csv", baseline: base)
        let id = l.applyPatch(author: A, originalFile: base, hunks: hunks(base, agentText), toolUseID: "tool", date: t0).last!.id
        return (l, id)
    }

    /// Scalar range of line `n` (1-based, terminator included) of the agent text.
    private func line(_ n: Int) -> Range<Int> {
        let lines = agentText.split(separator: "\n", omittingEmptySubsequences: false).map { $0.unicodeScalars.count + 1 }
        let start = lines[..<(n - 1)].reduce(0, +)
        return start..<(start + lines[n - 1])
    }

    @Test func keepingOneRangeLeavesTheRestOfTheEditLive() {
        var (l, id) = agentLedger()
        let v = l.version
        let sibling = l.keep(id, visibleRange: line(2))
        #expect(sibling != nil && sibling != id)
        #expect(l.version > v)
        #expect(l.text.text == agentText)
        #expect(l.runs().filter { $0.edit != nil }.map(\.text) == ["A"])
        #expect(l.lineOwners() == [nil, nil, nil, nil, id, nil])
        #expect(l.edits.first { $0.id == id }?.state == .live)
        let rec = l.edits.first { $0.id == sibling }!
        #expect(rec.state == .kept && rec.author == A && rec.toolUseID == "tool" && rec.date == t0)
    }

    @Test func revertingTheOriginalEditAfterAPartialKeepRevertsOnlyTheRest() {
        var (l, id) = agentLedger()
        l.keep(id, visibleRange: line(2))
        let out = l.revert(id, date: t0)
        #expect(out == .reverted(newText: "l1\nA2\nl3\nl4\nl5\nl6\n"))
    }

    @Test func keepRangeOfWholeEditEqualsKeep() {
        var (l, id) = agentLedger()
        var m = l
        m.keep(id)
        let r = l.keep(id, visibleRange: 0..<agentText.unicodeScalars.count)
        #expect(r == id)
        #expect(l.runs() == m.runs())
        #expect(l.edits.map(\.state) == m.edits.map(\.state))
        #expect(l.version == m.version)
    }

    @Test func keepRangeOfDeletionTouchingTheRangeRemovesTheTombstones() {
        var l = FileLedger(path: "f.csv", baseline: base)
        let after = "l1\nl2\nl4\nl5\nl6\n"
        let id = l.applyPatch(author: A, originalFile: base, hunks: hunks(base, after), toolUseID: nil, date: t0).last!.id
        // l3 was deleted; the tombstone sits at the start of l4 (offset 6).
        #expect(l.deletionPoints().contains { $0.edit == id && $0.offset == 6 })
        let s = l.keep(id, visibleRange: 6..<6)
        #expect(s != nil)
        #expect(l.deletionPoints().isEmpty)
        #expect(l.text.text == after)
        #expect(l.revert(id, date: t0) == .conflict(reason: "This edit is no longer live."))
        #expect(l.text.text == after)
    }

    @Test func keepingBothRangesOfOneEditTwiceLeavesNothingLive() {
        var (l, id) = agentLedger()
        let first = l.keep(id, visibleRange: line(2))
        let second = l.keep(id, visibleRange: line(5))
        #expect(first != nil && second != nil && first != second)
        #expect(l.text.text == agentText)
        #expect(l.runs().allSatisfy { $0.edit == nil })
        #expect(l.lineOwners() == Array(repeating: nil, count: 6))
        let o2 = line(2).lowerBound + 1, o5 = line(5).lowerBound
        let a2 = l.anchor(atOffset: o2, bias: .right), a5 = l.anchor(atOffset: o5, bias: .right)
        #expect(l.offset(of: a2) == o2 && l.offset(of: a5) == o5)
    }

    @Test func keepRangeOutsideAnyEditDoesNothing() {
        var (l, id) = agentLedger()
        let v = l.version
        #expect(l.keep(id, visibleRange: line(3)) == nil)
        #expect(l.version == v)
        #expect(l.edits.first { $0.id == id }?.state == .live)
        #expect(l.keep(UUID(), visibleRange: line(2)) == nil)
    }

    @Test func codableRoundTripAfterPartialKeep() throws {
        var (l, id) = agentLedger()
        l.keep(id, visibleRange: line(2))
        let back = try JSONDecoder().decode(FileLedger.self, from: JSONEncoder().encode(l))
        #expect(back == l)
        #expect(back.runs() == l.runs())
        #expect(back.version == l.version)
    }

    @Test func anchorsStillResolveAfterPartialKeep() {
        var (l, id) = agentLedger()
        let o2 = line(2).lowerBound + 1, o5 = line(5).lowerBound
        let a2 = l.anchor(atOffset: o2, bias: .right), a5 = l.anchor(atOffset: o5, bias: .right)
        l.keep(id, visibleRange: line(2))
        #expect(l.offset(of: a2) == o2)
        #expect(l.offset(of: a5) == o5)
        let n2 = l.anchor(atOffset: o2, bias: .right)
        #expect(l.offset(of: n2) == o2)
    }

    @Test func laterLiveEditInsideTheRangeStillConflictsCorrectly() {
        var (l, id) = agentLedger()
        l.keep(id, visibleRange: line(2))
        let b = UUID()
        let two = "l1\nB2\nl3\nl4\nA5\nl6\n"
        let other = l.applyPatch(author: .session(b), originalFile: agentText, hunks: hunks(agentText, two), toolUseID: nil, date: t0).last!.id
        // The kept sibling is baseline now: reverting the later edit restores the agent's kept text.
        #expect(l.revert(other, date: t0) == .reverted(newText: agentText))
        // The original still reverts cleanly for its own remaining part.
        #expect(l.revert(id, date: t0) == .reverted(newText: "l1\nA2\nl3\nl4\nl5\nl6\n"))
    }

    @Test func oldLedgerFixtureDecodes() throws {
        let (l, _) = agentLedger()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any])
        var h = try #require(json["history"] as? [String: Any])
        h.removeValue(forKey: "aliases")
        json["history"] = h
        let old = try JSONSerialization.data(withJSONObject: json)
        let back = try JSONDecoder().decode(FileLedger.self, from: old)
        #expect(back == l)
    }
}
