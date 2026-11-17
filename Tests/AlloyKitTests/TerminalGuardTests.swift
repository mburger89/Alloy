@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
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

    /// Code 1 with the panel visible, measured: 100 element requests per frame, 9 more than `steadyCode1`. Breakdown, by
    /// swapping parts: a plain VStack in place of the VSplitView gives 93, so the split and its divider cost 7 and are
    /// unavoidable; the remaining 2 are the pane's own text and frame. Dropping the HStack/ForEach/frame/accessibility
    /// wrappers around a single pane changed nothing (93), so they are free. The panel body never reruns while typing
    /// (0 body evaluations). A hidden panel holds `steadyCode1` exactly.
    static let steadyCode1WithTerminal = 100

    @Test func typingInEditorWithPanelVisibleHoldsGuard() async throws {
        try await guardCode(.code1, steady: Self.steadyCode1WithTerminal, hidden: false)
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
}
