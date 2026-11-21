@testable import AlloyCore
import Testing

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
private func parse(_ s: String, _ d: CSVDialect = .comma) -> CSVRowParse { CSVParser.parseRow(bytes(s), dialect: d) }
private func values(_ s: String, _ d: CSVDialect = .comma) -> [String] {
    let b = bytes(s), p = parse(s, d)
    return zip(p.fields, p.quoted).map { CSVParser.value(of: b[$0], quoted: $1) }
}

@Suite struct CSVParserTests {
    @Test func plainRow() {
        let p = parse("a,b,c\n")
        #expect(p.fields == [0..<1, 2..<3, 4..<5])
        #expect(p.terminatorLength == 1)
        #expect(!p.flagged)
    }

    @Test func crlfAndNoNewlineAndMixed() {
        #expect(parse("a,b\r\n").terminatorLength == 2)
        #expect(parse("a,b").terminatorLength == 0)
        let src = bytes("a\r\nb\nc\r\n")
        var at = 0
        var lens: [Int] = []
        while at < src.count {
            let end = CSVRowScanner.nextRow(in: src, from: at, dialect: .comma).end
            lens.append(CSVParser.parseRow(Array(src[at..<end]), dialect: .comma).terminatorLength)
            at = end
        }
        #expect(lens == [2, 1, 2])
    }

    @Test func quotedDelimiterAndNewline() {
        let s = "\"a,b\",\"line1\nline2\",c\n"
        let p = parse(s)
        #expect(p.fields.count == 3)
        #expect(values(s) == ["a,b", "line1\nline2", "c"])
        let b = bytes(s)
        #expect(CSVParser.displayValue(of: b[p.fields[1]], quoted: true) == "line1\u{23CE}")
        #expect(CSVRowScanner.nextRow(in: b, from: 0, dialect: .comma).end == b.count)
    }

    @Test func doubledQuotes() {
        #expect(values("\"say \"\"hi\"\"\"") == ["say \"hi\""])
    }

    @Test func emptyFieldsAndRagged() {
        #expect(parse(",,\n").fields.count == 3)
        #expect(values(",,\n") == ["", "", ""])
        #expect(parse("a,b\n").fields.count == 2)
    }

    @Test func dialectIgnoresBOM() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        #expect(CSVDialect.detect(language: "csv", firstRow: bom + bytes("a;b;c")).delimiter == UInt8(ascii: ";"))
        #expect(CSVDialect.detect(language: "csv", firstRow: bom + bytes("a,b")).delimiter == UInt8(ascii: ","))
    }

    @Test func semicolonDetected() {
        #expect(CSVDialect.detect(language: "csv", firstRow: bytes("a;b;c")).delimiter == UInt8(ascii: ";"))
        #expect(CSVDialect.detect(language: "csv", firstRow: bytes("\"a,b\";c")).delimiter == UInt8(ascii: ";"))
        #expect(CSVDialect.detect(language: "tsv", firstRow: bytes("a;b;c;d")).delimiter == UInt8(ascii: "\t"))
        #expect(CSVDialect.detect(language: "csv", firstRow: bytes("a,b;c")).delimiter == UInt8(ascii: ","))
    }

    @Test func strayQuoteMidFieldIsLiteral() {
        let p = parse("ab\"c,d\n")
        #expect(p.fields.count == 2)
        #expect(!p.flagged)
        #expect(values("ab\"c,d\n") == ["ab\"c", "d"])
    }

    @Test func quoteOpensOnlyAtFieldStart() {
        let s = "x\"a,b\",c\n"
        #expect(values(s) == ["x\"a", "b\"", "c"])
        #expect(!parse(s).flagged)
    }

    @Test func unmatchedOpeningQuoteFallsBack() {
        let s = bytes("\"abc,def\nnext,row\n")
        let first = CSVRowScanner.nextRow(in: s, from: 0, dialect: .comma)
        #expect(first.end == 9)
        #expect(first.flagged)
        let p = CSVParser.parseRow(Array(s[0..<first.end]), dialect: .comma)
        #expect(p.flagged)
        #expect(p.fields.count == 2)
        #expect(String(decoding: s[p.fields[0]], as: UTF8.self) == "\"abc")
        let second = CSVRowScanner.nextRow(in: s, from: first.end, dialect: .comma)
        #expect(second.end == s.count)
        #expect(!second.flagged)
    }

    @Test func closingQuoteNotFollowedByDelimiterFlags() {
        let p = parse("\"ab\"c,d\n")
        #expect(p.flagged)
        #expect(p.fields.count == 2)
    }

    @Test func lookaheadBoundRespected() {
        var s = bytes("\"first line\n")
        s += [UInt8](repeating: UInt8(ascii: "x"), count: 1 << 20)
        s += bytes("\nmore\n")
        let r = CSVRowScanner.nextRow(in: s, from: 0, dialect: .comma, lookahead: CSVLookahead(maxBytes: 100, maxLines: 3))
        #expect(r.end == 12)
        #expect(r.flagged)
        // Default bounds on a 1 MB tail also fall back instead of swallowing the file.
        let d = CSVRowScanner.nextRow(in: s, from: 0, dialect: .comma)
        #expect(d.end == 12 && d.flagged)
    }

    @Test func tsvFollowsTheSameRules() {
        let t = CSVDialect.tab
        #expect(values("a\t\"b\tc\"\td\n", t) == ["a", "b\tc", "d"])
        #expect(values("ab\"c\td\n", t) == ["ab\"c", "d"])
        #expect(parse("\"abc\tdef\nx\n", t).flagged)
        #expect(parse("a,b\tc\n", t).fields.count == 2)
    }

    @Test func rowsAcrossChunkBoundary() {
        // A quoted field straddling the 64 KB chunk boundary.
        let big = String(repeating: "y", count: 65_530)
        let s = bytes("\"\(big)\nzz\",k\nnext\n")
        let r = CSVRowScanner.nextRow(in: s, from: 0, dialect: .comma)
        #expect(r.end == s.count - 5)
        #expect(!r.flagged)
    }

    @Test func emptyInputAndUnclosedAtEOF() {
        #expect(CSVRowScanner.nextRow(in: [UInt8](), from: 0, dialect: .comma).end == 0)
        #expect(parse("\"abc\"").fields == [0..<5])
    }
}
