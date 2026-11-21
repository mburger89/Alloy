@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Tints by author and deletion markers in the Table.
@MainActor
@Suite struct CSVTableTintTests {
    /// Element requests of one scrolling frame of a table with a third of its rows tinted and a deletion marker in view
    /// (measured on this branch: 282, was 276 before the header change buttons; pinned, never loosened; at most `steadyScroll` + 2). A `.help` on a marker
    /// costs about 640 more per frame (MetalUI gap), so the marker carries an accessibility hint instead.
    static let steadyTintedScroll = 282

    private static let base = "id,name,city\n1,ann,rome\n2,bob,oslo\n3,cy,lima\n"

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// Opens data.csv as a table after a session's Edit changed it (`hunk` turns `Self.base` into `new`).
    private func editedTable(new: String, hunk: PatchHunk, base: String = CSVTableTintTests.base,
                             presentation: Presentation = .table)
        async throws -> (rig: Rig, window: TestWindow, g0: UUID, session: Session, model: CSVTableModel) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("data.csv")
        try base.write(to: url, atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("data.csv", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        try new.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: base, hunks: [hunk]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["data.csv"] == nil { await Task.yield() }
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g0))
        if presentation != .table { rig.workspace.setPresentation(presentation, of: "data.csv", in: .group(g0)) }
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") || presentation != .table }
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await model.ownershipSettled()
        await settle(window)
        return (rig, window, g0, session, model)
    }

    private static let changeBob = PatchHunk(oldStart: 3, oldLines: 1, newStart: 3, newLines: 1,
                                             lines: ["-2,bob,oslo", "+2,bobby,oslo"])
    private static let bobby = "id,name,city\n1,ann,rome\n2,bobby,oslo\n3,cy,lima\n"

    @Test func theChangedRowCarriesTheSessionsColour() async throws {
        let (rig, window, g0, session, _) = try await editedTable(new: Self.bobby, hunk: Self.changeBob)
        let tinted = try window.element(identifier: "csv-cell-\(g0)-2-1")
        #expect(tinted.value == "tint-session\(session.colorIndex % 12)", "\(String(describing: tinted.value))")
        #expect(try window.element(identifier: "csv-cell-\(g0)-2-0").value != "tint-session\(session.colorIndex % 12)")
        #expect(try window.element(identifier: "csv-cell-\(g0)-1-1").value == "ann")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func plainPresentationOfTheTextViewDoesNotChangeTheTint() async throws {
        let (rig, window, g0, session, _) = try await editedTable(new: Self.bobby, hunk: Self.changeBob)
        rig.workspace.setPresentation(.plain, of: "data.csv", in: .group(g0))
        await settle(window)
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        await settle(window)
        #expect(try window.element(identifier: "csv-cell-\(g0)-2-1").value == "tint-session\(session.colorIndex % 12)")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func keepingTheChangeClearsTheTint() async throws {
        let (rig, window, g0, _, model) = try await editedTable(new: Self.bobby, hunk: Self.changeBob)
        let edit = try #require(rig.workspace.ledger.files["data.csv"]?.edits.last { $0.state == .live }?.id)
        rig.workspace.ledger.files["data.csv"]?.keep(edit)
        model.ledgerChanged()
        await model.ownershipSettled()
        await settle(window)
        #expect(try window.element(identifier: "csv-cell-\(g0)-2-1").value == "bobby")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func deletedRowsShowAMarkerWithTheRemovedText() async throws {
        let new = "id,name,city\n3,cy,lima\n"
        let hunk = PatchHunk(oldStart: 2, oldLines: 2, newStart: 2, newLines: 0, lines: ["-1,ann,rome", "-2,bob,oslo"])
        let (rig, window, g0, _, _) = try await editedTable(new: new, hunk: hunk)
        let marker = try window.element(identifier: "csv-row-\(g0)-1-marker")
        #expect(marker.hint == "1,ann,rome\n2,bob,oslo", "\(String(describing: marker.hint))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func rowsDeletedAtTheEndShowATrailingMarkerRow() async throws {
        let new = "id,name,city\n1,ann,rome\n"
        let hunk = PatchHunk(oldStart: 3, oldLines: 2, newStart: 3, newLines: 0, lines: ["-2,bob,oslo", "-3,cy,lima"])
        let (rig, window, g0, _, _) = try await editedTable(new: new, hunk: hunk)
        let marker = try window.element(identifier: "csv-row-\(g0)-2-marker")
        #expect(marker.hint == "2,bob,oslo\n3,cy,lima", "\(String(describing: marker.hint))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func idleTintedTableAsksNoFrames() async throws {
        let (rig, window, _, _, _) = try await editedTable(new: Self.bobby, hunk: Self.changeBob)
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func scrollingATintedTableHasASteadyCost() async throws {
        let rows = (0..<5000).map { "\($0),name\($0),city\($0),note \($0)\n" }
        let base = "id,name,city,note\n" + rows.joined()
        var changed = rows
        for i in stride(from: 10, to: 5000, by: 3) { changed[i] = "\(i),NAME\(i),city\(i),note \(i)\n" }
        changed.removeSubrange(40..<45)
        let new = "id,name,city,note\n" + changed.joined()
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("data.csv")
        try new.write(to: url, atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("data.csv", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        var ledger = FileLedger(path: "data.csv", baseline: base)
        ledger.applyFullText(author: .session(session.id), newText: new, toolUseID: nil, date: Date())
        rig.workspace.ledger.files["data.csv"] = ledger
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await model.ownershipSettled()
        await settle(window, 20)
        let table = try window.element(identifier: "csv-table-\(g0)")
        let centre = Point(x: Pixels((table.frame.minX.value + table.frame.maxX.value) / 2),
                           y: Pixels((table.frame.minY.value + table.frame.maxY.value) / 2))
        for _ in 0..<5 { window.scroll(at: centre, byDeltaX: 0, deltaY: -40); window.tick(); await Task.yield() }
        window.resetFrameWork()
        for _ in 0..<20 { window.scroll(at: centre, byDeltaX: 0, deltaY: -40); window.tick(); await Task.yield() }
        let work = window.frameWork.map(\.elementRequests)
        #expect(model.tint(forFileRow: 14, column: 1) != nil && model.deletionMarker(beforeFileRow: 41) != nil)
        #expect(work.allSatisfy { $0 <= Self.steadyTintedScroll + 2 }, "per-frame \(work)")
        withExtendedLifetime((rig, window)) {}
    }
}
