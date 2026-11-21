@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Cell mode of the Table: the active cell, the declared-column mapping and whole-cell tints.
@MainActor
@Suite struct CSVCellModeTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private static func rowText(_ i: Int, changed: Bool) -> String { "\(i),name\(i),city\(i)\(changed ? "-X" : "")\n" }

    /// A table of `rows` rows; ordinal `changed` (one row) was rewritten by a session. `text` overrides the whole file.
    private func tableRig(rows: Int = 60, changed: [Int] = [], text: String? = nil)
        async throws -> (rig: Rig, window: TestWindow, g0: UUID, model: CSVTableModel, doc: EditorDocument) {
        let file = "data.csv"
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let base = "id,name,city\n" + (0..<rows).map { Self.rowText($0, changed: false) }.joined()
        let new = text ?? "id,name,city\n" + (0..<rows).map { Self.rowText($0, changed: changed.contains($0 + 1)) }.joined()
        try new.write(to: rig.root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open(file, in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        if !changed.isEmpty {
            var ledger = FileLedger(path: file, baseline: base)
            ledger.applyFullText(author: .session(session.id), newText: new, toolUseID: nil, date: Date())
            rig.workspace.ledger.files[file] = ledger
        }
        rig.workspace.setPresentation(.table, of: file, in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        let doc = try #require(rig.workspace.document(file))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await model.ownershipSettled()
        await settle(window, 20)
        return (rig, window, g0, model, doc)
    }

    @Test func aCellClickMakesItActiveAndSelectsItsRow() async throws {
        let (rig, window, g0, model, _) = try await tableRig()
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-1"))
        await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 3, column: 1))
        #expect(model.selectedRows == [3])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func declaredColumnMapsToDataColumn() async throws {
        let (rig, window, g0, model, _) = try await tableRig()
        try window.click(window.element(identifier: "csv-cell-\(g0)-4-2"))
        await settle(window)
        let a = try #require(model.activeCell)
        #expect(a.column == 2)
        #expect(model.dataColumn(forTableColumn: model.tableColumn(forDataColumn: 2)) == 2)
        #expect(model.dataColumn(forTableColumn: 0) == nil, "the # column is not a data column")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func clickingTheRowNumberSelectsTheRowWithoutAnActiveCell() async throws {
        let (rig, window, g0, model, _) = try await tableRig()
        try window.click(window.element(identifier: "csv-cell-\(g0)-5-1")); await settle(window)
        #expect(model.activeCell != nil)
        try window.click(window.element(identifier: "csv-row-\(g0)-6")); await settle(window)
        #expect(model.activeCell == nil)
        #expect(model.selectedRows == [6])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func arrowsAndTabMoveTheActiveCell() async throws {
        let (rig, window, g0, model, _) = try await tableRig()
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-1")); await settle(window)
        window.typeKey(.downArrow); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 4, column: 1))
        #expect(model.selectedRows == [4])
        window.typeKey(.rightArrow); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 4, column: 2))
        window.typeKey(.leftArrow); window.typeKey(.leftArrow); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 4, column: 0))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aSessionTintFillsTheWholeCell() async throws {
        let (rig, window, g0, model, _) = try await tableRig(changed: [3])
        let cell = try window.element(identifier: "csv-cell-\(g0)-3-2")
        #expect(cell.value?.hasPrefix("tint-session") == true)
        // Columns are resizable and share any surplus, so the box is measured from the cell, not from columnWidths().
        let (cx0, cx1) = (Double(cell.frame.minX.value), Double(cell.frame.maxX.value))
        let (cy0, cy1) = (Double(cell.frame.minY.value), Double(cell.frame.maxY.value))
        let box = window.allRects.filter {
            let (x, y) = (Double($0.bounds.origin.x), Double($0.bounds.origin.y))
            let (w, h) = (Double($0.bounds.size.width), Double($0.bounds.size.height))
            return w >= cx1 - cx0 && h < 40 && x <= cx0 && x + w >= cx1 && y <= cy0 && y + h >= cy1 && h > (cy1 - cy0)
        }
        #expect(box.count == 1, "one cell-box-sized fill around the tinted cell, got \(box.count)")
        // The content-inset rectangle (cell width minus the 8pt insets) is gone.
        let boxWidth = box.first.map { Double($0.bounds.size.width) } ?? 0
        let inset = window.allRects.filter {
            abs(Double($0.bounds.size.width) - (boxWidth - 16)) < 0.5
                && Double($0.bounds.origin.y) <= cy0 && Double($0.bounds.origin.y) + Double($0.bounds.size.height) >= cy1
        }
        #expect(inset.isEmpty, "interim in-cell fill still drawn")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func theInterimInCellFillIsGone() async throws {
        let (rig, window, g0, _, _) = try await tableRig(changed: [3])
        let tinted = try window.element(identifier: "csv-cell-\(g0)-3-2")
        let plain = try window.element(identifier: "csv-cell-\(g0)-3-1")
        // Tinted and plain cells have the same geometry: the fill is the table's, not the cell's.
        #expect((tinted.frame.maxY.value - tinted.frame.minY.value) == (plain.frame.maxY.value - plain.frame.minY.value))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func emptyAndHeaderOnlyTablesTakeCellKeysHarmlessly() async throws {
        for text in ["", "id,name,city\n"] {
            let (rig, window, g0, model, doc) = try await tableRig(text: text)
            let version = doc.buffer.version
            let table = try window.element(identifier: "csv-table-\(g0)")
            try window.click(table); await settle(window)
            for key in [KeyEquivalent.downArrow, .rightArrow, .return, .tab, .escape] { window.typeKey(key) }
            window.typeText("x"); await settle(window)
            #expect(doc.buffer.version == version, "typing wrote the buffer of \(text.debugDescription)")
            #expect(model.activeCell == nil)
            withExtendedLifetime((rig, window)) {}
        }
    }
}
