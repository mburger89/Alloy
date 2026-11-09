import Foundation
import Testing
@testable import AlloyCore

private struct SeededRng: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct SideBySideModelTests {
    private let session = UUID()

    private func randomText(_ rng: inout SeededRng) -> String {
        let words = ["alpha", "beta", "gamma", "", "x", "if a {", "}", "\u{e9}t\u{e9}"]
        let count = Int.random(in: 0...8, using: &rng)
        var text = (0..<count).map { _ in words.randomElement(using: &rng)! }.joined(separator: "\n")
        if count > 0, Bool.random(using: &rng) { text += "\n" }
        return text
    }

    private func model(_ ledger: FileLedger, ending: String = "\n") -> SideBySideModel {
        let entries = ledger.diffEntries()
        return SideBySideModel.build(entries.map(\.line), terminators: entries.map(\.terminator),
                                     authorOf: { _ in .session(session) }, lineEnding: ending)
    }

    /// Display row of buffer row `row` given the fillers in front of rows.
    private func display(_ row: Int, _ fillers: [SideBySideModel.Filler]) -> Int {
        row + fillers.filter { $0.beforeRow <= row }.reduce(0) { $0 + $1.count }
    }

    @Test func fillersBalanceRowCounts() {
        var rng = SeededRng(state: 7)
        for _ in 0..<200 {
            var ledger = FileLedger(path: "f.txt", baseline: randomText(&rng))
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let record = ledger.applyFullText(author: .session(session), newText: randomText(&rng), toolUseID: nil, date: Date())
                if let record, Int.random(in: 0..<3, using: &rng) == 0 { ledger.keep(record.id) }
            }
            let lines = ledger.diffLines()
            let m = model(ledger)
            #expect(m.leftRowCount + m.leftFillers.reduce(0) { $0 + $1.count }
                    == m.rightRowCount + m.rightFillers.reduce(0) { $0 + $1.count })
            // Every unchanged line sits on the same display row on both sides.
            var l = 0, r = 0
            for line in lines {
                switch line {
                case .context:
                    #expect(display(l, m.leftFillers) == display(r, m.rightFillers))
                    l += 1; r += 1
                case .added: r += 1
                case .removed: l += 1
                }
            }
        }
    }

    @Test func oldTextIsTheBaselineWhenNothingIsKept() {
        var rng = SeededRng(state: 11)
        for _ in 0..<100 {
            let baseline = randomText(&rng)
            var ledger = FileLedger(path: "f.txt", baseline: baseline)
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                ledger.applyFullText(author: .session(session), newText: randomText(&rng), toolUseID: nil, date: Date())
            }
            #expect(model(ledger).oldText == baseline)
        }
    }

    @Test func oldTextEqualsBaselinePlusKept() throws {
        var ledger = FileLedger(path: "f.txt", baseline: "a\nb\nc\n")
        let edited = ledger.applyFullText(author: .user, newText: "a\nB\nc\n", toolUseID: nil, date: Date())
        let first = try #require(edited)
        ledger.keep(first.id)
        ledger.applyFullText(author: .session(session), newText: "a\nB\nc\nd\n", toolUseID: nil, date: Date())
        ledger.applyFullText(author: .session(session), newText: "a\nc\nd\n", toolUseID: nil, date: Date())
        let m = model(ledger)
        #expect(m.oldText == "a\nB\nc\n")
        #expect(m.rightFillers == [.init(beforeRow: 1, count: 1)])
    }

    @Test func crlfTerminatorsAreKeptInOldText() {
        var ledger = FileLedger(path: "f.txt", baseline: "a\r\nb\r\nc")
        ledger.applyFullText(author: .user, newText: "a\r\nX\r\nc", toolUseID: nil, date: Date())
        let m = model(ledger, ending: "\r\n")
        #expect(m.oldText == "a\r\nb\r\nc")
    }

    @Test func replacedBlockPadsTheShorterSide() {
        let e = UUID()
        let lines: [DiffLine] = [
            .context(text: "a", line: 1),
            .removed(text: "o1", edit: e), .removed(text: "o2", edit: e), .removed(text: "o3", edit: e),
            .added(text: "n1", line: 2, edit: e, runs: []),
            .context(text: "z", line: 3),
            .added(text: "p", line: 4, edit: e, runs: []), .added(text: "q", line: 5, edit: e, runs: []),
        ]
        let m = SideBySideModel.build(lines, authorOf: { _ in .user }, lineEnding: "\n")
        #expect(m.oldText == "a\no1\no2\no3\nz\n")
        #expect(m.rightFillers == [.init(beforeRow: 2, count: 2)])
        #expect(m.leftFillers == [.init(beforeRow: 5, count: 2)])
        #expect(m.leftBars.map(\.rows) == [1..<4])
        #expect(m.rightBars.map(\.rows) == [1..<2, 3..<5])
        #expect(m.leftBars.first?.tag == m.tagOf[e])
    }
}

@MainActor @Suite struct RevealLineTests {
    @Test func revealOnAnOpenTabSelectsAndReveals() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\nthree\n")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        let before = doc.buffer.revealSerial
        await e.ws.open("a.txt", revealLine: 2, mode: .sideBySide)
        let snap = doc.buffer.snapshot()
        #expect(doc.buffer.primarySelection.range == snap.lineRange(1))
        #expect(doc.buffer.revealSerial > before)
        #expect(doc.diffMode == .sideBySide)
        // A second reveal of the same line still reveals.
        let again = doc.buffer.revealSerial
        await e.ws.open("a.txt", revealLine: 2)
        #expect(doc.buffer.revealSerial > again)
        #expect(doc.diffMode == .sideBySide)
    }

    @Test func revealBeyondEndSelectsTheLastRealLine() async throws {
        let e = Env(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        await e.ws.open("a.txt", revealLine: 99)
        let doc = try #require(e.ws.document("a.txt"))
        #expect(doc.buffer.primarySelection.range == doc.buffer.snapshot().lineRange(1))
        e.write("b.txt", "solo")
        await e.ws.open("b.txt", revealLine: 5)
        let b = try #require(e.ws.document("b.txt"))
        #expect(b.buffer.primarySelection.range == b.buffer.snapshot().lineRange(0))
    }

    @Test func revealWorksOnAReadOnlyDocument() async throws {
        let e = Env(); defer { e.cleanup() }
        try Data([0x61, 0xFF, 0x0A, 0x62, 0x0A]).write(to: e.root.appendingPathComponent("bad.txt"))
        await e.ws.open("bad.txt")
        let doc = try #require(e.ws.document("bad.txt"))
        let before = doc.buffer.revealSerial
        await e.ws.open("bad.txt", revealLine: 2)
        #expect(doc.buffer.primarySelection.range == doc.buffer.snapshot().lineRange(1))
        #expect(doc.buffer.revealSerial > before)
        #expect(!doc.isDirty)
    }

    @Test func workspaceFirstLineUsesTheRecordForAKeptEdit() async throws {
        let e = Env(); defer { e.cleanup() }
        var ledger = FileLedger(path: "f.txt", baseline: "a\nb\nc\nd\n")
        let rec = ledger.applyFullText(author: .user, newText: "a\nb\nc\nX\nd\n", toolUseID: nil, date: Date())
        let id = try #require(rec).id
        ledger.keep(id)
        #expect(ledger.firstLine(of: id) == nil)
        #expect(ledger.recordedLine(of: id) == 4)
    }

    @Test func firstLineOfAnEdit() throws {
        var ledger = FileLedger(path: "f.txt", baseline: "a\nb\nc\nd\n")
        let addedRecord = ledger.applyFullText(author: .user, newText: "a\nb\nc\nX\nY\nd\n", toolUseID: nil, date: Date())
        let added = try #require(addedRecord)
        #expect(ledger.firstLine(of: added.id) == 4)
        let removedRecord = ledger.applyFullText(author: .user, newText: "a\nc\nX\nY\nd\n", toolUseID: nil, date: Date())
        let removed = try #require(removedRecord)
        #expect(ledger.firstLine(of: removed.id) == 2)
        #expect(ledger.firstLine(of: UUID()) == nil)
    }
}
