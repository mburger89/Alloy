@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Row-level Keep and Revert from the Table's header and context menu.
@MainActor
@Suite struct CSVTableActionsTests {
    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n4,di,kiel\n"
    private static let agent = "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n4,di,KIEL\n"

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func table(readOnly: Bool = false, author: Author? = nil, agent: String = CSVTableActionsTests.agent)
        async throws -> (rig: Rig, window: TestWindow, g0: UUID, session: Session, model: CSVTableModel, doc: EditorDocument) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        try agent.write(to: rig.root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("data.csv", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        var ledger = FileLedger(path: "data.csv", baseline: Self.base)
        ledger.applyFullText(author: author ?? .session(session.id), newText: agent, toolUseID: nil, date: Date())
        rig.workspace.ledger.files["data.csv"] = ledger
        let doc = try #require(rig.workspace.document("data.csv"))
        if readOnly { doc.state = .readOnly(reason: "test") }
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await model.ownershipSettled()
        await settle(window, 20)
        return (rig, window, g0, session, model, doc)
    }

    private func tinted(_ window: TestWindow, _ g0: UUID, _ row: Int, _ col: Int) -> Bool {
        (try? window.element(identifier: "csv-cell-\(g0)-\(row)-\(col)").value)?.hasPrefix("tint-") == true
    }

    @Test func keepAndRevertAppearOnlyForAChangedSelection() async throws {
        let (rig, window, g0, _, _, _) = try await table()
        #expect(!exists(window, "csv-keep-\(g0)"))
        try window.click(window.element(identifier: "csv-cell-\(g0)-1-1")); await settle(window)
        #expect(!exists(window, "csv-keep-\(g0)"))
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        #expect(exists(window, "csv-keep-\(g0)") && exists(window, "csv-revert-\(g0)"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func keepClearsThatRowsTintOnly() async throws {
        let (rig, window, g0, _, _, _) = try await table()
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        try window.click(window.element(identifier: "csv-keep-\(g0)")); await settle(window, 20)
        #expect(!tinted(window, g0, 2, 1))
        #expect(tinted(window, g0, 4, 2))
        #expect(!exists(window, "csv-keep-\(g0)"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func revertRestoresTheCellMarksDirtyAndUndoReturns() async throws {
        let (rig, window, g0, _, _, doc) = try await table()
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        try window.click(window.element(identifier: "csv-revert-\(g0)")); await settle(window, 20)
        #expect(try window.element(identifier: "csv-cell-\(g0)-2-1").value == "bob" || (try window.element(identifier: "csv-cell-\(g0)-2-1").value)?.hasPrefix("tint-") == true)
        #expect(doc.isDirty)
        let now = String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.snapshot().utf8Count), as: UTF8.self)
        #expect(now.contains("2,bob,oslo"))
        doc.buffer.undo(); await settle(window, 20)
        let back = String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.snapshot().utf8Count), as: UTF8.self)
        #expect(back == Self.agent)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func readOnlyDocumentsHaveDisabledButtons() async throws {
        let (rig, window, g0, _, _, _) = try await table(readOnly: true)
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        if exists(window, "csv-keep-\(g0)") {
            #expect(try window.element(identifier: "csv-keep-\(g0)").isEnabled == false)
            #expect(try window.element(identifier: "csv-revert-\(g0)").isEnabled == false)
        }
        withExtendedLifetime((rig, window)) {}
    }

    @Test func afterKeepAndRevertTheTableReturnsToIdle() async throws {
        let (rig, window, g0, _, _, _) = try await table()
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        try window.click(window.element(identifier: "csv-keep-\(g0)")); await settle(window, 20)
        try window.click(window.element(identifier: "csv-cell-\(g0)-4-2")); await settle(window)
        try window.click(window.element(identifier: "csv-revert-\(g0)")); await settle(window, 30)
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    private static let multi = "id,name,city\n1,ann,rome\n2,bobby,OSLO\n3,cy,lima\n4,di,KIEL\n"

    private func text(_ doc: EditorDocument) -> String {
        String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.snapshot().utf8Count), as: UTF8.self)
    }

    @Test func keepOfTheActiveCellClearsOnlyThatCell() async throws {
        let (rig, window, g0, _, model, _) = try await table(agent: Self.multi)
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 2, column: 1))
        try window.click(window.element(identifier: "csv-keep-\(g0)")); await settle(window, 20)
        #expect(!tinted(window, g0, 2, 1))
        #expect(tinted(window, g0, 2, 2))
        #expect(tinted(window, g0, 4, 2))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func revertOfTheActiveCellChangesOnlyThatCell() async throws {
        let (rig, window, g0, _, _, doc) = try await table(agent: Self.multi)
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-2")); await settle(window)
        try window.click(window.element(identifier: "csv-revert-\(g0)")); await settle(window, 20)
        #expect(text(doc) == Self.multi.replacingOccurrences(of: "OSLO", with: "oslo"))
        #expect(doc.isDirty)
        doc.buffer.undo(); await settle(window, 20)
        #expect(text(doc) == Self.multi)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func afterACellKeepAndRevertTheTableReturnsToIdle() async throws {
        let (rig, window, g0, _, _, _) = try await table(agent: Self.multi)
        try window.click(window.element(identifier: "csv-cell-\(g0)-2-1")); await settle(window)
        try window.click(window.element(identifier: "csv-keep-\(g0)")); await settle(window, 20)
        try window.click(window.element(identifier: "csv-cell-\(g0)-4-2")); await settle(window)
        try window.click(window.element(identifier: "csv-revert-\(g0)")); await settle(window, 30)
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }
}
