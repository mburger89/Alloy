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

    // MARK: Command retargeting while a terminal is focused

    private func runCommand(_ rig: Rig, _ id: String) {
        testCenter(for: rig.workspace).registry.run(id: id)
    }

    private func openEditorTabs(_ rig: Rig) async throws {
        for name in ["a.txt", "b.txt"] {
            try "x\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            await rig.workspace.open(name)
        }
    }

    private func terminalTabs(_ rig: Rig) -> Int { rig.workspace.terminalLayout.tabs.count }

    @Test func commandWClosesTheTerminalTabWhileFocused() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        try await openEditorTabs(rig)
        store.toggle(); store.newTab(); settle(window)
        #expect(terminalTabs(rig) == 2)
        let editorTabs = rig.workspace.tabs(in: rig.workspace.defaultPane)
        store.hasFocus = true
        runCommand(rig, "tab.close")
        #expect(terminalTabs(rig) == 1)
        #expect(rig.workspace.tabs(in: rig.workspace.defaultPane) == editorTabs)
        store.hasFocus = false
        store.newTab()
        runCommand(rig, "tab.close")
        await rig.workspace.settle()
        #expect(terminalTabs(rig) == 2, "terminal tabs untouched with the editor focused")
        #expect(rig.workspace.tabs(in: rig.workspace.defaultPane).count == editorTabs.count - 1)
        withExtendedLifetime(window) {}
    }

    @Test func commandWOnTheLastTerminalTabHidesThePanelAndFocusesTheEditor() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        store.toggle(); settle(window)
        let group = rig.workspace.codeLayout.focusedGroupID
        store.hasFocus = true
        runCommand(rig, "tab.close")
        settle(window)
        #expect(!store.visible && !store.hasFocus)
        #expect(rig.workspace.codeLayout.focusedGroupID == group)
    }

    @Test func controlTabCyclesTerminalTabsWhileFocused() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        store.toggle(); store.newTab(); store.newTab(); settle(window)
        let ids = rig.workspace.terminalLayout.tabs.map(\.id)
        store.hasFocus = true
        #expect(rig.workspace.terminalLayout.activeTab == ids[2])
        runCommand(rig, "tab.next")
        #expect(rig.workspace.terminalLayout.activeTab == ids[0], "wraps forward")
        runCommand(rig, "tab.previous")
        #expect(rig.workspace.terminalLayout.activeTab == ids[2], "wraps backward")
        runCommand(rig, "tab.previous")
        #expect(rig.workspace.terminalLayout.activeTab == ids[1])
        withExtendedLifetime(window) {}
    }

    @Test func commandTOpensANewTerminalTabWhileFocused() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        store.toggle(); settle(window)
        store.hasFocus = true
        runCommand(rig, "tab.new")
        #expect(terminalTabs(rig) == 2)
        withExtendedLifetime(window) {}
    }

    @Test func commandTIsDisabledWhenNoTerminalFocused() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        store.toggle(); settle(window)
        let registry = testCenter(for: rig.workspace).registry
        #expect(registry.command(id: "tab.new")?.descriptor.keyID == "global-key-new-terminal-tab")
        #expect(registry.command(id: "tab.new")?.descriptor.title == "New Terminal Tab")
        runCommand(rig, "tab.new")
        #expect(terminalTabs(rig) == 1)
        withExtendedLifetime(window) {}
    }

    @Test func chatModeIgnoresTerminalFocus() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        store.toggle(); store.newTab(); settle(window)
        store.hasFocus = true
        rig.workspace.setMode(.chat)
        #expect(!rig.workspace.terminalHasFocus)
        runCommand(rig, "tab.close")
        runCommand(rig, "tab.next")
        runCommand(rig, "tab.new")
        #expect(terminalTabs(rig) == 2)
        withExtendedLifetime(window) {}
    }

    @Test func commandsReadFocusInsideTheActionOnly() async throws {
        let (rig, window, store) = try await codeWindowWithStore()
        store.toggle(); settle(window)
        let names = ["AlloyScreen", "GlobalKeys", "TerminalPanel"]
        let before = names.map { BodyProbe.count($0) }
        store.hasFocus = true; settle(window)
        store.hasFocus = false; settle(window)
        #expect(names.map { BodyProbe.count($0) } == before)
        withExtendedLifetime(rig) {}
    }

    // MARK: OSC titles, cwd and live theme and settings through the real view

    private func shellWindow() async throws -> (Rig, TestWindow, TerminalPanelStore, ScriptedPtySpawner) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        return (rig, window, store, spawner)
    }

    private func pump(_ window: TestWindow, _ n: Int = 12) async {
        for _ in 0..<n { try? await Task.sleep(nanoseconds: 10_000_000); window.tick() }
    }

    private func osc(_ body: String, terminator: String = "\u{07}") -> [UInt8] { Array("\u{1B}]\(body)\(terminator)".utf8) }

    @Test func oscTitleReachesTheTab() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        spawner.spawned[0].feed(osc("0;vim"))
        await pump(window)
        #expect(store.tabSummaries.first?.title == "vim")
        withExtendedLifetime(rig) {}
    }

    @Test func oscTitleIsCapped() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        spawner.spawned[0].feed(osc("0;" + String(repeating: "y", count: 1000)))
        await pump(window)
        #expect(store.tabSummaries.first?.title.count == 256)
        withExtendedLifetime(rig) {}
    }

    @Test func oscSevenUpdatesLastCwdAndRestartUsesIt() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        spawner.spawned[0].feed(osc("7;file:///tmp", terminator: "\u{1B}\\"))
        await pump(window)
        let cwd = rig.workspace.terminalLayout.tabs.compactMap { $0.panes[pane]?.lastCwd }.first
        #expect(cwd == "/tmp")
        spawner.spawned[0].finish(.exited(0))
        await pump(window)
        store.restart(pane)
        await pump(window)
        #expect(spawner.spawned.count == 2)
        withExtendedLifetime(rig) {}
    }

    @Test func themeChangeRepaintsThePalette() async throws {
        final class Holder { var controller: ThemeController? }
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: ScriptedPtySpawner(), environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace), terminal: store)
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.testApp.app, watcher: ScriptedChangeSource())
        holder.controller = controller
        defer { controller.stop() }
        try controller.choose(mode: .single, theme: "dracula")
        for _ in 0..<5 { window.tick() }
        let before = store.appearance(themes: controller)
        let panel = BodyProbe.count("TerminalPanel")
        try controller.choose(mode: .single, theme: "alloy-light")
        for _ in 0..<5 { window.tick() }
        let after = store.appearance(themes: controller)
        #expect(before.palette != after.palette)
        #expect(BodyProbe.count("TerminalPanel") - panel <= 1)
    }

    @Test func terminalSettingsChangeAppliesLive() async throws {
        let (rig, window, store, _) = try await shellWindow()
        let first = store.appearance(themes: nil)
        var settings = rig.workspace.settings
        settings.terminal.fontSize = 18
        settings.terminal.cursorBlink = !first.cursorBlink
        try rig.workspace.updateSettings(settings, persist: false)
        let panel = BodyProbe.count("TerminalPanel")
        for _ in 0..<5 { window.tick() }
        let second = store.appearance(themes: nil)
        #expect(second.fontSize == 18 && second.cursorBlink != first.cursorBlink)
        #expect(BodyProbe.count("TerminalPanel") - panel <= 1)
    }
}
