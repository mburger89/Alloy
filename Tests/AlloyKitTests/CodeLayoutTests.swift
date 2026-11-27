@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct CodeLayoutTests {
    private func codeWindow(gutter: Double? = nil, restore: Bool = true) async throws -> (Rig, TestWindow) {
        let rig = Rig()
        if let gutter {
            var s = rig.workspace.settings
            s.appearance = AppearanceOverrides(gutter: gutter)
            try rig.workspace.updateSettings(s)
        }
        if restore { await rig.workspace.restoreUIState() }
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<3 { window.tick() }
        return (rig, window)
    }

    private func frame(_ window: TestWindow, _ id: String) throws -> Bounds<Pixels> { try window.element(identifier: id).frame }
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    @Test func codeModeShowsThreeIslands() async throws {
        let (_, window) = try await codeWindow()
        let s = try frame(window, "island-code-sidebar"), e = try frame(window, "island-code-editor")
        let c = try frame(window, "island-code-chat")
        #expect(s.minX < e.minX && e.minX < c.minX)
        #expect(!exists(window, "island-sidebar") && !exists(window, "island-files"))
    }

    @Test func islandsAreInsetByTheGutterInCodeMode() async throws {
        let (_, window) = try await codeWindow(gutter: 6)
        let s = try frame(window, "island-code-sidebar"), e = try frame(window, "island-code-editor")
        let c = try frame(window, "island-code-chat"), title = try frame(window, "island-title")
        #expect(abs(s.minX.value - 6) < 0.5)
        #expect(abs(e.minX.value - s.maxX.value - 6) < 1.5)
        #expect(abs(c.minX.value - e.maxX.value - 6) < 1.5)
        #expect(abs(c.maxX.value - (1200 - 6)) < 0.5)
        #expect(abs(s.maxY.value - (800 - 6)) < 0.5)
        #expect(abs(s.minY.value - (title.maxY.value + 6)) < 0.5)
    }

    @Test func bottomPanelTakesNoSpace() async throws {
        let (_, window) = try await codeWindow()
        let area = try frame(window, "code-editor-area"), island = try frame(window, "island-code-editor")
        #expect(abs((area.maxY.value - area.minY.value) - (island.maxY.value - island.minY.value)) < 0.5)
    }

    @Test func sidebarStartsOnTheFilesTab() async throws {
        let (_, window) = try await codeWindow()
        #expect(exists(window, "code-sidebar-tab-files"))
        #expect(exists(window, "file-tree"))
        #expect(exists(window, "code-sidebar-tab-search") && !exists(window, "code-sidebar-tab-git"))
        #expect(!exists(window, "search-query"))
    }

    private struct NestedSpike: Component {
        let style: AppearanceStyle
        var content: some ElementGroup {
            HSplitView {
                Color.clear.accessibilityIdentifier("spike-a").frame(minWidth: Pixels(50))
                VSplitView {
                    Color.clear.accessibilityIdentifier("spike-b").frame(minHeight: Pixels(50))
                    Color.clear.accessibilityIdentifier("spike-c").frame(minHeight: Pixels(50))
                }
            }
            .island(style: style, identifier: "spike-island")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @Test func nestedSplitViewsLayOut() async throws {
        let window = try TestWindow(size: Size(width: Pixels(1000), height: Pixels(600))) {
            VStack(spacing: 0) { NestedSpike(style: .defaults) }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        window.tick(); window.tick()
        let island = try frame(window, "spike-island")
        let a = try frame(window, "spike-a"), b = try frame(window, "spike-b"), c = try frame(window, "spike-c")
        for f in [a, b, c] { #expect(f.maxX.value - f.minX.value > 1 && f.maxY.value - f.minY.value > 1) }
        func overlap(_ x: Bounds<Pixels>, _ y: Bounds<Pixels>) -> Bool {
            x.minX.value < y.maxX.value - 0.5 && y.minX.value < x.maxX.value - 0.5
                && x.minY.value < y.maxY.value - 0.5 && y.minY.value < x.maxY.value - 0.5
        }
        #expect(!overlap(a, b) && !overlap(a, c) && !overlap(b, c))
        // The union (the dividers are the only slack) reaches each edge of the island.
        let all = [a, b, c]
        #expect(abs(all.map(\.minX.value).min()! - island.minX.value) < 1.5)
        #expect(abs(all.map(\.maxX.value).max()! - island.maxX.value) < 1.5)
        #expect(abs(all.map(\.minY.value).min()! - island.minY.value) < 1.5)
        #expect(abs(all.map(\.maxY.value).max()! - island.maxY.value) < 1.5)
    }

    @Test func paneSizesGoThroughTheWorkspace() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        let store = UIStateSplitStore(workspace: rig.workspace)
        #expect(store.paneSizes(forName: "code-main") == nil)
        store.setPaneSizes([200, 600, 300], forName: "code-main")
        #expect(store.queriedNames.contains("code-main"))
        // The debounced timer writes the file on its own, without a flush.
        let file = rig.workspace.uiStateURL
        for _ in 0..<50 { await Task.yield() }
        rig.clock.advance(by: 0.5)
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: file.path) { await Task.yield() }
        #expect(FileManager.default.fileExists(atPath: file.path))
        let again = Workspace(projectRoot: rig.workspace.projectRoot, appSupport: rig.workspace.appSupport,
                              settings: AlloySettings(), locate: { _ in URL(fileURLWithPath: "/fake/claude") })
        await again.restoreUIState()
        #expect(again.paneSizes(forName: "code-main") == [200, 600, 300])
    }

    @Test func restoreAfterTheStoreExistsAppliesSavedSizes() async throws {
        let (rig, window) = try await codeWindow(restore: false)
        #expect(!exists(window, "island-code-sidebar") && !exists(window, "island-code-editor"))
        #expect(exists(window, "island-code-restoring"))
        try UIStateFile.save(UIState(mode: .code, paneSizes: ["code-main": [400, 400, 300]]), to: rig.workspace.uiStateURL)
        await rig.workspace.restoreUIState()
        for _ in 0..<3 { window.tick() }
        let after = try frame(window, "island-code-sidebar")
        #expect(abs((after.maxX.value - after.minX.value) - 400) < 2)
        #expect(!exists(window, "island-code-restoring"))
    }

    @Test func uiStateRestoredBecomesTrueWithoutAFile() async {
        let rig = Rig()
        #expect(!rig.workspace.uiStateRestored)
        await rig.workspace.restoreUIState()
        #expect(rig.workspace.uiStateRestored)
    }

    @Test func shiftCmdNCreatesASessionInCodeMode() async throws {
        let (rig, window) = try await codeWindow()
        let before = rig.workspace.sessions.count
        window.typeKey("n", modifierFlags: [.command, .shift])
        try await window.runUntil { rig.workspace.sessions.count == before + 1 }
        #expect(rig.workspace.sessions.count == before + 1)
    }

    @Test func shiftCmdNStillFiresOnceInChatMode() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let before = rig.workspace.sessions.count
        window.typeKey("n", modifierFlags: [.command, .shift])
        try await window.runUntil { rig.workspace.sessions.count >= before + 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.workspace.sessions.count == before + 1)
    }
}
