@testable import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "let x = 1\nlet y = x\n"
private let f2 = KeyEquivalent("\u{f705}")

/// Rename Symbol in the Edit menu, the palette and on F2: where it sits, when it is enabled and what it does.
@MainActor
@Suite
struct RenameCommandTests {
    private func menu(_ window: TestWindow, _ id: String) throws { try window.testApp.performMenuBarItem(accessibilityIdentifier: id) }

    private func isDisabled(_ window: TestWindow, _ id: String) -> Bool {
        do { try menu(window, id); return false } catch { return true }
    }

    private func caret(_ r: IntelRig, _ path: String = "main.rs", at offset: Int = 5) throws {
        try #require(r.rig.workspace.selectionState(for: path, in: .chat)).select(offset..<offset, reveal: false)
    }

    private func ready(_ r: IntelRig, _ window: TestWindow) async throws {
        let doc = try #require(r.rig.workspace.document("main.rs"))
        try await window.runUntil { CodePanelStore.existingView(for: doc)?.features.rename == true }
    }

    @Test func theItemSitsAfterThePasteboardGroupAndBeforeFormat() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            let window = try alloyWindow(r.rig.workspace)
            let edit = try #require(window.testApp.menuBar.first { $0.title == "Edit" })
            let titles = edit.items.map(\.title)
            let rename = try #require(titles.firstIndex(of: "Rename Symbol"))
            #expect(titles.firstIndex(of: "Format Document") == rename + 1)
            #expect(rename > 0)
            #expect(edit.items[rename].accessibilityIdentifier == "menu-rename")
            #expect(edit.items[rename].shortcut == PlatformKeyEquivalent(key: "\u{f705}", modifiers: []))
        }
    }

    @Test func theMenuItemOpensTheField() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            try await ready(r, window)
            try caret(r)
            try menu(window, "menu-rename")
            try await window.runUntil { r.exists(window, "rename-field") }
            #expect(r.count("textDocument/prepareRename") == 1)
        }
    }

    @Test func f2OpensTheFieldFromTheFocusedCodeView() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            try await ready(r, window)
            try caret(r)
            window.typeKey(f2)
            try await window.runUntil { r.exists(window, "rename-field") }
        }
    }

    @Test func thePaletteListsItWithF2AndRunsIt() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            try await ready(r, window)
            try caret(r)
            window.typeKey("p", modifierFlags: [.command, .shift])
            try await window.runUntil { r.exists(window, "command-palette-field") }
            window.typeText("Rename Symbol")
            try await window.runUntil { r.exists(window, "command-palette-row-0") }
            let row = try window.element(identifier: "command-palette-row-0")
            let shown = descendants(of: row, in: window).compactMap { $0.value ?? $0.label }
            #expect(shown.contains("Edit: Rename Symbol"), "\(shown)")
            #expect(shown.contains("F2"), "\(shown)")
            window.typeKey(.return)
            try await window.runUntil { r.exists(window, "rename-field") }
        }
    }

    @Test func disabledForAReadOnlyDocument() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            try await ready(r, window)
            try caret(r)
            try #require(r.rig.workspace.document("main.rs")).state = .readOnly(reason: "test")
            for _ in 0..<3 { window.tick(); await Task.yield() }
            #expect(isDisabled(window, "menu-rename"))
            #expect(r.count("textDocument/prepareRename") == 0)
        }
    }

    @Test func disabledWhenTheServerLacksRename() async throws {
        try await IntelRig.run(script: IntelRig.script(caps: #""hoverProvider":true"#)) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            try caret(r)
            #expect(isDisabled(window, "menu-rename"))
            #expect(r.count("textDocument/prepareRename") == 0)
        }
    }

    @Test func disabledWithNoServer() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            try r.write("notes.txt", "plain words\n")
            let window = try await r.open2("notes.txt")
            try caret(r, "notes.txt", at: 2)
            #expect(isDisabled(window, "menu-rename"))
            #expect(r.methods().isEmpty)
        }
    }

    @Test func disabledWithNoEditorAndRunIsANoOp() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect(isDisabled(window, "menu-rename"))
        let registry = testCenter(for: rig.workspace).registry
        registry.run(id: "edit.rename")
        for _ in 0..<3 { window.tick() }
        #expect((try? window.element(identifier: "rename-field")) == nil)
    }

    @Test func aKeybindingOverrideMovesAndUnbindsIt() async throws {
        let rig = Rig()
        _ = try alloyWindow(rig.workspace)
        var s = rig.workspace.settings
        s.keybindings = ["edit.rename": "primary+alt+shift+r"]
        try rig.workspace.updateSettings(s)
        let moved = testCenter(for: rig.workspace).registry.keymap.chord(for: "edit.rename")
        #expect(moved == KeyChord.parse("primary+alt+shift+r"))
        s.keybindings = ["edit.rename": "none"]
        try rig.workspace.updateSettings(s)
        #expect(testCenter(for: rig.workspace).registry.keymap.chord(for: "edit.rename") == nil)
    }

    @Test func theDefaultIsF2() {
        let rig = Rig()
        let command = testCenter(for: rig.workspace).registry.command(id: "edit.rename")
        #expect(command?.descriptor.title == "Rename Symbol")
        #expect(command?.descriptor.menuID == "menu-rename")
        #expect(command?.descriptor.shortcut == KeyChord(modifiers: [], key: .named(.f2)))
        #expect(command?.descriptor.recordsRecent == true)
    }
}
