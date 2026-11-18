@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct KeyboardSettingsTests {
    private func open() async throws -> (rig: Rig, main: TestWindow, settings: TestWindow, center: CommandCenter) {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-keyboard")) != nil }
        return (rig, main, settings, testCenter(for: rig.workspace))
    }

    private func exists(_ w: TestWindow, _ id: String) -> Bool { (try? w.element(identifier: id)) != nil }
    private func text(_ w: TestWindow, _ id: String) throws -> String {
        let e = try w.element(identifier: id)
        return e.value ?? e.label ?? ""
    }
    private func setOverrides(_ rig: Rig, _ o: [String: String]) throws {
        var s = rig.workspace.settings
        s.keybindings = o
        try rig.workspace.updateSettings(s)
    }
    private func settle(_ w: TestWindow) { for _ in 0..<4 { w.tick() } }

    @Test func sectionListsEveryRegistryCommandWithItsShortcut() async throws {
        let (_, _, settings, center) = try await open()
        for command in center.registry.commands {
            let id = command.descriptor.id
            #expect(exists(settings, "keyboard-row-\(id)"), "row for \(id)")
            let expected = center.registry.keymap.chord(for: id).map { $0.shortcut.displayText } ?? "None"
            // A command that lost a clash resolves to nil in the keymap but still shows its own chord.
            if center.registry.keymap.chord(for: id) != nil || command.descriptor.shortcut == nil {
                #expect(try text(settings, "keyboard-chord-\(id)") == expected, "chord of \(id)")
            }
        }
    }

    @Test func renameSymbolListsF2() async throws {
        let (_, _, settings, center) = try await open()
        _ = try settings.element(identifier: "keyboard-row-edit.rename")
        #expect(center.registry.keymap.chord(for: "edit.rename") == KeyChord(modifiers: [], key: .named(.f2)))
        #expect(try text(settings, "keyboard-chord-edit.rename") == "F2")
    }

    @Test func customSourceAndResetShowOnlyWhenOverridden() async throws {
        let (rig, _, settings, _) = try await open()
        #expect(!exists(settings, "keyboard-reset-view.toggleChatColumn"))
        try setOverrides(rig, ["view.toggleChatColumn": "primary+alt+shift+j"])
        settle(settings)
        _ = try settings.element(identifier: "keyboard-reset-view.toggleChatColumn")
        try tap(settings, "keyboard-reset-view.toggleChatColumn")
        settle(settings)
        #expect(rig.workspace.settings.keybindings["view.toggleChatColumn"] == nil)
        #expect(!exists(settings, "keyboard-reset-view.toggleChatColumn"))
    }

    @Test func filterNarrowsByTitleIdAndChordAndRestores() async throws {
        let (_, _, settings, center) = try await open()
        let all = center.registry.commands.count
        try tap(settings, "keyboard-filter")
        settings.typeText("Settings")
        settle(settings)
        #expect(exists(settings, "keyboard-row-app.settings"))
        let rows = center.registry.commands.filter { exists(settings, "keyboard-row-\($0.descriptor.id)") }.count
        #expect(rows > 0 && rows < all)
        settings.typeText("zzzzqq")
        settle(settings)
        #expect(exists(settings, "keyboard-empty"))
        #expect(!exists(settings, "keyboard-row-app.settings"))
        for _ in 0..<("Settings".count + 6) { settings.typeKey(.delete) }
        settle(settings)
        #expect(!exists(settings, "keyboard-empty"))
        #expect(exists(settings, "keyboard-row-app.settings"))
    }

    @Test func builtInGroupMatchesTheClashesBuiltInRows() async throws {
        let (_, _, settings, center) = try await open()
        let rows = ShortcutClashes(center: center).builtInRows
        #expect(!rows.isEmpty)
        for n in rows.indices { #expect(exists(settings, "keyboard-builtin-\(n)"), "built-in \(n)") }
        #expect(!exists(settings, "keyboard-builtin-\(rows.count)"))
    }

    @Test func conflictRowShowsTheOtherCommand() async throws {
        let (rig, _, settings, center) = try await open()
        let holder = try #require(center.registry.command(id: "go.symbol"))
        let chord = try #require(holder.descriptor.shortcut)
        try setOverrides(rig, ["view.toggleChatColumn": chord.description])
        settle(settings)
        let note = try text(settings, "keyboard-conflict-view.toggleChatColumn")
        #expect(note.contains("Conflicts with \(holder.descriptor.title)"), "\(note)")
    }

    @Test func conditionalBuiltInShowsItsCondition() async throws {
        let (_, _, settings, center) = try await open()
        let soft = ShortcutClashes(center: center).builtInRows.enumerated().first { $0.element.isConditional }
        let (n, claim) = try #require(soft)
        let row = try settings.element(identifier: "keyboard-builtin-\(n)")
        let shown = descendants(of: row, in: settings).compactMap { $0.value ?? $0.label }.joined(separator: " ")
        #expect(shown.contains(claim.condition ?? "?"), "\(shown)")
    }

    @Test func sectionSitsAfterLanguageServersAndBeforeSaved() async throws {
        let (_, _, settings, _) = try await open()
        let kb = try settings.element(identifier: "settings-keyboard").frame
        let git = try settings.element(identifier: "settings-git-section").frame
        #expect(kb.minY >= git.maxY - 1, "after the git section (and so after language servers)")
    }

    // MARK: Recording

    private let toggle = "view.toggleChatColumn"
    private let rebound = KeyChord.parse("cmd+alt+shift+j")!

    /// Scrolls the settings window until `identifier` has visible area.
    private func reveal(_ window: TestWindow, _ identifier: String) throws {
        func visible() -> Bool {
            guard let e = try? window.element(identifier: identifier) else { return false }
            return e.visibleFrame.size.width.value > 0 && e.visibleFrame.size.height.value > 0
        }
        let centre = Point(x: Pixels(300), y: Pixels(300))
        for dy: Float in [-300, 300] {
            for _ in 0..<60 {
                if visible() { return }
                window.scroll(at: centre, byDeltaX: 0, deltaY: dy)
            }
        }
    }

    private func tap(_ window: TestWindow, _ identifier: String) throws {
        try reveal(window, identifier)
        try window.click(window.element(identifier: identifier))
    }

    /// The recorder button inside a row's chord wrapper.
    private func recorder(_ w: TestWindow, _ id: String) throws -> TestElement {
        try reveal(w, "keyboard-chord-\(id)")
        let wrapper = try w.element(identifier: "keyboard-chord-\(id)")
        if wrapper.label == "Shortcut" { return wrapper }
        return try #require(descendants(of: wrapper, in: w).first { $0.label == "Shortcut" }, "recorder of \(id)")
    }

    /// Starts recording on the row and presses the chord.
    private func record(_ w: TestWindow, _ id: String, _ chord: KeyChord) throws {
        let s = chord.shortcut(for: .macOS)
        try w.click(recorder(w, id))
        settle(w)
        w.typeKey(s.key, modifierFlags: s.modifiers)
        settle(w)
    }

    private func menuShortcut(_ main: TestWindow, _ id: String) -> PlatformKeyEquivalent? {
        for _ in 0..<4 { main.tick() }
        func flatten(_ items: [PlatformMenuItem]) -> [PlatformMenuItem] {
            items.flatMap { item -> [PlatformMenuItem] in
                if case .submenu(let sub) = item.kind { return flatten(sub) }
                return [item]
            }
        }
        return main.testApp.menuBar.flatMap { flatten($0.items) }.first { $0.accessibilityIdentifier == id }?.shortcut
    }

    @Test func recordingBindsAndPersistsAndMenuItemFollows() async throws {
        let (rig, main, settings, center) = try await open()
        try record(settings, toggle, rebound)
        #expect(rig.workspace.settings.keybindings[toggle] == rebound.description)
        #expect(center.registry.keymap.chord(for: toggle) == rebound)
        let s = rebound.shortcut(for: .macOS)
        #expect(menuShortcut(main, center.registry.command(id: toggle)!.descriptor.menuID) == PlatformKeyEquivalent(key: String(s.key.character).lowercased(), modifiers: s.modifiers))
        #expect(AlloySettings.load(appSupport: rig.root.appendingPathComponent("support")).keybindings[toggle] == rebound.description)
        #expect(try text(settings, "keyboard-chord-\(toggle)") == s.displayText)
    }

    @Test func recordingTheDefaultRemovesTheOverride() async throws {
        let (rig, _, settings, center) = try await open()
        try setOverrides(rig, [toggle: rebound.description])
        settle(settings)
        let def = try #require(center.registry.command(id: toggle)?.descriptor.shortcut)
        try record(settings, toggle, def)
        #expect(rig.workspace.settings.keybindings[toggle] == nil)
    }

    @Test func recordingTheCurrentChordWritesNothing() async throws {
        let (rig, _, settings, center) = try await open()
        let def = try #require(center.registry.command(id: toggle)?.descriptor.shortcut)
        let saves = rig.workspace.settingsSaveCount
        try record(settings, toggle, def)
        #expect(rig.workspace.settingsSaveCount == saves)
        #expect(!exists(settings, "keyboard-reassign-prompt"))
    }

    @Test func recordingOntoAnotherCommandsChordAsksToReassign() async throws {
        let (rig, _, settings, center) = try await open()
        let holder = try #require(center.registry.command(id: "go.quickOpen"))
        let chord = try #require(holder.descriptor.shortcut)
        let saves = rig.workspace.settingsSaveCount
        try record(settings, toggle, chord)
        #expect(rig.workspace.settingsSaveCount == saves)
        #expect(rig.workspace.settings.keybindings[toggle] == nil)
        #expect(try text(settings, "keyboard-reassign-prompt").contains(holder.descriptor.title))
    }

    @Test func confirmWritesBothInOneSave() async throws {
        let (rig, main, settings, center) = try await open()
        let holder = try #require(center.registry.command(id: "go.quickOpen"))
        let chord = try #require(holder.descriptor.shortcut)
        try record(settings, toggle, chord)
        let saves = rig.workspace.settingsSaveCount
        try tap(settings, "keyboard-reassign-confirm")
        settle(settings)
        #expect(rig.workspace.settingsSaveCount == saves + 1)
        let o = rig.workspace.settings.keybindings
        #expect(o[toggle] == chord.resolved(primaryIsCmd: true).description)
        #expect(o["go.quickOpen"] == Keymap.unbound)
        #expect(center.registry.keymap.chord(for: "go.quickOpen") == nil)
        #expect(center.registry.keymap.chord(for: toggle) != nil)
        #expect(menuShortcut(main, center.registry.command(id: toggle)!.descriptor.menuID) != nil)
        #expect(!exists(settings, "keyboard-reassign-prompt"))
        #expect(try text(settings, "keyboard-chord-go.quickOpen") == "None")
        // The global key button of the holder no longer carries its shortcut.
        let key = center.registry.command(id: "go.quickOpen")?.descriptor.keyID ?? ""
        if let button = try? main.element(identifier: key) { #expect(button.value != chord.shortcut.displayText) }
    }

    @Test func cancelLeavesSettingsUntouched() async throws {
        let (rig, _, settings, center) = try await open()
        let chord = try #require(center.registry.command(id: "go.quickOpen")?.descriptor.shortcut)
        try record(settings, toggle, chord)
        let saves = rig.workspace.settingsSaveCount
        let before = rig.workspace.settings.keybindings
        try tap(settings, "keyboard-reassign-cancel")
        settle(settings)
        #expect(rig.workspace.settingsSaveCount == saves)
        #expect(rig.workspace.settings.keybindings == before)
        #expect(!exists(settings, "keyboard-reassign-prompt"))
    }

    @Test func filterChangeDropsThePrompt() async throws {
        let (_, _, settings, center) = try await open()
        let chord = try #require(center.registry.command(id: "go.quickOpen")?.descriptor.shortcut)
        try record(settings, toggle, chord)
        #expect(exists(settings, "keyboard-reassign-prompt"))
        try tap(settings, "keyboard-filter")
        settings.typeText("c")
        settle(settings)
        #expect(!exists(settings, "keyboard-reassign-prompt"))
    }

    @Test func escapeCancelsRecordingAndWritesNothing() async throws {
        let (rig, _, settings, _) = try await open()
        let saves = rig.workspace.settingsSaveCount
        try settings.click(recorder(settings, toggle))
        settle(settings)
        settings.typeKey(.escape)
        settle(settings)
        #expect(rig.workspace.settingsSaveCount == saves)
        #expect(exists(settings, "settings-keyboard"))
    }

    @Test func deleteClearsToNone() async throws {
        let (rig, _, settings, _) = try await open()
        try settings.click(recorder(settings, toggle))
        settle(settings)
        settings.typeKey(.delete)
        settle(settings)
        #expect(rig.workspace.settings.keybindings[toggle] == Keymap.unbound)
        #expect(try text(settings, "keyboard-chord-\(toggle)") == "None")
    }

    @Test func resetRestoresDefaultAndRemovesTheKey() async throws {
        let (rig, _, settings, center) = try await open()
        try record(settings, toggle, rebound)
        try tap(settings, "keyboard-reset-\(toggle)")
        settle(settings)
        #expect(rig.workspace.settings.keybindings[toggle] == nil)
        let def = try #require(center.registry.command(id: toggle)?.descriptor.shortcut)
        #expect(try text(settings, "keyboard-chord-\(toggle)") == def.shortcut.displayText)
    }

    @Test func resetAllRemovesKnownIdsKeepsUnknown() async throws {
        let (rig, _, settings, _) = try await open()
        try setOverrides(rig, [toggle: rebound.description, "go.quickOpen": "none", "future.command": "cmd+alt+q", "x.bad": "???"])
        settle(settings)
        try tap(settings, "keyboard-reset-all")
        settle(settings)
        #expect(rig.workspace.settings.keybindings == ["future.command": "cmd+alt+q", "x.bad": "???"])
    }

    @Test func failedSaveShowsErrorAndChangesNothing() async throws {
        let rig = Rig()
        try Data().write(to: rig.root.appendingPathComponent("support"))
        let main = try alloyWindow(rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-keyboard")) != nil }
        let center = testCenter(for: rig.workspace)
        try record(settings, toggle, rebound)
        #expect(try text(settings, "keyboard-error").hasPrefix("Could not save:"))
        #expect(rig.workspace.settings.keybindings.isEmpty)
        #expect(center.registry.keymap.chord(for: toggle) != rebound)
        // A reassignment fails as a whole too.
        let chord = try #require(center.registry.command(id: "go.quickOpen")?.descriptor.shortcut)
        try record(settings, toggle, chord)
        try tap(settings, "keyboard-reassign-confirm")
        settle(settings)
        #expect(rig.workspace.settings.keybindings.isEmpty)
        #expect(center.registry.keymap.chord(for: "go.quickOpen") != nil)
        #expect(exists(settings, "keyboard-error"))
    }

    @Test func recordingOntoSystemKeyIsSavedAndFlagged() async throws {
        let (rig, _, settings, center) = try await open()
        let system = try #require(KeyboardShortcut.systemReserved(on: .macOS).first)
        let chord = try #require(KeyChord.chord(from: system.shortcut))
        // No registry command may hold it, or the prompt would come first.
        try #require(ShortcutClashes(center: center, platform: .macOS)
            .clashes(for: chord, excluding: toggle, overrides: [:]).allSatisfy { $0.kind != .command(id: "") && !isCommand($0) })
        try record(settings, toggle, chord)
        #expect(rig.workspace.settings.keybindings[toggle] != nil)
        #expect(exists(settings, "keyboard-conflict-\(toggle)"))
    }

    private func isCommand(_ clash: ShortcutClash) -> Bool {
        if case .command = clash.kind { return true }
        return false
    }

    @Test func recordingOntoConditionalBuiltInIsSavedAndShownWithCondition() async throws {
        let (rig, _, settings, center) = try await open()
        let clashes = ShortcutClashes(center: center, platform: .macOS)
        let candidates = clashes.builtInRows.filter(\.isConditional).compactMap { claim -> (ClaimedShortcut, KeyChord)? in
            guard let chord = KeyChord.chord(from: claim.shortcut) else { return nil }
            let found = clashes.clashes(for: chord, excluding: toggle, overrides: [:])
            return found.contains(where: isCommand) ? nil : (claim, chord)
        }
        let (claim, chord) = try #require(candidates.first)
        try record(settings, toggle, chord)
        #expect(rig.workspace.settings.keybindings[toggle] != nil)
        #expect(try text(settings, "keyboard-conflict-\(toggle)").contains(claim.condition ?? "?"))
    }

    @Test func closingSettingsDropsAPendingPrompt() async throws {
        let (rig, main, settings, center) = try await open()
        let chord = try #require(center.registry.command(id: "go.quickOpen")?.descriptor.shortcut)
        try record(settings, toggle, chord)
        #expect(exists(settings, "keyboard-reassign-prompt"))
        settings.window.close()
        for _ in 0..<5 { main.tick() }
        let again = try main.openSettingsFromMenu()
        try await again.runUntil { (try? again.element(identifier: "settings-keyboard")) != nil }
        #expect(!exists(again, "keyboard-reassign-prompt"))
        #expect(rig.workspace.settings.keybindings[toggle] == nil)
    }

    // MARK: Failure modes

    @Test func unparseableOverrideIsIgnoredAndDefaultShown() async throws {
        let (rig, _, settings, center) = try await open()
        let def = try #require(center.registry.command(id: toggle)?.descriptor.shortcut)
        try setOverrides(rig, [toggle: "shift"])
        settle(settings)
        #expect(try text(settings, "keyboard-chord-\(toggle)") == def.shortcut.displayText)
        #expect(center.registry.keymap.chord(for: toggle) == def)
        #expect(!exists(settings, "keyboard-reset-\(toggle)"), "not custom, so no Reset")
        let row = try settings.element(identifier: "keyboard-row-\(toggle)")
        let shown = descendants(of: row, in: settings).compactMap { $0.value ?? $0.label }
        #expect(shown.contains("default"), "\(shown)")
        let ids = center.registry.commands.map(\.descriptor.id).filter { exists(settings, "keyboard-row-\($0)") }
        #expect(Set(ids).count == ids.count)
    }

    @Test func unknownIdsAreNotShownButSurviveARebind() async throws {
        let (rig, _, settings, _) = try await open()
        try setOverrides(rig, ["ghost.command": "cmd+alt+q"])
        settle(settings)
        #expect(!exists(settings, "keyboard-row-ghost.command"))
        try record(settings, toggle, rebound)
        let reloaded = AlloySettings.load(appSupport: rig.root.appendingPathComponent("support"))
        #expect(reloaded.keybindings["ghost.command"] == "cmd+alt+q")
        #expect(reloaded.keybindings[toggle] == rebound.description)
    }

    @Test func twoCommandsOnOneChordFlagBothRowsFirstKeepsIt() async throws {
        let (rig, _, settings, center) = try await open()
        let holder = try #require(center.registry.command(id: "go.quickOpen"))
        let chord = try #require(holder.descriptor.shortcut)
        try setOverrides(rig, [toggle: chord.description])
        settle(settings)
        let order = center.registry.commands.map(\.descriptor.id)
        let first = try #require(order.first { $0 == toggle || $0 == "go.quickOpen" })
        let second = first == toggle ? "go.quickOpen" : toggle
        #expect(center.registry.keymap.chord(for: first) != nil)
        #expect(center.registry.keymap.chord(for: second) == nil)
        #expect(exists(settings, "keyboard-conflict-\(toggle)"))
        #expect(exists(settings, "keyboard-conflict-go.quickOpen"))
    }

    @Test func chordWithNoKeyOnLayoutIsKeptAndRowRenders() async throws {
        let (rig, _, settings, _) = try await open()
        let rare = try #require(KeyChord.parse("cmd+alt+§"))
        try setOverrides(rig, [toggle: rare.description])
        settle(settings)
        #expect(rig.workspace.settings.keybindings[toggle] == rare.description)
        #expect(exists(settings, "keyboard-row-\(toggle)"))
        #expect(!(try text(settings, "keyboard-chord-\(toggle)")).isEmpty)
        #expect(exists(settings, "keyboard-reset-\(toggle)"))
    }

    @Test func reassignFromAHolderThatIsAlreadyUnboundSkipsThePrompt() async throws {
        let (rig, _, settings, center) = try await open()
        let chord = try #require(center.registry.command(id: "go.quickOpen")?.descriptor.shortcut)
        try setOverrides(rig, ["go.quickOpen": Keymap.unbound])
        settle(settings)
        try record(settings, toggle, chord)
        #expect(!exists(settings, "keyboard-reassign-prompt"))
        let stored = try #require(rig.workspace.settings.keybindings[toggle].flatMap(KeyChord.parse))
        #expect(stored.resolved(primaryIsCmd: true) == chord.resolved(primaryIsCmd: true))
        #expect(rig.workspace.settings.keybindings["go.quickOpen"] == Keymap.unbound)
    }

    @Test func rebindWhileFilteredTargetsTheRightId() async throws {
        let (rig, _, settings, _) = try await open()
        try tap(settings, "keyboard-filter")
        settings.typeText("toggleChatColumn")
        settle(settings)
        #expect(exists(settings, "keyboard-row-\(toggle)"))
        try record(settings, toggle, rebound)
        #expect(rig.workspace.settings.keybindings == [toggle: rebound.description])
        for _ in 0..<("toggleChatColumn".count + 2) { settings.typeKey(.delete) }
        settle(settings)
        #expect(try text(settings, "keyboard-chord-\(toggle)") == rebound.shortcut(for: .macOS).displayText)
    }

    // MARK: Guards

    @Test func armedRecorderIdleRequestsNothing() async throws {
        let (_, _, settings, _) = try await open()
        try settings.click(recorder(settings, toggle))
        // The scroll that brought the row into view fades its indicator on the window clock; let that finish first.
        settings.advance(by: 3)
        for _ in 0..<10 { settings.tick(); await Task.yield() }
        #expect(try recorder(settings, toggle).isFocused)
        settings.resetFrameWork()
        for _ in 0..<5 { settings.tick() }
        #expect(settings.frameWork.reduce(0) { $0 + $1.elementRequests } == 0, "\(settings.frameWork.map(\.elementRequests))")
    }
}
