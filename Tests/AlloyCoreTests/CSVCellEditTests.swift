@testable import AlloyCore
import MetalUICodeBuffer
import Testing

@MainActor
private func makeDoc(_ text: String, state: DocState = .editable) -> EditorDocument {
    EditorDocument(path: "t.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv",
                   state: state, diskStamp: FileStamp(modified: nil, size: text.utf8.count))
}

@MainActor
private func model(_ text: String, state: DocState = .editable) async -> (CSVTableModel, EditorDocument) {
    let d = makeDoc(text, state: state)
    let m = CSVTableModel(document: d)
    await m.buildFinished()
    _ = m.cells(forDataRow: 0)
    for i in 0..<m.rowCount { _ = m.cells(forDataRow: i) }
    return (m, d)
}

@MainActor
private func text(_ d: EditorDocument) -> String {
    let s = d.buffer.snapshot()
    return String(decoding: s.utf8(in: 0..<s.utf8Count), as: UTF8.self)
}

@MainActor
private func commit(_ m: CSVTableModel, row: Int, col: Int, _ value: String) -> CSVCellEditOutcome {
    guard let t = m.beginCellEdit(fileRow: row, column: col) else { return .refusedNoRow }
    return m.commitCellEdit(t, text: value)
}

@MainActor
@Suite struct CSVCellEditTests {
    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n"

    @Test func commitReplacesOnlyTheFieldRange() async {
        let (m, d) = await model(Self.base)
        #expect(commit(m, row: 1, col: 1, "annabel") == .applied)
        #expect(text(d) == "id,name,city\n1,annabel,rome\n2,bob,oslo\n")
        #expect(m.cells(forDataRow: 0).values[1] == "annabel")
    }

    @Test func unchangedValueIsANoOp() async {
        let (m, d) = await model(Self.base)
        let v = d.buffer.version
        #expect(commit(m, row: 1, col: 1, "ann") == .unchanged)
        #expect(d.buffer.version == v)
    }

    @Test func quotedFieldStaysQuoted() async {
        let (m, d) = await model("a,b\n1,\"x\"\n")
        #expect(commit(m, row: 1, col: 1, "y") == .applied)
        #expect(text(d) == "a,b\n1,\"y\"\n")
    }

    @Test func valueWithDelimiterQuoteNewlineOrEdgeSpacesIsQuotedAndDoubled() async {
        for (v, enc) in [("a,b", "\"a,b\""), ("say \"hi\"", "\"say \"\"hi\"\"\""), ("l1\nl2", "\"l1\nl2\""),
                         (" pad", "\" pad\""), ("pad ", "\"pad \"")] {
            let (m, d) = await model("a,b\n1,2\n")
            #expect(commit(m, row: 1, col: 1, v) == .applied)
            #expect(text(d) == "a,b\n1,\(enc)\n")
            let t = m.beginCellEdit(fileRow: 1, column: 1)
            #expect(t?.initialValue == v)
        }
    }

    @Test func emptyingAQuotedFieldKeepsTheQuotes() async {
        let (m, d) = await model("a,b\n1,\"x\"\n")
        #expect(commit(m, row: 1, col: 1, "") == .applied)
        #expect(text(d) == "a,b\n1,\"\"\n")
    }

    @Test func raggedRowInsertsDelimitersBeforeTheTerminator() async {
        let (m, d) = await model("a,b,c,d\r\n1,2\r\n3,4,5,6\r\n")
        #expect(commit(m, row: 1, col: 3, "x") == .applied)
        #expect(text(d) == "a,b,c,d\r\n1,2,,x\r\n3,4,5,6\r\n")
    }

    @Test func lastRowWithoutNewlineRaggedEdit() async {
        let (m, d) = await model("a,b,c\n1,2,3\n4")
        #expect(commit(m, row: 2, col: 2, "z") == .applied)
        #expect(text(d) == "a,b,c\n1,2,3\n4,,z")
        let (m2, d2) = await model("a,b,c\n1,2,3\n4,5")
        #expect(commit(m2, row: 2, col: 1, "q") == .applied)
        #expect(text(d2) == "a,b,c\n1,2,3\n4,q")
    }

    @Test func missingCellLeftEmptyIsANoOp() async {
        let (m, d) = await model("a,b,c\n1\n")
        let v = d.buffer.version
        #expect(commit(m, row: 1, col: 2, "") == .unchanged)
        #expect(d.buffer.version == v)
    }

    @Test func crlfAndBomFilesKeepTheirBytes() async {
        let src = "\u{FEFF}a,b\r\n1,\"x\"\r\n2,3\r\n"
        let (m, d) = await model(src)
        #expect(commit(m, row: 1, col: 0, "9") == .applied)
        #expect(commit(m, row: 2, col: 1, "t,u") == .applied)
        #expect(text(d) == "\u{FEFF}a,b\r\n9,\"x\"\r\n2,\"t,u\"\r\n")
    }

    @Test func undoRestoresExactBytesAndRedoReapplies() async {
        let (m, d) = await model(Self.base)
        _ = d.buffer.replace(0..<2, with: "ID", origin: .typing)
        m.sync()
        await m.buildFinished()
        let typed = text(d)
        #expect(commit(m, row: 1, col: 2, "paris") == .applied)
        let edited = text(d)
        #expect(d.buffer.undo())
        #expect(text(d) == typed)
        m.sync()
        await m.buildFinished()
        #expect(m.cells(forDataRow: 0).values[2] == "rome")
        #expect(d.buffer.redo())
        #expect(text(d) == edited)
        #expect(d.buffer.undo())
        #expect(d.buffer.undo())
        #expect(text(d) == Self.base)
    }

    @Test func externalEditElsewhereStillCommitsAtTheMappedRange() async throws {
        let (m, d) = await model(Self.base)
        let t = try #require(m.beginCellEdit(fileRow: 2, column: 1))
        try d.buffer.applyExternalEdits([CodeTextEdit(range: 0..<2, text: "IDENT")])
        #expect(m.commitCellEdit(t, text: "bobby") == .applied)
        #expect(text(d) == "IDENT,name,city\n1,ann,rome\n2,bobby,oslo\n")
    }

    @Test func externalEditToTheSameFieldRefuses() async throws {
        let (m, d) = await model(Self.base)
        let t = try #require(m.beginCellEdit(fileRow: 1, column: 1))
        let at = text(d).utf8.distance(from: text(d).startIndex, to: text(d).range(of: "ann")!.lowerBound)
        try d.buffer.applyExternalEdits([CodeTextEdit(range: at..<(at + 3), text: "ann")])   // identical bytes: still fine
        try d.buffer.applyExternalEdits([CodeTextEdit(range: at..<(at + 3), text: "amy")])
        let before = text(d)
        let v = d.buffer.version
        let out = m.commitCellEdit(t, text: "zed")
        #expect(out == .refusedChanged)
        #expect(out.notice != nil)
        #expect(text(d) == before && d.buffer.version == v)
    }

    @Test func externalEditOverlappingTheFieldBoundaryRefuses() async throws {
        let (m, d) = await model(Self.base)
        let t = try #require(m.beginCellEdit(fileRow: 1, column: 1))
        let at = text(d).utf8.distance(from: text(d).startIndex, to: text(d).range(of: "1,ann")!.lowerBound)
        try d.buffer.applyExternalEdits([CodeTextEdit(range: (at + 1)..<(at + 3), text: ";a")])   // delimiter plus first byte
        let before = text(d)
        #expect(m.commitCellEdit(t, text: "zed") == .refusedChanged)
        #expect(text(d) == before)
        // An insertion right at the end of the field counts as touching it.
        let (m2, d2) = await model(Self.base)
        let t2 = try #require(m2.beginCellEdit(fileRow: 1, column: 1))
        let end = text(d2).utf8.distance(from: text(d2).startIndex, to: text(d2).range(of: "ann")!.upperBound)
        try d2.buffer.applyExternalEdits([CodeTextEdit(range: end..<end, text: "x")])
        #expect(m2.commitCellEdit(t2, text: "zed") == .refusedChanged)
    }

    @Test func readOnlyDocumentRefuses() async {
        let (m, d) = await model(Self.base, state: .readOnly(reason: "test"))
        #expect(!m.canEdit(fileRow: 1, column: 1))
        #expect(m.beginCellEdit(fileRow: 1, column: 1) == nil)
        #expect(text(d) == Self.base)
    }

    @Test func readOnlyAfterBeginRefusesCommit() async throws {
        let (m, d) = await model(Self.base)
        let t = try #require(m.beginCellEdit(fileRow: 1, column: 1))
        d.state = .readOnly(reason: "test")
        #expect(m.commitCellEdit(t, text: "x") == .refusedReadOnly)
        #expect(text(d) == Self.base)
    }

    @Test func flaggedRowRefuses() async {
        let (m, d) = await model("a,b\n1,\"open\n2,3\n")
        let flagged = (1..<3).filter { !m.canEdit(fileRow: $0, column: 0) }
        #expect(!flagged.isEmpty)
        for r in flagged { #expect(m.beginCellEdit(fileRow: r, column: 0) == nil) }
        #expect(text(d) == "a,b\n1,\"open\n2,3\n")
    }

    @Test func unknownRowRefuses() async {
        let (m, _) = await model(Self.base)
        #expect(m.beginCellEdit(fileRow: 0, column: 0) == nil)   // the header
        #expect(m.beginCellEdit(fileRow: 99, column: 0) == nil)
        #expect(m.beginCellEdit(fileRow: 1, column: 9) == nil)
        #expect(m.beginCellEdit(fileRow: 1, column: -1) == nil)
        let (e, _) = await model("")
        #expect(e.beginCellEdit(fileRow: 0, column: 0) == nil)
        let (h, _) = await model("a,b\n")
        #expect(h.beginCellEdit(fileRow: 1, column: 0) == nil)
    }

    @Test func commitOriginIsProgrammaticAndOneUndoStep() async throws {
        let (m, d) = await model(Self.base)
        let cursor = d.buffer.makeEditCursor()
        _ = cursor.drain()
        #expect(commit(m, row: 1, col: 2, "a,b") == .applied)
        guard case .edits(let edits) = cursor.drain() else { Issue.record("expected edits"); return }
        #expect(edits.count == 1 && edits.allSatisfy { $0.origin == .programmatic })
        #expect(d.buffer.undo())
        #expect(text(d) == Self.base)
    }

    @Test func roundTripProperty() async {
        let table = ["", " ", "a", "a,b", "\"", "\"\"", "x\ny", "x\r\ny", " lead", "trail ", "é\u{1F600}", "a;b", "\t", ",", "q\"q,\n"]
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let quoted = Bool.random(using: &rng)
            let src = "a,b,c\r\n1,\(quoted ? "\"old\"" : "old"),3\r\n4,5,6"
            let (m, d) = await model(src)
            let value = table[Int.random(in: 0..<table.count, using: &rng)] + (Bool.random() ? table[Int.random(in: 0..<table.count)] : "")
            let t = m.beginCellEdit(fileRow: 1, column: 1)
            let outcome = commit(m, row: 1, col: 1, value)
            #expect(outcome == (value == "old" ? .unchanged : .applied))
            let after = m.beginCellEdit(fileRow: 1, column: 1)
            #expect(after?.initialValue == value)
            #expect(t != nil)
            let s = text(d)
            #expect(s.hasPrefix("a,b,c\r\n1,") && s.hasSuffix(",3\r\n4,5,6"))
            #expect(m.beginCellEdit(fileRow: 2, column: 2)?.initialValue == "6")
        }
    }
}
