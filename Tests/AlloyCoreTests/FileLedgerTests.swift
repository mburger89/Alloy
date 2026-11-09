import Foundation
import Testing
@testable import AlloyCore

private func hunks(_ old: String, _ new: String) -> [PatchHunk] {
    Patch.diff(old: TextLines(old).lines, new: TextLines(new).lines)
}

private let t0 = Date(timeIntervalSince1970: 1_000)

@Suite struct FileLedgerTests {
    let a = UUID(), b = UUID()
    var A: Author { .session(a) }
    var B: Author { .session(b) }

    private func edit(_ l: inout FileLedger, _ author: Author, to new: String, at: Double = 1_000) -> EditRecord {
        let old = l.text.text
        return l.applyPatch(author: author, originalFile: old, hunks: hunks(old, new), toolUseID: nil,
                            date: Date(timeIntervalSince1970: at)).last!
    }

    @Test func sessionEditOwnsChangedLine() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let e = edit(&l, A, to: "1\nX\n3\n").id
        #expect(l.text.text == "1\nX\n3\n")
        #expect(l.lineOwners() == [nil, e, nil])
        #expect(l.diffLines() == [
            .context(text: "1", line: 1),
            .removed(text: "2", edit: e),
            .added(text: "X", line: 2, edit: e, runs: [AttributedRun(text: "X", edit: e)]),
            .context(text: "3", line: 3),
        ])
    }

    @Test func twoSessionsSameLineBothAttributed() {
        var l = FileLedger(path: "f.txt", baseline: "let value = 1\n")
        let e = edit(&l, A, to: "let value = 10\n", at: 1).id
        let f = edit(&l, B, to: "var value = 10\n", at: 2).id
        #expect(l.text.text == "var value = 10\n")
        #expect(l.runs() == [
            AttributedRun(text: "var", edit: f),
            AttributedRun(text: " value = 1", edit: nil),
            AttributedRun(text: "0", edit: e),
            AttributedRun(text: "\n", edit: nil),
        ])
        #expect(l.lineOwners() == [f])
    }

    @Test func staleOriginalRecordsOutsideEditFirst() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let original = "1\n2\n3\n4\n"
        let recs = l.applyPatch(author: A, originalFile: original, hunks: hunks(original, "1\n2\n3\n4\n5\n"),
                                toolUseID: "t", date: t0)
        #expect(recs.count == 2)
        #expect(recs[0].author == .outside)
        #expect(recs[1].author == A)
        #expect(recs[1].toolUseID == "t")
        #expect(l.text.text == "1\n2\n3\n4\n5\n")
        let owners = l.lineOwners()
        #expect(owners == [nil, nil, nil, recs[0].id, recs[1].id])
    }

    @Test func mismatchedHunksChangeNothing() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let bad = [PatchHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-nope", "+X"])]
        let recs = l.applyPatch(author: A, originalFile: "1\n2\n3\n", hunks: bad, toolUseID: nil, date: t0)
        #expect(recs.isEmpty)
        #expect(l.text.text == "1\n2\n3\n")
        #expect(l.edits.isEmpty)
    }

    @Test func writeCreateOwnsEverything() {
        var l = FileLedger(path: "f.txt", baseline: "")
        let e = l.applyFullText(author: A, newText: "a\nb\n", toolUseID: nil, date: t0)!.id
        #expect(l.lineOwners() == [e, e])
        #expect(l.runs() == [AttributedRun(text: "a\nb\n", edit: e)])
    }

    @Test func keepFoldsIntoBaseline() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let e = edit(&l, A, to: "1\nX\n3\n").id
        l.keep(e)
        #expect(l.text.text == "1\nX\n3\n")
        #expect(l.edits.first { $0.id == e }?.state == .kept)
        #expect(l.diffLines() == [.context(text: "1", line: 1), .context(text: "X", line: 2), .context(text: "3", line: 3)])
        #expect(l.runs().allSatisfy { $0.edit == nil })
        #expect(l.lineOwners() == [nil, nil, nil])
    }

    @Test func revertSurvivesShiftedLines() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let e = edit(&l, A, to: "1\nX\n3\n").id
        let hundred = (0..<100).map { "new \($0)\n" }.joined()
        _ = edit(&l, B, to: hundred + "1\nX\n3\n")
        guard case .reverted(let newText) = l.revert(e, date: t0) else { Issue.record("expected revert"); return }
        #expect(newText == hundred + "1\n2\n3\n")
        #expect(l.text.text == newText)
    }

    @Test func revertRestoresDeletedText() {
        let base = "1\n2\n3\n4\n5\n6\n7\n"
        var l = FileLedger(path: "f.txt", baseline: base)
        let e = edit(&l, A, to: "1\n2\n6\n7\n").id
        guard case .reverted(let newText) = l.revert(e, date: t0) else { Issue.record("expected revert"); return }
        #expect(newText == base)
        #expect(l.text.text == base)
    }

    @Test func revertConflictWhenLaterEditTouchesInsertedText() {
        var l = FileLedger(path: "f.txt", baseline: "x\n")
        let e = edit(&l, A, to: "xhello\n").id
        _ = edit(&l, B, to: "xhelp\n")
        let before = l
        guard case .conflict(let reason) = l.revert(e, date: t0) else { Issue.record("expected conflict"); return }
        #expect(reason.contains(b.uuidString))
        #expect(l == before)
        #expect(l.text.text == "xhelp\n")
    }

    @Test func revertConflictWhenLaterEditInsertsInsideRun() {
        var l = FileLedger(path: "f.txt", baseline: "x\n")
        let e = edit(&l, A, to: "xhello\n").id
        _ = edit(&l, B, to: "xhe--llo\n")
        guard case .conflict = l.revert(e, date: t0) else { Issue.record("expected conflict"); return }
    }

    @Test func insertAdjacentToRunIsNotAConflict() {
        var l = FileLedger(path: "f.txt", baseline: "1\n3\n")
        let e = edit(&l, A, to: "1\n2\n3\n").id
        _ = edit(&l, B, to: "1\n2\n2b\n3\n")
        guard case .reverted(let t) = l.revert(e, date: t0) else { Issue.record("expected revert"); return }
        #expect(t == "1\n2b\n3\n")
    }

    @Test func revertIsAUserEdit() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let e = edit(&l, A, to: "1\nX\n3\n").id
        _ = l.revert(e, date: t0)
        #expect(l.edits.last?.author == .user)
        #expect(l.edits.first(where: { $0.id == e })?.state == .reverted)
        #expect(!l.edits.last!.hunks.isEmpty)
    }

    @Test func anchorsTrackEdits() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let e = edit(&l, A, to: "1\nX\n3\n").id
        let anchor = l.anchor(atOffset: 2, bias: .right)
        #expect(l.offset(of: anchor) == 2)
        _ = l.applyFullText(author: B, newText: "abc\n" + l.text.text, toolUseID: nil, date: t0)
        #expect(l.offset(of: anchor) == 6)
        guard case .reverted = l.revert(e, date: t0) else { Issue.record("expected revert"); return }
        #expect(l.text.text == "abc\n1\n2\n3\n")
        #expect(l.offset(of: anchor) == 6)   // nearest visible position on its bias side
        let end = l.anchor(atOffset: l.text.text.unicodeScalars.count, bias: .right)
        _ = l.applyFullText(author: B, newText: "abc\n1\n2\n3\nmore\n", toolUseID: nil, date: t0)
        #expect(l.offset(of: end) == 15)
    }

    @Test func anchorsSurviveKeep() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let right = l.anchor(atOffset: 2, bias: .right), left = l.anchor(atOffset: 2, bias: .left)
        let e = edit(&l, A, to: "1\nX\n3\n").id
        #expect(l.offset(of: right) == 3)   // "2" is deleted: next visible char is the "\n" after X
        #expect(l.offset(of: left) == 2)    // previous visible char is X
        l.keep(e)                           // physically removes the "2" tombstone
        #expect(l.text.text == "1\nX\n3\n")
        #expect(l.offset(of: right) == 3)
        #expect(l.offset(of: left) == 2)
        _ = l.applyFullText(author: B, newText: "abc\n" + l.text.text, toolUseID: nil, date: t0)
        #expect(l.offset(of: right) == 7)
        #expect(l.offset(of: left) == 6)
    }

    @Test func keptInsertInsideRunDoesNotBlockRevert() {
        var l = FileLedger(path: "f.txt", baseline: "x\n")
        let e = edit(&l, A, to: "xhello\n").id
        let f = edit(&l, B, to: "xhe--llo\n").id
        l.keep(f)
        guard case .reverted(let t) = l.revert(e, date: t0) else { Issue.record("expected revert"); return }
        #expect(t == "x--\n")
    }

    @Test func keptDeletionDoesNotBlockRevert() {
        var l = FileLedger(path: "f.txt", baseline: "x\n")
        let e = edit(&l, A, to: "xhello\n").id
        let f = edit(&l, B, to: "xheo\n").id
        l.keep(f)
        guard case .reverted(let t) = l.revert(e, date: t0) else { Issue.record("expected revert"); return }
        #expect(t == "x\n")
    }

    @Test func removedLineFallsBackToRegionOwner() {
        var l = FileLedger(path: "f.txt", baseline: "let value = 1\nother\n")
        let e = edit(&l, A, to: "let value = 10\nother\n", at: 1).id
        let f = edit(&l, B, to: "let value = 10\nchanged\n", at: 2).id
        let lines = l.diffLines()
        #expect(lines.contains(.removed(text: "let value = 1", edit: e)))
        #expect(lines.contains(.removed(text: "other", edit: f)))
        #expect(lines.contains { if case .added("let value = 10", 1, e, _) = $0 { true } else { false } })
    }

    @Test func removedLineAttributedByIdentityWhenEarlierLineInserted() {
        var l = FileLedger(path: "f.txt", baseline: "let value = 1\nz\n")
        let e = edit(&l, A, to: "let value = 10\nz\n", at: 1).id
        let f = edit(&l, B, to: "new\nlet value = 10\nz\n", at: 2).id
        let lines = l.diffLines()
        #expect(lines.contains(.removed(text: "let value = 1", edit: e)))
        #expect(lines.contains { if case .added("new", 1, f, _) = $0 { true } else { false } })
        #expect(lines.contains { if case .added("let value = 10", 2, e, _) = $0 { true } else { false } })
    }

    @Test func addedLineAttributedByIdentityWhenEarlierLineInserted() {
        var l = FileLedger(path: "f.txt", baseline: "let value = 10\nz\n")
        let e = edit(&l, A, to: "let value = 1\nz\n", at: 1).id   // deletes the "0"
        _ = edit(&l, B, to: "new\nlet value = 1\nz\n", at: 2)
        let lines = l.diffLines()
        #expect(lines.contains { if case .added("let value = 1", 2, e, _) = $0 { true } else { false } })
        #expect(lines.contains(.removed(text: "let value = 10", edit: e)))
    }

    @Test func multiEditRegionKeepsPerLineAttribution() {
        var l = FileLedger(path: "f.txt", baseline: "let value = 1\nz\nq\n")
        let e = edit(&l, A, to: "let value = 10\nz\nq\n", at: 1).id
        let f = edit(&l, B, to: "p1\np2\nlet value = 10\nz\nr\n", at: 2).id
        let lines = l.diffLines()
        #expect(lines.contains(.removed(text: "let value = 1", edit: e)))
        #expect(lines.contains(.removed(text: "q", edit: f)))
        #expect(lines.contains { if case .added("let value = 10", 3, e, _) = $0 { true } else { false } })
        #expect(lines.contains { if case .added("r", 5, f, _) = $0 { true } else { false } })
    }

    @Test func lineSplitAddedLineIsAttributedToSplitter() {
        for (base, split, final, line) in [("abcd\n", "ab\ncd\n", "new\nab\ncd\n", 3), ("abcd", "ab\ncd", "new\nab\ncd", 3)] {
            var l = FileLedger(path: "f.txt", baseline: base)
            let a = edit(&l, A, to: split, at: 1).id
            _ = edit(&l, B, to: final, at: 2)
            #expect(l.diffLines().contains { if case .added("cd", line, a, _) = $0 { true } else { false } }, "\(base.debugDescription)")
        }
    }

    @Test func lineJoinRemovedLineIsAttributedToJoiner() {
        for (base, join, final) in [("ab\ncd\n", "abcd\n", "new\nabcd\n"), ("ab\ncd", "abcd", "new\nabcd")] {
            var l = FileLedger(path: "f.txt", baseline: base)
            let a = edit(&l, A, to: join, at: 1).id
            _ = edit(&l, B, to: final, at: 2)
            #expect(l.diffLines().contains(.removed(text: "cd", edit: a)), "\(base.debugDescription)")
        }
    }

    @Test func insertionAtLineStartIsAttributedByIdentity() {
        var l = FileLedger(path: "f.txt", baseline: "a\nfoo()\nz\n")
        let e = edit(&l, A, to: "a\n    foo()\nz\n", at: 1).id
        _ = edit(&l, B, to: "a\nnew\n    foo()\nz\n", at: 2)
        #expect(l.diffLines().contains(.removed(text: "foo()", edit: e)))
    }

    @Test func insertionAtEndOfUnterminatedFinalLineIsAttributedByIdentity() {
        var l = FileLedger(path: "f.txt", baseline: "let value = 1")
        let e = edit(&l, A, to: "let value = 10", at: 1).id
        _ = edit(&l, B, to: "new\nlet value = 10", at: 2)
        #expect(l.diffLines().contains(.removed(text: "let value = 1", edit: e)))
    }

    @Test func addedSideDeletionAtLineStartAndUnterminatedEnd() {
        var l = FileLedger(path: "f.txt", baseline: "a\n    foo()\nz\n")
        let e = edit(&l, A, to: "a\nfoo()\nz\n", at: 1).id   // deletes the indent
        _ = edit(&l, B, to: "a\nnew\nfoo()\nz\n", at: 2)
        #expect(l.diffLines().contains { if case .added("foo()", 3, e, _) = $0 { true } else { false } })
        var m = FileLedger(path: "g.txt", baseline: "let value = 10")
        let e2 = edit(&m, A, to: "let value = 1", at: 1).id
        _ = edit(&m, B, to: "new\nlet value = 1", at: 2)
        #expect(m.diffLines().contains { if case .added("let value = 1", 2, e2, _) = $0 { true } else { false } })
    }

    @Test func decodesLedgerWithoutRemovalsOrMetas() throws {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n")
        _ = edit(&l, A, to: "1\nX\n")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as! [String: Any]
        var history = json["history"] as! [String: Any]
        history["removals"] = nil
        json["history"] = history
        let old = try JSONDecoder().decode(FileLedger.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old == l)
        history["metas"] = nil
        json["history"] = history
        let older = try JSONDecoder().decode(FileLedger.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(older.fragmentCount == l.fragmentCount)
    }

    @Test func normalisationOnlyChangeIsRecorded() {
        let nfc = "caf\u{E9}\n", nfd = "cafe\u{301}\n"
        var l = FileLedger(path: "f.txt", baseline: nfc)
        let r = l.applyFullText(author: A, newText: nfd, toolUseID: nil, date: t0)
        #expect(r != nil)
        #expect(l.text.text.utf8.elementsEqual(nfd.utf8))
        #expect(!r!.hunks.isEmpty)
        #expect(!l.lineOwners().compactMap { $0 }.isEmpty)
    }

    @Test func crlfFileStaysCRLF() {
        var l = FileLedger(path: "f.txt", baseline: "a\r\nb\r\nc\r\n")
        let recs = l.applyPatch(author: A, originalFile: "a\r\nb\r\nc\r\n",
                                hunks: [PatchHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 4,
                                                  lines: [" a", "-b", "+b2", "+b3", " c"])],
                                toolUseID: nil, date: t0)
        #expect(recs.count == 1)
        #expect(l.text.text == "a\r\nb2\r\nb3\r\nc\r\n")
        #expect(!l.text.text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }

    @Test func noTrailingNewlineRoundTrips() {
        var l = FileLedger(path: "f.txt", baseline: "a\nb")
        _ = edit(&l, A, to: "a\nb\nc")
        #expect(l.text.text == "a\nb\nc")
        // Line hunks cannot express a trailing-newline change; a full-text write can.
        l.applyFullText(author: A, newText: "a\nb\nc\n", toolUseID: nil, date: t0)
        #expect(l.text.text == "a\nb\nc\n")
    }

    @Test func largeFileSingleEditIsCheap() {
        let lines = (0..<100_000).map { "line \($0)" }
        let base = lines.joined(separator: "\n") + "\n"
        var l = FileLedger(path: "big.txt", baseline: base)
        let h = PatchHunk(oldStart: 49_998, oldLines: 7, newStart: 49_998, newLines: 7,
                          lines: [" line 49997", " line 49998", " line 49999", "-line 50000", "+CHANGED",
                                  " line 50001", " line 50002", " line 50003"])
        let recs = l.applyPatch(author: A, originalFile: base, hunks: [h], toolUseID: nil, date: t0)
        #expect(recs.count == 1)
        #expect(l.edits.count == 1)
        #expect(l.fragmentCount <= 8)
        #expect(l.text.lines[50_000] == "CHANGED")
        #expect(l.lineOwners().count == 100_000)
    }

    @Test func codableRoundTripIsEqual() throws {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        _ = edit(&l, A, to: "1\nX\n3\n")
        let data = try JSONEncoder().encode(l)
        #expect(try JSONDecoder().decode(FileLedger.self, from: data) == l)
    }

    // MARK: Late tool results

    @Test func lateToolResultAdoptsTheOutsideRecord() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        let n = "1\n2\nX\n"
        l.applyFullText(author: .outside, newText: n, toolUseID: nil, date: t0)
        l.applyFullText(author: .user, newText: "1\nmine\nX\n", toolUseID: nil, date: t0)
        let rec = l.adoptOutside(as: A, originalFile: "1\n2\n3\n", newText: n, toolUseID: "tu1")
        #expect(rec?.author == A && rec?.toolUseID == "tu1")
        #expect(l.edits.map(\.author) == [A, .user])
        #expect(l.text.text == "1\nmine\nX\n")
        let owners = l.lineOwners().map { id in id.flatMap { id in l.edits.first { $0.id == id }?.author } }
        #expect(owners == [nil, .user, A])
    }

    /// A relabel changes no text, edit count or state, yet a cache keyed by `version` must see it.
    @Test func adoptionMovesTheVersionAndSurvivesPersistence() throws {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        l.applyFullText(author: .outside, newText: "1\n2\nX\n", toolUseID: nil, date: t0)
        let before = l.version
        #expect(l.adoptOutside(as: A, originalFile: "1\n2\n3\n", newText: "1\n2\nX\n", toolUseID: "tu1") != nil)
        #expect(l.version > before)
        let back = try JSONDecoder().decode(FileLedger.self, from: JSONEncoder().encode(l))
        #expect(back == l && back.version == l.version)
        // A ledger saved before the counter existed still decodes.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any])
        object.removeValue(forKey: "revision")
        let old = try JSONDecoder().decode(FileLedger.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.edits == l.edits)
    }

    /// The common path (no live outside or Bash record, or a ledger still at the original) is a cheap no.
    @Test func canAdoptIsFalseUnlessARecordCouldBeAdopted() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        #expect(!l.canAdopt(originalFile: "1\n2\n3\n"))
        #expect(!l.canAdopt(originalFile: "other\n"))   // no records at all
        l.applyFullText(author: A, newText: "1\n2\nX\n", toolUseID: "tu0", date: t0)
        #expect(!l.canAdopt(originalFile: "1\n2\n3\n"))   // only a tool record
        l.applyFullText(author: .outside, newText: "1\n2\nY\n", toolUseID: nil, date: t0)
        #expect(l.canAdopt(originalFile: "1\n2\nX\n"))
        #expect(!l.canAdopt(originalFile: "1\n2\nY\n"))   // the ledger is already at the original
        l.keepAll { _ in true }
        #expect(!l.canAdopt(originalFile: "1\n2\nX\n"))   // the outside record is no longer live
    }

    @Test func adoptionNeedsALedgerThatMovedPastTheOriginal() {
        var l = FileLedger(path: "f.txt", baseline: "1\n2\n3\n")
        l.applyFullText(author: .outside, newText: "1\n2\nX\n", toolUseID: nil, date: t0)
        // The ledger text is the original: nothing to adopt, the result is recorded the normal way.
        #expect(l.adoptOutside(as: A, originalFile: "1\n2\nX\n", newText: "1\n2\nX\n", toolUseID: nil) == nil)
        // A different outside change is not adopted.
        l.applyFullText(author: .user, newText: "1\nmine\nX\n", toolUseID: nil, date: t0)
        #expect(l.adoptOutside(as: A, originalFile: "1\n2\n3\n", newText: "1\n2\nY\n", toolUseID: nil) == nil)
        #expect(l.edits.map(\.author) == [.outside, .user])
    }
}

@Suite struct AdoptSessionRecordTests {
    @Test func adoptsBashAttributedRecordButNotAToolRecord() {
        let a = UUID(), b = UUID()
        var f = FileLedger(path: "a.txt", baseline: "one\ntwo\n")
        let bash = f.applyFullText(author: .session(a), newText: "one\nTWO\n", toolUseID: nil, date: Date())
        let hunks = TextDiff.hunks(old: "one\ntwo\n", new: "one\nTWO\n")
        let adopted = f.adoptOutside(as: .session(b), originalFile: "one\ntwo\n", newText: "one\nTWO\n", toolUseID: "t9")
        #expect(adopted?.id == bash?.id)
        #expect(adopted?.author == .session(b))
        #expect(adopted?.toolUseID == "t9")
        #expect(hunks == adopted?.hunks)
        // A record that carries a tool call id belongs to that call and is never taken over.
        var g = FileLedger(path: "a.txt", baseline: "one\ntwo\n")
        g.applyFullText(author: .session(a), newText: "one\nTWO\n", toolUseID: "own", date: Date())
        #expect(g.adoptOutside(as: .session(b), originalFile: "one\ntwo\n", newText: "one\nTWO\n", toolUseID: "t9") == nil)
    }
}
