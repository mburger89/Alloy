@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The Table costs nothing when hidden or idle and a steady, measured amount while it scrolls.
@MainActor
@Suite struct CSVTableGuardTests {
    /// Element requests of one scrolling frame of a table (measured on this branch, the largest of 280, 263 and 252 once the Previous/Next change buttons joined the header (was 274, +6 for two buttons); pinned, never loosened).
    static let steadyScroll = 280

    private static func csvText(rows: Int) -> String {
        "id,name,city,note\n" + (0..<rows).map { "\($0),name\($0),city\($0),note \($0)\n" }.joined()
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    /// A rig with login.swift in `layout`'s groups and data.csv written beside it.
    private func rigWithCSV(_ layout: CodeModePerformanceTests.Layout, rows: Int = 3000) async throws
        -> (rig: Rig, window: TestWindow, id: String, perf: CodeModePerformanceTests) {
        let perf = CodeModePerformanceTests()
        let text = Self.csvText(rows: rows)
        let (rig, window, id) = try await perf.rigged(layout, install: { rig in
            try? text.write(to: rig.root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        })
        return (rig, window, id, perf)
    }

    @Test func aHiddenTableTabCostsTypingNothing() async throws {
        let (rig, window, id, perf) = try await rigWithCSV(.code1)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("data.csv", in: .group(g0))
        rig.workspace.activate("login.swift", in: .group(g0))
        try await window.runUntil { self.exists(window, id) }
        let before = BodyProbe.count("TablePanel")
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= CodeModePerformanceTests.steadyCode1 + 2 }, "per-frame \(t.perFrame)")
        #expect(t.requests <= CodeModePerformanceTests.steadyCode1 * 20 * 102 / 100, "requests \(t.requests)")
        #expect(BodyProbe.count("TablePanel") == before, "a hidden table ran")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func existingGuardsHoldWithATableOpenInAnotherGroup() async throws {
        let (rig, window, id, perf) = try await rigWithCSV(.code2)
        let ids = rig.workspace.codeLayout.tree.groupIDs
        let g0 = ids[0], g1 = ids[1]
        await rig.workspace.open("data.csv", in: .group(g1))
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g1))
        try await window.runUntil { self.exists(window, "csv-table-\(g1)") }
        await settle(window)
        rig.workspace.focusGroup(id: g0)
        await settle(window)
        let tableBefore = BodyProbe.count("TablePanel")
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched + ["TablePanel", "CSVCell"])
        #expect(t.documentGrew)
        // Group 0 types; group 1 shows the table, so only one code view moves: the code-2 guard holds (it counts two).
        #expect(t.perFrame.allSatisfy { $0 <= CodeModePerformanceTests.steadyCode2 + 2 }, "per-frame \(t.perFrame)")
        #expect(t.requests <= CodeModePerformanceTests.steadyCode2 * 20 * 102 / 100, "requests \(t.requests)")
        #expect(BodyProbe.count("TablePanel") == tableBefore, "typing re-ran the table")
        #expect(t.reruns["CSVCell"] == 0)
        withExtendedLifetime((rig, window, g0)) {}
    }

    private func tableRig() async throws -> (rig: Rig, window: TestWindow, g0: UUID) {
        let rig = Rig()
        try Self.csvText(rows: 5000).write(to: rig.root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
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
        return (rig, window, g0)
    }

    @Test func idleTableAsksNoFrames() async throws {
        let (rig, window, _) = try await tableRig()
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func scrollingATable20FramesHasASteadyCost() async throws {
        let (rig, window, g0) = try await tableRig()
        let table = try window.element(identifier: "csv-table-\(g0)")
        let centre = Point(x: Pixels((table.frame.minX.value + table.frame.maxX.value) / 2),
                           y: Pixels((table.frame.minY.value + table.frame.maxY.value) / 2))
        // Warm up so the realised window is in place.
        for _ in 0..<5 { window.scroll(at: centre, byDeltaX: 0, deltaY: -40); window.tick(); await Task.yield() }
        let headerBefore = BodyProbe.count("FilePanelHeader"), barBefore = BodyProbe.count("GroupBar")
        window.resetFrameWork()
        for _ in 0..<20 { window.scroll(at: centre, byDeltaX: 0, deltaY: -40); window.tick(); await Task.yield() }
        let work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= Self.steadyScroll + 2 }, "per-frame \(work)")
        #expect(BodyProbe.count("FilePanelHeader") == headerBefore && BodyProbe.count("GroupBar") == barBefore,
                "scrolling re-ran the bar")
        withExtendedLifetime((rig, window)) {}
    }

    /// A csv opens straight into the Table by default: the bar and header re-run at most once each beyond the open itself,
    /// and the switch back to Text (explicit .plain) costs no more than that either.
    @Test func defaultTableAddsNoFrameWork() async throws {
        let rig = Rig()
        try Self.csvText(rows: 100).write(to: rig.root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
        try "let x = 1\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("a.swift", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view-\(g0)") }
        await settle(window)
        let h = BodyProbe.count("FilePanelHeader"), b = BodyProbe.count("GroupBar")
        await rig.workspace.open("data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        let doc = try #require(rig.workspace.document("data.csv"))
        await (try #require(CodePanelStore.tableModel(for: doc))).buildFinished()
        await settle(window, 30)
        // Opening a tab re-runs the bar and header once for the new tab and once for the new document.
        #expect(BodyProbe.count("FilePanelHeader") - h <= 2, "header \(BodyProbe.count("FilePanelHeader") - h)")
        #expect(BodyProbe.count("GroupBar") - b <= 2, "bar \(BodyProbe.count("GroupBar") - b)")
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func anUnfocusedSelectableTableBesideARedrawingSiblingReplaysRetained() async throws {
        let (rig, window, id, perf) = try await rigWithCSV(.code2)
        let ids = rig.workspace.codeLayout.tree.groupIDs
        let g0 = ids[0], g1 = ids[1]
        await rig.workspace.open("data.csv", in: .group(g1))
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g1))
        try await window.runUntil { self.exists(window, "csv-table-\(g1)") }
        await settle(window)
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await settle(window)
        model.setSelection([3])
        rig.workspace.focusGroup(id: g0)
        await settle(window, 20)
        let tableBefore = BodyProbe.count("TablePanel"), cellBefore = BodyProbe.count("CSVCell")
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched + ["TablePanel", "CSVCell"])
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= CodeModePerformanceTests.steadyCode2 + 2 }, "per-frame \(t.perFrame)")
        #expect(t.requests <= CodeModePerformanceTests.steadyCode2 * 20 * 102 / 100, "requests \(t.requests)")
        #expect(BodyProbe.count("TablePanel") == tableBefore, "the unfocused table re-ran")
        #expect(BodyProbe.count("CSVCell") == cellBefore, "cells re-ran")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func idleCellModeTableCostsZero() async throws {
        let (rig, window, g0) = try await tableRig()
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-1"))
        await settle(window, 20)
        #expect(model.activeCell == CSVTableModel.ActiveCell(row: 3, column: 1))
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func anUnfocusedCellModeTableBesideARedrawingSiblingReplaysRetained() async throws {
        let (rig, window, id, perf) = try await rigWithCSV(.code2)
        let ids = rig.workspace.codeLayout.tree.groupIDs
        let g0 = ids[0], g1 = ids[1]
        await rig.workspace.open("data.csv", in: .group(g1))
        rig.workspace.setPresentation(.table, of: "data.csv", in: .group(g1))
        try await window.runUntil { self.exists(window, "csv-table-\(g1)") }
        await settle(window)
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        await settle(window)
        model.setActiveCell(CSVTableModel.ActiveCell(row: 3, column: 1))
        rig.workspace.focusGroup(id: g0)
        await settle(window, 20)
        #expect(model.activeCell != nil)
        let tableBefore = BodyProbe.count("TablePanel"), cellBefore = BodyProbe.count("CSVCell")
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched + ["TablePanel", "CSVCell"])
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= CodeModePerformanceTests.steadyCode2 + 2 }, "per-frame \(t.perFrame)")
        #expect(t.requests <= CodeModePerformanceTests.steadyCode2 * 20 * 102 / 100, "requests \(t.requests)")
        #expect(BodyProbe.count("TablePanel") == tableBefore, "the unfocused table re-ran")
        #expect(BodyProbe.count("CSVCell") == cellBefore, "cells re-ran")
        withExtendedLifetime((rig, window)) {}
    }

    /// A selection or active-cell move rebuilds the focused table's window (measured 774 and 361 on alternate frames,
    /// the same order as the row-selection click's 757); pinned, never loosened.
    static let steadyCellMove = 780

    @Test func moveOfTheActiveCellCostsABoundedFrame() async throws {
        let (rig, window, g0) = try await tableRig()
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-1"))
        await settle(window, 20)
        let startRow = try #require(model.activeCell).row
        window.resetFrameWork()
        for _ in 0..<5 { window.typeKey(.downArrow); window.tick(); await Task.yield() }
        let work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= Self.steadyCellMove }, "per-frame \(work)")
        #expect(model.activeCell?.row == startRow + 5)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func realisedRowsStayBoundedAfterAJumpFarDown() async throws {
        let (rig, window, g0) = try await tableRig()
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        model.setSelection([4000])
        model.scrollTo(fileRow: 4000)
        await settle(window, 20)
        let prefix = "csv-row-\(g0)-"
        let rows = ((try? window.elements(where: { _ in true })) ?? []).compactMap { e -> Int? in
            guard let i = e.identifier, i.hasPrefix(prefix) else { return nil }
            return Int(i.dropFirst(prefix.count))
        }
        #expect(rows.contains(4000), "\(rows)")
        #expect(rows.count <= 40, "realised \(rows.count)")
        withExtendedLifetime((rig, window)) {}
    }
}

extension CSVTableGuardTests {
    /// Element requests per frame of a commit (measured 774, 361, 311) and of an editor keystroke (775 and 362 alternating):
    /// a focused table rebuilds its window like a cell move (`steadyCellMove`). Pinned, never raised.
    static let steadyCommit = 780
    static let steadyEditorKey = 780

    private func editingRig() async throws -> (rig: Rig, window: TestWindow, g0: UUID, model: CSVTableModel) {
        let (rig, window, g0) = try await tableRigForEditing()
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        try window.click(window.element(identifier: "csv-cell-\(g0)-3-1"))
        await settle(window, 10)
        window.typeKey(.return)
        await settle(window, 20)
        return (rig, window, g0, model)
    }

    @Test func idleWhileEditingAsksNoFrames() async throws {
        let (rig, window, _, model) = try await editingRig()
        #expect(model.editingCell != nil)
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aKeystrokeInTheEditorStaysUnderTheEditorKeyGuard() async throws {
        let (rig, window, _, _) = try await editingRig()
        let headerBefore = BodyProbe.count("FilePanelHeader"), barBefore = BodyProbe.count("GroupBar")
        window.resetFrameWork()
        for _ in 0..<5 { window.typeText("a"); window.tick(); await Task.yield() }
        let work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= Self.steadyEditorKey }, "per-frame \(work)")
        #expect(BodyProbe.count("FilePanelHeader") == headerBefore && BodyProbe.count("GroupBar") == barBefore)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func committingACellIsOneBoundedFrame() async throws {
        let (rig, window, _, model) = try await editingRig()
        window.typeText("zz")
        window.tick(); await Task.yield()
        window.resetFrameWork()
        window.typeKey(.return)
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(model.editingCell == nil)
        let work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= Self.steadyCommit }, "per-frame \(work)")
        window.resetFrameWork()
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "not idle after commit")
        withExtendedLifetime((rig, window)) {}
    }

    private func tableRigForEditing() async throws -> (rig: Rig, window: TestWindow, g0: UUID) {
        let (rig, window, g0) = try await tableRig()
        let doc = try #require(rig.workspace.document("data.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        await model.buildFinished()
        return (rig, window, g0)
    }
}
