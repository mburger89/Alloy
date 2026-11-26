@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The user's own unsaved edits tinted in the Table.
@MainActor
@Suite struct CSVOwnTintTests {
    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n"
    private static let bobby = "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n"

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 15) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @MainActor private struct Table {
        let rig: Rig
        let window: TestWindow
        let g0: UUID
        let model: CSVTableModel
        let doc: EditorDocument

        func value(_ row: Int, _ column: Int) throws -> String? {
            try window.element(identifier: "csv-cell-\(g0)-\(row)-\(column)").value
        }
    }

    private func table(enabled: Bool, agentEdit: Bool = false) async throws -> Table {
        let rig = Rig()
        let url = rig.root.appendingPathComponent("data.csv")
        try Self.base.write(to: url, atomically: true, encoding: .utf8)
        if enabled {
            var s = rig.workspace.settings
            s.ownEditTint = OwnEditTint(enabled: true)
            try rig.workspace.updateSettings(s, persist: false)
        }
        _ = await rig.workspace.newSession(name: "A")
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("data.csv", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        if agentEdit {
            let changed = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lime\n"
            try changed.write(to: url, atomically: true, encoding: .utf8)
            let hunk = PatchHunk(oldStart: 4, oldLines: 1, newStart: 4, newLines: 1, lines: ["-3,cy,lima", "+3,cy,lime"])
            await rig.transports[0].emit(.toolResult(ToolResultMessage(
                toolUseID: "t1", isError: false, text: "ok",
                result: .edit(filePath: url.path, originalFile: Self.base, hunks: [hunk]))))
            for _ in 0..<200_000 where rig.workspace.ledger.files["data.csv"] == nil { await Task.yield() }
        }
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await model.ownershipSettled()
        await settle(window)
        return Table(rig: rig, window: window, g0: g0, model: model, doc: doc)
    }

    /// Replaces "bob" with "bobby" in the buffer, as a cell edit commit does.
    private func typeBobby(_ t: Table) async {
        let text = t.doc.buffer.snapshot().text
        let at = text.utf8.distance(from: text.utf8.startIndex, to: text.range(of: "bob")!.upperBound.samePosition(in: text.utf8)!)
        t.doc.buffer.replace(at..<at, with: "by")
        await settle(t.window, 5)
        await t.model.ownTintSettled()
        await settle(t.window)
    }

    @Test func ownCellTintedOnlyWhenOn() async throws {
        let on = try await table(enabled: true)
        await typeBobby(on)
        #expect(try on.value(2, 1) == "tint-own")
        #expect(try on.value(2, 0) != "tint-own")
        #expect(try on.value(1, 1) == "ann")
        let off = try await table(enabled: false)
        await typeBobby(off)
        #expect(try off.value(2, 1) == "bobby")
        #expect(off.model.ownDiffs == 0, "no work with the setting off")
    }

    @Test func saveClearsOwnCellTint() async throws {
        let t = try await table(enabled: true)
        await typeBobby(t)
        #expect(try t.value(2, 1) == "tint-own")
        try await t.rig.workspace.save("data.csv")
        await settle(t.window, 30)
        await t.model.ownTintSettled()
        await settle(t.window)
        #expect(try t.value(2, 1) == "bobby")
    }

    @Test func undoBackToSavedClearsOwnCellTint() async throws {
        let t = try await table(enabled: true)
        await typeBobby(t)
        let text = t.doc.buffer.snapshot().text
        let at = text.utf8.distance(from: text.utf8.startIndex, to: text.range(of: "bobby")!.upperBound.samePosition(in: text.utf8)!)
        t.doc.buffer.replace((at - 2)..<at, with: "")
        #expect(t.doc.buffer.snapshot().text == Self.base)
        await settle(t.window, 5)
        await t.model.ownTintSettled()
        await settle(t.window)
        #expect(try t.value(2, 1) == "bob")
    }

    @Test func agentCellTintUnchanged() async throws {
        let t = try await table(enabled: true, agentEdit: true)
        let session = try #require(t.rig.workspace.sessions.first)
        #expect(try t.value(3, 2) == "tint-session\(session.colorIndex % 12)")
        await typeBobby(t)
        #expect(try t.value(2, 1) == "tint-own")
        #expect(try t.value(3, 2) == "tint-session\(session.colorIndex % 12)")
    }

    @Test func toggleOffClearsTableTint() async throws {
        let t = try await table(enabled: true)
        await typeBobby(t)
        #expect(try t.value(2, 1) == "tint-own")
        var s = t.rig.workspace.settings
        s.ownEditTint.enabled = false
        try t.rig.workspace.updateSettings(s, persist: false)
        await settle(t.window, 30)
        #expect(try t.value(2, 1) == "bobby")
        let diffs = t.model.ownDiffs
        await typeBobby(t)
        #expect(t.model.ownDiffs == diffs)
    }

    @Test func changedRowListExcludesOwnEdits() async throws {
        let t = try await table(enabled: true)
        await typeBobby(t)
        #expect(try t.value(2, 1) == "tint-own")
        #expect(t.model.changedRows().isEmpty)
        #expect(t.model.changedCells().isEmpty)
    }
}
