@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

private final class CSVTransports: @unchecked Sendable {
    private let lock = NSLock()
    var factory: TransportFactory {
        { [self] _ in lock.withLock { ScriptedTransport() } }
    }
}

/// Row-level Keep and Revert on byte ranges: targets from the model, actions on the workspace.
@MainActor
@Suite struct CSVRangeActionsTests {
    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n4,di,kiel\n5,ed,bern\n"
    private static let agent = "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n4,di,KIEL\n5,ed,bern\n"

    private struct Fixture {
        let ws: Workspace
        let doc: EditorDocument
        let model: CSVTableModel
        let root: URL
    }

    private func fixture(base: String = CSVRangeActionsTests.base, new: String = CSVRangeActionsTests.agent,
                         author: Author? = nil, readOnly: Bool = false) async throws -> Fixture {
        let root = TempFiles.url("alloy-csvr")
        let support = TempFiles.url("alloy-csvr")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try base.write(to: root.appendingPathComponent("d.csv"), atomically: true, encoding: .utf8)
        let transports = CSVTransports()
        let ws = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: transports.factory)
        let s = await ws.newSession(name: "A")
        await ws.open("d.csv", in: ws.defaultPane)
        try new.write(to: root.appendingPathComponent("d.csv"), atomically: true, encoding: .utf8)
        await ws.appendToLedger("d.csv", saved: nil, baseline: base, edits: [(author ?? .session(s.id), new)])
        let doc = try #require(ws.document("d.csv"))
        _ = doc.buffer.replace(0..<doc.buffer.snapshot().utf8Count, with: new, origin: .programmatic)
        doc.savedVersion = doc.buffer.version
        if readOnly { doc.state = .readOnly(reason: "test") }
        let model = CSVTableModel(document: doc)
        model.ledgerProvider = { [weak ws] in (ws?.ledger.files["d.csv"], ws?.sessions ?? []) }
        await model.buildFinished()
        model.ledgerChanged()
        await model.ownershipSettled()
        return Fixture(ws: ws, doc: doc, model: model, root: root)
    }

    private func text(_ f: Fixture) -> String { String(decoding: f.doc.buffer.snapshot().utf8(in: 0..<f.doc.buffer.snapshot().utf8Count), as: UTF8.self) }

    @Test func revertRowRestoresOldBytesInOneUndoStep() async throws {
        let f = try await fixture()
        let t = try #require(f.model.rowTarget(fileRow: 2))
        let before = text(f)
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == before.replacingOccurrences(of: "2,bobby,oslo", with: "2,bob,oslo"))
        f.doc.buffer.undo()
        #expect(text(f) == before)
    }

    @Test func revertDeletionMarkerReinsertsRemovedRows() async throws {
        let f = try await fixture(new: "id,name,city\n3,cy,lima\n4,di,kiel\n5,ed,bern\n")
        let t = try #require(f.model.markerTarget(beforeFileRow: 1))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == Self.base)
        let end = try await fixture(new: "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n")
        let te = try #require(end.model.markerTarget(beforeFileRow: nil))
        #expect(end.ws.revertRanges(path: "d.csv", targets: [te], in: end.ws.defaultPane))
        #expect(text(end) == Self.base)
    }

    @Test func revertingAnAddedRowRemovesIt() async throws {
        let f = try await fixture(new: Self.base + "6,fy,nice\n")
        let t = try #require(f.model.rowTarget(fileRow: 6))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == Self.base)
    }

    @Test func untouchedBytesStayIdenticalWithCRLFAndBOM() async throws {
        let bom = "\u{FEFF}"
        let base = (bom + Self.base).replacingOccurrences(of: "\n", with: "\r\n")
        let new = (bom + Self.agent).replacingOccurrences(of: "\n", with: "\r\n")
        let f = try await fixture(base: base, new: new)
        let t = try #require(f.model.rowTarget(fileRow: 2))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == new.replacingOccurrences(of: "2,bobby,oslo", with: "2,bob,oslo"))
    }

    @Test func revertPreservesQuotingStyle() async throws {
        let base = "id,name\n1,\"a, b\"\n2,x\n"
        let new = "id,name\n1,\"a, c\"\n2,x\n"
        let f = try await fixture(base: base, new: new)
        let t = try #require(f.model.rowTarget(fileRow: 1))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == base)
    }

    @Test func readOnlyAndFlaggedRowsRefuse() async throws {
        let ro = try await fixture(readOnly: true)
        #expect(ro.model.rowTarget(fileRow: 2) == nil)
        let flagged = try await fixture(base: "id,name\n1,\"a\n2,x\n", new: "id,name\n1,\"b\n2,x\n")
        let v = flagged.doc.buffer.version
        #expect(flagged.model.rowTarget(fileRow: 1) == nil)
        #expect(flagged.doc.buffer.version == v)
    }

    @Test func staleRevertIsRefusedWithNotice() async throws {
        let f = try await fixture()
        let t = try #require(f.model.rowTarget(fileRow: 2))
        _ = f.doc.buffer.replace(0..<0, with: "x", origin: .typing)
        let v = f.doc.buffer.version
        #expect(!f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(f.doc.buffer.version == v)
        #expect(f.ws.notices.last?.text == "This row changed while you were reverting it.")
    }

    @Test func keepRowClearsOnlyThatRowsTint() async throws {
        let f = try await fixture()
        let t = try #require(f.model.rowTarget(fileRow: 2))
        let v = f.doc.buffer.version
        #expect(f.ws.keepRanges(path: "d.csv", targets: [t]))
        f.model.ledgerChanged(); await f.model.ownershipSettled()
        #expect(f.model.tint(forFileRow: 2, column: 1) == nil)
        #expect(f.model.tint(forFileRow: 4, column: 2) != nil)
        #expect(f.model.changedRows() == [4])
        #expect(f.doc.buffer.version == v)
        // Undo of the buffer changes nothing about Keep, and the other row can still be reverted.
        let t4 = try #require(f.model.rowTarget(fileRow: 4))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t4], in: f.ws.defaultPane))
        #expect(text(f).contains("4,di,kiel"))
        #expect(text(f).contains("2,bobby,oslo"))
    }

    @Test func keepRowWithUnsavedTypingBeforeItMapsTheRange() async throws {
        let f = try await fixture()
        _ = f.doc.buffer.replace(0..<0, with: "zz,zz,zz\n", origin: .typing)
        f.model.sync(); await f.model.buildFinished()
        let t = try #require(f.model.rowTarget(fileRow: 3))
        #expect(f.ws.keepRanges(path: "d.csv", targets: [t]))
        f.model.ledgerChanged(); await f.model.ownershipSettled()
        #expect(f.model.tint(forFileRow: 3, column: 1) == nil)
        #expect(f.model.tint(forFileRow: 5, column: 2) != nil)
    }

    @Test func revertWhileSortedActsOnFileRows() async throws {
        let f = try await fixture()
        f.model.sort(column: 1, ascending: false)
        await f.model.buildFinished()
        let t = try #require(f.model.rowTarget(fileRow: 4))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f).contains("4,di,kiel"))
    }

    @Test func keepThenUndoBufferChangesNothing() async throws {
        let f = try await fixture()
        let t = try #require(f.model.rowTarget(fileRow: 2))
        let before = text(f)
        #expect(f.ws.keepRanges(path: "d.csv", targets: [t]))
        #expect(text(f) == before)
    }

    @Test func keepingADeletionMarkerClearsIt() async throws {
        let f = try await fixture(new: "id,name,city\n3,cy,lima\n4,di,kiel\n5,ed,bern\n")
        let t = try #require(f.model.markerTarget(beforeFileRow: 1))
        #expect(f.ws.keepRanges(path: "d.csv", targets: [t]))
        f.model.ledgerChanged(); await f.model.ownershipSettled()
        #expect(f.model.deletionMarker(beforeFileRow: 1) == nil)
    }

    // MARK: Cell-level Keep and Revert

    private static let multi = "id,name,city\n1,ann,rome\n2,bobby,OSLO\n3,cy,lima\n4,di,kiel\n5,ed,bern\n"

    @Test func keepOneCellLeavesTheRestOfTheSameAgentEditTinted() async throws {
        let f = try await fixture(new: Self.multi)
        let t = try #require(f.model.cellTarget(fileRow: 2, column: 1))
        let before = text(f)
        #expect(f.ws.keepRanges(path: "d.csv", targets: [t]))
        await f.model.ownershipSettled()
        f.model.ledgerChanged()
        await f.model.ownershipSettled()
        #expect(text(f) == before)
        #expect(f.model.tint(forFileRow: 2, column: 1) == nil)
        #expect(f.model.tint(forFileRow: 2, column: 2) != nil)
        #expect(f.model.changedCells().map { [$0.row, $0.column] } == [[2, 2]])
    }

    @Test func revertOneCellRestoresOnlyThatFieldAndIsOneUndoStep() async throws {
        let f = try await fixture(new: Self.multi)
        let t = try #require(f.model.cellTarget(fileRow: 2, column: 2))
        let before = text(f)
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == before.replacingOccurrences(of: "2,bobby,OSLO", with: "2,bobby,oslo"))
        f.doc.buffer.undo()
        #expect(text(f) == before)
    }

    @Test func revertOneCellKeepsQuotingOfItsOwnField() async throws {
        let base = "id,name\n1,\"a,b\"\n2,plain\n"
        let f = try await fixture(base: base, new: "id,name\n1,x\n2,\"p\"\"q\"\n")
        let t = try #require(f.model.cellTarget(fileRow: 1, column: 1))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == "id,name\n1,\"a,b\"\n2,\"p\"\"q\"\n")
    }

    @Test func revertOfAnEmptiedCellRestoresTheOldValue() async throws {
        let f = try await fixture(new: "id,name,city\n1,ann,rome\n2,,oslo\n3,cy,lima\n4,di,kiel\n5,ed,bern\n")
        let t = try #require(f.model.cellTarget(fileRow: 2, column: 1))
        #expect(f.ws.revertRanges(path: "d.csv", targets: [t], in: f.ws.defaultPane))
        #expect(text(f) == Self.base)
    }

    @Test func cellActionsRefuseOnReadOnlyAndFlagged() async throws {
        let ro = try await fixture(new: Self.multi, readOnly: true)
        #expect(ro.model.cellTarget(fileRow: 2, column: 1) == nil)
        let fl = try await fixture(base: "id,name\n1,a\n2,b\n", new: "id,name\n1,a\n2,\"b\n")
        #expect(fl.model.cellTarget(fileRow: 2, column: 1) == nil)
        let clean = try await fixture(new: Self.multi)
        #expect(clean.model.cellTarget(fileRow: 1, column: 1) == nil)
    }

    @Test func actionTargetsPreferTheActiveTintedCell() async throws {
        let f = try await fixture(new: Self.multi)
        f.model.setActiveCell(CSVTableModel.ActiveCell(row: 2, column: 2))
        #expect(f.model.actionTargets().count == 1)
        #expect(f.model.actionTargets().first?.current == f.model.cellTarget(fileRow: 2, column: 2)?.current)
        // An untinted active cell in a changed row falls back to the row.
        f.model.setActiveCell(CSVTableModel.ActiveCell(row: 2, column: 0))
        #expect(f.model.actionTargets() == f.model.targets(forSelection: [2]))
    }
}
