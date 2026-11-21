@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// View-only sort in the Table: header click, File order, frozen order and the stale hint.
@MainActor
@Suite struct CSVTableSortTests {
    /// Element requests of one scrolling frame of a sorted table (measured: the largest of 285, 268, 263 and 257 with the change buttons in the header). The unsorted
    /// bound is `CSVTableGuardTests.steadyScroll` (280); the difference is MetalUI's sort-indicator chevron in the header, which
    /// the table requests every frame. Pinned, never loosened.
    static let steadySortedScroll = 285

    private static let csv = "key,name\n30,cc\n10,aa\n20,bb\n9,dd\n"

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func table(_ csv: String = csv, rows: Int? = nil) async throws
        -> (rig: Rig, window: TestWindow, g0: UUID, model: CSVTableModel, doc: EditorDocument) {
        let rig = Rig()
        try csv.write(to: rig.root.appendingPathComponent("data.csv"), atomically: true, encoding: .utf8)
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
        await settle(window)
        return (rig, window, g0, model, doc)
    }

    private func header(_ window: TestWindow, _ title: String) throws -> TestElement {
        // A sorted column's label carries the direction ("key, Go Down").
        let all = try window.elements(where: { e in
            let t = e.value ?? e.label
            return e.identifier == nil && (t == title || t?.hasPrefix(title + ", Go") == true)
        })
        return try #require(all.min { $0.frame.minY.value < $1.frame.minY.value }, "no header \(title)")
    }

    /// First column values of the cells in screen order (top to bottom).
    private func keysOnScreen(_ window: TestWindow, _ g0: UUID) throws -> [String] {
        let cells = try window.elements(where: { $0.identifier?.hasPrefix("csv-cell-\(g0)-") == true && $0.identifier?.hasSuffix("-0") == true })
        return cells.sorted { $0.frame.minY.value < $1.frame.minY.value }.compactMap(\.value)
    }

    private func numbersOnScreen(_ window: TestWindow, _ g0: UUID) throws -> [String] {
        let cells = try window.elements(where: { $0.identifier?.hasPrefix("csv-row-\(g0)-") == true && $0.identifier?.contains("flag") == false })
        return cells.sorted { $0.frame.minY.value < $1.frame.minY.value }.compactMap { $0.value ?? $0.label }
    }

    @Test func headerClickSortsAndKeepsFileRowNumbers() async throws {
        let (rig, window, g0, model, _) = try await table()
        #expect(try keysOnScreen(window, g0) == ["30", "10", "20", "9"])
        try window.click(header(window, "key"))
        await settle(window)
        #expect(model.sort != nil)
        #expect(try keysOnScreen(window, g0) == ["9", "10", "20", "30"])
        // The # column still shows file row numbers, now out of order.
        #expect(try numbersOnScreen(window, g0) == ["5", "3", "4", "2"])
        #expect(model.sort?.permutation == [4, 2, 3, 1])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func fileOrderButtonShowsOnlyWhileSortedAndRestores() async throws {
        let (rig, window, g0, model, _) = try await table()
        #expect(!exists(window, "csv-file-order-\(g0)"))
        try window.click(header(window, "key"))
        await settle(window)
        #expect(exists(window, "csv-file-order-\(g0)"))
        try window.click(window.element(identifier: "csv-file-order-\(g0)"))
        await settle(window)
        #expect(model.sort == nil)
        #expect(!exists(window, "csv-file-order-\(g0)"))
        #expect(try keysOnScreen(window, g0) == ["30", "10", "20", "9"])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func secondClickReversesTheOrder() async throws {
        let (rig, window, g0, model, _) = try await table()
        try window.click(header(window, "key"))
        await settle(window)
        try window.click(header(window, "key"))
        await settle(window)
        #expect(model.sort?.ascending == false)
        #expect(try keysOnScreen(window, g0) == ["30", "20", "10", "9"])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func staleHintAfterAnAgentEditAndClearedByAnotherClick() async throws {
        let (rig, window, g0, model, doc) = try await table()
        try window.click(header(window, "key"))
        await settle(window)
        #expect(!exists(window, "csv-sort-stale-\(g0)"))
        let end = doc.buffer.snapshot().utf8Count
        try doc.buffer.applyExternalEdits([CodeTextEdit(range: end..<end, text: "5,ee\n")])
        model.sync()
        await settle(window)
        #expect(model.sortIsStale)
        #expect(exists(window, "csv-sort-stale-\(g0)"))
        // The added row goes last; the order stays frozen.
        #expect(try keysOnScreen(window, g0) == ["9", "10", "20", "30", "5"])
        try window.click(header(window, "key"))
        await settle(window)
        #expect(!model.sortIsStale)
        #expect(!exists(window, "csv-sort-stale-\(g0)"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func aRowEditedWhileSortedKeepsItsPosition() async throws {
        let (rig, window, g0, model, doc) = try await table()
        try window.click(header(window, "key"))
        await settle(window)
        // "10" (file row 2) becomes "99": it stays second.
        let snap = doc.buffer.snapshot()
        let text = String(decoding: snap.utf8(in: 0..<snap.utf8Count), as: UTF8.self)
        let at = text.utf8.distance(from: text.startIndex, to: text.range(of: "10,aa")!.lowerBound)
        try doc.buffer.applyExternalEdits([CodeTextEdit(range: at..<(at + 2), text: "99")])
        model.sync()
        await settle(window)
        #expect(try keysOnScreen(window, g0) == ["9", "99", "20", "30"])
        withExtendedLifetime((rig, window)) {}
    }

    @Test func sortIsOnePublish() async throws {
        let (rig, window, _, model, _) = try await table()
        let before = model.revision
        try window.click(header(window, "key"))
        await settle(window, 20)
        #expect(model.revision == before + 1)
        withExtendedLifetime((rig, window)) {}
    }

    @Test func scrollingAndIdleWhileSortedStayWithinTheGuards() async throws {
        var text = "id,name,city,note\n"
        for i in 0..<5000 { text += "\((i * 7919) % 5000),name\(i),city\(i),note \(i)\n" }
        let (rig, window, g0, model, _) = try await table(text)
        try window.click(header(window, "id"))
        for _ in 0..<2000 where model.sort == nil { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
        await settle(window, 20)
        #expect(model.sort != nil)
        window.resetFrameWork()
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        let t = try window.element(identifier: "csv-table-\(g0)")
        let centre = Point(x: Pixels((t.frame.minX.value + t.frame.maxX.value) / 2),
                           y: Pixels((t.frame.minY.value + t.frame.maxY.value) / 2))
        for _ in 0..<5 { window.scroll(at: centre, byDeltaX: 0, deltaY: -40); window.tick(); await Task.yield() }
        window.resetFrameWork()
        for _ in 0..<20 { window.scroll(at: centre, byDeltaX: 0, deltaY: -40); window.tick(); await Task.yield() }
        let work = window.frameWork.map(\.elementRequests)
        #expect(work.allSatisfy { $0 <= Self.steadySortedScroll }, "per-frame \(work)")
        withExtendedLifetime((rig, window)) {}
    }
}
