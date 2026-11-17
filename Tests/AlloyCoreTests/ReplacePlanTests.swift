import Foundation
import Testing

@testable import AlloyCore

private func plan(_ text: String, _ query: SearchQuery, template: String) throws -> (ReplacePlan, ReplaceFile, [UInt8]) {
    let bytes = Array(text.utf8)
    let matches = try query.compile().scan(bytes).matches
    let file = ReplaceFile(path: "a.txt", matches: matches)
    return (ReplacePlan(files: [file], query: query, template: template), file, bytes)
}

private func apply(_ text: String, _ query: SearchQuery, _ template: String) throws -> String {
    let (p, f, bytes) = try plan(text, query, template: template)
    guard case .rewritten(let out) = p.rewrite(f, bytes: bytes) else { Issue.record("skipped"); return "" }
    return String(decoding: out, as: UTF8.self)
}

@Suite struct ReplacePlanTests {
    @Test func editsRunBackToFront() throws {
        let (p, f, bytes) = try plan("foo foo foo", SearchQuery(text: "foo"), template: "x")
        let starts = p.edits(for: f, in: bytes).map(\.range.lowerBound)
        #expect(starts == [8, 4, 0])
        #expect(p.totalMatches == 3)
    }

    @Test func manyMatchesInLargeFileRewriteInOnePass() throws {
        let n = 50_000
        let text = String(repeating: "alpha foo beta\n", count: n)
        let (p, f, bytes) = try plan(text, SearchQuery(text: "foo"), template: "quux")
        #expect(f.matches.count == n)
        let start = ContinuousClock.now
        guard case .rewritten(let out) = p.rewrite(f, bytes: bytes) else { Issue.record("skipped"); return }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(String(decoding: out, as: UTF8.self) == String(repeating: "alpha quux beta\n", count: n))
    }

    @Test func verifyFailsWhenBytesDiffer() throws {
        let (p, f, _) = try plan("foo bar", SearchQuery(text: "foo"), template: "x")
        #expect(p.verify(f, against: Array("foo bar".utf8)))
        #expect(!p.verify(f, against: Array("fxo bar".utf8)))
        #expect(!p.verify(f, against: Array("a foo bar".utf8)))
    }

    @Test func verifyFailsWhenFileIsShorter() throws {
        let (p, f, _) = try plan("bar foo", SearchQuery(text: "foo"), template: "x")
        #expect(!p.verify(f, against: Array("bar".utf8)))
    }

    @Test func multibyteBeforeMatch() throws {
        #expect(try apply("😀é\u{0301} foo 日本", SearchQuery(text: "foo"), "bar") == "😀é\u{0301} bar 日本")
    }

    @Test func crlfKept() throws {
        #expect(try apply("foo\r\nfoo\r\n", SearchQuery(text: "foo"), "x") == "x\r\nx\r\n")
        #expect(try apply("a foo\r\nb", SearchQuery(text: "foo$", regex: true), "x") == "a x\r\nb")
    }

    @Test func regexCapturesExpand() throws {
        let q = SearchQuery(text: "(\\w+)=(\\d+)", caseSensitive: true, regex: true)
        #expect(try apply("a=1 b=22", q, "$2:$1") == "1:a 22:b")
        #expect(try apply("a=1", q, "${2}-${1}-$0") == "1-a-a=1")
        #expect(try apply("a=1", q, "$$1") == "$1")
    }

    @Test func namedCapturesExpand() throws {
        let q = SearchQuery(text: "(?<k>\\w+)=(?<v>\\d+)", caseSensitive: true, regex: true)
        #expect(try apply("a=1", q, "${v}/${k}") == "1/a")
    }

    @Test func signedAndUnknownCaptureKeysDoNotCrash() throws {
        let q = SearchQuery(text: "(\\w+)=(\\d+)", caseSensitive: true, regex: true)
        #expect(try apply("a=1", q, "[${-1}]") == "[]")
        #expect(try apply("a=1", q, "[${+1}]") == "[]")
        #expect(try apply("a=1", q, "[${nope}]") == "[]")
    }

    @Test func literalAndWholeWordInsertDollarVerbatim() throws {
        #expect(try apply("foo", SearchQuery(text: "foo"), "$1") == "$1")
        #expect(try apply("foo", SearchQuery(text: "foo", wholeWord: true), "${x}$1") == "${x}$1")
    }

    @Test func replacementContainingMatchDoesNotRematch() throws {
        #expect(try apply("foo foo", SearchQuery(text: "foo"), "foofoo") == "foofoo foofoo")
    }

    @Test func skipReasons() {
        #expect(ReplacePlan.skipReason(bytes: Array("ok".utf8)) == nil)
        #expect(ReplacePlan.skipReason(bytes: [0xFF, 0xFE, 0x41]) == "not valid UTF-8")
        #expect(ReplacePlan.skipReason(bytes: Array("ok".utf8), size: 17 * 1024 * 1024) == "larger than 16 MB")
        #expect(ReplacePlan.skipReason(bytes: Array("ok".utf8), readOnly: true) == "read-only")
    }

    @Test func rewriteSkipsChangedFile() throws {
        let (p, f, _) = try plan("foo", SearchQuery(text: "foo"), template: "x")
        #expect(p.rewrite(f, bytes: Array("fo".utf8)) == .skipped(reason: "changed since search"))
        #expect(p.rewrite(f, bytes: [0xFF]) == .skipped(reason: "not valid UTF-8"))
    }
}
