@testable import AlloyCore
import Testing

private func enc(_ s: String, _ d: UInt8 = UInt8(ascii: ","), q: Bool = false) -> String {
    String(decoding: CSVEncoder.encode(s, delimiter: d, wasQuoted: q), as: UTF8.self)
}

@Suite struct CSVEncoderTests {
    @Test func needsQuotesForDelimiterQuoteCRLFAndEdgeSpaces() {
        #expect(enc("plain") == "plain")
        #expect(enc("a,b") == "\"a,b\"")
        #expect(enc("a\tb") == "a\tb")
        #expect(enc("a\tb", UInt8(ascii: "\t")) == "\"a\tb\"")
        #expect(enc("a\"b") == "\"a\"\"b\"")
        #expect(enc("a\nb") == "\"a\nb\"")
        #expect(enc("a\rb") == "\"a\rb\"")
        #expect(enc(" a") == "\" a\"")
        #expect(enc("a ") == "\"a \"")
        #expect(enc("a b") == "a b")
        #expect(enc("") == "")
    }

    @Test func keepsQuotingWhenWasQuoted() {
        #expect(enc("abc", q: true) == "\"abc\"")
        #expect(enc("", q: true) == "\"\"")
    }

    @Test func doublesQuotes() {
        #expect(enc("\"", q: false) == "\"\"\"\"")
        #expect(enc("say \"hi\"") == "\"say \"\"hi\"\"\"")
    }

    @Test func roundTrip() {
        let samples = ["", " ", "  x  ", "a", "a,b", "a;b", "a\tb", "\"", "\"\"", "\"a\"", "a\"b", ",", ",,", "\n", "\r\n", "a\nb\r\nc",
                       "\rx", "x\r", "é", "日本語,語", "emoji 😀,\"", "tab\there", "semi;colon", "lead,", ",trail", "q\"\"q", "  \"  ",
                       "line1\nline2,\"x\"", "\u{23CE}", "a b", "0", "-1.5e3", "null"]
        #expect(samples.count >= 30)
        for d in [UInt8(ascii: ","), UInt8(ascii: "\t")] {
            for wasQuoted in [false, true] {
                for v in samples {
                    let e = CSVEncoder.encode(v, delimiter: d, wasQuoted: wasQuoted)
                    let isQ = e.first == UInt8(ascii: "\"") && e.count >= 2
                    #expect(CSVParser.value(of: e[...], quoted: isQ) == v, "\(v.debugDescription) delimiter \(d)")
                    // The encoded field parses back as exactly one field.
                    let p = CSVParser.parseRow(e, dialect: CSVDialect(delimiter: d))
                    #expect(p.fields.count == 1 && !p.flagged, "\(v.debugDescription)")
                }
            }
        }
    }
}
