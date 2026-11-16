@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The Chat | Code switch in the title island and the View menu's shortcuts.
@MainActor
@Suite struct ModeSwitchTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func islandFrames(_ window: TestWindow) throws -> [Bounds<Pixels>] {
        try ["island-sidebar", "island-chat", "island-files"].map { try window.element(identifier: $0).frame }
    }

    @Test func pickerSitsBetweenProjectAndPills() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let picker = try window.element(identifier: "mode-switch").frame
        let project = try window.element(identifier: "title-project").frame
        let pill = try window.element(identifier: "title-new-session").frame
        #expect(picker.minX > project.maxX)
        #expect(picker.maxX < pill.minX)
    }

    @Test func segmentsSwitchMode() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "mode-code"))
        window.tick(); window.tick()
        #expect(rig.workspace.mode == .code)
        #expect(exists(window, "code-screen"))
        #expect(!exists(window, "island-files"))
        try window.click(window.element(identifier: "mode-chat"))
        window.tick(); window.tick()
        #expect(rig.workspace.mode == .chat)
        for id in ["island-sidebar", "island-chat", "island-files"] { #expect(exists(window, id)) }
        #expect(!exists(window, "code-screen"))
    }

    @Test func menuShortcutsSwitchMode() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        window.typeKey("2", modifierFlags: [.control, .command])
        window.tick()
        #expect(rig.workspace.mode == .code)
        window.typeKey("1", modifierFlags: [.control, .command])
        window.tick()
        #expect(rig.workspace.mode == .chat)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-mode-code")
        #expect(rig.workspace.mode == .code)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-mode-chat")
        #expect(rig.workspace.mode == .chat)
    }

    @Test func chatModeIsUnchanged() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let before = try islandFrames(window)
        rig.workspace.setMode(.code); window.tick(); window.tick()
        rig.workspace.setMode(.chat); window.tick(); window.tick()
        let after = try islandFrames(window)
        for (a, b) in zip(before, after) {
            #expect(a.minX == b.minX && a.minY == b.minY && a.maxX == b.maxX && a.maxY == b.maxY)
        }
    }

    @Test func switchingWithFocusedDirtyEditorDoesNotSave() async throws {
        let rig = Rig()
        try "let a = 1\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = "a.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try window.click(window.element(identifier: "code-view"))
        window.typeText("x")
        window.tick()
        let document = try #require(rig.workspace.document("a.swift"))
        #expect(document.isDirty)
        #expect(rig.workspace.codePanelFocused, "the code view holds focus before the switch")
        let writes = rig.workspace.writeCount
        window.typeKey("2", modifierFlags: [.control, .command])
        for _ in 0..<50 { window.tick(); await Task.yield() }
        #expect(rig.workspace.mode == .code)
        #expect(rig.workspace.writeCount == writes)
        #expect(rig.workspace.document("a.swift") === document)
        #expect(document.isDirty)
    }

    @Test func codeToChatWithFocusedDirtyGroupEditorDoesNotSave() async throws {
        let rig = Rig()
        try "let a = 1\n".write(to: rig.root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("a.swift", in: .group(g0))
        let window = try alloyWindow(rig.workspace)
        let id = "code-view-\(g0.uuidString)"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        try window.click(window.element(identifier: id))
        window.typeText("x")
        window.tick()
        let document = try #require(rig.workspace.document("a.swift"))
        #expect(document.isDirty)
        let writes = rig.workspace.writeCount
        window.typeKey("1", modifierFlags: [.control, .command])
        for _ in 0..<50 { window.tick(); await Task.yield() }
        #expect(rig.workspace.mode == .chat)
        #expect(rig.workspace.writeCount == writes)
        #expect(rig.workspace.document("a.swift") === document)
        #expect(document.isDirty)
    }
}
