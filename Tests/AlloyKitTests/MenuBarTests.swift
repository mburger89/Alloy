import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import MetalUIPlatform
import Testing

/// The File, Edit > Find and Window menus generated from the command registry.
@MainActor @Suite struct MenuBarTests {
    private func menu(_ window: TestWindow, _ title: String) throws -> PlatformMenu {
        try #require(window.testApp.menuBar.first { $0.title == title }, "no \(title) menu")
    }

    private func titles(_ items: [PlatformMenuItem]) -> [String] { items.filter { $0.kind != .separator }.map(\.title) }

    private func submenu(_ items: [PlatformMenuItem], _ title: String) throws -> [PlatformMenuItem] {
        let item = try #require(items.first { $0.title == title }, "no \(title) submenu")
        guard case .submenu(let children) = item.kind else { Issue.record("\(title) is not a submenu"); return [] }
        return children
    }

    private func key(_ s: String, _ modifiers: Modifiers) -> PlatformKeyEquivalent {
        PlatformKeyEquivalent(key: s, modifiers: modifiers)
    }

    @Test func fileMenuListsNewSessionNewTerminalTabAndQuickOpen() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let items = try menu(window, "File").items
        let wanted = ["New Session", "New Terminal Tab", "Quick Open"]
        let found = items.filter { wanted.contains($0.title) }
        #expect(found.map(\.title) == wanted, "\(titles(items))")
        #expect(found.map(\.shortcut) == [key("n", [.command]), key("t", [.command]), key("p", [.command])])
    }

    @Test func windowMenuListsTabCommandsWithChords() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let items = try menu(window, "Window").items
        let wanted = ["Next Tab", "Previous Tab"] + (1...9).map { "Go to Tab \($0)" }
        let found = items.filter { wanted.contains($0.title) }
        #expect(found.map(\.title) == wanted, "\(titles(items))")
        #expect(found[0].shortcut?.modifiers == [.control] && found[1].shortcut?.modifiers == [.control, .shift])
        #expect(found.dropFirst(2).map(\.shortcut) == (1...9).map { key(String($0), [.command]) })
        // After MetalUI's own window items, never before them.
        let index = try #require(items.firstIndex { $0.title == "Next Tab" })
        #expect(index > 0)
    }

    @Test func findInFilesAndReplaceMovedFromViewToEditFind() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let view = try menu(window, "View").items
        #expect(!titles(view).contains("Find in Files") && !titles(view).contains("Replace in Files"))
        let find = try submenu(try menu(window, "Edit").items, "Find")
        let found = find.filter { ["Find in Files", "Replace in Files"].contains($0.title) }
        #expect(found.map(\.title) == ["Find in Files", "Replace in Files"], "\(titles(find))")
        #expect(found.map(\.shortcut) == [key("f", [.command, .shift]), key("h", [.command, .shift])])
        #expect(found.allSatisfy { $0.isEnabled })
    }

    @Test func movedCommandsHaveNoHiddenGlobalKey() async throws {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        let moved = ["session.new", "tab.new", "go.quickOpen", "tab.next", "tab.previous"] + (1...9).map { "tab.select\($0)" }
        let hidden = Set(registry.commands.filter { $0.descriptor.binding == .global || $0.descriptor.binding == .globalInCode }
            .map(\.descriptor.id))
        for id in moved {
            let command = try #require(registry.command(id: id), "\(id)")
            #expect(command.descriptor.binding == .menu, "\(id)")
            #expect(command.descriptor.menu != nil, "\(id)")
            #expect(!hidden.contains(id), "\(id) still has a hidden key (\(command.descriptor.keyID))")
        }
        // Only the terminal's own commands keep a hidden key.
        #expect(hidden.isSubset(of: ["terminal.copy", "terminal.selectAll", "terminal.find", "terminal.clearScrollback"]),
                "\(hidden)")
    }

    @Test func cmdNInChatModeMakesOneSession() async throws {
        let rig = Rig()
        #expect(rig.workspace.mode == .chat)
        let window = try alloyWindow(rig.workspace)
        let before = rig.workspace.sessions.count
        window.typeKey("n", modifierFlags: .command)
        try await window.runUntil { rig.workspace.sessions.count > before }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(rig.workspace.sessions.count == before + 1)
        // The sidebar's + button still works, and has no shortcut of its own.
        try window.click(window.element(identifier: "new-session"))
        try await window.runUntil { rig.workspace.sessions.count > before + 1 }
        #expect(rig.workspace.sessions.count == before + 2)
    }

    @Test func ctrlTabInFocusedTerminalCyclesTerminalTabs() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace)
        let window = try alloyWindow(rig.workspace, terminal: store)
        store.toggle(); store.newTab(); store.newTab()
        for _ in 0..<3 { window.tick() }
        let ids = rig.workspace.terminalLayout.tabs.map(\.id)
        store.hasFocus = true
        #expect(rig.workspace.terminalLayout.activeTab == ids[2])
        window.typeKey(.tab, modifierFlags: .control)
        #expect(rig.workspace.terminalLayout.activeTab == ids[0], "wraps forward")
        window.typeKey(.tab, modifierFlags: [.control, .shift])
        #expect(rig.workspace.terminalLayout.activeTab == ids[2], "wraps backward")
        withExtendedLifetime(window) {}
    }

    @Test func noNewShortcutClashes() async throws {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        #expect(registry.keymap.conflicts.isEmpty, "\(registry.keymap.conflicts)")
        for command in registry.commands {
            if command.descriptor.shortcut != nil {
                #expect(registry.keymap.chord(for: command.descriptor.id) != nil, "\(command.descriptor.id) lost its chord")
            }
        }
        #expect(registry.rejections.isEmpty)
    }
}
