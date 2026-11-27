import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing

/// File > Close Tab, Close Window, Save, Save As… and Save All (MetalUI's `.saveItem` group).
@MainActor @Suite struct SaveMenuTests {
    private func dirtyRig(_ names: [String] = ["a.txt"]) async throws -> Rig {
        let rig = Rig()
        for name in names { try "hello\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        for name in names {
            await rig.workspace.open(name)
            _ = try #require(rig.workspace.document(name)).buffer.replace(0..<0, with: "x")
        }
        return rig
    }

    private func read(_ rig: Rig, _ name: String) -> String? {
        try? String(contentsOf: rig.root.appendingPathComponent(name), encoding: .utf8)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    @Test func fileMenuListsTheFiveItemsInOrderWithChords() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let file = try #require(window.testApp.menuBar.first { $0.title == "File" })
        let wanted = ["Close Tab", "Close Window", "Save", "Save As\u{2026}", "Save All"]
        let found = file.items.filter { wanted.contains($0.title) }
        #expect(found.map(\.title) == wanted, "\(file.items.map(\.title))")
        #expect(found.map(\.shortcut) == [
            PlatformKeyEquivalent(key: "w", modifiers: [.command]),
            PlatformKeyEquivalent(key: "w", modifiers: [.command, .shift]),
            PlatformKeyEquivalent(key: "s", modifiers: [.command]),
            PlatformKeyEquivalent(key: "s", modifiers: [.command, .shift]),
            PlatformKeyEquivalent(key: "s", modifiers: [.command, .option]),
        ])
        // MetalUI's own Close (also ⌘W) is gone: one Close Tab, no second "Close".
        #expect(!file.items.contains { $0.title == "Close" })
    }

    @Test func noGlobalKeyCloseTab() async throws {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        let close = try #require(registry.command(id: "tab.close"))
        #expect(close.descriptor.binding == .menu)
        #expect(registry.command(id: "file.save")?.descriptor.binding == .menu)
        let hidden = Set(registry.commands.filter { $0.descriptor.binding == .global }.map(\.descriptor.id))
        #expect(hidden == ["terminal.copy", "terminal.selectAll", "terminal.find", "terminal.clearScrollback"], "\(hidden)")
    }

    @Test func commandSSavesExactlyOnce() async throws {
        let rig = try await dirtyRig()
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try window.click(window.element(identifier: "code-view"))
        window.tick()
        var formats = 0
        rig.workspace.formatBeforeSave = { _ in formats += 1 }
        let before = rig.workspace.writeCount
        window.typeKey("s", modifierFlags: .command)
        try await waitFor { read(rig, "a.txt") == "xhello\n" }
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(rig.workspace.writeCount == before + 1)
        #expect(formats == 1)
    }

    @Test func commandWInFocusedTerminalClosesTheTerminalTab() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: ScriptedPtySpawner())
        let window = try alloyWindow(rig.workspace, terminal: store)
        store.toggle(); store.newTab()
        for _ in 0..<3 { window.tick() }
        #expect(rig.workspace.terminalLayout.tabs.count == 2)
        store.hasFocus = true
        window.typeKey("w", modifierFlags: .command)
        #expect(rig.workspace.terminalLayout.tabs.count == 1)
        #expect(rig.workspace.tabs(in: rig.workspace.defaultPane) == ["a.txt"])
    }

    @Test func saveAsCancelledDoesNothing() async throws {
        let rig = try await dirtyRig()
        let center = testCenter(for: rig.workspace)
        center.chooseSaveURL = { _, _ in nil }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save-as")
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(rig.workspace.tabs == ["a.txt"])
        #expect(read(rig, "a.txt") == "hello\n")
    }

    @Test func saveAsInsideProjectReplacesTabInPlace() async throws {
        let rig = try await dirtyRig(["a.txt", "b.txt", "c.txt"])
        rig.workspace.activeTab = "b.txt"
        let center = testCenter(for: rig.workspace)
        var proposed: (String, URL)?
        let target = rig.root.appendingPathComponent("copy.txt")
        center.chooseSaveURL = { name, directory in proposed = (name, directory); return target }
        let window = try alloyWindow(rig.workspace)
        let before = rig.workspace.tabs
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save-as")
        // `open` makes the new tab active before the move and the close finish: wait for the whole replacement.
        try await waitFor { rig.workspace.tabs == ["a.txt", "copy.txt", "c.txt"] && rig.workspace.document("b.txt") == nil }
        #expect(rig.workspace.activeTab == "copy.txt")
        // The tab count is unchanged, the new path sits at the old index, the old file was saved first.
        #expect(rig.workspace.tabs.count == before.count)
        #expect(rig.workspace.tabs == ["a.txt", "copy.txt", "c.txt"], "\(rig.workspace.tabs)")
        #expect(rig.workspace.document("b.txt") == nil)
        #expect(read(rig, "b.txt") == "xhello\n")
        #expect(read(rig, "copy.txt") == "xhello\n")
        #expect(proposed?.0 == "b.txt")
        #expect(proposed?.1.standardizedFileURL.path == rig.root.standardizedFileURL.path)
        #expect(rig.workspace.document("copy.txt") != nil)
    }

    @Test func saveAsToOwnPathIsPlainSave() async throws {
        let rig = try await dirtyRig()
        let center = testCenter(for: rig.workspace)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("a.txt") }
        let window = try alloyWindow(rig.workspace)
        let writes = rig.workspace.writeCount
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save-as")
        try await waitFor { read(rig, "a.txt") == "xhello\n" }
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(rig.workspace.tabs == ["a.txt"] && rig.workspace.activeTab == "a.txt")
        #expect(rig.workspace.writeCount == writes + 1)
    }

    @Test func saveAsOutsideTheProjectWritesAndLeavesTheTab() async throws {
        let rig = try await dirtyRig()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-saveas-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let center = testCenter(for: rig.workspace)
        center.chooseSaveURL = { _, _ in elsewhere }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save-as")
        try await waitFor { (try? String(contentsOf: elsewhere, encoding: .utf8)) == "xhello\n" }
        #expect(rig.workspace.tabs == ["a.txt"] && rig.workspace.activeTab == "a.txt")
    }

    @Test func saveAllSavesTwoDirtyTabs() async throws {
        let rig = try await dirtyRig(["a.txt", "b.txt"])
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save-all")
        try await waitFor { read(rig, "a.txt") == "xhello\n" && read(rig, "b.txt") == "xhello\n" }
    }

    @Test func closeWindowCallsTheInjectedCloser() async throws {
        let rig = Rig()
        var closed = 0
        testCenter(for: rig.workspace).closeKeyWindow = { closed += 1 }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "window-close")
        #expect(closed == 1)
    }

    @Test func cmdWWithAnotherWindowKeyClosesThatWindowNotATab() async throws {
        let rig = try await dirtyRig(["a.txt", "b.txt"])
        let center = testCenter(for: rig.workspace)
        var closed = 0
        center.closeKeyWindow = { closed += 1 }
        center.isProjectWindowKey = { false }
        let window = try alloyWindow(rig.workspace)
        let tabs = rig.workspace.tabs
        // The item stays enabled, so the chord reaches the command.
        #expect(window.testApp.menuBar.flatMap { $0.items }.first { $0.accessibilityIdentifier == "file-close-tab" }?.isEnabled == true)
        window.typeKey("w", modifierFlags: .command)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(closed == 1)
        #expect(rig.workspace.tabs == tabs)
    }
}
