@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The command palette (⇧⌘P): open and close, ranking, running, disabled rows, recents and the quick-open exclusion.
@MainActor
@Suite struct CommandPaletteTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func open(_ window: TestWindow) async throws {
        window.typeKey("p", modifierFlags: [.command, .shift])
        try await window.runUntil { self.exists(window, "command-palette-field") }
    }

    private func rowText(_ window: TestWindow, _ i: Int) -> String? {
        guard let row = try? window.element(identifier: "command-palette-row-\(i)") else { return nil }
        return descendants(of: row, in: window).compactMap { $0.value ?? $0.label }.first
    }

    private func codeRig() async throws -> (Rig, TestWindow) {
        let rig = Rig()
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        await rig.workspace.open("a.txt")
        let window = try alloyWindow(rig.workspace)
        return (rig, window)
    }

    @Test func opensInChatAndCodeModeAndTogglesClosed() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        #expect(exists(window, "command-palette"))
        window.typeKey("p", modifierFlags: [.command, .shift])
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        rig.workspace.setMode(.code)
        window.tick(); window.tick()
        try await open(window)
        window.typeKey("p", modifierFlags: [.command, .shift])
        try await window.runUntil { !self.exists(window, "command-palette-field") }
    }

    @Test func doesNothingInTheChooser() throws {
        let model = LauncherModel()
        let window = try TestWindow(size: Size(width: Pixels(900), height: Pixels(600))) { launcherRoot(model: model, center: testCenter(for: model)) }
        window.installAlloyMenu(model: model)
        window.tick()
        window.typeKey("p", modifierFlags: [.command, .shift])
        window.tick()
        #expect(!exists(window, "command-palette"))
        let item = window.testApp.menuBar.flatMap { $0.items }.first { $0.accessibilityIdentifier == "view-command-palette" }
        #expect(item?.isEnabled == false)
    }

    @Test func doesNotOpenDuringCompositionInATextField() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "composer") }
        try window.click(window.element(identifier: "composer"))
        #expect(window.setMarkedText("に"))
        window.typeKey("p", modifierFlags: [.command, .shift])
        window.tick()
        #expect(!exists(window, "command-palette"))
    }

    @Test func querySelectsAndReturnRuns() async throws {
        let (rig, window) = try await codeRig()
        try await open(window)
        window.typeText("spl r")
        try await window.runUntil { self.rowText(window, 0) == "View: Split Right" }
        let groups = rig.workspace.codeLayout.groups.count
        window.typeKey(.return)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        #expect(rig.workspace.codeLayout.groups.count == groups + 1)
        #expect(rig.workspace.recentCommands.first == "view.splitRight")
    }

    @Test func escapeCloses() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeKey(.escape)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
    }

    /// Also covers clicks on the rest of the window: the layer frame has no handlers, so the click reaches the element and focus loss closes.
    @Test func focusLossCloses() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "composer") }
        try await open(window)
        try window.click(window.element(identifier: "composer"))
        try await window.runUntil { !self.exists(window, "command-palette-field") }
    }

    private func shortcutText(_ window: TestWindow, _ i: Int) -> String? {
        guard let e = try? window.element(identifier: "command-palette-row-\(i)-shortcut") else { return nil }
        return e.value ?? e.label
    }

    /// Opens the palette on `query` and returns the shortcut text of the first row (which must be `title`).
    private func firstRowShortcut(_ window: TestWindow, query: String, title: String) async throws -> String? {
        try await open(window)
        window.typeText(query)
        try await window.runUntil { self.rowText(window, 0) == title }
        return shortcutText(window, 0)
    }

    @Test func rowsShowTheShortcutInTheMacForm() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect(try await firstRowShortcut(window, query: "Command Palette", title: "View: Command Palette…") == "⇧⌘P")
        #expect(try shortcutTexts(window, "Add Next Occurrence", "Selection: Add Next Occurrence") == "⌘D")
        #expect(try shortcutTexts(window, "Next Result", "Go: Next Result") == "F4")
        #expect(try shortcutTexts(window, "Toggle Terminal", "View: Toggle Terminal") == "⌃`")
    }

    /// Replaces the query of the open palette.
    private func shortcutTexts(_ window: TestWindow, _ query: String, _ title: String) throws -> String? {
        window.typeKey("a", modifierFlags: .command)
        window.typeText(query)
        for _ in 0..<20 where rowText(window, 0) != title { window.tick() }
        #expect(rowText(window, 0) == title)
        return shortcutText(window, 0)
    }

    @Test func linuxAndWindowsFormsComeFromMetalUI() {
        let palette = KeyChord.parse("primary+shift+p")!
        #expect(CommandPaletteModel.shortcutText(for: palette, platform: .macOS) == "⇧⌘P")
        #expect(CommandPaletteModel.shortcutText(for: palette, platform: .linux) == "Ctrl+Shift+P")
        #expect(CommandPaletteModel.shortcutText(for: palette, platform: .windows) == "Ctrl+Shift+P")
        let f4 = KeyChord(modifiers: [], key: .named(.f4))
        #expect(CommandPaletteModel.shortcutText(for: f4, platform: .macOS) == "F4")
        #expect(CommandPaletteModel.shortcutText(for: f4, platform: .linux) == "F4")
        let ctrlTick = KeyChord(modifiers: .ctrl, key: .character("`"))
        #expect(CommandPaletteModel.shortcutText(for: ctrlTick, platform: .macOS) == "⌃`")
        #expect(CommandPaletteModel.shortcutText(for: ctrlTick, platform: .windows) == "Ctrl+`")
        let cmdD = KeyChord(modifiers: .cmd, key: .character("d"))
        #expect(CommandPaletteModel.shortcutText(for: cmdD, platform: .macOS) == "⌘D")
        #expect(CommandPaletteModel.shortcutText(for: cmdD, platform: .linux) == "Super+D")
        #expect(CommandPaletteModel.shortcutText(for: cmdD, platform: .windows) == "Win+D")
    }

    @Test func anOverriddenBindingShowsTheOverrideAndAnUnboundOneNothing() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        var s = rig.workspace.settings
        s.keybindings = ["view.splitRight": "primary+shift+d", "terminal.toggle": "none"]
        try rig.workspace.updateSettings(s)
        window.tick(); window.tick()
        #expect(try await firstRowShortcut(window, query: "Split Right", title: "View: Split Right") == "⇧⌘D")
        #expect(try shortcutTexts(window, "Toggle Terminal", "View: Toggle Terminal") == nil)
    }

    @Test func rowsWithoutAShortcutShowNoneAndADisabledRowGreysIt() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect(try await firstRowShortcut(window, query: "Compare with HEAD", title: "Git: Compare with HEAD") == nil)
        #expect(try shortcutTexts(window, "Split Right", "View: Split Right") == "⌘\\")
        #expect(try window.element(identifier: "command-palette-row-0").value == "unavailable")
    }

    @Test func disabledRowIsMutedAndReturnOnlyCloses() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeText("split right")
        try await window.runUntil { self.rowText(window, 0) == "View: Split Right" }
        let row = try window.element(identifier: "command-palette-row-0")
        #expect(row.value == "unavailable")
        let groups = rig.workspace.codeLayout.groups.count
        window.typeKey(.return)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        #expect(rig.workspace.codeLayout.groups.count == groups)
        #expect(!rig.workspace.recentCommands.contains("view.splitRight"))
    }

    @Test func settingOffHidesDisabledButNeverEnabledCommands() async throws {
        let rig = Rig()
        var s = rig.workspace.settings
        s.paletteShowsDisabled = false
        try rig.workspace.updateSettings(s)
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeText("split right")
        try await window.runUntil { self.exists(window, "command-palette-empty") || self.rowText(window, 0) != nil }
        #expect(self.rowText(window, 0) != "View: Split Right", "Split Right is unavailable in Chat mode")
        window.typeKey(.escape)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        try await open(window)
        window.typeText("code mode")
        try await window.runUntil { self.rowText(window, 0) == "View: Code Mode" }
        let row = try window.element(identifier: "command-palette-row-0")
        #expect(row.value != "unavailable")
    }

    @Test func emptyQueryListsRecentsFirstUnderAHeading() async throws {
        let rig = Rig()
        rig.workspace.noteCommandRun(id: "view.codeMode")
        rig.workspace.noteCommandRun(id: "no.such.command")
        rig.workspace.noteCommandRun(id: "view.chatMode")
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        #expect(exists(window, "command-palette-recent-header"))
        #expect(rowText(window, 0) == "View: Chat Mode")
        #expect(rowText(window, 1) == "View: Code Mode")
        // The unknown id is skipped, not shown.
        #expect(rowText(window, 2) != nil && rowText(window, 2) != "no.such.command")
    }

    @Test func clearingTheQueryRestoresRecentOrder() async throws {
        let rig = Rig()
        rig.workspace.noteCommandRun(id: "view.codeMode")
        rig.workspace.noteCommandRun(id: "view.chatMode")
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        #expect(rowText(window, 0) == "View: Chat Mode")
        window.typeText("z")
        try await window.runUntil { self.rowText(window, 0) != "View: Chat Mode" }
        window.typeKey(.delete)
        try await window.runUntil { self.rowText(window, 0) == "View: Chat Mode" }
        #expect(rowText(window, 1) == "View: Code Mode")
    }

    @Test func emptyQueryWithNoRecentsHasNoHeading() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        #expect(!exists(window, "command-palette-recent-header"))
        #expect(exists(window, "command-palette-row-0"))
    }

    @Test func noMatchShowsTheEmptyState() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeText("zzzzqq")
        try await window.runUntil { self.exists(window, "command-palette-empty") }
        #expect(!exists(window, "command-palette-row-0"))
        window.typeKey(.return)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
    }

    @Test func oddQueriesDoNotCrash() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeText("日本語 é")
        window.tick()
        window.typeText(String(repeating: "split ", count: 84))
        window.tick()
        #expect(exists(window, "command-palette-field"))
    }

    @Test func paletteAndQuickOpenExcludeEachOther() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { self.exists(window, "quick-open-field") && !self.exists(window, "command-palette-field") }
        try await open(window)
        #expect(!exists(window, "quick-open-field"))
    }

    @Test func commandWDoesNotCloseATabWhileOpen() async throws {
        let rig = Rig()
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeKey("w", modifierFlags: .command)
        window.tick()
        #expect(rig.workspace.tabs == ["a.txt"])
    }

    @Test func aCommandUnregisteredWhileOpenDoesNothing() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        var ran = false
        let source = CommandSource.plugin(id: "tmp")
        registry.register(CommandDescriptor(id: "plugin.tmp", title: "Zebra Thing", category: CommandCategory(name: "Tmp"), source: source),
                          run: { ran = true })
        try await open(window)
        window.typeText("zebra")
        try await window.runUntil { self.rowText(window, 0) == "Tmp: Zebra Thing" }
        registry.unregister(source: source)
        window.typeKey(.return)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        #expect(!ran)
    }

    @Test func tabCyclingRecordsNoRecentAndWritesNothing() async throws {
        let rig = Rig()
        for n in ["a.txt", "b.txt"] { try "x\n".write(to: rig.root.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        await rig.workspace.open("a.txt")
        await rig.workspace.open("b.txt")
        let window = try alloyWindow(rig.workspace)
        let writes = rig.workspace.uiStateWriteCount
        for _ in 0..<20 { window.typeKey(.tab, modifierFlags: .control) }
        #expect(rig.workspace.recentCommands.isEmpty)
        #expect(rig.workspace.uiStateWriteCount == writes)
    }

    @Test func aRecordingCommandRecordsOncePerRunFromEverySource() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        // Key.
        window.typeKey("2", modifierFlags: [.control, .command])
        #expect(rig.workspace.recentCommands == ["view.codeMode"])
        // Menu.
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-mode-chat")
        #expect(rig.workspace.recentCommands == ["view.chatMode", "view.codeMode"])
        // Palette.
        try await open(window)
        window.typeText("code mode")
        try await window.runUntil { self.rowText(window, 0) == "View: Code Mode" }
        window.typeKey(.return)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        #expect(rig.workspace.recentCommands == ["view.codeMode", "view.chatMode"])
        // Opening the palette itself records nothing.
        #expect(center.registry.command(id: "view.commandPalette")?.descriptor.recordsRecent == false)
    }

    @Test func arrowsMoveOverEveryRowAndClickRuns() async throws {
        let (rig, window) = try await codeRig()
        try await open(window)
        window.typeText("split")
        try await window.runUntil { self.rowText(window, 1) != nil }
        window.typeKey(.downArrow)
        window.typeKey(.upArrow)
        try window.click(window.element(identifier: "command-palette-row-0"))
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        #expect(rig.workspace.codeLayout.groups.count == 2)
    }
}
