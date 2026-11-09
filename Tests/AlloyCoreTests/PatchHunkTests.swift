import AlloyCore
import Foundation
import Testing

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

@Suite struct PatchHunkTests {
    @Test(arguments: ["a\nb\n", "a\nb", "a\r\nb\r\n", "", "\n"])
    func textLinesRoundTrip(_ text: String) {
        #expect(TextLines(text).text == text)
    }

    @Test func textLinesShape() {
        let a = TextLines("a\r\nb\r\n")
        #expect(a.lines == ["a", "b"])
        #expect(a.lineEnding == "\r\n")
        #expect(a.hasTrailingNewline)
        #expect(TextLines("").lines == [])
        #expect(!TextLines("").hasTrailingNewline)
        #expect(TextLines("\n").lines == [""])
        #expect(TextLines("\n").hasTrailingNewline)
        #expect(TextLines("a\nb").lines == ["a", "b"])
        #expect(!TextLines("a\nb").hasTrailingNewline)
    }

    @Test func applyRecordedEditHunk() throws {
        var found = false
        for line in Fixture.lines("edit-turn") {
            guard case .toolResult(let r) = InboundDecoder.decode(line),
                  case .edit(_, let original?, let hunks) = r.result else { continue }
            found = true
            let src = TextLines(original)
            let out = try Patch.apply(hunks, to: src.lines)
            var result = src
            result.lines = out
            let expected = original.replacingOccurrences(
                of: "    return user == \"admin\"", with: "    return user == \"root\"")
            #expect(result.text == expected)
            // Reversal restores the original.
            let back = try Patch.apply(hunks.map(Patch.reversed), to: out)
            #expect(back == src.lines)
        }
        #expect(found)
    }

    @Test func diffThenApplyRoundTrips() throws {
        var rng = SplitMix64(state: 42)
        for _ in 0..<200 {
            func lines() -> [String] {
                (0..<Int.random(in: 0...30, using: &rng)).map { _ in "l\(Int.random(in: 0..<6, using: &rng))" }
            }
            let old = lines(), new = lines()
            let hunks = Patch.diff(old: old, new: new)
            #expect(try Patch.apply(hunks, to: old) == new)
            #expect(try Patch.apply(hunks.map(Patch.reversed), to: new) == old)
        }
    }

    @Test func diffMatchesStructuredPatchShape() {
        #expect(Patch.diff(old: ["a", "b", "c"], new: ["a", "B", "c"]) ==
            [PatchHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" a", "-b", "+B", " c"])])
    }

    @Test func diffMatchesRecordedCliShape() {
        let old = ["import Foundation", "", "func login() {", "    // TODO", "    return admin", "}", ""]
        var new = old
        new[4] = "    return root"
        #expect(Patch.diff(old: old, new: new) == [PatchHunk(
            oldStart: 2, oldLines: 6, newStart: 2, newLines: 6,
            lines: [" ", " func login() {", "     // TODO", "-    return admin", "+    return root", " }", " "])])
    }

    @Test func diffSplitsDistantChangesAndMergesNearOnes() {
        let old = (1...20).map(String.init)
        var far = old
        far[0] = "x"; far[19] = "y"
        #expect(Patch.diff(old: old, new: far).count == 2)
        var near = old
        near[2] = "x"; near[9] = "y"   // 6 equal lines between: merges at context 3
        #expect(Patch.diff(old: old, new: near).count == 1)
        near[9] = old[9]; near[10] = "y"  // 7 equal lines between: splits
        #expect(Patch.diff(old: old, new: near).count == 2)
        #expect(Patch.diff(old: old, new: old).isEmpty)
    }

    @Test func diffInsertionConventions() throws {
        let h = Patch.diff(old: [], new: ["a"])
        #expect(h == [PatchHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: ["+a"])])
        #expect(try Patch.apply(h, to: []) == ["a"])
    }

    @Test func applyDetectsMismatch() {
        let hunk = PatchHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [" a", "-zzz", "+b"])
        #expect(throws: PatchMismatch(hunkIndex: 0, line: 2)) {
            try Patch.apply([hunk], to: ["a", "b"])
        }
        #expect(throws: PatchMismatch.self) {
            try Patch.apply([hunk], to: ["a"])
        }
    }
}
