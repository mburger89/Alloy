import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyCore

/// Absolute time bounds run only on demand, on a quiet machine: `ALLOY_PERF=1 swift test --filter OverlapIndexTests`.
private let perfBounds = ProcessInfo.processInfo.environment["ALLOY_PERF"] == "1"

@MainActor @Suite struct OverlapIndexTests {
    let a = UUID(), b = UUID()
    var A: Author { .session(a) }
    var B: Author { .session(b) }

    /// 30 lines "line1\n" ... "line30\n".
    static let base = (1...30).map { "line\($0)\n" }.joined()

    @MainActor final class World {
        var files: [String: FileLedger] = [:]
        var docs: [String: EditorDocument] = [:]
        lazy var index = OverlapIndex(ledger: { [unowned self] in self.files[$0] },
                                      document: { [unowned self] in self.docs[$0] })

        func ledger(_ path: String, baseline: String) { files[path] = FileLedger(path: path, baseline: baseline) }

        /// The session replaces `line` (1-based) with new text.
        @discardableResult
        func edit(_ path: String, _ author: Author, line: Int, to new: String, toolUseID: String? = nil) -> EditRecord? {
            var f = files[path]!
            var lines = TextLines(f.text.text)
            let old = f.text.text
            lines.lines[line - 1] = new
            let rec = f.applyPatch(author: author, originalFile: old,
                                   hunks: Patch.diff(old: TextLines(old).lines, new: lines.lines),
                                   toolUseID: toolUseID, date: Date(timeIntervalSince1970: 1_000)).last
            files[path] = f
            return rec
        }

        /// Deletes lines `range` (1-based).
        func delete(_ path: String, _ author: Author, lines range: ClosedRange<Int>) {
            var f = files[path]!
            let old = f.text.text
            var lines = TextLines(old)
            lines.lines.removeSubrange((range.lowerBound - 1)..<range.upperBound)
            f.applyPatch(author: author, originalFile: old,
                         hunks: Patch.diff(old: TextLines(old).lines, new: lines.lines),
                         toolUseID: nil, date: Date(timeIntervalSince1970: 1_002))
            files[path] = f
        }

        func insertTop(_ path: String, _ author: Author, count: Int) {
            var f = files[path]!
            let old = f.text.text
            var lines = TextLines(old)
            lines.lines.insert(contentsOf: (0..<count).map { "new\($0)" }, at: 0)
            f.applyPatch(author: author, originalFile: old,
                         hunks: Patch.diff(old: TextLines(old).lines, new: lines.lines),
                         toolUseID: nil, date: Date(timeIntervalSince1970: 1_001))
            files[path] = f
        }

        func open(_ path: String, text: String) -> EditorDocument {
            let d = EditorDocument(path: path, buffer: CodeBuffer(utf8: Array(text.utf8)), language: nil,
                                   state: .editable, diskStamp: FileStamp(modified: nil, size: text.utf8.count))
            docs[path] = d
            return d
        }
    }

    private func proposal(_ s: UUID, _ id: String, _ lines: ClosedRange<Int>, path: String = "f.txt",
                          date: Date = Date()) -> ProposedChange {
        ProposedChange(session: s, toolUseID: id, range: LineRange(path: path, lines: lines),
                       date: date, diff: "-x\n+y")
    }

    // MARK: Mapping

    @Test func editMapsToItsLines() throws {
        let input: JSONValue = .object(["file_path": .string("/p/f.txt"), "old_string": .string("line5\nline6\n"),
                                        "new_string": .string("X\n")])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "t1", path: "f.txt", toolName: "Edit",
                                                 input: input, currentText: Self.base))
        #expect(p.range == LineRange(path: "f.txt", lines: 5...6))
        #expect(p.ranges == [5...6])
        #expect(p.diff.contains("-line5") && p.diff.contains("+X"))
        // No match: nothing to propose.
        let miss: JSONValue = .object(["old_string": .string("nope"), "new_string": .string("x")])
        #expect(ProposedChange.from(session: a, toolUseID: "t2", path: "f.txt", toolName: "Edit",
                                    input: miss, currentText: Self.base) == nil)
    }

    @Test func replaceAllMapsEveryMatch() throws {
        let text = "x\nfoo\nx\nx\nfoo\nx\n"
        let input: JSONValue = .object(["old_string": .string("foo"), "new_string": .string("bar"),
                                        "replace_all": .bool(true)])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f.txt", toolName: "Edit",
                                                 input: input, currentText: text))
        #expect(p.ranges == [2...2, 5...5])
        #expect(p.range.lines == 2...5)
    }

    @Test func writeMapsTheChangedSpan() throws {
        var lines = Self.base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[9] = "CHANGED"
        let input: JSONValue = .object(["file_path": .string("/p/f.txt"), "content": .string(lines.joined(separator: "\n"))])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "w", path: "f.txt", toolName: "Write",
                                                 input: input, currentText: Self.base))
        #expect(p.range.lines == 10...10)
        // A file Alloy has no text for is not mapped.
        #expect(ProposedChange.from(session: a, toolUseID: "w", path: "f.txt", toolName: "Write",
                                    input: input, currentText: nil) == nil)
    }

    @Test func notebookCellMapsToItsLines() throws {
        let nb = """
        {
         "cells": [
          {
           "id": "c1",
           "source": ["print(1)"]
          },
          {
           "id": "c2",
           "source": ["print(2)"]
          }
         ]
        }
        """
        let input: JSONValue = .object(["notebook_path": .string("/p/n.ipynb"), "cell_id": .string("c2"),
                                        "new_source": .string("print(3)")])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "n", path: "n.ipynb", toolName: "NotebookEdit",
                                                 input: input, currentText: nb))
        #expect(p.range.lines == 7...10)
        let unknown: JSONValue = .object(["cell_id": .string("zz"), "new_source": .string("x")])
        #expect(ProposedChange.from(session: a, toolUseID: "n", path: "n.ipynb", toolName: "NotebookEdit",
                                    input: unknown, currentText: nb) == nil)
    }

    @Test func diffIsCappedAtTwentyLines() throws {
        let old = (1...100).map { "l\($0)\n" }.joined()
        let input: JSONValue = .object(["old_string": .string(old), "new_string": .string("")])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit",
                                                 input: input, currentText: old))
        #expect(p.diff.split(separator: "\n").count <= 20)
    }

    // MARK: Overlap

    @Test func adjacentWithinThreeLinesOverlaps() async {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 10, to: "B10")
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 13...14))
        #expect(o.count == 1)
        #expect(o.first?.other == B)
        #expect(o.first?.lines == 10...10)
        if case .active = o.first?.kind {} else { Issue.record("expected active") }
        #expect(o.first?.diff.contains("+B10") == true)
    }

    @Test func fourLinesApartDoesNot() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 10, to: "B10")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 14...15)).isEmpty)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 7...7)).count == 1)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 6...6)).isEmpty)
        // Another file is never consulted.
        #expect(w.index.overlaps(for: a, range: LineRange(path: "g.txt", lines: 10...10)).isEmpty)
    }

    @Test func ownEditsNeverOverlap() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", A, line: 10, to: "A10")
        w.index.propose(proposal(a, "t1", 10...10))
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
    }

    @Test func keptEditsDoNotCount() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        let rec = w.edit("f.txt", B, line: 10, to: "B10")!
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).count == 1)
        w.files["f.txt"]!.keep(rec.id)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
    }

    @Test func activeEditReanchorsAfterEarlierLinesChange() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 10, to: "B10")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).count == 1)
        w.insertTop("f.txt", A, count: 5)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 15...15))
        #expect(o.first?.lines == 15...15)
    }

    @Test func proposedChangesOverlapOthers() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.index.propose(proposal(b, "tb", 20...22))
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 24...25))
        #expect(o.count == 1)
        #expect(o.first?.other == B)
        #expect(o.first?.kind == .proposed(toolUseID: "tb"))
    }

    @Test func resolveDropsTheProposal() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.index.propose(proposal(b, "tb", 20...22))
        w.index.resolve(toolUseID: "tb")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 20...22)).isEmpty)
    }

    @Test func unsavedUserTypingCountsAsProposed() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        let d = w.open("f.txt", text: Self.base)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 1...30)).isEmpty)
        let at = Self.base.range(of: "line8")!.upperBound.utf16Offset(in: Self.base)
        _ = d.buffer.replace(at..<at, with: " typed")
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 9...10))
        #expect(o.count == 1)
        #expect(o.first?.other == .user)
        #expect(o.first?.kind == .userTyping)
        #expect(o.first?.lines == 8...8)
        // Saved text is not typing.
        d.markSaved(snapshot: d.buffer.snapshot(), stamp: FileStamp(modified: nil, size: 0))
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 8...8)).isEmpty)
    }

    @Test func multiLineUserTypingMapsBytesToLines() {
        let w = World(); w.ledger("f.txt", baseline: "héllo\nwörld\nthree\nfour\n")
        let text = "héllo\nwörld\nthree\nfour\n"
        let d = w.open("f.txt", text: text)
        // Insert at the start of "three" (UTF-8 offset differs from the character offset).
        let off = Array(text.utf8).count - "three\nfour\n".utf8.count
        _ = d.buffer.replace(off..<off, with: "A\nB\n")
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 3...4))
        #expect(o.first?.lines == 3...3)   // saved coordinates: the insertion point
    }

    @Test func queryIsFastOnALargeFileWithManyEdits() {
        let big = (1...5_000).map { "let value\($0) = \($0)\n" }.joined()
        let w = World(); w.ledger("big.swift", baseline: big)
        for i in 0..<200 { w.edit("big.swift", i % 2 == 0 ? A : B, line: 10 + i * 24, to: "let edited\(i) = 0") }
        let r = LineRange(path: "big.swift", lines: 2_407...2_408)
        let c = UUID()
        let clock = ContinuousClock()
        var colds: [Duration] = []
        for _ in 0..<7 {
            w.index.invalidate(path: "big.swift")
            colds.append(clock.measure { _ = w.index.overlaps(for: c, range: r) })
        }
        // The minimum of 7: a load spike inflates samples, never deflates them.
        let cold = colds.min()!
        let warm = clock.measure { for _ in 0..<10 { _ = w.index.overlaps(for: c, range: r) } } / 10
        #expect(warm * 10 <= cold)
        if perfBounds {
            #expect(cold < .milliseconds(5))
            #if DEBUG
            #expect(warm < .milliseconds(1))
            #else
            #expect(warm < .microseconds(500))
            #endif
        }
        #expect(!w.index.overlaps(for: c, range: r).isEmpty)
    }

    @Test func mappingIsFastOnFiveThousandLines() throws {
        let big = (1...5_000).map { "let value\($0) = \($0)\n" }.joined()
        let edit: JSONValue = .object(["old_string": .string("let value4000 = 4000\n"), "new_string": .string("x\n")])
        var lines = big.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines[2_999] = "changed"
        let write: JSONValue = .object(["content": .string(lines.joined(separator: "\n"))])
        let clock = ContinuousClock()
        var e: [Duration] = [], wr: [Duration] = []
        for _ in 0..<7 {
            e.append(clock.measure { _ = ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit", input: edit, currentText: big) })
            wr.append(clock.measure { _ = ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Write", input: write, currentText: big) })
        }
        let p = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit", input: edit, currentText: big))
        #expect(p.range.lines == 4_000...4_000)
        #expect(try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Write", input: write, currentText: big)).range.lines == 3_000...3_000)
        if perfBounds {
            #if DEBUG
            let bound = Duration.milliseconds(10)
            #else
            let bound = Duration.milliseconds(2)
            #endif
            #expect(e.min()! < bound)
            #expect(wr.min()! < bound)
        }
    }

    // MARK: Scale-free timing guards (always run)

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// `big` within 40x of `small` (linear growth is 10x for 10x the lines; quadratic is about 100x). A floor keeps
    /// a near-zero small run from turning noise into a huge ratio.
    private static func scalesLinearly(_ big: Duration, _ small: Duration, _ what: String) {
        let floor = 0.00005
        let ratio = seconds(big) / max(seconds(small), floor)
        #expect(ratio < 40, "\(what): \(ratio)x")
    }

    private static func minOf7(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return (0..<7).map { _ in clock.measure(body) }.min()!
    }

    @Test func coldQueryAndFirstTypingBuildScaleLinearly() {
        func cold(_ lines: Int) -> Duration {
            let text = (1...lines).map { "let value\($0) = \($0)\n" }.joined()
            let w = World(); w.ledger("big.swift", baseline: text)
            for i in 0..<(lines / 25) { w.edit("big.swift", i % 2 == 0 ? A : B, line: 10 + i * 24, to: "let edited\(i) = 0") }
            let r = LineRange(path: "big.swift", lines: (lines / 2)...(lines / 2 + 1)), c = UUID()
            return Self.minOf7 { w.index.invalidate(path: "big.swift"); _ = w.index.overlaps(for: c, range: r) }
        }
        func typing(_ lines: Int) -> Duration {
            let text = (1...lines).map { "let value\($0) = \($0)\n" }.joined()
            let w = World(); w.ledger("big.swift", baseline: text)
            let d = w.open("big.swift", text: text), c = UUID()
            for i in 0..<(lines * 3 / 10) {
                let at = d.buffer.snapshot().lineRange(i * 3).lowerBound
                _ = d.buffer.replace(at..<at, with: "x")
            }
            var at = d.buffer.snapshot().lineRange(lines * 4 / 5).lowerBound
            for _ in 0..<(lines * 3 / 10) { _ = d.buffer.replace(at..<at, with: "y"); at += 1 }
            let r = LineRange(path: "big.swift", lines: (lines * 4 / 5 + 1)...(lines * 4 / 5 + 1))
            return Self.minOf7 { w.index.invalidate(path: "big.swift"); _ = w.index.overlaps(for: c, range: r) }
        }
        Self.scalesLinearly(cold(5_000), cold(500), "cold query")
        Self.scalesLinearly(typing(5_000), typing(500), "first typing build")
    }

    @Test func proposedChangeMappingScalesLinearly() {
        func run(_ lines: Int, write: Bool) -> Duration {
            let text = (1...lines).map { "let value\($0) = \($0)\n" }.joined()
            let edit: JSONValue = .object(["old_string": .string("let value\(lines * 4 / 5) = \(lines * 4 / 5)\n"), "new_string": .string("x\n")])
            var ls = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            ls[lines * 3 / 5 - 1] = "changed"
            let w: JSONValue = .object(["content": .string(ls.joined(separator: "\n"))])
            return Self.minOf7 {
                _ = ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: write ? "Write" : "Edit",
                                        input: write ? w : edit, currentText: text)
            }
        }
        Self.scalesLinearly(run(5_000, write: false), run(500, write: false), "Edit mapping")
        Self.scalesLinearly(run(5_000, write: true), run(500, write: true), "Write mapping")
    }

    // MARK: Unsaved typing: cost, coordinates, deletions, lost log

    @Test func unsavedTypingCostIsBounded() {
        let big = (1...5_000).map { "let value\($0) = \($0)\n" }.joined()
        let w = World(); w.ledger("big.swift", baseline: big)
        let d = w.open("big.swift", text: big)
        let c = UUID()
        // 1,500 scattered single-character edits, then a 1,500-character word typed on one line.
        var offset = 0
        for i in 0..<1_500 {
            let snap = d.buffer.snapshot()
            offset = snap.lineRange(i * 3).lowerBound
            _ = d.buffer.replace(offset..<offset, with: "x")
        }
        var at = d.buffer.snapshot().lineRange(4_000).lowerBound
        for _ in 0..<1_500 { _ = d.buffer.replace(at..<at, with: "y"); at += 1 }
        let r = LineRange(path: "big.swift", lines: 4_001...4_001)
        let clock = ContinuousClock()
        // Cold cost is the minimum of three cold runs, so one preempted sample can't fake a slow start.
        var colds: [Duration] = []
        for _ in 0..<3 {
            w.index.invalidate(path: "big.swift")
            colds.append(clock.measure { _ = w.index.overlaps(for: c, range: r) })
        }
        let first = colds.min()!
        let warm = clock.measure { for _ in 0..<10 { _ = w.index.overlaps(for: c, range: r) } } / 10
        // One more keystroke only advances the running list. The minimum of 7 keystrokes, timing only the query.
        var nexts: [Duration] = []
        for _ in 0..<7 {
            _ = d.buffer.replace(at..<at, with: "z")
            nexts.append(clock.measure { _ = w.index.overlaps(for: c, range: r) })
        }
        let next = nexts.min()!
        // 3× leaves headroom under heavy parallel load; a regression to full recompute per keystroke is ~1×.
        #expect(next * 3 <= first)
        if perfBounds {
            #expect(first < .milliseconds(500))
            #expect(warm < .milliseconds(1))
            #expect(next < .milliseconds(5))
        }
        #expect(!w.index.overlaps(for: c, range: r).isEmpty)
    }

    @Test func typingIsReportedAtSavedLines() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        let d = w.open("f.txt", text: Self.base)
        // Five lines typed above shift everything below by five buffer lines.
        let top = Self.base.range(of: "line2\n")!.upperBound.utf16Offset(in: Self.base)
        _ = d.buffer.replace(top..<top, with: "a\nb\nc\nd\ne\n")
        // Then a character on what is now buffer line 20: saved line 15.
        let snap = d.buffer.snapshot()
        let l20 = snap.lineRange(19).lowerBound
        _ = d.buffer.replace(l20..<l20, with: "T")
        let near = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 15...15)).filter { $0.kind == .userTyping }
        #expect(near.count == 1)
        #expect(near.first?.lines == 15...15)
        // Buffer line 20 is saved line 20 only if nothing shifted; it must not match there.
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 20...22)).filter { $0.kind == .userTyping }.isEmpty)
        // The earlier insertion is reported at saved line 3 (where it was typed), not 3...8.
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 3...3)).contains { $0.kind == .userTyping && $0.lines == 3...3 })
    }

    @Test func pureDeletionTypingMapsToSavedLines() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        let d = w.open("f.txt", text: Self.base)
        let r = Self.base.range(of: "line8\nline9\n")!
        let lo = r.lowerBound.utf16Offset(in: Self.base), hi = r.upperBound.utf16Offset(in: Self.base)
        _ = d.buffer.replace(lo..<hi, with: "")
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 8...9)).filter { $0.kind == .userTyping }
        #expect(o.count == 1)
        #expect(o.first?.lines == 8...9)
    }

    @Test func lostEditLogReportsCoarseUnsavedChanges() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        let d = w.open("f.txt", text: Self.base)
        let at = Self.base.range(of: "line8")!.upperBound.utf16Offset(in: Self.base)
        _ = d.buffer.replace(at..<at, with: "!")
        d.editLogLost = true
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 25...25))
        #expect(o.count == 1)
        #expect(o.first?.kind == .userTyping)
        #expect(o.first?.other == .user)
        #expect(o.first?.lines == nil)
    }

    // MARK: Deletions, user edits, outside edits

    @Test func deleteOnlyEditsOverlap() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.delete("f.txt", B, lines: 10...12)
        func hits(_ line: Int) -> Int { w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: line...line)).count }
        #expect(hits(11) == 1)
        #expect(hits(14) == 1)
        #expect(hits(15) == 0)
        #expect(hits(7) == 1)
        #expect(hits(6) == 0)
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 11...11))
        #expect(o.first?.other == B)
        #expect(o.first?.lines == 10...11)
    }

    @Test func partialLineDeleteOverlaps() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 10, to: "ne")   // "line10" -> "ne": deletes characters, inserts none beyond the line itself
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).count == 1)
    }

    @Test func savedUserEditsCount() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", .user, line: 10, to: "U10")
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10))
        #expect(o.count == 1)
        #expect(o.first?.other == .user)
        if case .active = o.first?.kind {} else { Issue.record("expected active") }
    }

    @Test func outsideEditsAreSkipped() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", .outside, line: 10, to: "O10")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
    }

    // MARK: Proposals

    @Test func proposalsOutliveLongPromptsButNotAnHour() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        var clock = Date(timeIntervalSince1970: 2_000)
        let idx = OverlapIndex(ledger: { w.files[$0] }, document: { w.docs[$0] }, now: { clock })
        idx.propose(proposal(b, "tb", 20...22, date: clock))
        let q = LineRange(path: "f.txt", lines: 20...22)
        clock = Date(timeIntervalSince1970: 2_000 + 600)
        #expect(idx.overlaps(for: a, range: q).count == 1)
        clock = Date(timeIntervalSince1970: 2_000 + 3_599)
        #expect(idx.overlaps(for: a, range: q).count == 1)
        clock = Date(timeIntervalSince1970: 2_000 + 3_601)
        #expect(idx.overlaps(for: a, range: q).isEmpty)
    }

    @Test func typingCacheResetsAfterSaveAndForAReplacedDocument() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        let d = w.open("f.txt", text: Self.base)
        let at8 = Self.base.range(of: "line8")!.upperBound.utf16Offset(in: Self.base)
        _ = d.buffer.replace(at8..<at8, with: "!")
        let all = LineRange(path: "f.txt", lines: 1...30)
        #expect(w.index.overlaps(for: a, range: all).compactMap(\.lines) == [8...8])
        // Save, then type on line 20: only the new typing is reported, at its saved line.
        d.markSaved(snapshot: d.buffer.snapshot(), stamp: FileStamp(modified: nil, size: 0))
        let text = d.buffer.snapshot().text
        let at20 = text.range(of: "line20")!.upperBound.utf16Offset(in: text)
        _ = d.buffer.replace(at20..<at20, with: "?")
        #expect(w.index.overlaps(for: a, range: all).compactMap(\.lines) == [20...20])
        // A different document object for the same path starts clean.
        let d2 = w.open("f.txt", text: Self.base)
        #expect(w.index.overlaps(for: a, range: all).isEmpty)
        let at3 = Self.base.range(of: "line3")!.upperBound.utf16Offset(in: Self.base)
        _ = d2.buffer.replace(at3..<at3, with: "#")
        #expect(w.index.overlaps(for: a, range: all).compactMap(\.lines) == [3...3])
    }

    /// Seeded random edit sequences: outside the regions the buffer must equal the saved text at the mapped
    /// offsets, and the regions must account for the whole length difference.
    @Test func typingRegionsMatchABruteForceReplay() {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(max(n, 1)))
        }
        for round in 0..<200 {
            let saved = (0..<(20 + next(60))).map { _ in UInt8(97 + next(26)) }
            var buffer = saved
            var regions = TypingRegions()
            for _ in 0..<(1 + next(25)) {
                let lo = next(buffer.count + 1)
                let hi = min(buffer.count, lo + (next(4) == 0 ? 0 : next(6)))
                let insert = (0..<next(5)).map { _ in UInt8(65 + next(26)) }
                if hi == lo && insert.isEmpty { continue }
                buffer.replaceSubrange(lo..<hi, with: insert)
                regions.apply(range: lo..<hi, newLength: insert.count)
            }
            let rs = regions.regions
            var bPos = 0, sPos = 0
            var ok = true
            for r in rs {
                ok = ok && r.b.lowerBound >= bPos && r.s.lowerBound >= sPos
                    && r.b.lowerBound - bPos == r.s.lowerBound - sPos
                    && buffer[bPos..<r.b.lowerBound] == saved[sPos..<r.s.lowerBound]
                bPos = r.b.upperBound; sPos = r.s.upperBound
            }
            ok = ok && buffer.count - bPos == saved.count - sPos && buffer[bPos...] == saved[sPos...]
            #expect(ok, "round \(round)")
            // Touching regions are merged.
            for (x, y) in zip(rs, rs.dropFirst()) { #expect(x.b.upperBound < y.b.lowerBound) }
        }
    }

    @Test func dropProposalsBySession() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.index.propose(proposal(b, "t1", 20...22))
        w.index.propose(proposal(a, "t2", 5...5))
        w.index.dropProposals(session: b)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 20...22)).isEmpty)
        #expect(w.index.overlaps(for: b, range: LineRange(path: "f.txt", lines: 5...5)).count == 1)
    }

    @Test func appliedEditAndItsProposalAreNotBothReported() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 10, to: "B10", toolUseID: "t9")
        w.index.propose(proposal(b, "t9", 10...10))
        let o = w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10))
        #expect(o.count == 1)
        if case .active = o.first?.kind {} else { Issue.record("expected active") }
    }

    @Test func invalidateDropsTheCache() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 10, to: "B10")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).count == 1)
        // Replace the ledger by another with the same version but its edit elsewhere.
        w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 20, to: "B20")
        w.index.invalidate(path: "f.txt")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 20...20)).count == 1)
    }

    @Test func replaceAllGapIsNotClaimed() throws {
        let text = "foo\n" + (1...17).map { "x\($0)\n" }.joined() + "foo\n"
        let input: JSONValue = .object(["old_string": .string("foo"), "new_string": .string("bar"), "replace_all": .bool(true)])
        let p = try #require(ProposedChange.from(session: b, toolUseID: "t", path: "f.txt", toolName: "Edit", input: input, currentText: text))
        #expect(p.ranges == [1...1, 19...19])
        let w = World(); w.ledger("f.txt", baseline: text)
        w.index.propose(p)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 18...18)).count == 1)
    }

    @Test func replaceAllMergesAdjacentSpansAndCapsTheirCount() throws {
        let adjacent = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit",
            input: .object(["old_string": .string("foo"), "new_string": .string("b"), "replace_all": .bool(true)]),
            currentText: "foo\nfoo\nx\nfoo\n"))
        #expect(adjacent.ranges == [1...2, 4...4])
        let many = (0..<100).map { _ in "foo\nx\ny\n" }.joined()
        let p = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit",
            input: .object(["old_string": .string("foo"), "new_string": .string("b"), "replace_all": .bool(true)]),
            currentText: many))
        #expect(p.ranges.count <= 50)
        #expect(p.ranges.first == 1...1)
        #expect(p.ranges.last?.upperBound == 298)
    }

    // MARK: Mapping edge cases

    @Test func writeThatOnlyChangesTheFinalNewlineIsAChange() throws {
        let input: JSONValue = .object(["content": .string("a\nb")])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "w", path: "f", toolName: "Write", input: input, currentText: "a\nb\n"))
        #expect(p.range.lines == 2...2)
        #expect(ProposedChange.from(session: a, toolUseID: "w", path: "f", toolName: "Write", input: input, currentText: "a\nb") == nil)
    }

    @Test func crlfAndUnterminatedLastLine() throws {
        let crlf = "one\r\ntwo\r\nthree\r\n"
        let e: JSONValue = .object(["old_string": .string("two\r\nthree"), "new_string": .string("x")])
        #expect(try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit", input: e, currentText: crlf)).range.lines == 2...3)
        let diff = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit", input: e, currentText: crlf)).diff
        #expect(!diff.contains("\r"))
        let noEOL = "a\nb\nlast"
        let l: JSONValue = .object(["old_string": .string("last"), "new_string": .string("z")])
        #expect(try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit", input: l, currentText: noEOL)).range.lines == 3...3)
        let wr: JSONValue = .object(["content": .string("a\nb\nlast2")])
        #expect(try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Write", input: wr, currentText: noEOL)).range.lines == 3...3)
    }

    @Test func marginAtTheFirstAndLastLine() {
        let w = World(); w.ledger("f.txt", baseline: Self.base)
        w.edit("f.txt", B, line: 4, to: "B4")
        w.edit("f.txt", B, line: 27, to: "B27")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 1...1)).count == 1)
        w.index.invalidate(path: "f.txt")
        #expect(w.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 30...30)).count == 1)
        let w2 = World(); w2.ledger("f.txt", baseline: Self.base)
        w2.edit("f.txt", B, line: 5, to: "B5")
        w2.edit("f.txt", B, line: 26, to: "B26")
        #expect(w2.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 1...1)).isEmpty)
        #expect(w2.index.overlaps(for: a, range: LineRange(path: "f.txt", lines: 30...30)).isEmpty)
    }

    @Test func notebookInsertModeAndNestedIds() throws {
        let nb = """
        {
         "cells": [
          {
           "id": "c1",
           "metadata": {"id": "inner"},
           "source": ["print(1)"]
          },
          {
           "id": "c2",
           "source": ["print(2)"]
          }
         ]
        }
        """
        let insert: JSONValue = .object(["cell_id": .string("c1"), "edit_mode": .string("insert"), "new_source": .string("z")])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "n", path: "n", toolName: "NotebookEdit", input: insert, currentText: nb))
        #expect(p.range.lines == 7...8)   // c1 closes on line 7: the new cell sits between 7 and 8
        let nested: JSONValue = .object(["cell_id": .string("inner"), "new_source": .string("z")])
        #expect(ProposedChange.from(session: a, toolUseID: "n", path: "n", toolName: "NotebookEdit", input: nested, currentText: nb) == nil)
    }

    @Test func clipCountsBytes() throws {
        let long = String(repeating: "\u{00E9}", count: 100)   // 200 bytes
        let e: JSONValue = .object(["old_string": .string(long), "new_string": .string("x")])
        let p = try #require(ProposedChange.from(session: a, toolUseID: "t", path: "f", toolName: "Edit", input: e, currentText: long))
        for line in p.diff.split(separator: "\n") { #expect(line.utf8.count <= 1 + ProposedChange.maxDiffLineCharacters + 3) }
    }
}
