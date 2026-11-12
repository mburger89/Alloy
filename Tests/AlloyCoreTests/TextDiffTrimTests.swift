import Foundation
import Testing
@testable import AlloyCore

private struct TrimRng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The byte-trimmed fast paths of `TextDiff.ops` / `TextDiff.hunks` must equal the untrimmed algorithms exactly.
@Suite struct TextDiffTrimTests {
    private func assertSame(_ old: String, _ new: String, _ note: String = "") {
        #expect(TextDiff.ops(old: old, new: new) == TextDiff.opsReference(old: old, new: new), "ops \(note) \(old.debugDescription) -> \(new.debugDescription)")
        #expect(TextDiff.hunks(old: old, new: new) == TextDiff.hunksReference(old: old, new: new), "hunks \(note) \(old.debugDescription) -> \(new.debugDescription)")
        #expect(TextDiff.hunks(old: old, new: new, context: 0) == TextDiff.hunksReference(old: old, new: new, context: 0), "hunks0 \(note)")
    }

    @Test func edgeCases() {
        let t = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n"
        assertSame("", "")
        assertSame("", t)
        assertSame(t, "")
        assertSame(t, t)
        assertSame(t, "X\n" + t)                 // start
        assertSame(t, t + "X\n")                 // end
        assertSame(t, String(t.dropLast()))       // trailing newline removed
        assertSame(String(t.dropLast()), t)
        assertSame(t, t.replacingOccurrences(of: "e\n", with: "E\n"))   // middle
        assertSame(t, "completely\ndifferent\n")
        assertSame("x", "x\n")
        assertSame("x\ny", "x\nz")
        assertSame("é\nb\nc\nd\ne\nf\ng\nh\ni\nj\n", "é\nb\nc\nd\nE\nf\ng\nh\ni\nj\n")
        assertSame("日本語\nabc\n", "日本語\nabd\n")
        assertSame("e\u{301}\nx\n", "\u{e9}\nx\n")   // canonically equal, byte-different
        let crlf = t.replacingOccurrences(of: "\n", with: "\r\n")
        assertSame(crlf, crlf.replacingOccurrences(of: "e\r\n", with: "E\r\n"))
        assertSame(crlf, t)
        assertSame("a\r\nb\nc\n", "a\r\nb\nd\n")
    }

    @Test func randomEdits() {
        let pieces = ["a", "b", "\n", "\n", "xy", "é", "日", "\r\n", " ", "\n\n"]
        for seed in 0..<400 {
            var rng = TrimRng(state: UInt64(seed) &+ 1)
            func rand(_ n: Int) -> String { (0..<n).map { _ in pieces.randomElement(using: &rng)! }.joined() }
            let old = rand(Int.random(in: 0...60, using: &rng))
            var scalars = Array(old.unicodeScalars)
            for _ in 0..<Int.random(in: 0...3, using: &rng) {
                let at = Int.random(in: 0...scalars.count, using: &rng)
                let del = Int.random(in: 0...min(6, scalars.count - at), using: &rng)
                scalars.replaceSubrange(at..<(at + del), with: Array(rand(Int.random(in: 0...3, using: &rng)).unicodeScalars))
            }
            let new = seed % 25 == 0 ? rand(Int.random(in: 0...30, using: &rng)) : String(String.UnicodeScalarView(scalars))
            assertSame(old, new, "seed \(seed)")
        }
    }

    @Test func largeFileSmallEdits() {
        var rng = TrimRng(state: 99)
        let lines = (0..<400).map { "let value\($0) = \($0)  // é\n" }
        for _ in 0..<60 {
            var edited = lines
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                edited[Int.random(in: 0..<edited.count, using: &rng)] = ["changed\n", "", "two\nlines\n", "tail no newline"].randomElement(using: &rng)!
            }
            assertSame(lines.joined(), edited.joined())
        }
    }
}
