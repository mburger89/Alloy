@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Inline cell editing through `tableCellEditing`: the editor, its commits and the refusal notice.
@MainActor
@Suite struct CSVCellEditUITests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func tableRig(text: String, readOnlyBytes: Bool = false)
        async throws -> (rig: Rig, window: TestWindow, g0: UUID, model: CSVTableModel, doc: EditorDocument) {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("data.csv", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await settle(window, 20)
        return (rig, window, g0, model, doc)
    }

    private static let base = "id,name,city\n1,ann,paris\n2,bob,rome\n3,cy,oslo\n"

    private func bytes(_ doc: EditorDocument) -> String { String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.snapshot().utf8Count), as: UTF8.self) }

    private func begin(_ window: TestWindow, _ g0: UUID, row: Int, col: Int) async throws {
        try window.click(window.element(identifier: "csv-cell-\(g0)-\(row)-\(col)"))
        await settle(window)
        window.typeKey(.return)
        await settle(window)
    }

    @Test func returnBeginsAnEditAndReturnCommitsAndMovesDown() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        try await begin(window, g0, row: 1, col: 1)
        #expect(model.editingCell == CSVTableModel.ActiveCell(row: 1, column: 1))
        window.typeText("zed"); window.typeKey(.return); await settle(window)
        #expect(bytes(doc) == "id,name,city\n1,annzed,paris\n2,bob,rome\n3,cy,oslo\n")
        #expect(model.editingCell == nil)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 2, column: 1))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aPrintableKeyReplacesAndTabCommitsAndMovesRight() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        try window.click(window.element(identifier: "csv-cell-\(g0)-1-1")); await settle(window)
        window.typeText("q"); await settle(window)
        window.typeKey(.tab); await settle(window)
        #expect(bytes(doc) == "id,name,city\n1,q,paris\n2,bob,rome\n3,cy,oslo\n")
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 1, column: 2))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func escapeCancelsWithTheBufferUntouched() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        let version = doc.buffer.version
        try await begin(window, g0, row: 1, col: 1)
        window.typeText("zzz"); window.typeKey(.escape); await settle(window)
        #expect(doc.buffer.version == version)
        #expect(model.editingCell == nil)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aCommitIsOneProgrammaticStepAndUndoRestoresTheBytes() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        try await begin(window, g0, row: 2, col: 2)
        window.typeText("x"); window.typeKey(.return); await settle(window)
        #expect(bytes(doc).contains("2,bob,romex"))
        _ = doc.buffer.undo()
        await settle(window)
        #expect(bytes(doc) == Self.base)
        let values = model.cells(forDataRow: 1).values
        #expect(values[2] == "rome")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func clickingAnotherCellCommits() async throws {
        let (rig, window, g0, _, doc) = try await tableRig(text: Self.base)
        try await begin(window, g0, row: 1, col: 1)
        window.typeText("!")
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-2")); await settle(window)
        #expect(bytes(doc) == "id,name,city\n1,ann!,paris\n2,bob,rome\n3,cy,oslo\n")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aReadOnlyDocumentNeverStartsAnEdit() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        doc.state = .readOnly(reason: "test")
        doc.buffer.isReadOnly = true
        model.sync()
        let version = doc.buffer.version
        try window.click(window.element(identifier: "csv-cell-\(g0)-1-1")); await settle(window)
        window.typeText("x"); window.typeKey(.return); await settle(window)
        #expect(model.editingCell == nil)
        #expect(doc.buffer.version == version)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aFlaggedRowNeverStartsAnEdit() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: "id,name\n1,\"ann\n2,bob\n")
        let flagged = (0..<model.rowCount).first { model.cells(forDataRow: $0).flagged }
        let row = try #require(flagged)
        let version = doc.buffer.version
        try window.click(window.element(identifier: "csv-cell-\(g0)-\(model.fileRow(forDataRow: row))-1")); await settle(window)
        window.typeText("x"); await settle(window)
        #expect(model.editingCell == nil)
        #expect(doc.buffer.version == version)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func anAgentEditToTheSameCellRefusesWithTheNoticeAndKeepsTheClipboardValue() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        try await begin(window, g0, row: 1, col: 1)
        window.typeText("mine")
        let snap = doc.buffer.snapshot()
        let at = bytes(doc).range(of: "ann")!
        let lo = bytes(doc).utf8.distance(from: bytes(doc).utf8.startIndex, to: at.lowerBound.samePosition(in: bytes(doc).utf8)!)
        _ = snap
        doc.buffer.transaction { $0.replace(lo..<(lo + 3), with: "agent", origin: .external) }
        window.typeKey(.return); await settle(window)
        #expect(bytes(doc) == "id,name,city\n1,agent,paris\n2,bob,rome\n3,cy,oslo\n")
        #expect(rig.workspace.notices.last(where: { $0.path == "data.csv" })?.text == CSVCellEditOutcome.refusedChanged.notice)
        withExtendedLifetime((rig, window, model)) {}
    }

    @Test func anAgentEditToAnotherRowStillCommits() async throws {
        let (rig, window, g0, _, doc) = try await tableRig(text: Self.base)
        try await begin(window, g0, row: 1, col: 1)
        window.typeText("mine")
        let at = bytes(doc).utf8.distance(from: bytes(doc).utf8.startIndex, to: bytes(doc).range(of: "oslo")!.lowerBound.samePosition(in: bytes(doc).utf8)!)
        doc.buffer.transaction { $0.replace(at..<(at + 4), with: "OSLO", origin: .external) }
        window.typeKey(.return); await settle(window)
        #expect(bytes(doc) == "id,name,city\n1,annmine,paris\n2,bob,rome\n3,cy,OSLO\n")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aSortedTableCommitsToTheFileRow() async throws {
        let (rig, window, g0, model, doc) = try await tableRig(text: Self.base)
        model.sort(column: 1, ascending: false)
        await settle(window, 20)
        try await begin(window, g0, row: 3, col: 1)
        window.typeText("!"); window.typeKey(.return); await settle(window)
        #expect(bytes(doc) == "id,name,city\n1,ann,paris\n2,bob,rome\n3,cy!,oslo\n")
        withExtendedLifetime((rig, window)) {}
    }
}
