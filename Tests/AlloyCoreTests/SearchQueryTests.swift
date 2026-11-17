import Testing

@testable import AlloyCore

private func scan(_ text: String, _ query: SearchQuery, stop: @escaping () -> Bool = { false }) throws -> ScanResult {
    try query.compile().scan(Array(text.utf8), regexBudget: nil, shouldStop: stop)
}

@Suite struct SearchQueryTests {
    @Test func literalIsCaseInsensitiveByDefault() throws {
        let r = try scan("Foo\nxx foo\nbar", SearchQuery(text: "foo"))
        #expect(r.matches.map(\.line) == [1, 2])
        #expect(r.matches.map(\.range) == [0..<3, 7..<10])
        #expect(r.matches[1].lineStart == 4)
    }

    @Test func matchCaseExcludes() throws {
        let r = try scan("Foo\nfoo", SearchQuery(text: "foo", caseSensitive: true))
        #expect(r.matches.map(\.range) == [4..<7])
    }

    @Test func wholeWord() throws {
        let q = SearchQuery(text: "foo", wholeWord: true)
        #expect(try scan("foo(", q).matches.count == 1)
        #expect(try scan("foobar", q).matches.isEmpty)
        #expect(try scan("_foo", q).matches.isEmpty)
        #expect(try scan("foofoo foo", q).matches.map(\.range) == [7..<10])
    }

    @Test func nonOverlapping() throws {
        let r = try scan("aaaa", SearchQuery(text: "aa"))
        #expect(r.matches.map(\.range) == [0..<2, 2..<4])
    }

    @Test func multibyteBytesAndPreview() throws {
        let text = "é😀x foo"
        let r = try scan(text, SearchQuery(text: "foo"))
        let m = try #require(r.matches.first)
        #expect(m.range == 8..<11)
        #expect(m.preview == text)
        #expect(String(decoding: Array(m.preview.utf8)[m.previewMatch], as: UTF8.self) == "foo")
    }

    @Test func multibyteRegexOffsets() throws {
        let text = "e\u{301}😀 日本 foo"
        let r = try scan(text, SearchQuery(text: "fo+", regex: true))
        let m = try #require(r.matches.first)
        #expect(String(decoding: Array(text.utf8)[m.range], as: UTF8.self) == "foo")
    }

    @Test func crlfRegexDollarAndPreview() throws {
        let r = try scan("foo\r\nbar", SearchQuery(text: "foo$", regex: true))
        let m = try #require(r.matches.first)
        #expect(m.range == 0..<3)
        #expect(!m.preview.contains("\r"))
        let lit = try scan("foo\r\nbar\r\n", SearchQuery(text: "bar"))
        #expect(lit.matches.first?.preview == "bar")
        #expect(lit.matches.first?.line == 2)
    }

    @Test func regexReplacementCaptures() throws {
        let matcher = try SearchQuery(text: "(\\w+)=(\\d+)", regex: true).compile()
        let line = "  key=42 other=7"
        let r = matcher.scan(Array(line.utf8))
        #expect(r.matches.count == 2)
        #expect(matcher.replacement(for: r.matches[0], in: Substring(line), template: "$2=${1}") == "42=key")
        #expect(matcher.replacement(for: r.matches[1], in: Substring(line), template: "$2=${1}") == "7=other")
        #expect(matcher.replacement(for: r.matches[1], in: Substring(line), template: "$$9 $5 $") == "$9  $")
    }

    @Test func literalReplacementKeepsDollar() throws {
        let matcher = try SearchQuery(text: "a").compile()
        let r = matcher.scan(Array("a".utf8))
        #expect(matcher.replacement(for: r.matches[0], in: "a", template: "$1") == "$1")
    }

    @Test func zeroWidthYieldsNothingAndTerminates() throws {
        let a = try scan("b", SearchQuery(text: "a*", regex: true))
        #expect(a.matches.isEmpty && a.sawOnlyEmpty)
        let c = try scan("x\ny", SearchQuery(text: "^", regex: true))
        #expect(c.matches.isEmpty && c.sawOnlyEmpty)
        let d = try scan("baab", SearchQuery(text: "a*", regex: true))
        #expect(d.matches.map(\.range) == [1..<3])
        #expect(!d.sawOnlyEmpty)
    }

    @Test func invalidAndEmpty() {
        #expect(throws: SearchError.self) { try SearchQuery(text: "(", regex: true).compile() }
        #expect(throws: SearchError.empty) { try SearchQuery(text: "").compile() }
        #expect(throws: SearchError.empty) { try SearchQuery(text: "", regex: true).compile() }
    }

    @Test func longLineSkippedInRegexMode() throws {
        let long = String(repeating: "a", count: 70_000)
        let r = try scan(long + "\nfoo", SearchQuery(text: "fo+", regex: true))
        #expect(r.skippedLongLines)
        #expect(r.matches.map(\.line) == [2])
        let lit = try scan(long + "foo", SearchQuery(text: "foo"))
        #expect(!lit.skippedLongLines)
        #expect(lit.matches.count == 1)
    }

    @Test func shouldStopEndsEarly() throws {
        var calls = 0
        let text = (0..<100).map { _ in "foo" }.joined(separator: "\n")
        let r = try SearchQuery(text: "foo").compile().scan(Array(text.utf8), regexBudget: nil) {
            calls += 1
            return calls > 5
        }
        #expect(r.matches.count == 5)
    }

    @Test func previewIsCapped() throws {
        let text = String(repeating: "x", count: 500) + "NEEDLE" + String(repeating: "y", count: 500)
        let m = try #require(try scan(text, SearchQuery(text: "needle")).matches.first)
        #expect(m.preview.count <= 200)
        #expect(String(decoding: Array(m.preview.utf8)[m.previewMatch], as: UTF8.self) == "NEEDLE")
    }

    @Test func hugeLineWithManyMatchesIsFastAndPreviewsAreCorrect() throws {
        let unit = "😀é abc needle xyz "  // multibyte filler so windows land mid-scalar
        let text = String(repeating: unit, count: 40_000)  // roughly 1 MB, one line
        let clock = ContinuousClock()
        var r = ScanResult()
        let t = try clock.measure { r = try scan(text, SearchQuery(text: "needle")) }
        #expect(r.matches.count == 40_000)
        #expect(t < .seconds(2))
        for m in [r.matches[0], r.matches[20_000], r.matches[39_999]] {
            #expect(m.preview.count <= 200)
            #expect(String(decoding: Array(m.preview.utf8)[m.previewMatch], as: UTF8.self) == "needle")
            #expect(!m.preview.contains("\u{FFFD}"))
        }
        #expect(r.matches[0].preview.hasPrefix("😀é abc needle"))
    }

    @Test func previewTrimsIndent() throws {
        let m = try #require(try scan("    \t foo  ", SearchQuery(text: "foo")).matches.first)
        #expect(m.preview == "foo")
        #expect(m.previewMatch == 0..<3)
    }

    @Test func emptyBytes() throws {
        #expect(try scan("", SearchQuery(text: "a")).matches.isEmpty)
    }
}
