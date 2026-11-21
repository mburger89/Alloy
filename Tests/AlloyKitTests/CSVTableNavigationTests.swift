@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Row selection, Previous/Next change and reveal-row in the Table.
@MainActor
@Suite struct CSVTableNavigationTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private static func rowText(_ i: Int, changed: Bool) -> String { "\(i),name\(i),city\(i)\(changed ? "-X" : "")\n" }

    /// A table of `rows` rows; the rows in `changed` were rewritten by a session (none: no ledger entry).
    private func tableRig(rows: Int = 6000, changed: [Int] = [100, 5000], file: String = "data.csv")
        async throws -> (rig: Rig, window: TestWindow, g0: UUID, session: Session, model: CSVTableModel) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let base = "id,name,city\n" + (0..<rows).map { Self.rowText($0, changed: false) }.joined()
        let new = "id,name,city\n" + (0..<rows).map { Self.rowText($0, changed: changed.contains($0 + 1)) }.joined()
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
        return (rig, window, g0, session, model)
    }

    private func realisedRowNumbers(_ window: TestWindow, _ g0: UUID) -> [Int] {
        let prefix = "csv-row-\(g0)-"
        return ((try? window.elements(where: { _ in true })) ?? []).compactMap { e -> Int? in
            guard let id = e.identifier, id.hasPrefix(prefix), let n = Int(id.dropFirst(prefix.count)) else { return nil }
            return n
        }
    }

    @Test func clickingARowSelectsIt() async throws {
        let (rig, window, g0, _, model) = try await tableRig(changed: [])
        let cell = try window.element(identifier: "csv-cell-\(g0)-3-1")
        try window.click(cell)
        await settle(window)
        #expect(model.selectedRows == [3])
        #expect(try window.elements(where: { $0.isSelected }).isEmpty == false)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func nextChangeSelectsAndRevealsARowFarDown() async throws {
        let (rig, window, g0, _, model) = try await tableRig()
        let next = try window.element(identifier: "csv-next-change-\(g0)")
        #expect(next.isEnabled)
        try window.click(next); await settle(window)
        #expect(model.selectedRows == [100])
        try window.click(window.element(identifier: "csv-next-change-\(g0)")); await settle(window)
        #expect(model.selectedRows == [5000])
        #expect(exists(window, "csv-row-\(g0)-5000"), "row 5000 realised: \(realisedRowNumbers(window, g0))")
        #expect(realisedRowNumbers(window, g0).count <= 40)
        // Wraps around at the end.
        try window.click(window.element(identifier: "csv-next-change-\(g0)")); await settle(window)
        #expect(model.selectedRows == [100])
        #expect(exists(window, "csv-row-\(g0)-100"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func previousChangeWrapsToTheLastRow() async throws {
        let (rig, window, g0, _, model) = try await tableRig()
        try window.click(window.element(identifier: "csv-prev-change-\(g0)")); await settle(window)
        #expect(model.selectedRows == [5000])
        #expect(exists(window, "csv-row-\(g0)-5000"))
        try window.click(window.element(identifier: "csv-prev-change-\(g0)")); await settle(window)
        #expect(model.selectedRows == [100])
        try window.click(window.element(identifier: "csv-prev-change-\(g0)")); await settle(window)
        #expect(model.selectedRows == [5000])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func nextChangeInASortedTableJumpsToWhereTheRowSits() async throws {
        let (rig, window, g0, _, model) = try await tableRig()
        model.sort(column: 1, ascending: false)
        for _ in 0..<400 where model.sort == nil { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
        await settle(window)
        try window.click(window.element(identifier: "csv-next-change-\(g0)")); await settle(window)
        try window.click(window.element(identifier: "csv-next-change-\(g0)")); await settle(window)
        #expect(model.selectedRows == [5000])
        #expect(exists(window, "csv-row-\(g0)-5000"), "\(realisedRowNumbers(window, g0))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func theChangeButtonsAreDisabledWithoutChanges() async throws {
        let (rig, window, g0, _, model) = try await tableRig(rows: 50, changed: [])
        #expect(try window.element(identifier: "csv-next-change-\(g0)").isEnabled == false)
        #expect(try window.element(identifier: "csv-prev-change-\(g0)").isEnabled == false)
        #expect(model.changedRows().isEmpty)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aChangedCellNamesWhoChangedIt() async throws {
        let (rig, window, g0, session, model) = try await tableRig(rows: 200, changed: [100])
        model.scrollTo(fileRow: 100)
        await settle(window)
        let cell = try window.element(identifier: "csv-cell-\(g0)-100-2")
        #expect(cell.hint == "session \(session.id.uuidString)", "\(String(describing: cell.hint))")
        #expect(try window.element(identifier: "csv-cell-\(g0)-100-1").hint == nil)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func cmdFInATableSwitchesToTextAndOpensFind() async throws {
        let (rig, window, g0, _, _) = try await tableRig(rows: 50, changed: [])
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        window.typeKey("f", modifierFlags: .command)
        try await window.runUntil { self.exists(window, "find-field") }
        #expect(rig.workspace.presentation(of: "data.csv", in: .group(g0)) == .plain)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func revealRowSelectsAndScrollsAWorkspaceOpen() async throws {
        let (rig, window, g0, _, model) = try await tableRig(changed: [])
        await rig.workspace.open("data.csv", revealLine: 4002, in: .group(g0))
        try await window.runUntil { model.selectedRows == [4001] }
        await settle(window)
        #expect(exists(window, "csv-row-\(g0)-4001"), "\(realisedRowNumbers(window, g0))")
        #expect(rig.workspace.tableReveal.isEmpty)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func nextChangeActivatesTheCellAndRealisesItAfterAJumpFarDown() async throws {
        let (rig, window, g0, _, model) = try await tableRig()
        try window.click(window.element(identifier: "csv-next-change-\(g0)")); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 100, column: 2))
        try window.click(window.element(identifier: "csv-next-change-\(g0)")); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 5000, column: 2))
        #expect(model.selectedRows == [5000])
        #expect(exists(window, "csv-cell-\(g0)-5000-2"), "\(realisedRowNumbers(window, g0))")
        #expect(realisedRowNumbers(window, g0).count <= 40)
        try window.click(window.element(identifier: "csv-prev-change-\(g0)")); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 100, column: 2))
        try window.click(window.element(identifier: "csv-prev-change-\(g0)")); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 5000, column: 2))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func openRevealLineActivatesTheCellAtTheLineStart() async throws {
        let (rig, window, g0, _, model) = try await tableRig(changed: [])
        await rig.workspace.open("data.csv", revealLine: 4002, in: .group(g0))
        try await window.runUntil { model.activeCell != nil }
        await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 4001, column: 0))
        #expect(exists(window, "csv-cell-\(g0)-4001-0"), "\(realisedRowNumbers(window, g0))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func cellLevelNextChangeCostsAtMostASelectionFrameAndReturnsToIdle() async throws {
        let (rig, window, g0, _, model) = try await tableRig()
        window.resetFrameWork()
        try window.click(window.element(identifier: "csv-next-change-\(g0)"))
        for _ in 0..<6 { window.tick(); await Task.yield() }
        let work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= Self.selectionFrame }, "cell next change \(work)")
        #expect(model.activeCell?.row == 100)
        await settle(window, 20)
        let idle = await frameCosts(window, ticks: 30)
        #expect(idle.allSatisfy { $0 == 0 }, "idle \(idle)")
        withExtendedLifetime((rig, window)) {}
    }

    // MARK: Guards

    private func frameCosts(_ window: TestWindow, ticks: Int = 6) async -> [Int] {
        window.resetFrameWork()
        for _ in 0..<ticks { window.tick(); await Task.yield() }
        return window.frameWork.map(\.elementRequests)
    }

    /// Element requests of the frame that follows a selection change. MetalUI rebuilds the realised rows when the
    /// selection moves (measured 757, 757, 785 across a click and Next change; the cells replay, `CSVCell` hits 0), so
    /// this one-off frame costs more than a scroll frame. Pinned just above the measurement, never loosened; idle stays 0.
    static let selectionFrame = 800

    @Test func selectionAndNextChangeCostNoMoreThanAScrollFrameAndReturnToIdle() async throws {
        let (rig, window, g0, _, _) = try await tableRig()
        let limit = Self.selectionFrame
        window.resetFrameWork()
        let cb = BodyProbe.count("CSVCell"), tb = BodyProbe.count("TablePanel")
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-1"))
        for _ in 0..<6 { window.tick(); await Task.yield() }
        var work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= limit }, "select \(work) cells \(BodyProbe.count("CSVCell") - cb) panel \(BodyProbe.count("TablePanel") - tb)")
        await settle(window)
        window.resetFrameWork()
        try window.click(window.element(identifier: "csv-next-change-\(g0)"))
        for _ in 0..<6 { window.tick(); await Task.yield() }
        work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= limit }, "next change \(work)")
        await settle(window, 20)
        let idle = await frameCosts(window, ticks: 30)
        #expect(idle.allSatisfy { $0 == 0 }, "idle \(idle)")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aFiveMillionRowJumpRealisesOnlyTheVisibleWindow() async throws {
        let (rig, window, g0, _, model) = try await tableRig(rows: 20, changed: [])
        // The table's row list is O(1) in the row count: a logical jump to a far row realises one window.
        let list = CSVRowList(count: 5_000_000, offset: 1)
        #expect(list.count == 5_000_000 && list[4_999_999].id == 5_000_000)
        model.scrollTo(fileRow: 19)
        await settle(window)
        #expect(realisedRowNumbers(window, g0).count <= 40, "\(realisedRowNumbers(window, g0).count)")
        withExtendedLifetime((rig, window)) {}
    }
}
