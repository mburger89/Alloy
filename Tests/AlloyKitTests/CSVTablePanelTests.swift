@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Text | Table: the presentation switch and the read-only table panel.
@MainActor
@Suite struct CSVTablePanelTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func setup(_ files: [String: Data]) async throws -> (rig: Rig, window: TestWindow, g0: UUID) {
        let rig = Rig()
        for (name, data) in files { try data.write(to: rig.root.appendingPathComponent(name)) }
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        for name in files.keys.sorted() { await rig.workspace.open(name, in: .group(g0)) }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-group-\(g0)") }
        return (rig, window, g0)
    }

    private func settle(_ window: TestWindow, _ n: Int = 6) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    private func showTable(_ rig: Rig, _ window: TestWindow, _ g0: UUID, _ path: String) async throws {
        rig.workspace.setPresentation(.table, of: path, in: .group(g0))
        try await window.runUntil { self.exists(window, "csv-table-\(g0)") }
        await settle(window)
    }

    private func texts(_ window: TestWindow) -> [String] {
        ((try? window.elements(where: { _ in true })) ?? []).compactMap { $0.value ?? $0.label }
    }

    private static let csv = Data("id,name,note\n1,ann,\"two\nlines\"\n2,bob,x\n3,\"bad,y\n".utf8)

    @Test func tableShowsRowsAndHeaderTitles() async throws {
        let (rig, window, g0) = try await setup(["data.csv": Self.csv])
        try await showTable(rig, window, g0, "data.csv")
        let all = texts(window)
        for t in ["id", "name", "note", "ann", "bob"] { #expect(all.contains(t), "\(t) in \(all)") }
        #expect(exists(window, "csv-cell-\(g0)-1-1"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func headerToggleShowsLetters() async throws {
        let (rig, window, g0) = try await setup(["data.csv": Self.csv])
        try await showTable(rig, window, g0, "data.csv")
        try window.click(window.element(identifier: "csv-header-toggle-\(g0)"))
        await settle(window)
        let all = texts(window)
        #expect(all.contains("A") && all.contains("B") && all.contains("C"), "\(all)")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func quotedNewlineShowsFirstLineAndMarker() async throws {
        let (rig, window, g0) = try await setup(["data.csv": Self.csv])
        try await showTable(rig, window, g0, "data.csv")
        let cell = try window.element(identifier: "csv-cell-\(g0)-1-2")
        let text = cell.value ?? ""
        #expect(text.hasPrefix("two") && text != "two" && !text.contains("lines"), "\(text)")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func flaggedRowShowsTheWarning() async throws {
        let (rig, window, g0) = try await setup(["data.csv": Self.csv])
        try await showTable(rig, window, g0, "data.csv")
        #expect(exists(window, "csv-row-\(g0)-3-flag"))
        #expect(!exists(window, "csv-row-\(g0)-1-flag"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func pickerOffersTableOnlyForCSVAndTSV() async throws {
        let (rig, window, g0) = try await setup(["data.csv": Self.csv, "t.tsv": Data("a\tb\n".utf8), "x.swift": Data("let a = 1\n".utf8)])
        for (path, expected) in [("data.csv", true), ("t.tsv", true), ("x.swift", false)] {
            rig.workspace.activate(path, in: .group(g0))
            await settle(window)
            let picker = try window.element(identifier: "code-group-presentation-\(g0)")
            let titles = descendants(of: picker, in: window).compactMap { $0.label }
            #expect(titles.contains("Table") == expected, "\(path): \(titles)")
        }
        withExtendedLifetime((rig, window)) {}
    }

    @Test func emptyBomOnlyAndHeaderOnlyFilesShowASaneTable() async throws {
        for (name, data) in [("empty.csv", Data()), ("bom.csv", Data([0xEF, 0xBB, 0xBF])), ("head.csv", Data("a,b".utf8))] {
            let (rig, window, g0) = try await setup([name: data])
            try await showTable(rig, window, g0, name)
            #expect(exists(window, "csv-header-toggle-\(g0)"), Comment(rawValue: name))
            withExtendedLifetime((rig, window)) {}
        }
    }

    @Test func invalidUTF8IsReadOnlyButRenders() async throws {
        let (rig, window, g0) = try await setup(["bad.csv": Data([0x61, 0x2C, 0xFF, 0x0A, 0x31, 0x2C, 0x32, 0x0A])])
        let doc = try #require(rig.workspace.document("bad.csv"))
        #expect(doc.state != .editable)
        try await showTable(rig, window, g0, "bad.csv")
        #expect(exists(window, "code-group-read-only-\(g0)"), "the file header carries the notice")
        #expect(!exists(window, "csv-read-only-\(g0)"), "the table bar does not repeat it")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func switchingBackClosesTheModelAndShowsCode() async throws {
        let (rig, window, g0) = try await setup(["data.csv": Self.csv])
        let doc = try #require(rig.workspace.document("data.csv"))
        try await showTable(rig, window, g0, "data.csv")
        #expect(CodePanelStore.tableModelCount(for: doc) == 1)
        rig.workspace.setPresentation(.plain, of: "data.csv", in: .group(g0))
        try await window.runUntil { self.exists(window, "code-view-\(g0)") }
        #expect(CodePanelStore.tableModelCount(for: doc) == 0)
        #expect(!exists(window, "csv-table-\(g0)"))
        withExtendedLifetime((rig, window)) {}
    }

    /// A read-only CSV that is sorted, so the bar carries "File order" too.
    private func readOnlySorted(_ window: TestWindow? = nil) async throws -> (Rig, TestWindow, UUID) {
        let (rig, window, g0) = try await setup(["bad.csv": Data([0x61, 0x2C, 0x62, 0x0A, 0x31, 0x2C, 0xFF, 0x0A, 0x32, 0x2C, 0x33, 0x0A])])
        try await showTable(rig, window, g0, "bad.csv")
        let doc = try #require(rig.workspace.document("bad.csv"))
        let model = try #require(CodePanelStore.tableModel(for: doc))
        model.sort(column: 0, ascending: false)
        await settle(window)
        return (rig, window, g0)
    }

    @Test func readOnlyNoticeAppearsOnceAndTheNameSurvivesNarrowWidths() async throws {
        let (rig, window, g0) = try await readOnlySorted()
        for width in [1200.0, 1100.0, 1000.0] {   // code panes of about 600, 500 and 400 pt; the name is asserted at 600
            window.resize(to: Size(width: Pixels(floatLiteral: width), height: Pixels(800)))
            await settle(window)
            let notices = try window.elements { ($0.identifier ?? "").contains("read-only") }
            #expect(notices.count == 1, "width \(width): \(notices.compactMap(\.identifier))")
            #expect(notices.first?.identifier == "code-group-read-only-\(g0)")
            #expect(!exists(window, "csv-read-only-\(g0)"))
            let path = try window.element(identifier: "code-group-path-\(g0)")
            let pane = try window.element(identifier: "code-group-\(g0)").frame
            let paneWidth = pane.maxX.value - pane.minX.value
            if paneWidth >= 560 { #expect((path.frame.maxX.value - path.frame.minX.value) >= 40, "width \(width): the file name keeps room, got \((path.frame.maxX.value - path.frame.minX.value)) in a pane of \(paneWidth)") }
        }
        withExtendedLifetime(rig) {}
    }

    @Test func tableBarLabelsStaySingleLine() async throws {
        let (rig, window, g0) = try await readOnlySorted()
        for width in [1200.0, 900.0, 700.0, 600.0, 450.0] {
            window.resize(to: Size(width: Pixels(floatLiteral: width), height: Pixels(800)))
            await settle(window)
            let toggle = try window.element(identifier: "csv-header-toggle-\(g0)")
            #expect((toggle.frame.maxY.value - toggle.frame.minY.value) < 30, "width \(width): the toggle wrapped, \(toggle.frame)")
            for id in ["csv-file-order", "csv-prev-change", "csv-next-change"] {
                // A variant that does not fit is dropped whole; whatever shows is one line.
                guard let el = try? window.element(identifier: "\(id)-\(g0)") else { continue }
                #expect((el.frame.maxY.value - el.frame.minY.value) < 30, "width \(width): \(id) wrapped, \(el.frame)")
            }
        }
        withExtendedLifetime(rig) {}
    }
}
