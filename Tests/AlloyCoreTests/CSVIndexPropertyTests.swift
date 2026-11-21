import MetalUICodeBuffer
@testable import AlloyCore
import Testing

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let pieces = ["a", "b", "c", "x1", ",", ",", "\"", "\"", "\"\"", "\n", "\n", "\r\n", ";", " ", "zz"]

private func randomText(_ rng: inout SplitMix, count: Int) -> String {
    var s = ""
    for _ in 0..<count { s += pieces.randomElement(using: &rng)! }
    return s
}

@MainActor
@Suite struct CSVIndexPropertyTests {
    @Test func incrementalEqualsRebuild() {
        var applied = 0, appliedNoQuote = 0, noQuote = 0
        for seed in 1...50 {
            var rng = SplitMix(state: UInt64(seed))
            // 40 to 200 rows of random cells.
            var text = ""
            for _ in 0..<Int.random(in: 40...200, using: &rng) {
                text += randomText(&rng, count: Int.random(in: 1...8, using: &rng)) + "\n"
            }
            let buffer = CodeBuffer(text)
            let cursor = buffer.makeEditCursor()
            var index = CSVIndex.build(buffer.snapshot(), dialect: .comma)
            for step in 0..<200 {
                let n = buffer.utf8Count
                let a = Int.random(in: 0...n, using: &rng)
                let b = rng.next() % 3 == 0 ? Int.random(in: a...n, using: &rng) : min(n, a + Int.random(in: 0...3, using: &rng))
                let ins = rng.next() % 4 == 0 ? "" : randomText(&rng, count: Int.random(in: 1...4, using: &rng))
                let touchesQuote = ins.contains("\"") || buffer.snapshot().utf8(in: a..<b).contains(UInt8(ascii: "\""))
                buffer.replace(a..<b, with: ins)
                guard case .edits(let edits) = cursor.drain() else { Issue.record("resync seed \(seed)"); return }
                let snap = buffer.snapshot()
                var ok = true
                for e in edits {
                    // Edits are reported one event at a time; only the last has the final text to hand.
                    if edits.count == 1 { ok = index.apply(e, newSource: snap) } else { ok = false }
                }
                if edits.isEmpty { ok = true } else {
                    if !touchesQuote { noQuote += 1; if ok { appliedNoQuote += 1 } }
                    if ok { applied += 1 }
                }
                if !ok { index = CSVIndex.build(snap, dialect: .comma) }
                let fresh = CSVIndex.build(snap, dialect: .comma)
                #expect(index == fresh, "seed \(seed) step \(step) edit \(a)..<\(b) -> \(ins.debugDescription)")
                if index != fresh { return }
            }
        }
        #expect(applied > 0)
        #expect(Double(appliedNoQuote) >= 0.7 * Double(noQuote), "incremental path used \(appliedNoQuote) of \(noQuote)")
    }

    @Test func strayQuoteWithinLookaheadIsRescanned() {
        // A flagged row far above the edit whose fallback depends on bytes the edit supplies.
        var text = "\"open,a\n"
        for _ in 0..<50 { text += "x,y\n" }
        let buffer = CodeBuffer(text)
        let cursor = buffer.makeEditCursor()
        var index = CSVIndex.build(buffer.snapshot(), dialect: .comma)
        #expect(index.flaggedRows == [0])
        buffer.replace(buffer.utf8Count..<buffer.utf8Count, with: "\"\n")
        guard case .edits(let edits) = cursor.drain(), edits.count == 1 else { Issue.record("edits"); return }
        if !index.apply(edits[0], newSource: buffer.snapshot()) { index = CSVIndex.build(buffer.snapshot(), dialect: .comma) }
        #expect(index == CSVIndex.build(buffer.snapshot(), dialect: .comma))
        #expect(index.rowCount == 1)
    }

    @Test func editAtBomRefuses() {
        let buffer = CodeBuffer("\u{FEFF}a,b\n")
        let cursor = buffer.makeEditCursor()
        var index = CSVIndex.build(buffer.snapshot(), dialect: .comma)
        buffer.replace(0..<0, with: "z")
        guard case .edits(let edits) = cursor.drain() else { return }
        let refused = !index.apply(edits[0], newSource: buffer.snapshot())
        #expect(refused)
    }
}
