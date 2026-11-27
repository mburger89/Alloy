@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The five multi-cursor commands: registration, Edit menu, chords, and which view they act on.
@MainActor @Suite struct MultiCursorCommandTests {
    private static let ids = ["editor.addNextOccurrence", "editor.selectAllOccurrences", "editor.skipNextOccurrence",
                              "editor.addCaretAbove", "editor.addCaretBelow"]
    private static let titles = ["Add Next Occurrence", "Select All Occurrences", "Skip to Next Occurrence", "Add Caret Above", "Add Caret Below"]

    private func ranges(_ s: CodeSelectionState) -> [Range<Int>] { s.selections.map { min($0.anchor, $0.head)..<max($0.anchor, $0.head) } }
    private func isDisabled(_ window: TestWindow, _ id: String) -> Bool {
        do { try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-\(id)"); return false } catch { return true }
    }
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    /// A chat-mode window on a.txt, focused on its code view.
    private func chatRig(_ text: String) async throws -> (rig: Rig, window: TestWindow, state: CodeSelectionState) {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = "a.txt"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view") }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let state = try #require(rig.workspace.selectionState(for: "a.txt", in: .chat))
        return (rig, window, state)
    }

    @Test func registersAllFiveWithoutRejection() async throws {
        let rig = Rig()
        let registry = testCenter(for: rig.workspace).registry
        for id in Self.ids {
            #expect(registry.command(id: id) != nil, "\(id) registered")
            #expect(!registry.rejections.contains { $0.id == id }, "\(id) rejected")
        }
        var seen: [KeyChord: String] = [:]
        for command in registry.commands {
            guard let chord = command.descriptor.shortcut else { continue }
            #expect(seen[chord] == nil, "\(command.descriptor.id) shares its chord with \(seen[chord] ?? "")")
            seen[chord] = command.descriptor.id
        }
    }

    /// macOS reserves alt+cmd+d (Show or Hide the Dock), so Skip to Next Occurrence has no default there.
    private var skipShortcut: PlatformKeyEquivalent? {
        #if os(macOS)
        nil
        #else
        PlatformKeyEquivalent(key: "d", modifiers: [.option, .command])
        #endif
    }

    @Test func editMenuListsThemAfterTheIntelItems() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let edit = try #require(window.testApp.menuBar.first { $0.title == "Edit" })
        let tail = edit.items.dropLast().suffix(11)   // the Find submenu comes last
        #expect(tail.map(\.title) == ["Format Document", "Format Selection", "Show Hover", "Trigger Completion", "Signature Help",
                                      "Quick Fix"] + Self.titles)
        let new = Array(edit.items.dropLast().suffix(5))
        #expect(new.compactMap(\.accessibilityIdentifier) == Self.ids.map { "cmd-\($0)" })
        #expect(new.map(\.shortcut) == [
            PlatformKeyEquivalent(key: "d", modifiers: [.command]),
            PlatformKeyEquivalent(key: "l", modifiers: [.command, .shift]),
            skipShortcut,
            PlatformKeyEquivalent(key: "\u{f700}", modifiers: [.control, .shift]),
            PlatformKeyEquivalent(key: "\u{f701}", modifiers: [.control, .shift]),
        ])
    }

    @Test func menuItemsRunAgainstTheFocusedView() async throws {
        let (rig, window, state) = try await chatRig("alpha beta\nalpha beta\nalpha beta\n")
        state.setSelections([CodeSelection(caret: 2)], primary: 0)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.addNextOccurrence")
        #expect(ranges(state) == [0..<5])
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.addNextOccurrence")
        #expect(ranges(state) == [0..<5, 11..<16])
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.skipNextOccurrence")
        #expect(ranges(state) == [0..<5, 22..<27])
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.selectAllOccurrences")
        #expect(ranges(state) == [0..<5, 11..<16, 22..<27])
        state.setSelections([CodeSelection(caret: 3)], primary: 0)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.addCaretBelow")
        #expect(ranges(state) == [3..<3, 14..<14])
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.addCaretAbove")
        #expect(state.selections.count == 3 || state.selections.count == 2)
        withExtendedLifetime(rig) {}
    }

    @Test func chordsReachTheCommandsFromTheFocusedCodeView() async throws {
        let (rig, window, state) = try await chatRig("alpha beta\nalpha beta\nalpha beta\n")
        state.setSelections([CodeSelection(caret: 2)], primary: 0)
        window.typeKey("d", modifierFlags: .command)
        #expect(ranges(state) == [0..<5])
        window.typeKey("d", modifierFlags: .command)
        #expect(ranges(state) == [0..<5, 11..<16])
        #if os(macOS)
        // No default chord on macOS (the system owns alt+cmd+d): drive the menu item instead.
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.skipNextOccurrence")
        #else
        window.typeKey("d", modifierFlags: [.option, .command])
        #endif
        #expect(ranges(state) == [0..<5, 22..<27])
        window.typeKey("l", modifierFlags: [.command, .shift])
        #expect(ranges(state) == [0..<5, 11..<16, 22..<27])
        state.setSelections([CodeSelection(caret: 3)], primary: 0)
        window.typeKey(.downArrow, modifierFlags: [.control, .shift])
        #expect(ranges(state) == [3..<3, 14..<14])
        window.typeKey(.downArrow, modifierFlags: [.control, .shift])
        #expect(ranges(state) == [3..<3, 14..<14, 25..<25])
        withExtendedLifetime(rig) {}
    }

    @Test func disabledWithNothingFocused() async throws {
        // The chooser: no workspace.
        let model = LauncherModel()
        let chooser = try TestWindow(size: Size(width: Pixels(900), height: Pixels(600))) { launcherRoot(model: model, center: testCenter(for: model)) }
        chooser.installAlloyMenu(model: model)
        chooser.tick()
        for id in Self.ids { #expect(isDisabled(chooser, id), "\(id) in the chooser") }
        #expect(!testCenter(for: model).registry.run(id: Self.ids[0]))

        // A workspace with no tab.
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let registry = testCenter(for: rig.workspace).registry
        for id in Self.ids {
            #expect(isDisabled(window, id), "\(id) with no tab")
            #expect(!registry.run(id: id), "\(id) ran with no tab")
        }

        // A tab that is not code (binary file).
        try Data([0x41, 0x00, 0x42]).write(to: rig.root.appendingPathComponent("b.bin"))
        rig.workspace.openFilePath = "b.bin"
        try await window.runUntil { rig.workspace.tabMessages["b.bin"] != nil }
        for id in Self.ids {
            #expect(isDisabled(window, id), "\(id) on a non-code tab")
            #expect(!registry.run(id: id), "\(id) ran on a non-code tab")
        }
    }

    @Test func actsOnTheFocusedGroupOnly() async throws {
        let rig = Rig()
        try "alpha beta alpha\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("a.txt", in: .group(g0))
        rig.workspace.splitFocused(.horizontal)
        let g1 = rig.workspace.codeLayout.focusedGroupID
        #expect(g1 != g0)
        await rig.workspace.open("a.txt", in: .group(g1))
        let window = try alloyWindow(rig.workspace)
        let a = try #require(rig.workspace.selectionState(for: "a.txt", in: .group(g0)))
        let b = try #require(rig.workspace.selectionState(for: "a.txt", in: .group(g1)))
        a.setSelections([CodeSelection(caret: 2)], primary: 0)
        b.setSelections([CodeSelection(caret: 2)], primary: 0)
        rig.workspace.focusGroup(id: g0)
        window.tick()
        for _ in 0..<2 { try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.addNextOccurrence") }
        #expect(a.selections.count == 2)
        #expect(b.selections.count == 1)
    }

    @Test func escapeWithOneSelectionStillClosesQuickOpen() async throws {
        let (rig, window, state) = try await chatRig("alpha beta alpha\n")
        state.setSelections([CodeSelection(caret: 2)], primary: 0)
        window.typeKey("d", modifierFlags: .command)
        window.typeKey("d", modifierFlags: .command)
        #expect(state.selections.count == 2)
        window.typeKey(.escape)
        #expect(state.selections.count == 1, "Escape collapses several carets (MetalUI)")
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { self.exists(window, "quick-open-field") }
        window.typeKey(.escape)
        try await window.runUntil { !self.exists(window, "quick-open-field") }
        withExtendedLifetime(rig) {}
    }

    @Test func aCappedRunShowsTheNoticeAndASelectionChangeRemovesIt() async throws {
        let (rig, window, state) = try await chatRig(String(repeating: "x\n", count: 10_050))
        state.setSelections([CodeSelection(caret: 0)], primary: 0)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "cmd-editor.selectAllOccurrences")
        #expect(state.selections.count == CodeSelectionState.selectionLimit)
        try await window.runUntil { self.exists(window, "file-panel-notice") }
        state.setSelections([CodeSelection(caret: 1)], primary: 0)
        try await window.runUntil { !self.exists(window, "file-panel-notice") }
        withExtendedLifetime(rig) {}
    }
}
