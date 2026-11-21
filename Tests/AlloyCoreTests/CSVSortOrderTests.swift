@testable import AlloyCore
import MetalUICodeBuffer
import Testing

@MainActor
private func makeDoc(_ text: String) -> EditorDocument {
    EditorDocument(path: "t.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv",
                   state: .editable, diskStamp: FileStamp(modified: nil, size: text.utf8.count))
}

@MainActor
private func model(_ text: String) async -> (CSVTableModel, EditorDocument) {
    let d = makeDoc(text)
    let m = CSVTableModel(document: d)
    await m.buildFinished()
    return (m, d)
}

/// Waits until the model's sort lands (a test hook: the sort publishes once).
@MainActor
private func sorted(_ m: CSVTableModel, column: Int, ascending: Bool = true) async {
    let before = m.revision
    m.sort(column: column, ascending: ascending)
    for _ in 0..<2000 where m.revision == before { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
}

@MainActor
private func text(_ d: EditorDocument) -> String {
    let s = d.buffer.snapshot()
    return String(decoding: s.utf8(in: 0..<s.utf8Count), as: UTF8.self)
}

@Suite struct CSVSorterTests {
    private func order(_ values: [String], ascending: Bool = true) -> [String] {
        CSVSorter.sort(column: 0, ascending: ascending, rowCount: values.count) { values[$0] }.map { values[Int($0)] }
    }

    @Test func numericAwareOrder() {
        #expect(order(["10", "9", "a2", "a10"]) == ["9", "10", "a2", "a10"])
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(order(["b", "A", "\u{00E1}c", "a"]).prefix(3).map { $0.lowercased() }.first == "a")
    }

    @Test func stableTiesByOrdinal() {
        let values = ["x", "x", "x", "a"]
        #expect(CSVSorter.sort(column: 0, ascending: true, rowCount: 4) { values[$0] } == [3, 0, 1, 2])
        // Ties keep file order in descending too.
        #expect(CSVSorter.sort(column: 0, ascending: false, rowCount: 4) { values[$0] } == [0, 1, 2, 3])
    }

    @Test func descendingReverses() {
        #expect(order(["10", "9", "2", "30"], ascending: false) == ["30", "10", "9", "2"])
    }

    @Test func emptyColumnValuesAndEmptyTable() {
        #expect(CSVSorter.sort(column: 0, ascending: true, rowCount: 0) { _ in "" }.isEmpty)
    }
}

@MainActor
@Suite struct CSVSortModelTests {
    private let base = "k,v\n5,e\n2,b\n9,i\n1,a\n"

    @Test func raggedRowsSortAsEmpty() async {
        let (m, _) = await model("a,b\n3,x\n1\n2,z\n")
        await sorted(m, column: 1)
        // Row "1" has no second field: empty sorts first.
        #expect(m.sort?.permutation == [2, 1, 3])
    }

    @Test func sortsByColumnAndLeavesFileRowNumbers() async {
        let (m, _) = await model(base)
        await sorted(m, column: 0)
        #expect(m.sort?.permutation == [4, 2, 1, 3])
        #expect(m.displayRow(at: 0) == 4)
        #expect(m.displayPosition(ofFileRow: 4) == 0)
        #expect(m.displayPosition(ofFileRow: 3) == 3)
        #expect(m.displayPosition(ofFileRow: 0) == nil)
        #expect(m.sortComparators == [CSVColumnComparator(column: 0, order: .forward)])
    }

    @Test func publishesOnce() async {
        let (m, _) = await model(base)
        let before = m.revision
        await sorted(m, column: 0)
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(m.revision == before + 1)
    }

    @Test func clearReturnsToFileOrder() async {
        let (m, _) = await model(base)
        await sorted(m, column: 0, ascending: false)
        #expect(m.sort?.permutation == [3, 1, 2, 4])
        m.clearSort()
        #expect(m.sort == nil && m.sortComparators.isEmpty)
        #expect(m.displayRow(at: 0) == 1 && m.displayRow(at: 3) == 4)
        #expect(m.displayPosition(ofFileRow: 2) == 1)
    }

    @Test func neverWritesTheBuffer() async {
        let (m, d) = await model(base)
        let v = d.buffer.version
        await sorted(m, column: 1)
        m.clearSort()
        #expect(d.buffer.version == v)
    }

    @Test func retainsOnlyThePermutation() async {
        var csv = "k\n"
        for i in 0..<5_000 { csv += "value number \(i)\n" }
        let (m, _) = await model(csv)
        let before = m.retainedByteEstimate
        await sorted(m, column: 0)
        // The sort holds [UInt32] for the permutation (4 bytes a row) and nothing of the column's text.
        #expect(m.retainedByteEstimate - before <= 5_000 * 4 + 4096)
        #expect(m.sort?.permutation.count == 5_000)
    }

    @Test func editedRowStaysAndAddedRowsGoLast() async throws {
        let (m, d) = await model(base)
        await sorted(m, column: 0)   // display: rows 4,2,1,3
        // Edit row 2's key ("2" -> "99"): it stays second.
        let t = text(d)
        let at = t.utf8.distance(from: t.startIndex, to: t.range(of: "2,b")!.lowerBound)
        try d.buffer.applyExternalEdits([CodeTextEdit(range: at..<(at + 1), text: "99")])
        m.sync()
        #expect(m.sort?.permutation == [4, 2, 1, 3])
        #expect(m.sortIsStale)
        // An agent adds a row in the middle: it goes to the end, later rows shift.
        let t2 = text(d)
        let at2 = t2.utf8.distance(from: t2.startIndex, to: t2.range(of: "9,i")!.lowerBound)
        try d.buffer.applyExternalEdits([CodeTextEdit(range: at2..<at2, text: "7,g\n")])
        m.sync()
        #expect(m.sort?.permutation == [5, 2, 1, 4, 3])
        #expect(Set(m.sort!.permutation) == Set(1...5))
    }

    @Test func removedRowsDropOut() async throws {
        let (m, d) = await model(base)
        await sorted(m, column: 0)   // 4,2,1,3
        let t = text(d)
        let lo = t.utf8.distance(from: t.startIndex, to: t.range(of: "2,b\n")!.lowerBound)
        try d.buffer.applyExternalEdits([CodeTextEdit(range: lo..<(lo + 4), text: "")])
        m.sync()
        await m.buildFinished()
        #expect(m.rowCount == 3)
        let p = m.sort!.permutation
        #expect(p.count == 3 && Set(p) == Set(1...3))
        // Every id still reads its own row's values.
        let values = p.map { m.cells(forDataRow: Int($0) - 1).values[0] }
        #expect(Set(values) == ["5", "9", "1"])
    }

    @Test func rewriteThatDeletesEverythingEmptiesTheOrder() async throws {
        let (m, d) = await model(base)
        await sorted(m, column: 0)
        let n = d.buffer.snapshot().utf8Count
        try d.buffer.applyExternalEdits([CodeTextEdit(range: 0..<n, text: "")])
        m.sync()
        await m.buildFinished()
        #expect(m.rowCount == 0)
        #expect(m.sort?.permutation.isEmpty ?? true)
        #expect(m.displayPosition(ofFileRow: 2) == nil)
    }

    @Test func headerToggleClearsTheSort() async {
        let (m, _) = await model(base)
        await sorted(m, column: 0)
        m.hasHeader = false
        #expect(m.sort == nil)
    }

    @Test func spliceKeepsAPermutation() {
        var s = CSVSortOrder(column: 0, ascending: true, permutation: [3, 1, 2], firstOrdinal: 1, sortedAtVersion: 0)
        s.apply(first: 2, removed: 1, inserted: 3)   // row 2 became rows 2,3,4; old row 3 is now row 5
        #expect(Set(s.permutation) == Set(1...5))
        #expect(s.permutation.prefix(3) == [5, 1, 2])
        s.apply(first: 1, removed: 4, inserted: 1)
        #expect(Set(s.permutation) == Set(1...2))
    }
}
