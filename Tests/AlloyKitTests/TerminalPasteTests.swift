@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITerminal
import MetalUITesting
import Testing

/// The multi-line paste guard and the store's pending-paste logic.
@MainActor
@Suite struct TerminalPasteTests {
    private func shellStore() async throws -> (Rig, TerminalPanelStore, ScriptedPty, UUID) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let pty = try #require(spawner.spawned.first)
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 10_000_000); window.tick() }
        return (rig, store, pty, pane)
    }

    private var plain: TerminalModes { TerminalModes() }
    private var bracketed: TerminalModes { var m = TerminalModes(); m.bracketedPaste = true; return m }

    @Test func lineCountTreatsCRLFCRAndLFAsOneBreakEach() {
        #expect(TerminalPasteGuard.lineCount("a") == 1)
        #expect(TerminalPasteGuard.lineCount("ls\n") == 1)
        #expect(TerminalPasteGuard.lineCount("a\nb") == 2)
        #expect(TerminalPasteGuard.lineCount("a\r\nb") == 2)
        #expect(TerminalPasteGuard.lineCount("a\rb\rc") == 3)
        #expect(TerminalPasteGuard.lineCount("a\n\n") == 2)
        #expect(TerminalPasteGuard.lineCount("") == 0)
    }

    @Test func singleLineAndBracketedAndDisabledReturnFalse() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        #expect(!store.pasteFromClipboard(pane, "ls\n", modes: plain))
        #expect(!store.pasteFromClipboard(pane, "a\nb\nc", modes: bracketed))
        #expect(store.pendingPaste == nil)
        var s = rig.workspace.settings
        s.terminal.confirmMultilinePaste = false
        try rig.workspace.updateSettings(s)
        #expect(!store.pasteFromClipboard(pane, "a\nb\nc", modes: plain))
        #expect(store.pendingPaste == nil)
        #expect(pty.written.isEmpty)
    }

    @Test func multiLineWithoutBracketedPromptsAndSendsNothing() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        #expect(store.pasteFromClipboard(pane, "a\nb\nc", modes: plain))
        #expect(store.pendingPaste?.lines == 3)
        #expect(pty.written.isEmpty)
        withExtendedLifetime(rig) {}
    }

    @Test func confirmSendsEncodedPaste() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        let text = "a\nb\u{1B}c\nd"
        _ = store.pasteFromClipboard(pane, text, modes: plain)
        let token = store.terminalFocusToken
        store.confirmPaste(dontAskAgain: false)
        #expect(pty.written == TerminalEncoder.encodePaste(text, modes: plain))
        #expect(store.pendingPaste == nil)
        #expect(store.terminalFocusToken != token)
        withExtendedLifetime(rig) {}
    }

    @Test func cancelSendsNothing() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        _ = store.pasteFromClipboard(pane, "a\nb", modes: plain)
        let token = store.terminalFocusToken
        store.cancelPaste()
        #expect(pty.written.isEmpty)
        #expect(store.pendingPaste == nil)
        #expect(store.terminalFocusToken != token)
        withExtendedLifetime(rig) {}
    }

    @Test func dontAskAgainClearsSettingAndPersists() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        _ = store.pasteFromClipboard(pane, "a\nb", modes: plain)
        store.confirmPaste(dontAskAgain: true)
        #expect(!pty.written.isEmpty)
        #expect(rig.workspace.settings.terminal.confirmMultilinePaste == false)
        #expect(!store.pasteFromClipboard(pane, "x\ny", modes: plain))
    }

    @Test func secondPasteWhilePendingKeepsFirst() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        #expect(store.pasteFromClipboard(pane, "a\nb", modes: plain))
        #expect(store.pasteFromClipboard(pane, "x\ny\nz", modes: plain))
        #expect(store.pendingPaste?.text == "a\nb")
        #expect(pty.written.isEmpty)
        withExtendedLifetime(rig) {}
    }

    @Test func exitOrClosePaneDropsPending() async throws {
        let (rig, store, pty, pane) = try await shellStore()
        _ = store.pasteFromClipboard(pane, "a\nb", modes: plain)
        store.markExited(pane, status: 0)
        #expect(store.pendingPaste == nil)
        _ = store.pasteFromClipboard(pane, "a\nb", modes: plain)
        store.confirmPaste(dontAskAgain: false)
        #expect(pty.written.isEmpty)
        store.restart(pane)
        _ = store.pasteFromClipboard(pane, "a\nb", modes: plain)
        store.closePane(pane)
        #expect(store.pendingPaste == nil)
        withExtendedLifetime(rig) {}
    }

    @Test func settingsToggleReflectsDontAskAgain() async throws {
        let (rig, store, _, pane) = try await shellStore()
        _ = store.pasteFromClipboard(pane, "a\nb", modes: plain)
        store.confirmPaste(dontAskAgain: true)
        #expect(rig.workspace.settings.terminal.confirmMultilinePaste == false)
        let main = try alloyWindow(rig.workspace, terminal: store)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-terminal-paste-confirm")) != nil }
        _ = try settings.element(identifier: "settings-terminal-paste-confirm")
        try settings.click(settings.element(identifier: "settings-terminal-paste-confirm"))
        try await settings.runUntil { rig.workspace.settings.terminal.confirmMultilinePaste }
        #expect(store.pasteFromClipboard(pane, "x\ny", modes: plain))
        #expect(store.pendingPaste != nil)
        await rig.workspace.stopAll()
    }
}

/// The confirm overlay in a live window.
@MainActor
@Suite struct TerminalPasteConfirmTests {
    private func open(_ text: String = "a\nb\nc") async throws -> (Rig, TestWindow, TerminalPanelStore, ScriptedPty, UUID) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let pty = try #require(spawner.spawned.first)
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 10_000_000); window.tick() }
        #expect(store.pasteFromClipboard(pane, text, modes: TerminalModes()))
        for _ in 0..<5 { window.tick() }
        return (rig, window, store, pty, pane)
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    @Test func confirmAppearsWithCopy() async throws {
        let (rig, window, _, _, _) = try await open()
        #expect(exists(window, "terminal-paste-confirm"))
        let text = try window.element(identifier: "terminal-paste-confirm-text")
        #expect(text.value?.contains("Paste 3 lines? They may run as commands") == true)
        withExtendedLifetime(rig) {}
    }

    @Test func confirmAppearsOnlyInTheTargetPane() async throws {
        let (rig, window, store, _, a) = try await open()
        store.cancelPaste()
        store.splitActive(axis: .horizontal)
        for _ in 0..<10 { try? await Task.sleep(nanoseconds: 10_000_000); window.tick() }
        #expect(store.pasteFromClipboard(a, "x\ny", modes: TerminalModes()))
        for _ in 0..<5 { window.tick() }
        let pane = try window.element(identifier: "terminal-pane-\(a.uuidString)")
        let confirm = try window.element(identifier: "terminal-paste-confirm")
        #expect(pane.frame.contains(confirm.frame.origin))
        store.cancelPaste()
        for _ in 0..<5 { window.tick() }
        #expect(!exists(window, "terminal-paste-confirm"))
        withExtendedLifetime(rig) {}
    }

    @Test func pasteButtonSendsAndDismisses() async throws {
        let (rig, window, store, pty, _) = try await open()
        let token = store.terminalFocusToken
        try window.click(window.element(identifier: "terminal-paste-confirm-paste"))
        for _ in 0..<5 { window.tick() }
        #expect(pty.written == TerminalEncoder.encodePaste("a\nb\nc", modes: TerminalModes()))
        #expect(!exists(window, "terminal-paste-confirm"))
        #expect(store.terminalFocusToken != token)
        withExtendedLifetime(rig) {}
    }

    @Test func cancelButtonSendsNothingAndDismisses() async throws {
        let (rig, window, store, pty, _) = try await open()
        let token = store.terminalFocusToken
        try window.click(window.element(identifier: "terminal-paste-confirm-cancel"))
        for _ in 0..<5 { window.tick() }
        #expect(pty.written.isEmpty)
        #expect(!exists(window, "terminal-paste-confirm"))
        #expect(store.terminalFocusToken != token)
        withExtendedLifetime(rig) {}
    }

    @Test func dontAskAgainThenPasteSetsSetting() async throws {
        let (rig, window, _, pty, _) = try await open()
        try window.click(window.element(identifier: "terminal-paste-confirm-dont-ask"))
        for _ in 0..<3 { window.tick() }
        try window.click(window.element(identifier: "terminal-paste-confirm-paste"))
        for _ in 0..<5 { window.tick() }
        #expect(!pty.written.isEmpty)
        #expect(rig.workspace.settings.terminal.confirmMultilinePaste == false)
    }

    @Test func escapeCancels() async throws {
        let (rig, window, store, pty, _) = try await open()
        window.typeKey(.escape)
        for _ in 0..<5 { window.tick() }
        #expect(store.pendingPaste == nil)
        #expect(pty.written.isEmpty)
        #expect(!exists(window, "terminal-paste-confirm"))
        withExtendedLifetime(rig) {}
    }
}
