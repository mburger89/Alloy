@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

/// The changed-cell list behind cell-level Previous/Next change, and reveal-cell.
@MainActor
@Suite struct CSVCellRevealTests {
    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n4,di,kiel\n5,ed,bern\n"
    private static let changed = "id,name,city\n1,ann,rome\n2,bobby,OSLO\n3,cy,lima\n4,di,KIEL\n5,ed,bern\n"
    private let session = UUID()

    final class Box { var ledger: FileLedger; init(_ l: FileLedger) { ledger = l } }

    private func rig(base: String = CSVCellRevealTests.base, new: String, author: Author? = nil)
        async -> (CSVTableModel, EditorDocument) {
        var ledger = FileLedger(path: "t.csv", baseline: base)
        _ = ledger.applyFullText(author: author ?? .session(session), newText: new, toolUseID: nil, date: Date())
        let box = Box(ledger)
        let doc = EditorDocument(path: "t.csv", buffer: CodeBuffer(utf8: Array(new.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: new.utf8.count))
        let model = CSVTableModel(document: doc)
        let s = Session(id: session, name: "S", colorIndex: 2, projectRoot: URL(fileURLWithPath: "/tmp"))
        model.ledgerProvider = { (box.ledger, [s]) }
        await model.buildFinished()
        model.ledgerChanged()
        await model.ownershipSettled()
        return (model, doc)
    }

    private func cells(_ m: CSVTableModel) -> [[Int]] { m.changedCells().map { [$0.row, $0.column] } }

    @Test func changedCellsListsTintedCellsAndMarkersInFileOrder() async {
        let (m, _) = await rig(new: Self.changed)
        #expect(cells(m) == [[2, 1], [2, 2], [4, 2]])
        #expect(Set(m.changedCells().map(\.row)) == Set(m.changedRows()))
        // A marker is the first column of the row after the gap; the trailing one sits on the last row.
        let (m2, _) = await rig(new: "id,name,city\n3,cy,lima\n4,di,kiel\n5,ed,bern\n")
        #expect(cells(m2) == [[1, 0]])
        let (m3, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bob,oslo\n")
        #expect(cells(m3) == [[2, 0]])
    }

    @Test func noChangesGivesNoCells() async {
        let (m, _) = await rig(new: Self.base, author: .user)
        #expect(m.changedCells().isEmpty)
        #expect(m.stepChange(forward: true) == nil)
        #expect(m.activeCell == nil)
    }

    @Test func unsavedTypingBeforeTheChangeKeepsTheRightCell() async {
        let (m, d) = await rig(new: Self.changed)
        _ = d.buffer.replace(0..<0, with: "zz,zz,zz\nyy,yy,yy\n")
        m.sync()
        await m.buildFinished()
        m.ledgerChanged()
        await m.ownershipSettled()
        #expect(cells(m) == [[4, 1], [4, 2], [6, 2]])
    }

    @Test func stepChangeWalksCellsAndWraps() async {
        let (m, _) = await rig(new: Self.changed)
        var seen: [CSVTableModel.ActiveCell] = []
        m.scroller = { seen.append($0) }
        for _ in 0..<4 { m.stepChange(forward: true); if let a = m.activeCell { #expect(m.selectedRows == [a.row]) } }
        #expect(seen.map { [$0.row, $0.column] } == [[2, 1], [2, 2], [4, 2], [2, 1]])
        #expect(m.activeCell == CSVTableModel.ActiveCell(row: 2, column: 1))
        m.stepChange(forward: false)
        #expect(m.activeCell == CSVTableModel.ActiveCell(row: 4, column: 2))
        m.stepChange(forward: false)
        #expect(m.activeCell == CSVTableModel.ActiveCell(row: 2, column: 2))
    }

    @Test func stepChangeWithOnlyARowSelectedStartsAfterIt() async {
        let (m, _) = await rig(new: Self.changed)
        m.setSelection([2])
        m.stepChange(forward: true)
        #expect(m.activeCell == CSVTableModel.ActiveCell(row: 4, column: 2))
        m.setSelection([4])
        m.stepChange(forward: false)
        #expect(m.activeCell == CSVTableModel.ActiveCell(row: 2, column: 2))
    }

    private func offset(of needle: String, in text: String) -> Int {
        text.range(of: needle).map { text.utf8.distance(from: text.utf8.startIndex, to: $0.lowerBound) } ?? 0
    }

    private func revealed(_ text: String, at needle: String, plus: Int = 0) async -> CSVTableModel.ActiveCell? {
        let doc = EditorDocument(path: "q.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: text.utf8.count))
        let m = CSVTableModel(document: doc)
        await m.buildFinished()
        m.reveal(byteOffset: offset(of: needle, in: text) + plus)
        return m.activeCell
    }

    @Test func revealMapsAnOffsetInsideAQuotedMultilineFieldToItsCell() async {
        let text = "id,note,tag\n1,\"first\nsecond line\",x\n2,y,z\n"
        #expect(await revealed(text, at: "second") == CSVTableModel.ActiveCell(row: 1, column: 1))
        #expect(await revealed(text, at: "2,y,z") == CSVTableModel.ActiveCell(row: 2, column: 0))
    }

    @Test func revealInsideADelimiterGoesToTheLeftField() async {
        let text = "id,note,tag\n1,abc,x\n"
        // The comma after "abc" belongs to the field on its left.
        #expect(await revealed(text, at: "abc", plus: 3) == CSVTableModel.ActiveCell(row: 1, column: 1))
        #expect(await revealed(text, at: ",x", plus: 0) == CSVTableModel.ActiveCell(row: 1, column: 1))
        #expect(await revealed(text, at: "x") == CSVTableModel.ActiveCell(row: 1, column: 2))
    }

    @Test func revealWhileBuildingWaitsForTheIndex() async {
        let text = Self.base
        let doc = EditorDocument(path: "q.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: text.utf8.count))
        let m = CSVTableModel(document: doc)
        var scrolled: [CSVTableModel.ActiveCell] = []
        m.scroller = { scrolled.append($0) }
        m.reveal(byteOffset: offset(of: "lima", in: text))
        m.reveal(byteOffset: offset(of: "kiel", in: text))
        #expect(m.activeCell == nil)
        await m.buildFinished()
        #expect(m.activeCell == CSVTableModel.ActiveCell(row: 4, column: 2))
        #expect(m.selectedRows == [4])
        #expect(scrolled == [CSVTableModel.ActiveCell(row: 4, column: 2)])
    }

    @Test func revealOnTheHeaderLandsOnTheFirstDataRow() async {
        let text = Self.base
        #expect(await revealed(text, at: "id,name", plus: 4) == CSVTableModel.ActiveCell(row: 1, column: 0))
    }
}
