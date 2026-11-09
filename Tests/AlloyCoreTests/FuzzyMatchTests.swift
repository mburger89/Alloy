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
}
