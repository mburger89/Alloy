@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct TerminalPanelTests {
    private func codeWindow() async throws -> (Rig, TestWindow) {
        let (rig, window, _) = try await codeWindowWithStore()
        return (rig, window)
    }

    private func codeWindowWithStore() async throws -> (Rig, TestWindow, TerminalPanelStore) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace)
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<3 { window.tick() }
        return (rig, window, store)
    }

    private func settle(_ window: TestWindow) { for _ in 0..<3 { window.tick() } }
    private func click(_ window: TestWindow, _ id: String) throws {
        try window.click(window.element(identifier: id))
        settle(window)
    }
    private func panes(_ window: TestWindow) -> [TestElement] {
        ((try? window.elements(where: { _ in true })) ?? []).filter { $0.identifier?.hasPrefix("terminal-pane-") == true }
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func frame(_ window: TestWindow, _ id: String) throws -> Bounds<Pixels> { try window.element(identifier: id).frame }
    private func toggle(_ window: TestWindow) throws {
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-toggle-terminal")
        for _ in 0..<3 { window.tick() }
    }

    @Test func toggleShowsAndHidesPanel() async throws {
        let (rig, window) = try await codeWindow()
        #expect(!exists(window, "code-terminal-panel") && !exists(window, "code-terminal"))
        try toggle(window)
        #expect(rig.workspace.terminalLayout.visible)
        let panel = try frame(window, "code-terminal-panel"), area = try frame(window, "code-editor-area")
        #expect(panel.minY >= area.maxY)
        try toggle(window)
        #expect(!exists(window, "code-terminal-panel") && !exists(window, "code-terminal"))
    }

    @Test func openingCreatesOneTab() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        #expect(rig.workspace.terminalLayout.tabs.count == 1)
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        #expect(exists(window, "terminal-pane-\(pane.uuidString)"))
    }

    @Test func hidingKeepsTabs() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        let tabs = rig.workspace.terminalLayout.tabs
        try toggle(window)
        #expect(rig.workspace.terminalLayout.tabs == tabs && !rig.workspace.terminalLayout.visible)
        try toggle(window)
        #expect(rig.workspace.terminalLayout.tabs == tabs)
    }

    @Test func heightPersistsInPaneSizes() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        let store = UIStateSplitStore(workspace: rig.workspace)
        store.setPaneSizes([500, 200], forName: "code-terminal")
        #expect(rig.workspace.paneSizes(forName: "code-terminal") == [500, 200])
    }

    @Test func minimumHeightIsFourRows() async throws {
        let (rig, window) = try await codeWindow()
        // A saved layout that asks for a 10 pt panel: the split must still enforce the minimum.
        UIStateSplitStore(workspace: rig.workspace).setPaneSizes([790, 10], forName: "code-terminal")
        try toggle(window)
        let h = try frame(window, "code-terminal-panel")
        #expect(h.maxY - h.minY >= terminalMinHeight - Pixels(0.5))
        #expect(terminalMinHeight == terminalTabStripHeight + terminalRowHeight * 4)
    }

    @Test func storeToggleHidesAndReturnsFocusToEditor() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        let store = TerminalPanelStore(workspace: rig.workspace)
        let group = rig.workspace.codeLayout.focusedGroupID
        store.toggle()
        #expect(store.visible)
        store.hasFocus = true
        store.toggle()
        #expect(!store.visible && !store.hasFocus)
        #expect(rig.workspace.codeLayout.focusedGroupID == group)
    }

    @Test func chatModeHidesPanelButKeepsLayout() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        rig.workspace.setMode(.chat)
        for _ in 0..<3 { window.tick() }
        #expect(!exists(window, "code-terminal-panel"))
        #expect(rig.workspace.terminalLayout.visible)
        rig.workspace.setMode(.code)
        for _ in 0..<3 { window.tick() }
        #expect(exists(window, "code-terminal-panel"))
    }

    @Test func viewMenuItemsAreDisabledOutsideCodeMode() async throws {
        let (rig, window) = try await codeWindow()
        rig.workspace.setMode(.chat)
        window.tick()
        #expect(throws: (any Error).self) { try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-toggle-terminal") }
        #expect(throws: (any Error).self) { try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-new-terminal") }
        #expect(!rig.workspace.terminalLayout.visible)
        rig.workspace.setMode(.code)
        window.tick()
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-new-terminal")
        #expect(rig.workspace.terminalLayout.tabs.count == 1)
    }

    // MARK: Tab strip, splits, exited panes

    @Test func tabStripListsTabsByIndexIds() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        try click(window, "terminal-new"); try click(window, "terminal-new")
        #expect(rig.workspace.terminalLayout.tabs.count == 3)
        for n in 1...3 { #expect(exists(window, "terminal-tab-\(n)") && exists(window, "terminal-tab-close-\(n)")) }
        #expect(try window.element(identifier: "terminal-tab-3").isSelected)
        #expect(try !window.element(identifier: "terminal-tab-1").isSelected)
    }

    @Test func plusAddsTabInProjectRoot() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        try click(window, "terminal-new")
        let layout = rig.workspace.terminalLayout
        #expect(layout.tabs.count == 2)
        let pane = try #require(layout.active?.focusedPane)
        #expect(layout.active?.panes[pane]?.lastCwd == rig.workspace.projectRoot.path)
    }

    @Test func clickingTabSelects() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        try click(window, "terminal-new")
        let first = rig.workspace.terminalLayout.tabs[0].id
        try click(window, "terminal-tab-1")
        #expect(rig.workspace.terminalLayout.activeTab == first)
    }

    @Test func closeButtonClosesTabAndLastCloseHidesPanel() async throws {
        let (rig, window) = try await codeWindow()
        try toggle(window)
        try click(window, "terminal-new")
        try click(window, "terminal-tab-close-2")
        #expect(rig.workspace.terminalLayout.tabs.count == 1 && rig.workspace.terminalLayout.visible)
        try click(window, "terminal-close")
        #expect(rig.workspace.terminalLayout.tabs.isEmpty && !rig.workspace.terminalLayout.visible)
        #expect(!exists(window, "code-terminal-panel"))
    }

    @Test func splitButtonMakesTwoPanesSideBySide() async throws {
        let (_, window) = try await codeWindow()
        try toggle(window)
        try click(window, "terminal-split")
        let p = panes(window).sorted { $0.frame.minX < $1.frame.minX }
        #expect(p.count == 2)
        #expect(p[0].frame.minY == p[1].frame.minY && p[0].frame.minX < p[1].frame.minX)
    }

    @Test func closingSplitPaneKeepsSibling() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try toggle(window)
        try click(window, "terminal-split")
        let tab = try #require(rig.workspace.terminalLayout.active)
        let ids = tab.tree.paneIDs
        store.closePane(ids[1]); settle(window)
        #expect(exists(window, "terminal-pane-\(ids[0].uuidString)") && !exists(window, "terminal-pane-\(ids[1].uuidString)"))
        #expect(rig.workspace.terminalLayout.tabs.count == 1)
    }

    @Test func exitedPaneShowsCloseAndRestart() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try toggle(window)
        try click(window, "terminal-split")
        let ids = try #require(rig.workspace.terminalLayout.active).tree.paneIDs
        var restarted: [UUID] = []
        store.onRestart = { restarted.append($0) }
        store.markExited(ids[0], status: 3); settle(window)
        let text = try window.element(identifier: "terminal-exited-text-\(ids[0].uuidString)")
        #expect(text.value?.contains("[process exited 3]") == true)
        try click(window, "terminal-exited-restart")
        #expect(store.paneState(ids[0]) == .running && restarted == [ids[0]])
        store.markExited(ids[0], status: 3); settle(window)
        try click(window, "terminal-exited-close")
        #expect(!exists(window, "terminal-pane-\(ids[0].uuidString)") && exists(window, "terminal-pane-\(ids[1].uuidString)"))
    }

    @Test func restartNeverHappensOnItsOwn() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try toggle(window)
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        var count = 0
        store.onRestart = { _ in count += 1 }
        store.markExited(pane, status: 1)
        for _ in 0..<20 { window.tick() }
        #expect(count == 0 && store.paneState(pane) == .exited(1))
    }

    @Test func titleDefaultsToShellName() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try toggle(window)
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let expected = (store.shellName as NSString).lastPathComponent
        #expect(!expected.isEmpty && store.tabSummaries.first?.title == expected)
        store.setTitle("vim", for: pane)
        #expect(store.tabSummaries.first?.title == "vim")
        store.setTitle(nil, for: pane)
        #expect(store.tabSummaries.first?.title == expected)
    }

    @Test func titleIsCappedAt256Characters() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try toggle(window)
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        store.setTitle(String(repeating: "x", count: 1000), for: pane)
        #expect(store.title(of: pane).count == 256)
    }

    @Test func splitSizesOfRemovedSplitsAreDropped() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try toggle(window)
        try click(window, "terminal-split")
        let tab = try #require(rig.workspace.terminalLayout.active)
        guard case .split(let splitID, _, _, let second) = tab.tree else { Issue.record("no split"); return }
        let name = "terminal-split-\(splitID.uuidString)"
        store.splitStore.setPaneSizes([300, 300], forName: name)
        #expect(rig.workspace.currentUIState().paneSizes[name] == [300, 300])
        store.closePane(try #require(second.paneIDs.first))
        #expect(rig.workspace.currentUIState().paneSizes[name] == nil)
    }
}
