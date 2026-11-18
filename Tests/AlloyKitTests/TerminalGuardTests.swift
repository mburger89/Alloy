@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITerminal
import MetalUITesting
import Testing

/// A hidden terminal panel costs nothing; a visible idle one costs nothing per frame.
@MainActor
@Suite struct TerminalGuardTests {
    private let perf = CodeModePerformanceTests()

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    private func openThenHide(_ workspace: Workspace, _ window: TestWindow, rich: Bool = false) {
        workspace.toggleTerminal(); for _ in 0..<3 { window.tick() }
        if rich {
            workspace.newTerminalTab(); workspace.newTerminalTab()
            var layout = workspace.terminalLayout
            layout.split(axis: .horizontal)
            workspace.terminalLayout = layout
            for _ in 0..<3 { window.tick() }
        }
        workspace.toggleTerminal(); for _ in 0..<3 { window.tick() }
    }

    private func guardCode(_ layout: CodeModePerformanceTests.Layout, steady: Int, hidden: Bool) async throws {
        let (rig, window, id) = try await perf.rigged(layout)
        if hidden { openThenHide(rig.workspace, window, rich: true) } else { rig.workspace.toggleTerminal() }
        for _ in 0..<3 { window.tick() }
        if hidden { #expect(!exists(window, "code-terminal") && !exists(window, "code-terminal-panel")) }
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        #expect(t.documentGrew)
        #expect(t.bodies == 0)
        // Hidden measures the steady constants exactly; the visible panel is pinned to its own measured constant.
        #expect(t.perFrame.allSatisfy { $0 <= steady }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= steady * 20, "element requests \(t.requests)")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func terminalHiddenHoldsCodeGuards() async throws {
        try await guardCode(.code1, steady: CodeModePerformanceTests.steadyCode1, hidden: true)
        try await guardCode(.code2, steady: CodeModePerformanceTests.steadyCode2, hidden: true)
        try await guardCode(.code3, steady: CodeModePerformanceTests.steadyCode3, hidden: true)
    }

    @Test func terminalHiddenHoldsChatGuard() async throws {
        let (rig, window, id) = try await perf.rigged(.chat)
        openThenHide(rig.workspace, window)
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        let steady = ViewRerunTests.steadyFrameRequests
        #expect(t.perFrame.allSatisfy { $0 <= steady }, "per-frame element requests \(t.perFrame)")
        #expect(!exists(window, "code-terminal"))
        withExtendedLifetime((rig, window)) {}
    }

    @Test func chatModeHasNoTerminalSurface() async throws {
        let (rig, window, _) = try await perf.rigged(.code1)
        rig.workspace.toggleTerminal()
        rig.workspace.setMode(.chat)
        for _ in 0..<3 { window.tick() }
        #expect(!exists(window, "code-terminal-panel"))
        #expect(rig.workspace.terminalLayout.active.map { !exists(window, "terminal-pane-\($0.focusedPane.uuidString)") } ?? false)
    }

    @Test func idleVisibleTerminalCostsNothing() async throws {
        let (rig, window, _) = try await perf.rigged(.code1)
        rig.workspace.toggleTerminal()
        for _ in 0..<10 { window.tick() }
        window.resetFrameWork()
        let before = BodyProbe.count("TerminalPanel")
        for _ in 0..<20 { window.tick() }
        #expect(BodyProbe.count("TerminalPanel") == before)
        #expect(window.frameWork.allSatisfy { $0.elementRequests == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime(rig) {}
    }

    /// Code 1 with the panel visible, measured: 55 element requests per frame, 9 more than `steadyCode1`: the split and
    /// its divider (7) and the pane's own frame (2). The panel body never reruns
    /// while typing.
    static let visiblePanelBaseline = 55
    /// A keystroke frame with a visible `TerminalView` costs no extra element requests since MetalUI surface replay (#362).
    static let knownVisibleTerminalGap = 0
    /// Measured 5 before surface replay (#362); 0 now.
    static let knownTerminalViewExcess = 0

    @Test func typingInEditorWithPanelVisibleHoldsGuard() async throws {
        try await guardCode(.code1, steady: Self.visiblePanelBaseline + Self.knownVisibleTerminalGap + Self.knownTerminalViewExcess, hidden: false)
    }

    /// Typing into a focused, visible terminal is surface-only: no body reruns and no more element requests than a keystroke in the editor.
    @Test func typingInTerminalIsSurfaceOnly() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<10 { window.tick() }
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        try window.click(window.element(identifier: "terminal-pane-\(pane.uuidString)"))
        for _ in 0..<10 { window.tick() }
        window.resetFrameWork()
        for _ in 0..<5 { window.tick() }
        let idle = window.frameWork.map(\.elementRequests).max() ?? 0
        let panel = BodyProbe.count("TerminalPanel"), row = BodyProbe.count("CodeIslandRow")
        window.resetFrameWork()
        for c in "abcdefghijklmnopqrst" { window.typeText(String(c)) }
        // A key event frame re-requests the whole tree like a keystroke in the editor does (54 here, 55 with the editor
        // focused: `visiblePanelBaseline`); the terminal adds nothing and reruns no body.
        #expect(idle == 0)
        #expect(window.frameWork.allSatisfy { $0.elementRequests <= Self.visiblePanelBaseline }, "\(window.frameWork.map(\.elementRequests))")
        #expect(BodyProbe.count("TerminalPanel") == panel && BodyProbe.count("CodeIslandRow") == row)
        #expect(spawner.spawned.first?.written.count == 20)
        withExtendedLifetime(rig) {}
    }

    private func focusedTerminal() async throws -> (Rig, TestWindow, TerminalPanelStore, UUID) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: ScriptedPtySpawner(), environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<10 { window.tick() }
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        try window.click(window.element(identifier: "terminal-pane-\(pane.uuidString)"))
        for _ in 0..<10 { window.tick() }
        return (rig, window, store, pane)
    }

    @Test func linkHoverIsSurfaceOnly() async throws {
        let (rig, window, _, pane) = try await focusedTerminal()
        let terminal = try window.element(identifier: "terminal-pane-\(pane.uuidString)")
        window.resetFrameWork()
        for _ in 0..<3 { window.tick() }
        let idle = window.frameWork.map(\.elementRequests).max() ?? 0
        let panel = BodyProbe.count("TerminalPanel")
        window.pressModifiers(.command)
        window.resetFrameWork()
        let frame = terminal.frame
        for i in 1..<6 {
            window.hover(at: Point(x: frame.origin.x + Pixels(Float(i) * 17), y: frame.origin.y + Pixels(40)))
        }
        #expect(idle == 0)
        #expect(window.frameWork.allSatisfy { $0.elementRequests <= Self.visiblePanelBaseline }, "\(window.frameWork.map(\.elementRequests))")
        #expect(BodyProbe.count("TerminalPanel") == panel)
        withExtendedLifetime(rig) {}
    }

    private func idleRequests(_ window: TestWindow) -> [Int] {
        window.resetFrameWork()
        for _ in 0..<10 { window.tick() }
        return window.frameWork.map(\.elementRequests)
    }

    @Test func findBarClosedCostsNothing() async throws {
        let (rig, window, _, _) = try await focusedTerminal()
        let bar = BodyProbe.count("TerminalFindBar"), panel = BodyProbe.count("TerminalPanel")
        #expect(idleRequests(window).allSatisfy { $0 == 0 })
        #expect(BodyProbe.count("TerminalFindBar") == bar && BodyProbe.count("TerminalPanel") == panel)
        #expect(!exists(window, "terminal-find-bar"))
        withExtendedLifetime(rig) {}
    }

    @Test func findBarOpenIdleCostsNothing() async throws {
        let (rig, window, store, _) = try await focusedTerminal()
        store.openFind()
        for _ in 0..<10 { window.tick() }
        #expect(exists(window, "terminal-find-bar"))
        let panel = BodyProbe.count("TerminalPanel")
        #expect(idleRequests(window).allSatisfy { $0 == 0 })
        #expect(BodyProbe.count("TerminalPanel") == panel)
        withExtendedLifetime(rig) {}
    }

    /// A key frame re-requests the whole tree; an open bar adds its own 13 elements (measured 68 against 55), nothing else.
    static let findBarElements = 13

    @Test func typingInFindFieldRerunsTheBarOnly() async throws {
        let (rig, window, store, _) = try await focusedTerminal()
        store.openFind()
        for _ in 0..<10 { window.tick() }
        let panel = BodyProbe.count("TerminalPanel"), row = BodyProbe.count("CodeIslandRow"), pane = BodyProbe.count("TerminalPaneView")
        window.resetFrameWork()
        window.typeText("abc")
        for _ in 0..<5 { window.tick() }
        #expect(store.findQuery == "abc")
        #expect(BodyProbe.count("TerminalPanel") == panel && BodyProbe.count("CodeIslandRow") == row)
        #expect(BodyProbe.count("TerminalPaneView") == pane)
        #expect(window.frameWork.allSatisfy { $0.elementRequests <= Self.visiblePanelBaseline + Self.findBarElements }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime(rig) {}
    }

    private func visibleWindow() async throws -> (Rig, TestWindow, TerminalPanelStore) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        rig.workspace.toggleTerminal()
        let store = TerminalPanelStore(workspace: rig.workspace)
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        return (rig, window, store)
    }

    @Test func titleSpamRerunsTabStripOnce() async throws {
        let (rig, window, store) = try await visibleWindow()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let before = BodyProbe.count("TerminalTabStrip")
        for i in 0..<1000 { store.setTitle(i.isMultiple(of: 2) ? "a" : "b", for: pane) }
        window.tick(); window.tick()
        #expect(BodyProbe.count("TerminalTabStrip") - before <= 1)
        let settled = BodyProbe.count("TerminalTabStrip"), panel = BodyProbe.count("TerminalPanel")
        for _ in 0..<1000 { store.setTitle("b", for: pane) }
        for _ in 0..<3 { window.tick() }
        #expect(BodyProbe.count("TerminalTabStrip") == settled && BodyProbe.count("TerminalPanel") == panel)
    }

    @Test func tabStripRerunsOnlyOnTabChanges() async throws {
        let (rig, window, id) = try await perf.rigged(.code1)
        rig.workspace.toggleTerminal()
        for _ in 0..<5 { window.tick() }
        #expect(exists(window, "code-terminal-panel"))
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched + ["TerminalPanel", "TerminalTabStrip"])
        #expect(t.documentGrew)
        #expect(t.reruns["TerminalPanel", default: 0] == 0 && t.reruns["TerminalTabStrip", default: 0] == 0, "\(t.reruns)")
        withExtendedLifetime((rig, window)) {}
    }

    // MARK: Real shells (scripted ptys) behind the panel

    /// Feeds `bytes` to a scripted pty in 64 KiB chunks.
    private func stream(_ pty: ScriptedPty, bytes: Int) {
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 64 * 1024)
        var left = bytes
        while left > 0 { pty.feed(Array(chunk.prefix(min(left, chunk.count)))); left -= chunk.count }
    }

    private func settleOutput(_ window: TestWindow) async {
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            window.tick()
        }
    }

    /// The owning store (with the scripted spawner) goes in before the rig builds its window.
    private func guardCodeWithShells(_ layout: CodeModePerformanceTests.Layout, steady: Int) async throws {
        let spawner = ScriptedPtySpawner()
        var owner: TerminalPanelStore?
        let (rig, window, id) = try await perf.rigged(layout, install: { rig in
            owner = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        })
        openThenHide(rig.workspace, window, rich: true)
        #expect(spawner.spawned.count >= 1)
        for pty in spawner.spawned { stream(pty, bytes: 4 * 1024 * 1024 / max(spawner.spawned.count, 1)) }
        await settleOutput(window)
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        #expect(t.documentGrew)
        #expect(t.bodies == 0)
        #expect(t.perFrame.allSatisfy { $0 <= steady }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= steady * 20, "element requests \(t.requests)")
        withExtendedLifetime((rig, window, owner)) {}
    }

    @Test func runningShellsHoldTheCodeGuards() async throws {
        try await guardCodeWithShells(.code1, steady: CodeModePerformanceTests.steadyCode1)
        try await guardCodeWithShells(.code2, steady: CodeModePerformanceTests.steadyCode2)
        try await guardCodeWithShells(.code3, steady: CodeModePerformanceTests.steadyCode3)
        let spawner = ScriptedPtySpawner()
        var owner: TerminalPanelStore?
        let (rig, window, id) = try await perf.rigged(.chat, install: { rig in
            owner = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        })
        openThenHide(rig.workspace, window, rich: true)
        for pty in spawner.spawned { stream(pty, bytes: 1024 * 1024) }
        await settleOutput(window)
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        #expect(t.perFrame.allSatisfy { $0 <= ViewRerunTests.steadyFrameRequests }, "\(t.perFrame)")
        withExtendedLifetime((rig, window, owner)) {}
    }

    private func shellWindow() async throws -> (Rig, TestWindow, TerminalPanelStore, ScriptedPtySpawner) {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        rig.workspace.toggleTerminal()
        let window = try alloyWindow(rig.workspace, terminal: store)
        for _ in 0..<5 { window.tick() }
        return (rig, window, store, spawner)
    }

    @Test func idleShellCausesNoFrames() async throws {
        let (rig, window, _, spawner) = try await shellWindow()
        #expect(spawner.spawned.count == 1)
        for _ in 0..<10 { window.tick() }
        window.resetFrameWork()
        let before = BodyProbe.count("TerminalPanel")
        for _ in 0..<20 { window.tick() }
        #expect(BodyProbe.count("TerminalPanel") == before)
        #expect(window.frameWork.allSatisfy { $0.elementRequests == 0 }, "\(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime(rig) {}
    }

    @Test func outputToAVisibleTerminalIsSurfaceOnly() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let session = try #require(store.manager?.session(for: pane))
        stream(spawner.spawned[0], bytes: 1024 * 1024)
        await settleOutput(window)
        let paneBefore = BodyProbe.count("TerminalPaneView"), panel0 = BodyProbe.count("TerminalPanel")
        for _ in 0..<1000 { await session.apply([.title("same")]) }
        await settleOutput(window)
        #expect(BodyProbe.count("TerminalPaneView") - paneBefore <= 1)
        #expect(BodyProbe.count("TerminalPanel") - panel0 <= 1)   // the first distinct title only
        let settled = BodyProbe.count("TerminalPaneView"), panel = BodyProbe.count("TerminalPanel")
        for _ in 0..<1000 { await session.apply([.title("same")]) }
        window.resetFrameWork()
        stream(spawner.spawned[0], bytes: 256 * 1024)
        await settleOutput(window)
        #expect(BodyProbe.count("TerminalPaneView") == settled)
        #expect(BodyProbe.count("TerminalPanel") == panel)
        // Output frames are surface-only: no element request however much arrived.
        #expect(window.frameWork.allSatisfy { $0.elementRequests == 0 }, "\(window.frameWork.map(\.elementRequests))")
        window.resetFrameWork()
        for _ in 0..<20 { window.tick() }
        #expect(window.frameWork.allSatisfy { $0.elementRequests == 0 }, "\(window.frameWork.map(\.elementRequests))")
    }

    @Test func oscTitleSpamThroughThePtyRerunsTabStripOnce() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        _ = store
        let before = BodyProbe.count("TerminalTabStrip")
        var bytes: [UInt8] = []
        for i in 0..<1000 { bytes += Array("\u{1B}]0;\(i.isMultiple(of: 2) ? "a" : "b")\u{07}".utf8) }
        spawner.spawned[0].feed(bytes)
        await settleOutput(window)
        #expect(BodyProbe.count("TerminalTabStrip") - before <= 1)
        let settled = BodyProbe.count("TerminalTabStrip"), pane = BodyProbe.count("TerminalPaneView")
        let again = Array(String(repeating: "\u{1B}]0;b\u{07}", count: 1000).utf8)
        spawner.spawned[0].feed(again)
        await settleOutput(window)
        #expect(BodyProbe.count("TerminalTabStrip") == settled && BodyProbe.count("TerminalPaneView") == pane)
        withExtendedLifetime(rig) {}
    }

    @Test func exitRerunsTheStripOnce() async throws {
        let (rig, window, store, spawner) = try await shellWindow()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let strip = BodyProbe.count("TerminalTabStrip"), paneBefore = BodyProbe.count("TerminalPaneView")
        spawner.spawned[0].finish(.exited(2))
        await settleOutput(window)
        #expect(store.paneState(pane) == .exited(2))
        #expect(BodyProbe.count("TerminalPaneView") - paneBefore == 1)
        #expect(BodyProbe.count("TerminalTabStrip") - strip <= 1)
    }

    @Test func hiddenPanelDoesNotBlockChild() async throws {
        let (rig, window, _, spawner) = try await shellWindow()
        rig.workspace.toggleTerminal()
        for _ in 0..<3 { window.tick() }
        let panel = BodyProbe.count("TerminalPanel")
        let pty = spawner.spawned[0]
        let total = 50 * 1024 * 1024
        stream(pty, bytes: total)
        // Every queued byte gets read: the child is never left blocked on a full pty.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, pty.readCalls.reduce(0, +) < total { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(pty.readCalls.reduce(0, +) >= total)
        for _ in 0..<3 { window.tick() }
        #expect(BodyProbe.count("TerminalPanel") == panel)
    }
}
