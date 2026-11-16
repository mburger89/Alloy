@testable import AlloyCore
import Testing

@Suite struct FuzzyMatchTests {
    // The brief's `wsv` cannot match `Workspace.swift` (it has no `v`), so the same shape uses `wsp`.
    @Test func fuzzyPrefersFileName() throws {
        let a = "Sources/AlloyCore/Model/Workspace.swift"
        let b = "docs/ws/p.md"
        let sa = try #require(FuzzyMatch.score("wsp", a))
        let sb = try #require(FuzzyMatch.score("wsp", b))
        #expect(sa > sb)
        #expect(FuzzyMatch.top("wsp", in: [b, a]) == [a, b])
    }

    @Test func fuzzyNoMatchNil() {
        #expect(FuzzyMatch.score("xyz", "Sources/Workspace.swift") == nil)
        #expect(FuzzyMatch.score("wsv", "Sources/AlloyCore/Model/Workspace.swift") == nil)
        #expect(FuzzyMatch.top("xyz", in: ["a", "b"]).isEmpty)
    }

    @Test func caseInsensitiveAndContiguousWins() throws {
        let contiguous = try #require(FuzzyMatch.score("COM", "src/compact.swift"))
        let scattered = try #require(FuzzyMatch.score("com", "src/cxoxm.swift"))
        #expect(contiguous > scattered)
    }

    @Test func boundaryBeatsMidWord() throws {
        let boundary = try #require(FuzzyMatch.score("fb", "src/foo_bar.swift"))
        let mid = try #require(FuzzyMatch.score("fb", "src/fxxbxx.swift"))
        #expect(boundary > mid)
    }

    @Test func ties_shorterFirstAndLimit() {
        #expect(FuzzyMatch.top("a", in: ["aaa", "a", "aa"]) == ["a", "aa", "aaa"])
        let many = (0..<100).map { "f\($0)" }
        #expect(FuzzyMatch.top("f", in: many).count == 50)
        #expect(FuzzyMatch.top("f", in: many, limit: 3).count == 3)
        #expect(FuzzyMatch.top("", in: ["bb", "a"]) == ["a", "bb"])
    }

    @Test func wordsMatchedRangesAtWordStarts() throws {
        let r = try #require(FuzzyMatch.scoreWords("vsr", in: "View: Split Right"))
        #expect(r.matched == [0..<1, 6..<7, 12..<13])
        #expect(FuzzyMatch.scoreWords("vsr", in: "Tab: Next Tab") == nil)
    }

    @Test func wordsPreferWordStartsOverScattered() throws {
        let good = try #require(FuzzyMatch.scoreWords("spl r", in: "View: Split Right"))
        let bad = try #require(FuzzyMatch.scoreWords("spl r", in: "Asparagus plus fur"))
        #expect(good.score > bad.score)
    }

    @Test func wordsAfterColonSpaceAndCamelCase() throws {
        let colon = try #require(FuzzyMatch.scoreWords("s", in: "View: Split"))
        let mid = try #require(FuzzyMatch.scoreWords("s", in: "Viewxsplit"))
        #expect(colon.score > mid.score)
        let camel = try #require(FuzzyMatch.scoreWords("gtd", in: "goToDefinition"))
        #expect(camel.matched == [0..<1, 2..<3, 4..<5])
        let flat = try #require(FuzzyMatch.scoreWords("gtd", in: "gotodefinition"))
        #expect(camel.score > flat.score)
    }

    @Test func wordsNonASCIIKeepsWholeScalars() throws {
        let r = try #require(FuzzyMatch.scoreWords("é", in: "Café Ünï"))
        #expect(r.matched == [3..<5])
        #expect(FuzzyMatch.scoreWords("É", in: "Café") == nil)
        // A lone lead byte of é must not match inside another scalar.
        #expect(FuzzyMatch.scoreWords("é", in: "cafè") == nil)
        for m in try #require(FuzzyMatch.scoreWords("üï", in: "xüï")).matched { #expect(m.count % 2 == 0) }
    }

    @Test func topIndicesEmptyQueryLimitAndOrder() {
        let c = ["bb", "a", "ccc"]
        #expect(FuzzyMatch.topIndices(query: "", in: c, limit: 10).map(\.index) == [0, 1, 2])
        #expect(FuzzyMatch.topIndices(query: "", in: c, limit: 2).count == 2)
        #expect(FuzzyMatch.topIndices(query: "", in: c, limit: 10).allSatisfy { $0.matched.isEmpty })
        let ties = FuzzyMatch.topIndices(query: "a", in: ["aaa", "a", "aa", "a"], limit: 3)
        #expect(ties.map(\.index) == [1, 3, 2])
        #expect(FuzzyMatch.topIndices(query: String(repeating: "z", count: 5000), in: c, limit: 5).isEmpty)
    }

    @Test func recentBonusOnlyReordersNearTies() {
        #expect(FuzzyMatch.recentBonus > 0)
        let near = ["Alpha: Go", "Alpha: Gx"]  // identical scores, equal length
        let r = FuzzyMatch.topIndices(query: "ag", in: near, limit: 2) { $0 == 1 ? FuzzyMatch.recentBonus : 0 }
        #expect(r.map(\.index) == [1, 0])
        // A word-start match beats a mid-word match even when the weaker one is recent.
        let c = ["xaxg thing", "Alpha Go"]
        let r2 = FuzzyMatch.topIndices(query: "ag", in: c, limit: 2) { $0 == 0 ? FuzzyMatch.recentBonus : 0 }
        #expect(r2.first?.index == 1)
    }
}
