import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The menus and hidden global keys are generated from the command registry; these tests pin them to what they were
/// before (titles, order, ids, shortcuts, enabled rules) and check the key overrides resolve into them.
@MainActor @Suite struct CommandParityTests {
    private func chord(_ s: String) -> KeyChord { KeyChord.parse(s)! }

    private func allItems(_ window: TestWindow) -> [PlatformMenuItem] {
        func flatten(_ items: [PlatformMenuItem]) -> [PlatformMenuItem] {
            items.flatMap { item -> [PlatformMenuItem] in
                if case .submenu(let sub) = item.kind { return flatten(sub) }
                return [item]
            }
        }
        return window.testApp.menuBar.flatMap { flatten($0.items) }
    }

    private func menuItem(_ window: TestWindow, _ id: String) -> PlatformMenuItem? {
        allItems(window).first { $0.accessibilityIdentifier == id }
    }

    private func platformShortcut(_ chord: KeyChord) -> PlatformKeyEquivalent {
        let s = chord.shortcut
        return PlatformKeyEquivalent(key: String(s.key.character).lowercased(), modifiers: s.modifiers)
    }

    @Test func menuItemsMatchRegistry() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        let menuBound = registry.commands.filter { $0.descriptor.menu != nil }
        for command in menuBound {
            let d = command.descriptor
            let item = try #require(menuItem(window, d.menuID), "no menu item for \(d.id)")
            #expect(item.title == d.title)
            #expect(item.shortcut == d.shortcut.map(platformShortcut), "\(d.id)")
        }
        // Today's order: the Go menu, then the View menu.
        let go = try #require(window.testApp.menuBar.first { $0.title == "Go" })
        #expect(go.items.map(\.title) == ["Go to Definition", "Go to Symbol…", "Find References", "Next Result", "Previous Result"])
        let gitMenu = try #require(window.testApp.menuBar.first { $0.title == "Git" })
        #expect(gitMenu.items.map(\.title) == [
            "Compare with HEAD", "Stage File", "Unstage File", "Commit…", "Switch Branch…", "Blame Line",
            "Toggle File Blame", "Next Change", "Previous Change", "Refresh",
        ])
        #expect(gitMenu.items.allSatisfy { $0.shortcut == nil })
        let edit = window.testApp.menuBar.first { $0.title == "Edit" }
        #expect(edit?.items.dropLast().map(\.title).suffix(12) == [
            "Rename Symbol", "Format Document", "Format Selection", "Show Hover", "Trigger Completion", "Signature Help", "Quick Fix",
            "Add Next Occurrence", "Select All Occurrences", "Skip to Next Occurrence", "Add Caret Above", "Add Caret Below",
        ])
        #expect(edit?.items.dropLast().suffix(5).compactMap(\.accessibilityIdentifier) == [
            "cmd-editor.addNextOccurrence", "cmd-editor.selectAllOccurrences", "cmd-editor.skipNextOccurrence",
            "cmd-editor.addCaretAbove", "cmd-editor.addCaretBelow",
        ])
        // macOS reserves alt+cmd+d (Show or Hide the Dock), so Skip to Next Occurrence has no default there.
        #if os(macOS)
        let skipShortcut: PlatformKeyEquivalent? = nil
        #else
        let skipShortcut: PlatformKeyEquivalent? = PlatformKeyEquivalent(key: "d", modifiers: [.option, .command])
        #endif
        #expect(edit?.items.dropLast().suffix(5).map(\.shortcut) == [
            PlatformKeyEquivalent(key: "d", modifiers: [.command]),
            PlatformKeyEquivalent(key: "l", modifiers: [.command, .shift]),
            skipShortcut,
            PlatformKeyEquivalent(key: "\u{f700}", modifiers: [.control, .shift]),
            PlatformKeyEquivalent(key: "\u{f701}", modifiers: [.control, .shift]),
        ])
        let view = try #require(window.testApp.menuBar.first { $0.title == "View" })
        #expect(view.items.map(\.title) == [
            "Chat Mode", "Code Mode", "Split Right", "Split Down", "Focus Left Group", "Focus Right Group",
            "Focus Up Group", "Focus Down Group", "Reveal in Tree", "Toggle Chat Column",
            "Toggle Terminal", "New Terminal", "Command Palette…", "Folding",
        ])
        #expect(view.items.compactMap(\.accessibilityIdentifier) == [
            "view-mode-chat", "view-mode-code", "view-split-right", "view-split-down", "view-focus-left",
            "view-focus-right", "view-focus-up", "view-focus-down", "view-reveal-in-tree", "view-toggle-chat-column",
            "view-toggle-terminal", "view-new-terminal", "view-command-palette",
        ])
        #expect(menuItem(window, "app-settings")?.shortcut == PlatformKeyEquivalent(key: ",", modifiers: [.command]))
        #expect(menuItem(window, "view-split-down")?.shortcut == PlatformKeyEquivalent(key: "\\", modifiers: [.option, .command]))
        // No menu item carries a global command, and no global command is in a menu.
        #expect(registry.commands.filter { $0.descriptor.menu == nil }.allSatisfy { $0.descriptor.binding != .menu })
    }

    @Test func menuItemsMatchRegistryInTheChooser() throws {
        let model = LauncherModel()
        let window = try TestWindow(size: Size(width: Pixels(900), height: Pixels(600))) { launcherRoot(model: model, center: testCenter(for: model)) }
        window.installAlloyMenu(model: model)
        window.tick()
        let registry = testCenter(for: model).registry
        for command in registry.commands where command.descriptor.menu != nil {
            let item = try #require(menuItem(window, command.descriptor.menuID))
            #expect(item.title == command.descriptor.title)
            // Close Tab and Close Window close the chooser's window (File > Close was MetalUI's, and is replaced).
            let closesChooser = ["tab.close", "window.close"].contains(command.descriptor.id)
            #expect(item.isEnabled == closesChooser, "\(command.descriptor.id) needs a workspace")
        }
    }

    @Test func globalKeysRunThroughRegistry() async throws {
        let rig = Rig()
        for name in ["a.txt", "b.txt"] { try "x\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        await rig.workspace.open("a.txt")
        await rig.workspace.open("b.txt")
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        window.typeKey("1", modifierFlags: .command)
        #expect(rig.workspace.activeTab == "a.txt")
        window.typeKey("2", modifierFlags: .command)
        #expect(rig.workspace.activeTab == "b.txt")
        window.typeKey(.tab, modifierFlags: .control)
        #expect(rig.workspace.activeTab == "a.txt")
        window.typeKey(.tab, modifierFlags: [.control, .shift])
        #expect(rig.workspace.activeTab == "b.txt")
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "quick-open-field")) != nil }
        #expect(rig.workspace.recentCommands.first == "go.quickOpen")
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "quick-open-field")) == nil }
        window.typeKey("w", modifierFlags: .command)
        try await window.runUntil { rig.workspace.tabs == ["a.txt"] }
        // ⌘N is the sidebar button's in Chat mode and a global key in Code mode; either way the registry command runs.
        rig.workspace.setMode(.code)
        window.tick()
        let before = rig.workspace.sessions.count
        window.typeKey("n", modifierFlags: .command)
        try await window.runUntil { rig.workspace.sessions.count > before }
        #expect(rig.workspace.recentCommands.contains("session.new"))
        #expect(registry.command(id: "session.new") != nil)
    }

    @Test func globalKeyCountsUnchanged() async throws {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        // Every chord with a menu item is delivered by the item: only the terminal's four commands keep a hidden key, so
        // the frame carries four elements for them, not eighteen.
        #expect(registry.commands.filter { $0.descriptor.binding == .global }.count == 4)
        #expect(!registry.commands.contains { $0.descriptor.binding == .globalInCode })
        let window = try alloyWindow(rig.workspace)
        // The buttons are hidden from the element tree, so the registry is the record; the keys still work (see
        // globalKeysRunThroughRegistry).
        window.tick()
        #expect(registry.commands.filter { $0.descriptor.binding == .global }.map(\.descriptor.keyID).contains("global-key-terminal-copy"))
    }

    @Test func disabledCommandNeverRuns() async throws {
        let rig = Rig()
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "quick-open-field")) != nil }
        #expect(!registry.run(id: "tab.close"))
        #expect(rig.workspace.tabs == ["a.txt"])
        window.typeKey(.escape)
        // Split Right needs Code mode.
        #expect(rig.workspace.mode == .chat)
        #expect(menuItem(window, "view-split-right")?.isEnabled == false)
        let groups = rig.workspace.codeLayout.groups.count
        window.typeKey("\\", modifierFlags: .command)
        #expect(!registry.run(id: "view.splitRight"))
        #expect(rig.workspace.codeLayout.groups.count == groups)
        #expect(!rig.workspace.recentCommands.contains("view.splitRight"))
    }

    @Test func overrideRebindsMenuAndKey() async throws {
        let rig = Rig()
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        var s = rig.workspace.settings
        s.keybindings = ["view.splitRight": "primary+shift+d"]
        try rig.workspace.updateSettings(s)
        window.tick(); window.tick()
        #expect(menuItem(window, "view-split-right")?.shortcut == PlatformKeyEquivalent(key: "d", modifiers: [.command, .shift]))
        let groupsBefore = rig.workspace.codeLayout.groups.count
        window.typeKey("\\", modifierFlags: .command)
        #expect(rig.workspace.codeLayout.groups.count == groupsBefore)
        window.typeKey("d", modifierFlags: [.command, .shift])
        #expect(rig.workspace.codeLayout.groups.count == groupsBefore + 1)
        #expect(registry.keymap.chord(for: "view.splitRight") == chord("primary+shift+d"))
    }

    @Test func noneUnbindsAMenuItemAndAGlobalKey() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        var s = rig.workspace.settings
        s.keybindings = ["view.codeMode": "none", "tab.next": "none"]
        try rig.workspace.updateSettings(s)
        window.tick(); window.tick()
        // The unbound global key no longer fires; the command itself is still registered.
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: rig.root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        await rig.workspace.open("b.txt")
        window.typeKey(.tab, modifierFlags: .control)
        #expect(rig.workspace.activeTab == "b.txt")
        #expect(testCenter(for: rig.workspace).registry.command(id: "tab.next") != nil)
        let item = try #require(menuItem(window, "view-mode-code"))
        #expect(item.shortcut == nil)
        #expect(item.isEnabled)
        #expect(testCenter(for: rig.workspace).registry.keymap.chord(for: "tab.next") == nil)
    }

    @Test func unknownIDAndMalformedChordChangeNothing() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        var s = rig.workspace.settings
        s.keybindings = ["no.such.command": "primary+q", "view.splitDown": "not a chord"]
        try rig.workspace.updateSettings(s)
        window.tick(); window.tick()
        #expect(registry.keymap.chord(for: "view.splitDown") == chord("alt+cmd+\\"))
        #expect(registry.keymap.chord(for: "no.such.command") == nil)
        #expect(menuItem(window, "view-split-down")?.shortcut == PlatformKeyEquivalent(key: "\\", modifiers: [.option, .command]))
        #expect(rig.workspace.settings.keybindings.count == 2)
    }

    @Test func failedSaveLeavesTheKeymapUnchanged() async throws {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        // Support dir is a plain file, so the save cannot succeed.
        try "x".write(to: rig.appSupport, atomically: true, encoding: .utf8)
        var s = rig.workspace.settings
        s.keybindings = ["view.splitRight": "primary+shift+d"]
        #expect(throws: (any Error).self) { try rig.workspace.updateSettings(s) }
        #expect(registry.keymap.chord(for: "view.splitRight") == chord("cmd+\\"))
        #expect(rig.workspace.settings.keybindings.isEmpty)
    }
}
