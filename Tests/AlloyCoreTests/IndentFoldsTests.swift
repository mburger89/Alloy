@testable import AlloyCore
import MetalUICodeBuffer
import Testing

private func r(_ s: Int, _ e: Int) -> FoldRange { FoldRange(startLine: s, endLine: e) }

@MainActor private func folds(_ text: String, tabWidth: Int = 4) -> [FoldRange] {
    let snap = CodeBuffer(text).snapshot()
    var f = IndentFolds(snapshot: snap, tabWidth: tabWidth)
    return f.ranges(in: snap)
}

@MainActor @Suite struct IndentFoldsTests {
    @Test func nestedBlocks() {
        #expect(folds("a\n  b\n    c\n    d\n  e\nf\n") == [r(0, 4), r(1, 3)])
    }

    @Test func blankLinesTakeNextNonBlankIndent() {
        #expect(folds("a\n  b\n\n  c\nd\n") == [r(0, 3)])
        #expect(folds("a\n  b\n\n\nd\n") == [r(0, 1)])
    }

    @Test func tabsCountAsTabWidth() {
        #expect(folds("a\n\tb\n\t\tc\nd\n") == [r(0, 2), r(1, 2)])
        #expect(folds("a\n\tb\n\t\tc\nd\n", tabWidth: 2) == [r(0, 2), r(1, 2)])
        #expect(folds("a\n  b\n\tc\n", tabWidth: 2) == [r(0, 2)])
    }

    @Test func crlfLinesAreNotIndented() {
        #expect(folds("a\r\n  b\r\n  c\r\nd\r\n") == [r(0, 2)])
        #expect(folds("a\r\n  b\r\n\r\n  c\r\nd\r\n") == [r(0, 3)])
        #expect(folds("a\r\n  b\r\n\r\nd\r\n") == [r(0, 1)])
    }

    @Test func noTrailingNewline() {
        #expect(folds("a\n  b") == [r(0, 1)])
    }

    @Test func emptyOneLineAndAllBlankDocuments() {
        #expect(folds("").isEmpty)
        #expect(folds("a").isEmpty)
        #expect(folds("\n\n  \n").isEmpty)
    }

    @Test func dedentToDeeperThanOpener() {
        #expect(folds("a\n    b\n  c\nd\n") == [r(0, 2)])
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func sample(lines: Int) -> String {
    var out = ""
    for i in 0..<lines {
        out += String(repeating: "  ", count: i % 5 == 0 ? 0 : (i % 4)) + "line \(i)\n"
    }
    return out
}

@MainActor @Suite struct IndentFoldsIncrementalTests {
    @Test func incrementalMatchesFullRebuild() {
        let buffer = CodeBuffer(sample(lines: 200))
        let cursor = buffer.makeEditCursor()
        var f = IndentFolds(snapshot: buffer.snapshot())
        _ = f.ranges(in: buffer.snapshot())
        var rng = SplitMix64(state: 42)
        let pieces = ["x", "  ", "\n", "\t", "\n    y\n", "a\n  b\n    c\n", ""]
        for step in 0..<300 {
            for _ in 0..<(1 + Int(rng.next() % 3)) {
                let len = buffer.snapshot().utf8Count
                let a = Int(rng.next() % UInt64(len + 1))
                let b = min(len, a + Int(rng.next() % 6))
                _ = buffer.replace(a..<b, with: pieces[Int(rng.next() % UInt64(pieces.count))])
            }
            let snap = buffer.snapshot()
            switch cursor.drain() {
            case .edits(let edits): f.apply(edits)
            case .resync: f.reset(to: snap)
            }
            var fresh = IndentFolds(snapshot: snap)
            #expect(f.ranges(in: snap) == fresh.ranges(in: snap), "step \\(step)")
        }
    }

    @Test func editsOutsideRowsMeasureOnlyDirtyLines() {
        let buffer = CodeBuffer(sample(lines: 50_000))
        let cursor = buffer.makeEditCursor()
        var f = IndentFolds(snapshot: buffer.snapshot())
        _ = f.ranges(in: buffer.snapshot())
        let before = f.measuredLineCount
        let at = buffer.snapshot().lineRange(30_000).lowerBound
        _ = buffer.replace(at..<at, with: "z")
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        f.apply(edits)
        _ = f.ranges(in: buffer.snapshot())
        #expect(f.measuredLineCount - before <= 2)
    }

    @Test func typingCostIsBounded() {
        let buffer = CodeBuffer(sample(lines: 50_000))
        let cursor = buffer.makeEditCursor()
        var f = IndentFolds(snapshot: buffer.snapshot())
        _ = f.ranges(in: buffer.snapshot())
        let before = f.measuredLineCount
        var rng = SplitMix64(state: 7)
        /// Returns the milliseconds spent in apply + ranges only.
        func type() -> Double {
            let row = Int(rng.next() % 49_000) + 10
            let at = buffer.snapshot().lineRange(row).lowerBound
            _ = buffer.replace(at..<at, with: "q")
            let t0 = ContinuousClock.now
            if case .edits(let e) = cursor.drain() { f.apply(e) }
            _ = f.ranges(in: buffer.snapshot())
            let d = ContinuousClock.now - t0
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        for _ in 0..<200 { _ = type() }
        #expect(f.measuredLineCount - before <= 400)
        var best = Double.infinity
        for _ in 0..<5 { best = min(best, type()) }
        // Debug build; the stack pass is O(n) integer work, so the bound is loose.
        #expect(best < 60, "best \(best) ms")
    }

    @Test func newlineInsertShiftsRowsWithoutRemeasuringTheRest() {
        let buffer = CodeBuffer(sample(lines: 1_000))
        let cursor = buffer.makeEditCursor()
        var f = IndentFolds(snapshot: buffer.snapshot())
        _ = f.ranges(in: buffer.snapshot())
        let before = f.measuredLineCount
        let at = buffer.snapshot().lineRange(500).lowerBound
        _ = buffer.replace(at..<at, with: "\n  x\n")
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        f.apply(edits)
        #expect(f.cache.count == 1_003)
        _ = f.ranges(in: buffer.snapshot())
        #expect(f.measuredLineCount - before <= 3)
    }

    @Test func rowMismatchFallsBackToFullMeasure() {
        let buffer = CodeBuffer(sample(lines: 100))
        let cursor = buffer.makeEditCursor()
        var f = IndentFolds(snapshot: buffer.snapshot())
        _ = f.ranges(in: buffer.snapshot())
        let before = f.measuredLineCount
        // Capture a real edit, then replay it against a cache it does not fit.
        _ = buffer.replace(0..<0, with: "a\nb\n")
        guard case .edits(let edits) = cursor.drain() else { Issue.record("resync"); return }
        f.apply(edits)
        f.apply(edits + edits + edits) // rows now disagree with the snapshot
        let snap = buffer.snapshot()
        var fresh = IndentFolds(snapshot: snap)
        #expect(f.ranges(in: snap) == fresh.ranges(in: snap))
        #expect(f.measuredLineCount - before >= snap.lineCount)
    }

    @Test func resetReplacesTheCache() {
        let a = CodeBuffer("a\n  b\n").snapshot()
        let b = CodeBuffer("x\n  y\n  z\nw\n  v\n").snapshot()
        var f = IndentFolds(snapshot: a)
        _ = f.ranges(in: a)
        f.reset(to: b)
        var fresh = IndentFolds(snapshot: b)
        #expect(f.ranges(in: b) == fresh.ranges(in: b))
    }
}
