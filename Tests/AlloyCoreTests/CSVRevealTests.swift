@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

/// Row selection, the changed-row list behind Previous/Next change, and reveal-row.
@MainActor
@Suite struct CSVRevealTests {
    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n4,di,kiel\n5,ed,bern\n"
    private let session = UUID()

    final class Box { var ledger: FileLedger; init(_ l: FileLedger) { ledger = l } }

    /// A model over `new` whose ledger baseline is `base` and which a session wrote.
    private func rig(base: String = CSVRevealTests.base, new: String, author: Author? = nil)
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

    private static let changed = "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n4,di,KIEL\n5,ed,bern\n"

    @Test func changedRowsIncludeTintedAndMarkerRows() async {
        let (m, _) = await rig(new: Self.changed)
        #expect(m.changedRows() == [2, 4])
        // Deleting rows 1 and 2 leaves a marker on the row after the gap (row 1 now holds "3,cy,lima").
        let (m2, _) = await rig(new: "id,name,city\n3,cy,lima\n4,di,kiel\n5,ed,bern\n")
        #expect(m2.changedRows() == [1])
        // Rows removed at the end: the trailing marker maps to the last row.
        let (m3, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bob,oslo\n")
        #expect(m3.changedRows() == [2])
    }

    @Test func noChangesGivesEmptyList() async {
        let (m, _) = await rig(new: Self.base, author: .user)
        #expect(m.changedRows().isEmpty)
        #expect(m.stepChange(forward: true) == nil)
        #expect(m.stepChange(forward: false) == nil)
        #expect(m.selectedRows.isEmpty)
        let plain = CSVTableModel(document: EditorDocument(path: "p.csv", buffer: CodeBuffer(utf8: []), language: "csv",
                                                           state: .editable, diskStamp: FileStamp(modified: nil, size: 0)))
        await plain.buildFinished()
        #expect(plain.changedRows().isEmpty)
        #expect(plain.stepChange(forward: true) == nil)
    }

    @Test func unsavedTypingBeforeTheChangeKeepsTheRightRow() async {
        let (m, d) = await rig(new: Self.changed)
        _ = d.buffer.replace(0..<0, with: "zz,zz,zz\nyy,yy,yy\n")
        m.sync()
        await m.buildFinished()
        #expect(m.changedRows() == [4, 6])
        #expect(m.stepChange(forward: true) == 4)
        #expect(m.cells(forDataRow: 3).values[1] == "bobby")
    }

    @Test func changedRowsAreCachedPerVersionPair() async {
        let (m, d) = await rig(new: Self.changed)
        let before = m.ownershipBuilds
        _ = m.changedRows(); _ = m.changedRows(); _ = m.changedRows()
        #expect(m.ownershipBuilds == before)
        _ = d.buffer.replace(0..<0, with: "q,q,q\n")
        m.sync()
        await m.buildFinished()
        #expect(m.changedRows() == [3, 5])
    }

    @Test func nextAndPreviousWalkFileOrderAndWrap() async {
        let (m, _) = await rig(new: Self.changed)
        #expect(m.stepChange(forward: true) == 2)
        #expect(m.selectedRows == [2])
        #expect(m.stepChange(forward: true) == 4)
        #expect(m.stepChange(forward: true) == 2)   // wraps
        #expect(m.stepChange(forward: false) == 4)  // wraps backwards
        #expect(m.stepChange(forward: false) == 2)
        m.setSelection([])
        #expect(m.stepChange(forward: false) == 4)  // nothing selected: the last
    }

    @Test func nextAfterAMultiSelectionGoesPastIt() async {
        let (m, _) = await rig(new: Self.changed)
        m.setSelection([1, 2, 3])
        #expect(m.stepChange(forward: true) == 4)
        m.setSelection([3, 4, 5])
        #expect(m.stepChange(forward: false) == 2)
    }

    @Test func selectionSurvivesASortAndDropsWithItsRow() async {
        let (m, d) = await rig(new: Self.changed)
        m.setSelection([2, 4])
        m.sort(column: 1, ascending: false)
        for _ in 0..<200 where m.sort == nil { await Task.yield() }
        #expect(m.selectedRows == [2, 4])
        m.clearSort()
        // An agent rewrite that drops the last rows removes the selected row 4.
        _ = d.buffer.replace(0..<d.buffer.snapshot().utf8Count, with: "id,name,city\n1,ann,rome\n")
        m.sync()
        await m.buildFinished()
        #expect(m.selectedRows.isEmpty)
        #expect(!m.selectedRows.contains(4))
    }

    @Test func headerRowIsNotSelectable() async {
        let (m, _) = await rig(new: Self.changed)
        m.setSelection([0, 1])
        #expect(m.selectedRows == [1])
        m.hasHeader = false
        m.setSelection([0])
        #expect(m.selectedRows == [0])
        m.hasHeader = true
        #expect(m.selectedRows.isEmpty)
    }

    @Test func hoverNamesTheChangeAuthor() async {
        let (m, _) = await rig(new: Self.changed)
        #expect(m.changeDescription(forFileRow: 2, column: 1) == "session \(session.uuidString)")
        #expect(m.changeDescription(forFileRow: 2, column: 0) == nil)
        let (o, _) = await rig(new: Self.changed, author: .outside)
        #expect(o.changeDescription(forFileRow: 2, column: 1) == "an outside change")
    }

    // MARK: Reveal

    private func offset(of needle: String, in text: String) -> Int {
        Array(text.utf8).firstRange(of: Array(needle.utf8))!.lowerBound
    }

    @Test func revealMapsLineInsideAQuotedMultilineRowToItsRow() async {
        let text = "id,note\n1,\"a\nb\nc\"\n2,x\n3,y\n"
        let doc = EditorDocument(path: "q.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: text.utf8.count))
        let m = CSVTableModel(document: doc)
        await m.buildFinished()
        // Text line 4 ("c\"") sits inside file row 1.
        m.reveal(byteOffset: offset(of: "c\"", in: text))
        #expect(m.selectedRows == [1])
        m.reveal(byteOffset: offset(of: "3,y", in: text))
        #expect(m.selectedRows == [3])
        m.reveal(byteOffset: 0)   // the header line: the first data row
        #expect(m.selectedRows == [1])
    }

    @Test func revealWhileBuildingWaitsForTheIndex() async {
        let text = Self.base
        let doc = EditorDocument(path: "q.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: text.utf8.count))
        let m = CSVTableModel(document: doc)
        #expect(m.isBuilding)
        var scrolled: [Int] = []
        m.scroller = { scrolled.append($0.row) }
        m.reveal(byteOffset: offset(of: "4,di", in: text))
        #expect(m.selectedRows.isEmpty)
        await m.buildFinished()
        #expect(m.selectedRows == [4])
        #expect(scrolled == [4])
    }

    @Test func newestRevealWins() async {
        let text = Self.base
        let doc = EditorDocument(path: "q.csv", buffer: CodeBuffer(utf8: Array(text.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: text.utf8.count))
        let m = CSVTableModel(document: doc)
        var scrolled: [Int] = []
        m.scroller = { scrolled.append($0.row) }
        m.reveal(byteOffset: offset(of: "2,bob", in: text))
        m.reveal(byteOffset: offset(of: "5,ed", in: text))
        await m.buildFinished()
        #expect(m.selectedRows == [5])
        #expect(scrolled == [5])
    }

    @Test func aScrollAskedForBeforeThePanelExistsWaitsForIt() async {
        let (m, _) = await rig(new: Self.changed)
        #expect(m.stepChange(forward: true) == 2)
        #expect(m.hasPendingScroll)
        var scrolled: [Int] = []
        m.scroller = { scrolled.append($0.row) }
        m.flushPendingScroll()
        #expect(scrolled == [2] && !m.hasPendingScroll)
    }

    // MARK: Workspace.open(revealLine:)

    private func csvEnv(_ presentation: Presentation?) async -> (Env, PaneID) {
        let e = Env()
        e.ws.setMode(.code)
        e.write("d.csv", "id,note\n1,\"a\nb\"\n2,x\n3,y\n")
        let pane = PaneID.group(e.ws.codeLayout.focusedGroupID)
        await e.ws.open("d.csv", in: pane)
        if let presentation { e.ws.setPresentation(presentation, of: "d.csv", in: pane) }
        return (e, pane)
    }

    @Test func revealOnATablePaneStoresTheLineOffsetAndLeavesTheCaret() async {
        let (e, pane) = await csvEnv(.table); defer { e.cleanup() }
        let before = e.ws.selectionState(for: "d.csv", in: pane)!.primarySelection
        await e.ws.open("d.csv", revealLine: 4, in: pane)
        // Line 4 is "2,x", after the quoted two-line field: byte offset of its start.
        #expect(e.ws.tableReveal["d.csv"] == TableReveal(pane: pane, offset: 16))
        #expect(e.ws.selectionState(for: "d.csv", in: pane)!.primarySelection == before)
    }

    @Test func revealOnATextPresentationStillSelectsTheLine() async {
        let (e, pane) = await csvEnv(.plain); defer { e.cleanup() }
        await e.ws.open("d.csv", revealLine: 2, in: pane)
        #expect(e.ws.tableReveal.isEmpty)
        #expect(e.ws.selectionState(for: "d.csv", in: pane)!.primarySelection == CodeSelection(anchor: 8, head: 12))
    }

    @Test func revealRequestsReplaceEachOtherPerPath() async {
        let (e, pane) = await csvEnv(.table); defer { e.cleanup() }
        await e.ws.open("d.csv", revealLine: 2, in: pane)
        await e.ws.open("d.csv", revealLine: 6, in: pane)
        #expect(e.ws.tableReveal.count == 1)
        #expect(e.ws.tableReveal["d.csv"]?.offset == 20)
    }
}
