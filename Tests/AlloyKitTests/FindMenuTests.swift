import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing

/// Edit > Find: Find…, Find Next and Find Previous act on the focused editor's find bar.
@MainActor @Suite struct FindMenuTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func enabled(_ window: TestWindow, _ id: String) -> Bool {
        let all = window.testApp.menuBar.flatMap { $0.items }.flatMap { item -> [PlatformMenuItem] in
            if case .submenu(let sub) = item.kind { return sub }
            return [item]
        }
        return all.first { $0.accessibilityIdentifier == id }?.isEnabled ?? false
    }

    private func fileWindow(_ text: String = "ab ab ab\n") async throws -> (Rig, TestWindow) {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = "a.txt"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view") }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        return (rig, window)
    }

    private func count(_ window: TestWindow) -> String? {
        (try? window.element(identifier: "find-count")).flatMap { $0.value ?? $0.label }
    }

    @Test func findMenuOpensTheFocusedEditorsFindBar() async throws {
        let (rig, window) = try await fileWindow()
        #expect(!exists(window, "find-field"))
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "edit-find")
        try await window.runUntil { self.exists(window, "find-field") }
        withExtendedLifetime(rig) {}
    }

    @Test func findNextAndPreviousMoveTheMatch() async throws {
        let (rig, window) = try await fileWindow()
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "edit-find")
        try await window.runUntil { self.exists(window, "find-field") }
        window.typeText("ab")
        try await window.runUntil { self.count(window) == "3 matches" }
        let state = try #require(rig.workspace.selectionState(for: "a.txt", in: .chat))
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "edit-find-next")
        #expect(state.primarySelection.range == 0..<2)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "edit-find-next")
        #expect(state.primarySelection.range == 3..<5)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "edit-find-previous")
        #expect(state.primarySelection.range == 0..<2)
    }

    @Test func cmdGStepsOnceNotTwice() async throws {
        let (rig, window) = try await fileWindow()
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "edit-find")
        try await window.runUntil { self.exists(window, "find-field") }
        window.typeText("ab")
        try await window.runUntil { self.count(window) == "3 matches" }
        try window.click(window.element(identifier: "code-view"))
        let state = try #require(rig.workspace.selectionState(for: "a.txt", in: .chat))
        window.typeKey("g", modifierFlags: .command)
        try await window.runUntil { self.count(window) == "1 of 3" }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(count(window) == "1 of 3", "\(String(describing: count(window)))")
        #expect(state.primarySelection.range == 0..<2)
        window.typeKey("g", modifierFlags: [.command, .shift])
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(count(window) == "3 of 3", "\(String(describing: count(window)))")
    }

    @Test func findDisabledWithoutAFocusedEditor() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        for id in ["edit-find", "edit-find-next", "edit-find-previous"] {
            #expect(!enabled(window, id), "\(id)")
        }
        withExtendedLifetime(rig) {}
    }

    @Test func cmdFInFocusedTerminalStillOpensTerminalFind() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace)
        let window = try alloyWindow(rig.workspace, terminal: store)
        store.toggle()
        for _ in 0..<3 { window.tick() }
        store.hasFocus = true
        #expect(store.findPane == nil)
        window.typeKey("f", modifierFlags: .command)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(store.findPane != nil)
        #expect(!exists(window, "find-field"))
        withExtendedLifetime(rig) {}
    }
}
