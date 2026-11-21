@testable import AlloyCore
import Testing

private func build(_ s: String, _ d: CSVDialect = .comma) -> CSVIndex {
    CSVIndex.build(Array(s.utf8), dialect: d)
}

@Suite struct CSVIndexTests {
    @Test func emptyFileHasNoRows() {
        let i = build("")
        #expect(i.rowCount == 0)
        #expect(i.row(containing: 5) == 0)
    }

    @Test func bomOnlyHasNoRows() {
        let i = build("\u{FEFF}")
        #expect(i.rowCount == 0)
        #expect(i.bomLength == 3)
    }

    @Test func bomIsSkippedAndKept() {
        let i = build("\u{FEFF}a,b\nc,d\n")
        #expect(i.bomLength == 3)
        #expect(i.rowStarts == [3, 7])
        #expect(i.rowRange(0) == 3..<7)
    }

    @Test func noTrailingNewlineLastRowComplete() {
        let i = build("a\nb")
        #expect(i.rowCount == 2)
        #expect(i.rowRange(1) == 2..<3)
        #expect(build("a\nb\n").rowCount == 2)
    }

    @Test func headerOnly() {
        #expect(build("a,b,c\n").rowCount == 1)
    }

    @Test func quotedNewlineIsOneRow() {
        let i = build("a,\"x\ny\"\nb,c\n")
        #expect(i.rowCount == 2)
        #expect(i.rowRange(0) == 0..<8)
    }

    @Test func mixedEndings() {
        let i = build("a\r\nb\nc\r\nd")
        #expect(i.rowStarts == [0, 3, 5, 8])
    }

    @Test func flaggedRowsRecorded() {
        let i = build("a,b\n\"oops,c\nd,e\n")
        #expect(i.flaggedRows == [1])
        #expect(i.isFlagged(1))
        #expect(!i.isFlagged(0))
        #expect(!i.isFlagged(2))
    }

    @Test func rowContainingOffsetClamps() {
        let i = build("ab\ncd\nef")
        #expect(i.row(containing: 0) == 0)
        #expect(i.row(containing: 2) == 0)
        #expect(i.row(containing: 3) == 1)
        #expect(i.row(containing: 100) == 2)
        #expect(i.row(containing: -4) == 0)
    }

    @Test func oneStrayQuoteInTenMegabytesDoesNotSwallowTheFile() {
        var lines: [String] = []
        let line = "alpha,beta,gamma,delta,epsilon,zeta,eta,theta"
        var total = 0
        var n = 0
        while total < 10 << 20 {
            let l = n == 3 ? "\"stray,quote,here" : line
            lines.append(l)
            total += l.utf8.count + 1
            n += 1
        }
        let bytes = Array((lines.joined(separator: "\n") + "\n").utf8)
        let start = ContinuousClock.now
        let i = CSVIndex.build(bytes, dialect: .comma)
        let elapsed = ContinuousClock.now - start
        #expect(i.rowCount == lines.count)
        #expect(i.flaggedRows == [3])
        #expect(elapsed < .seconds(2))
    }
}
