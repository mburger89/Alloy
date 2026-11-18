@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITerminal
import MetalUITesting
import Testing

/// The pane builds MetalUI's `TerminalView` over its session's source, or the overlay when there is none.
@MainActor
@Suite struct TerminalPaneTests {
    private func shellWindow(spawner: ScriptedPtySpawner = ScriptedPtySpawner(), ticks: Int = 5)
        async throws -> (Rig, TestWindow, TerminalPanelStore, ScriptedPtySpawner)
    {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<ticks { window.tick() }
        return (rig, window, store, spawner)
    }

    private func pump(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { try? await Task.sleep(nanoseconds: 10_000_000); window.tick() }
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func focusedPane(_ rig: Rig) throws -> UUID { try #require(rig.workspace.terminalLayout.active?.focusedPane) }

    @Test func runningPaneMountsATerminalView() async throws {
        let (rig, window, _, spawner) = try await shellWindow()
        let pane = try focusedPane(rig)
        await pump(window)
        #expect(exists(window, "terminal-pane-\(pane.uuidString)"))
        let size = try #require(spawner.spawned[0].resizes.last)
        #expect(size.cols != 80 || size.rows != 24)
        #expect(size.cols > 2 && size.rows >= 1)
        withExtendedLifetime(rig) {}
    }

    @Test func resizeReachesThePtyOnce() async throws {
        let (rig, window, _, spawner) = try await shellWindow()
        await pump(window)
        let count = spawner.spawned[0].resizes.count
        #expect(count >= 1)
        await pump(window)
        for _ in 0..<10 { window.tick() }
        #expect(spawner.spawned[0].resizes.count == count)
        withExtendedLifetime(rig) {}
    }

    @Test func exitedPaneShowsOverlayNotView() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        let pane = try focusedPane(rig)
        spawner.spawned[0].finish(.exited(2))
        await pump(window)
        let text = try window.element(identifier: "terminal-exited-text-\(pane.uuidString)")
        #expect(text.value?.contains("[process exited 2]") == true)
        try window.click(window.element(identifier: "terminal-exited-restart"))
        await pump(window)
        #expect(spawner.spawned.count == 2)
        #expect(!exists(window, "terminal-exited-text-\(pane.uuidString)"))
        #expect(store.paneState(pane) == .running)
        try window.click(window.element(identifier: "terminal-pane-\(pane.uuidString)"))
        withExtendedLifetime(rig) {}
    }

    @Test func exitedCloseClosesThePane() async throws {
        let (rig, window, _, spawner) = try await shellWindow()
        spawner.spawned[0].finish(.exited(0))
        await pump(window)
        try window.click(window.element(identifier: "terminal-exited-close"))
        await pump(window)
        #expect(!rig.workspace.terminalVisible)
        withExtendedLifetime(rig) {}
    }

    @Test func restartBindsTheNewSource() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        let pane = try focusedPane(rig)
        let before = try #require(store.snapshotSource(of: pane))
        spawner.spawned[0].finish(.exited(1))
        await pump(window)
        store.restart(pane)
        await pump(window)
        let after = try #require(store.snapshotSource(of: pane))
        #expect(before !== after)
        withExtendedLifetime(rig) {}
    }

    @Test func noSessionNoView() async throws {
        let spawner = ScriptedPtySpawner()
        spawner.failure = .openFailed(code: 2)
        let (rig, window, store, _) = try await shellWindow(spawner: spawner)
        let pane = try focusedPane(rig)
        await pump(window)
        #expect(store.snapshotSource(of: pane) == nil)
        let notice = try #require(store.notice(of: pane))
        let line = try window.element(identifier: "terminal-notice-\(pane.uuidString)")
        #expect(line.value == notice)
        withExtendedLifetime(rig) {}
    }

    @Test func noticeIsShownForCwdFallback() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        let pane = try focusedPane(rig)
        var layout = rig.workspace.terminalLayout
        layout.setCwd("/nonexistent-alloy-dir", for: pane)
        rig.workspace.terminalLayout = layout
        spawner.spawned[0].finish(.exited(0))
        await pump(window)
        store.restart(pane)
        await pump(window)
        let line = try window.element(identifier: "terminal-notice-\(pane.uuidString)")
        #expect(line.value?.contains("not found") == true)
        withExtendedLifetime(rig) {}
    }

    @Test func fontSizeSettingChangesGrid() async throws {
        let (rig, window, _, spawner) = try await shellWindow()
        await pump(window)
        let before = try #require(spawner.spawned[0].resizes.last)
        var settings = rig.workspace.settings
        settings.terminal.fontSize = 20
        try rig.workspace.updateSettings(settings, persist: false)
        await pump(window)
        let after = try #require(spawner.spawned[0].resizes.last)
        #expect(after.cols < before.cols)
        withExtendedLifetime(rig) {}
    }

    // MARK: focus

    /// What the pane wrapper's focus-within change reports. The focus tests below drive the store's
    /// response directly where the view-driven path is not the point.
    private func focusPane(_ store: TerminalPanelStore, _ id: UUID) { store.paneDidChangeFocus(id, focused: true) }

    private func splitWindow() async throws -> (Rig, TestWindow, TerminalPanelStore, UUID, UUID) {
        let (rig, window, store, _) = try await shellWindow()
        let a = try focusedPane(rig)
        store.splitActive(axis: .horizontal)
        await pump(window)
        let b = try focusedPane(rig)
        #expect(a != b)
        store.focusPane(a)
        await pump(window)
        return (rig, window, store, a, b)
    }

    /// A primary press on a `TerminalView` focuses it (MetalUI #376), so the wrapper's `.focused` reads true from a click.
    @Test func clickingAPaneFocusesIt() async throws {
        let (rig, window, store, a, b) = try await splitWindow()
        try window.click(window.element(identifier: "terminal-pane-\(b.uuidString)"))
        await pump(window)
        #expect(store.hasFocus)
        #expect(try focusedPane(rig) == b)
        try window.click(window.element(identifier: "terminal-pane-\(a.uuidString)"))
        await pump(window)
        #expect(try focusedPane(rig) == a)
        #expect(store.hasFocus)
        withExtendedLifetime(rig) {}
    }

    /// Opens a file and clicks its code view, moving keyboard focus out of the terminal.
    private func clickEditor(_ rig: Rig, _ window: TestWindow) async throws {
        try "let x = 1\n".write(to: rig.root.appendingPathComponent("focus.swift"), atomically: true, encoding: .utf8)
        let g0 = rig.workspace.codeLayout.focusedGroupID
        await rig.workspace.open("focus.swift", in: .group(g0))
        await pump(window, 6)
        try window.click(window.element(identifier: "code-view-\(g0.uuidString)"))
        await pump(window)
    }

    @Test func blurringTheNonFocusedPaneKeepsFocus() async throws {
        let (rig, window, store, a, b) = try await splitWindow()
        focusPane(store, b)
        await pump(window)
        #expect(store.hasFocus)
        store.paneDidChangeFocus(a, focused: false)
        #expect(store.hasFocus, "A is not the focused pane")
        store.paneDidChangeFocus(b, focused: false)
        #expect(!store.hasFocus)
        withExtendedLifetime(rig) {}
    }

    @Test func focusSetsNothingOnKeys() async throws {
        let (rig, window, store, _, _) = try await splitWindow()
        try await clickEditor(rig, window)
        #expect(!store.hasFocus)
        for _ in 0..<5 { window.typeText("a"); window.tick() }
        await pump(window)
        #expect(!store.hasFocus)
        withExtendedLifetime(rig) {}
    }

    @Test func hiddenPanelHasNoFocus() async throws {
        let (rig, window, store, _, b) = try await splitWindow()
        focusPane(store, b)
        await pump(window)
        #expect(store.hasFocus)
        rig.workspace.toggleTerminal()
        await pump(window)
        #expect(!store.hasFocus)
        withExtendedLifetime(rig) {}
    }

    @Test func focusChangeCostsOneRerunAndNoElementRequests() async throws {
        let (rig, window, store, a, b) = try await splitWindow()
        focusPane(store, a)
        await pump(window)
        let before = BodyProbe.count("TerminalPaneView")
        focusPane(store, b)
        await pump(window, 4)
        #expect(BodyProbe.count("TerminalPaneView") - before <= 2, "A and B each at most once")
        window.resetFrameWork()
        for _ in 0..<10 { window.tick() }
        #expect(window.frameWork.allSatisfy { $0.elementRequests == 0 }, "\(window.frameWork.map(\.elementRequests))")
        #expect(store.hasFocus)
        withExtendedLifetime(rig) {}
    }
}
