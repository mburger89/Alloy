@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITerminal
import MetalUITerminalUI
import MetalUITesting
import Testing

/// Keys, committed text and focus reports reach the pane's pty; the allow-list and cursor mapping are pure.
@MainActor
@Suite struct TerminalInputTests {
    private func shellWindow(_ configure: (Workspace) throws -> Void = { _ in }) async throws
        -> (Rig, TestWindow, TerminalPanelStore, ScriptedPty, UUID)
    {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        try configure(rig.workspace)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let pty = try #require(spawner.spawned.first)
        await pump(window)
        try window.click(window.element(identifier: "terminal-pane-\(pane.uuidString)"))
        await pump(window)
        return (rig, window, store, pty, pane)
    }

    private func pump(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { try? await Task.sleep(nanoseconds: 10_000_000); window.tick() }
    }

    @Test func typedTextReachesThePty() async throws {
        let (rig, window, _, pty, _) = try await shellWindow()
        window.typeText("ls")
        window.typeKey(.return)
        await pump(window)
        let written = pty.written
        #expect(Array(written.prefix(2)) == Array("ls".utf8), "\(written)")
        #expect(written.last == 0x0D)
        withExtendedLifetime(rig) {}
    }

    @Test func controlCReachesTheProgram() async throws {
        let (rig, window, _, pty, _) = try await shellWindow()
        window.typeKey("c", modifierFlags: .control)
        await pump(window)
        #expect(pty.written.contains(0x03), "\(pty.written)")
        withExtendedLifetime(rig) {}
    }

    /// Option+b as the platform delivers it: the composed character, with the base key beside it.
    private func optionB(_ window: TestWindow) {
        window.send(.keyDown(KeyEvent(charactersIgnoringModifiers: "b", characters: "\u{222B}", modifiers: .option, timestamp: 0)))
        window.tick()
    }

    @Test func optionAsMetaFollowsSettings() async throws {
        let (rigOn, windowOn, _, ptyOn, _) = try await shellWindow()
        optionB(windowOn)
        await pump(windowOn)
        #expect(ptyOn.written == [0x1B, 0x62], "\(ptyOn.written)")
        let (rigOff, windowOff, _, ptyOff, _) = try await shellWindow { workspace in
            var settings = workspace.settings
            settings.terminal.optionAsMeta = false
            try workspace.updateSettings(settings, persist: false)
        }
        optionB(windowOff)
        await pump(windowOff)
        #expect(ptyOff.written == Array("\u{222B}".utf8), "\(ptyOff.written)")
        withExtendedLifetime((rigOn, rigOff)) {}
    }

    @Test func focusReportsFollowMode1004() async throws {
        let (rig, window, _, pty, pane) = try await shellWindow()
        pty.feed(Array("\u{1b}[?1004h".utf8))
        await pump(window)
        try "let x = 1\n".write(to: rig.root.appendingPathComponent("focus.swift"), atomically: true, encoding: .utf8)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("focus.swift", in: .group(g0))
        await pump(window, 6)
        let before = pty.written.count
        try window.click(window.element(identifier: "code-view-\(g0.uuidString)"))
        await pump(window)
        #expect(Array(pty.written.dropFirst(before)) == [0x1B, 0x5B, 0x4F], "focus out: \(pty.written)")
        try window.click(window.element(identifier: "terminal-pane-\(pane.uuidString)"))
        await pump(window)
        #expect(Array(pty.written.suffix(3)) == [0x1B, 0x5B, 0x49], "focus in: \(pty.written)")
        withExtendedLifetime(rig) {}
    }

    @Test func exitedPaneIgnoresInput() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        pty.finish(.exited(0))
        await pump(window)
        let before = pty.written
        store.sendInput(pane, Array("x".utf8))
        #expect(pty.written == before)
        withExtendedLifetime(rig) {}
    }

    @Test func cursorStyleMapsFromSettings() {
        #expect(TerminalKeys.cursorStyle(.bar, blink: false) == MetalUITerminal.TerminalCursorStyle(shape: .bar, blinking: false))
        #expect(TerminalKeys.cursorStyle(.underline, blink: true) == MetalUITerminal.TerminalCursorStyle(shape: .underline, blinking: true))
        let make = { (s: TerminalSettings) in
            TerminalAppearance.make(colors: [:], appearance: .dark, settings: s).cursorStyle
        }
        var settings = TerminalSettings()
        settings.cursorStyle = .bar
        settings.cursorBlink = false
        #expect(make(settings) == MetalUITerminal.TerminalCursorStyle(shape: .bar, blinking: false))
    }

    @Test func exceptionsIncludeAppShortcutsAndPlatformShifts() {
        let mac = Set(TerminalKeys.exceptions(platform: .macOS))
        for c: Character in ["w", "t", "k", "c", "v", "f", "a"] {
            #expect(mac.contains(KeyboardShortcut(KeyEquivalent(c), modifiers: .command)), "\(c)")
        }
        let linux = Set(TerminalKeys.exceptions(platform: .linux))
        for c: Character in ["w", "t", "k", "c", "v", "f", "a"] {
            #expect(linux.contains(KeyboardShortcut(KeyEquivalent(c), modifiers: [.control, .shift])), "\(c)")
        }
        #expect(linux.contains(KeyboardShortcut("`", modifiers: .control)))
        for platform in KeyboardShortcut.Platform.allCases {
            for s in TerminalKeys.exceptions(platform: platform) where s.modifiers == .control {
                #expect(!s.key.character.isLetter, "plain Ctrl-letter \(s.key.character) on \(platform)")
            }
        }
    }

    // MARK: Terminal commands

    private static let terminalCommandIDs = ["terminal.copy", "terminal.selectAll", "terminal.find",
                                             "terminal.clearScrollback"]

    @Test func terminalCommandsAreDisabledWithoutTerminalFocus() async throws {
        let rig = Rig()
        rig.workspace.setMode(.code)
        let registry = testCenter(for: rig.workspace).registry
        for id in Self.terminalCommandIDs {
            let command = try #require(registry.command(id: id), "\(id)")
            #expect(!command.isEnabled(), "\(id)")
            #expect(!registry.run(id: id), "\(id)")
        }
    }

    @Test func terminalCommandsRegisterWithKeyboardSettingsRows() async throws {
        let rig = Rig()
        let center = testCenter(for: rig.workspace)
        let groups = KeyboardSettingsSection.groups(center: center, overrides: [:], filter: "")
        let rows = groups.flatMap { $0.rows }
        for id in Self.terminalCommandIDs {
            let row = try #require(rows.first { $0.id == id }, "\(id)")
            #if os(macOS)
            // ⌘F is Edit > Find…, which runs the terminal's find while a terminal has focus: no chord of its own.
            if id == "terminal.find" { #expect(row.chordText == "None"); continue }
            #endif
            #expect(row.chordText != "None", "\(id)")
        }
        // No terminal chord is held by another built-in command.
        let clashes = ShortcutClashes(center: center)
        for id in Self.terminalCommandIDs {
            guard let chord = center.registry.command(id: id)?.descriptor.shortcut else {
                #expect(id == "terminal.find", "\(id) has no chord")
                continue
            }
            for clash in clashes.clashes(for: chord, excluding: id, overrides: [:]) {
                if case .command(let other) = clash.kind {
                    Issue.record("\(id) clashes with command \(other)")
                }
            }
        }
        #expect(groups.contains { $0.name == "Terminal" })
    }

    @Test func copyPutsSelectionOnTheClipboard() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        pty.feed(Array("alpha  \r\nbeta\r\n".utf8))
        await pump(window)
        let registry = testCenter(for: rig.workspace).registry
        // Nothing selected: the clipboard stays as it was.
        _ = window.window.clipboard.write("keep")
        #expect(registry.run(id: "terminal.copy"))
        await pump(window)
        #expect(window.window.clipboard.read(String.self) == "keep")
        #expect(registry.run(id: "terminal.selectAll"))
        await pump(window)
        #expect(registry.run(id: "terminal.copy"))
        await pump(window)
        let copied = try #require(window.window.clipboard.read(String.self))
        #expect(copied.hasPrefix("alpha\nbeta"), "\(copied.debugDescription)")
        #expect(!copied.contains("alpha  "), "trailing blanks are trimmed")
        withExtendedLifetime((store, pane)) {}
    }

    @Test func clearScrollbackRunsOnlyWithFocus() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        let lines = (0..<200).map { "line\($0)\r\n" }.joined()
        pty.feed(Array(lines.utf8))
        await pump(window)
        let screen = try #require(store.manager?.screen(for: pane))
        await screen.selectAll()
        let before = try #require(await screen.selectedText())
        #expect(before.contains("line0"))
        let registry = testCenter(for: rig.workspace).registry
        store.hasFocus = false
        #expect(!registry.run(id: "terminal.clearScrollback"))
        await pump(window)
        await screen.selectAll()
        #expect(try #require(await screen.selectedText()).contains("line0"), "unfocused: untouched")
        store.hasFocus = true
        #expect(registry.run(id: "terminal.clearScrollback"))
        await pump(window)
        await screen.selectAll()
        let after = try #require(await screen.selectedText())
        #expect(!after.contains("line0"), "scrollback dropped")
        #expect(after.contains("line199"), "screen kept")
    }

    @Test func exitedPaneCommandsAreNoOps() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        pty.feed(Array("hello\r\n".utf8))
        await pump(window)
        pty.finish(.exited(0))
        await pump(window)
        store.hasFocus = true
        let before = pty.written
        let registry = testCenter(for: rig.workspace).registry
        _ = window.window.clipboard.write("keep")
        for id in Self.terminalCommandIDs { _ = registry.run(id: id) }
        await pump(window)
        #expect(pty.written == before)
        #expect(window.window.clipboard.read(String.self) == "keep")
        #expect(store.focusedScreen == nil)
        withExtendedLifetime(pane) {}
    }

    // MARK: Find bar

    /// Feeds `hit A`, `hit B`, `hit C` separated by filler, enough to push the first into scrollback.
    private func feedHits(_ pty: ScriptedPty, _ window: TestWindow) async {
        var text = ""
        for (i, tag) in ["A", "B", "C"].enumerated() {
            text += "hit \(tag)\r\n"
            for j in 0..<20 { text += "filler \(i) \(j)\r\n" }
        }
        pty.feed(Array(text.utf8))
        await pump(window)
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    /// The text the pane's current selection covers, read off the emulator.
    private func selected(_ store: TerminalPanelStore, _ pane: UUID) async -> String? {
        await store.manager?.screen(for: pane)?.selectedText()
    }

    private func openBar(_ store: TerminalPanelStore, _ window: TestWindow) async {
        store.openFind()
        await pump(window)
    }

    @Test func openFindShowsTheBarAndFocusesTheField() async throws {
        let (rig, window, store, _, pane) = try await shellWindow()
        #expect(!exists(window, "terminal-find-bar"))
        await openBar(store, window)
        #expect(store.findPane == pane)
        #expect(exists(window, "terminal-find-bar"))
        window.typeText("hit")
        await pump(window)
        #expect(store.findQuery == "hit")
        withExtendedLifetime(rig) {}
    }

    @Test func returnFindsNextAndShiftReturnPrevious() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        await feedHits(pty, window)
        await openBar(store, window)
        window.typeText("hit")
        await pump(window)
        var seen: [String] = []
        func step(_ shift: Bool) async {
            if shift { window.typeKey(.return, modifierFlags: .shift) } else { window.typeKey(.return) }
            await pump(window)
            seen.append(await selected(store, pane) ?? "nil")
        }
        // Rows of the selection tell the matches apart.
        func row() async -> Int? {
            await withCheckedContinuation { c in
                store.snapshotSource(of: pane)?.perform { e in
                    c.resume(returning: e.selection.map { if case .linear(let r) = $0 { r.lowerBound.row } else { -1 } })
                }
            }
        }
        var rows: [Int] = []
        for _ in 0..<4 { await step(false); rows.append(await row() ?? -1) }
        #expect(rows[0] < rows[1] && rows[1] < rows[2], "\(rows)")
        #expect(rows[3] == rows[0], "wrap from the last to the first: \(rows)")
        await step(true)
        #expect(await row() == rows[2], "wrap back from the first to the last")
        await step(true)
        #expect(await row() == rows[1])
        #expect(seen.allSatisfy { $0 == "hit" }, "\(seen)")
        withExtendedLifetime(rig) {}
    }

    @Test func notFoundShowsStatusAndKeepsSelection() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        await feedHits(pty, window)
        await openBar(store, window)
        window.typeText("hit")
        window.typeKey(.return)
        await pump(window)
        #expect(store.findStatus == .found)
        let kept = await selected(store, pane)
        window.typeText("zzz")
        window.typeKey(.return)
        await pump(window)
        #expect(store.findStatus == .notFound)
        #expect(await selected(store, pane) == kept)
        #expect(exists(window, "terminal-find-status"))
        withExtendedLifetime(rig) {}
    }

    @Test func emptyNeedleIsIdle() async throws {
        let (rig, window, store, pty, pane) = try await shellWindow()
        await feedHits(pty, window)
        await openBar(store, window)
        window.typeKey(.return)
        await pump(window)
        #expect(store.findStatus == .idle)
        #expect(await selected(store, pane) == nil)
        withExtendedLifetime(rig) {}
    }

    @Test func closeFindReturnsFocusToTheTerminal() async throws {
        let (rig, window, store, pty, _) = try await shellWindow()
        await openBar(store, window)
        window.typeKey(.escape)
        await pump(window)
        #expect(store.findPane == nil)
        #expect(!exists(window, "terminal-find-bar"))
        let before = pty.written.count
        window.typeText("ok")
        await pump(window)
        #expect(Array(pty.written.dropFirst(before)) == Array("ok".utf8), "\(pty.written)")
        withExtendedLifetime(rig) {}
    }

    @Test func inputWorksAfterFindMovedTheViewport() async throws {
        let (rig, window, store, pty, _) = try await shellWindow()
        await feedHits(pty, window)
        await openBar(store, window)
        window.typeText("hit")
        window.typeKey(.return)
        await pump(window)
        store.closeFind()
        await pump(window)
        let before = pty.written.count
        window.typeText("z")
        await pump(window)
        #expect(Array(pty.written.dropFirst(before)) == [UInt8(ascii: "z")])
        withExtendedLifetime(rig) {}
    }

    @Test func paneExitWhileBarOpenClosesBar() async throws {
        let (rig, window, store, pty, _) = try await shellWindow()
        await openBar(store, window)
        pty.finish(.exited(0))
        await pump(window)
        #expect(store.findPane == nil)
        #expect(!exists(window, "terminal-find-bar"))
        store.find(next: true)
        withExtendedLifetime(rig) {}
    }

    @Test func closingThePaneClosesTheBar() async throws {
        let (rig, window, store, _, pane) = try await shellWindow()
        await openBar(store, window)
        store.closePane(pane)
        await pump(window)
        #expect(store.findPane == nil)
        #expect(!exists(window, "terminal-find-bar"))
        withExtendedLifetime(rig) {}
    }

    @Test func findWithoutAFocusedTerminalIsANoOp() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: ScriptedPtySpawner(), environment: [:])
        store.openFind()
        #expect(store.findPane == nil)
        store.find(next: true)
        store.closeFind()
        withExtendedLifetime(rig) {}
    }

    @Test func findingInAnotherPaneUsesThatPanesScreen() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        let first = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        store.splitActive(axis: .vertical)
        for _ in 0..<5 { window.tick() }
        let second = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        #expect(first != second)
        #expect(spawner.spawned.count == 2)
        spawner.spawned[0].feed(Array("only in first\r\n".utf8))
        spawner.spawned[1].feed(Array("only in second\r\n".utf8))
        await pump(window)
        store.focusPane(first)
        await openBar(store, window)
        #expect(store.findPane == first)
        store.setFindQuery("only in")
        await store.find(next: true)?.value
        #expect(await selected(store, first) == "only in")
        #expect(await selected(store, second) == nil)
        store.focusPane(second)
        await openBar(store, window)
        #expect(store.findPane == second)
        store.setFindQuery("only in")
        await store.find(next: true)?.value
        #expect(await selected(store, second) == "only in")
        withExtendedLifetime(rig) {}
    }

    // MARK: Links

    private func query(_ text: String, col: Int, _ phase: TerminalLinkQuery.Phase = .hover) -> TerminalLinkQuery {
        TerminalLinkQuery(cell: TerminalPosition(row: 0, col: col), rowText: text, phase: phase)
    }

    private func linkRig() async throws -> (Rig, TerminalPanelStore, UUID) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: ScriptedPtySpawner(), environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        return (rig, store, pane)
    }

    private func touch(_ rig: Rig, _ path: String) throws {
        let url = rig.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "line\n".write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func hoverOnPathLineGivesATarget() async throws {
        let (rig, store, pane) = try await linkRig()
        try touch(rig, "Sources/A/B.swift")
        let text = "error: Sources/A/B.swift:12:3 boom"
        let target = try #require(store.linkQuery(pane, query(text, col: 10)))
        #expect(target.columns == 7..<29)
        #expect(target.payload == "file:Sources/A/B.swift:12")
        #expect(store.linkQuery(pane, query(text, col: 2)) == nil)
        withExtendedLifetime(rig) {}
    }

    @Test func resolvesAgainstOSC7CwdThenSpawnCwdThenRoot() async throws {
        let (rig, store, pane) = try await linkRig()
        try touch(rig, "a.swift"); try touch(rig, "sub/a.swift"); try touch(rig, "sub/deep/a.swift")
        rig.workspace.terminalLayout.setCwd(rig.root.appendingPathComponent("sub/deep").path, for: pane)
        let q = query("a.swift:1", col: 2)
        #expect(store.linkQuery(pane, q)?.payload == "file:sub/deep/a.swift:1")
        try FileManager.default.removeItem(at: rig.root.appendingPathComponent("sub/deep/a.swift"))
        #expect(store.linkQuery(pane, q)?.payload == "file:a.swift:1")
        rig.workspace.terminalLayout.setCwd(rig.root.appendingPathComponent("sub").path, for: pane)
        #expect(store.linkQuery(pane, q)?.payload == "file:sub/a.swift:1")
        withExtendedLifetime(rig) {}
    }

    @Test func pathOutsideTheProjectIsNotALink() async throws {
        let (rig, store, pane) = try await linkRig()
        let outside = rig.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "x".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: rig.root.appendingPathComponent("esc.txt"), withDestinationURL: outside)
        #expect(store.linkQuery(pane, query("../../etc/passwd:1", col: 3)) == nil)
        #expect(store.linkQuery(pane, query("\(outside.path):1", col: 3)) == nil)
        #expect(store.linkQuery(pane, query("esc.txt:1", col: 3)) == nil)
        withExtendedLifetime(rig) {}
    }

    @Test func missingFileIsNotALink() async throws {
        let (rig, store, pane) = try await linkRig()
        #expect(store.linkQuery(pane, query("nope.swift:3", col: 2)) == nil)
        withExtendedLifetime(rig) {}
    }

    @Test func lineZeroAndHugeLineClamp() async throws {
        let (rig, store, pane) = try await linkRig()
        try touch(rig, "z.swift")
        #expect(store.linkQuery(pane, query("z.swift:0", col: 1))?.payload == "file:z.swift:1")
        #expect(store.linkQuery(pane, query("z.swift:1000000000000", col: 1))?.payload == "file:z.swift:1")
        withExtendedLifetime(rig) {}
    }

    @Test func activateOpensTheEditorAtTheLine() async throws {
        let (rig, store, pane) = try await linkRig()
        try touch(rig, "Sources/A/B.swift")
        #expect(store.linkQuery(pane, query("Sources/A/B.swift:1", col: 4, .activate)) == nil)
        await rig.workspace.settle()
        let group = rig.workspace.codeLayout.focusedGroupID
        #expect(rig.workspace.activeTab(in: .group(group)) == "Sources/A/B.swift")
        withExtendedLifetime(rig) {}
    }

    @Test func httpLinkOpensInTheBrowserHook() async throws {
        let (rig, store, pane) = try await linkRig()
        var opened: [URL] = []
        store.openURL = { opened.append($0) }
        let text = "see https://example.com/x for more"
        #expect(store.linkQuery(pane, query(text, col: 8))?.payload == "https://example.com/x")
        #expect(opened.isEmpty)
        _ = store.linkQuery(pane, query(text, col: 8, .activate))
        #expect(opened == [URL(string: "https://example.com/x")!])
        withExtendedLifetime(rig) {}
    }

    @Test func exitClearsNothingAndOpensNothing() async throws {
        let (rig, store, pane) = try await linkRig()
        try touch(rig, "q.swift")
        var opened = 0
        store.openURL = { _ in opened += 1 }
        #expect(store.linkQuery(pane, query("q.swift:1", col: 1, .exit)) == nil)
        await rig.workspace.settle()
        #expect(opened == 0 && rig.workspace.activeTab(in: .group(rig.workspace.codeLayout.focusedGroupID)) == nil)
        withExtendedLifetime(rig) {}
    }

    @Test func wideCharactersBeforeAPathKeepColumnsRight() async throws {
        let (rig, store, pane) = try await linkRig()
        try touch(rig, "w.swift")
        let text = "\u{4E2D}\u{6587} w.swift:2"   // two wide characters: 4 cells, a space, the path from cell 5
        let target = try #require(store.linkQuery(pane, query(text, col: 6)))
        #expect(target.columns == 5..<14)
        #expect(store.linkQuery(pane, query(text, col: 1)) == nil)
        withExtendedLifetime(rig) {}
    }
}
