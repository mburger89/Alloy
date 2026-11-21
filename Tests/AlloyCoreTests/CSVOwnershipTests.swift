@testable import AlloyCore
import Foundation
import MetalUICodeBuffer
import Testing

@MainActor
@Suite struct CSVOwnershipTests {
    private let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n"
    private let session = UUID()

    /// A model over `new`, with a ledger whose baseline is `base` and which records `new` by `author`.
    private func rig(base: String? = nil, new: String, author: Author? = nil, slot: Int = 3,
                     keep: Bool = false) async -> (CSVTableModel, EditorDocument, Box) {
        var ledger = FileLedger(path: "t.csv", baseline: base ?? self.base)
        let rec = ledger.applyFullText(author: author ?? .session(session), newText: new, toolUseID: nil, date: Date())
        if keep, let rec { ledger.keep(rec.id) }
        let box = Box(ledger)
        let doc = EditorDocument(path: "t.csv", buffer: CodeBuffer(utf8: Array(new.utf8)), language: "csv", state: .editable,
                                 diskStamp: FileStamp(modified: nil, size: new.utf8.count))
        let model = CSVTableModel(document: doc)
        let s = Session(id: session, name: "S", colorIndex: slot, projectRoot: URL(fileURLWithPath: "/tmp"))
        model.ledgerProvider = { (box.ledger, [s]) }
        await model.buildFinished()
        model.ledgerChanged()
        await model.ownershipSettled()
        return (model, doc, box)
    }

    final class Box { var ledger: FileLedger; init(_ l: FileLedger) { ledger = l } }

    @Test func agentChangedCellIsOwnedBySessionAndOthersAreNot() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n")
        #expect(m.tint(forFileRow: 2, column: 1) == .session(3))
        #expect(m.tint(forFileRow: 2, column: 0) == nil)
        #expect(m.tint(forFileRow: 2, column: 2) == nil)
        #expect(m.tint(forFileRow: 1, column: 1) == nil)
    }

    @Test func userEditIsNotTinted() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n", author: .user)
        #expect(m.tint(forFileRow: 2, column: 1) == nil)
    }

    @Test func outsideEditIsOutside() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n", author: .outside)
        #expect(m.tint(forFileRow: 2, column: 1) == .outside)
    }

    @Test func keptChangeClearsTint() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n", keep: true)
        #expect(m.tint(forFileRow: 2, column: 1) == nil)
    }

    @Test func unsavedTypingBeforeTheAgentCellShiftsTheSpans() async {
        let (m, d, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n")
        _ = d.buffer.replace(0..<0, with: "zzzz,zzzz,zzzz\n")
        m.sync()
        await m.buildFinished()
        #expect(m.tint(forFileRow: 3, column: 1) == .session(3))
        #expect(m.tint(forFileRow: 3, column: 0) == nil)
        #expect(m.tint(forFileRow: 0, column: 0) == nil)
    }

    @Test func emptiedCellIsTintedViaDeletionPoint() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,,oslo\n3,cy,lima\n")
        #expect(m.tint(forFileRow: 2, column: 1) == .session(3))
        #expect(m.tint(forFileRow: 2, column: 2) == nil)
    }

    @Test func emptyFieldAtRowEndTouchingDeletionIsTinted() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bob,\n3,cy,lima\n")
        #expect(m.tint(forFileRow: 2, column: 2) == .session(3))
        #expect(m.tint(forFileRow: 2, column: 1) == nil)
    }

    @Test func deletedRowsProduceAMarkerWithRemovedText() async {
        let (m, _, _) = await rig(new: "id,name,city\n3,cy,lima\n")
        let marker = m.deletionMarker(beforeFileRow: 1)
        #expect(marker?.removedRows == ["1,ann,rome", "2,bob,oslo"])
        #expect(marker?.help == "1,ann,rome\n2,bob,oslo")
        #expect(m.endDeletionMarker == nil)
    }

    @Test func deletedAtEndMarkerHasNilRow() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n")
        #expect(m.endDeletionMarker?.removedRows == ["2,bob,oslo", "3,cy,lima"])
        #expect(m.endDeletionMarker?.beforeFileRow == nil)
        #expect(m.deletionMarker(beforeFileRow: 1) == nil)
    }

    @Test func markerHelpTruncatesAfterFiveRows() {
        let marker = CSVDeletionMarker(beforeFileRow: 1, removedRows: (1...8).map(String.init), edit: UUID())
        #expect(marker.help == "1\n2\n3\n4\n5\nand 3 more")
    }

    @Test func removedColumnMarksTheHeader() async {
        let (m, _, _) = await rig(new: "id,name\n1,ann\n2,bob\n3,cy\n")
        #expect(m.headerHasRemovedColumn)
        let (m2, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n")
        #expect(!m2.headerHasRemovedColumn)
    }

    @Test func lookupIsLogarithmic() {
        var spans: [CSVOwnershipSource.Span] = []
        let e = UUID()
        for i in 0..<200_000 { spans.append(.init(range: (i * 10)..<(i * 10 + 4), edit: e)) }
        let source = CSVOwnershipSource(spans: spans, authors: [e: .outside], order: [e: 1], byteCount: 2_000_000)
        let o = CSVOwnership(source: source, map: { o, _ in o }, byteCount: 2_000_000)
        let start = ContinuousClock.now
        var hits = 0
        for k in 0..<10_000 { if o.owner(of: (k * 190 + 1)..<(k * 190 + 3)) != nil { hits += 1 } }
        let elapsed = ContinuousClock.now - start
        #expect(hits > 0)
        #expect(elapsed < .milliseconds(100), "\(elapsed)")
    }

    @Test func indexedOncePerVersionPair() async {
        let (m, _, _) = await rig(new: "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n")
        let builds = m.ownershipBuilds
        for _ in 0..<5 { _ = m.tint(forFileRow: 2, column: 1); _ = m.cells(forDataRow: 1) }
        #expect(m.ownershipBuilds == builds)
    }
}
