@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct TerminalQuitTests {
    /// The workspace holds the store weakly, so the rig keeps it alive for the test's duration.
    private var keep: [TerminalPanelStore] { get { Self.kept } set { Self.kept = newValue } }
    private static var kept: [TerminalPanelStore] = []

    private func busyRig(_ count: Int) -> (Rig, LauncherModel, TerminalPanelStore) {
        let rig = Rig()
        let store = TerminalPanelStore(workspace: rig.workspace)
        for _ in 0..<count { store.setBusy(true, for: UUID()) }
        Self.kept = [store]
        return (rig, LauncherModel(workspace: rig.workspace), store)
    }

    private func settled(_ replies: @autoclosure () -> Int, _ n: Int = 1) async {
        while replies() < n { await Task.yield() }
        for _ in 0..<100 { await Task.yield() }
    }

    @Test func noBusyTerminalQuitsWithoutPrompt() async {
        let (_, model, _) = busyRig(0)
        var replies: [Bool] = []
        #expect(model.shutdownRequested { replies.append($0) } == .later)
        #expect(model.quitPrompt == nil)
        await settled(replies.count)
        #expect(replies == [true])
    }

    @Test func twoBusyAsksOnceWithPluralText() async {
        let (_, model, _) = busyRig(2)
        var replies: [Bool] = []
        #expect(model.shutdownRequested { replies.append($0) } == .later)
        #expect(model.quitPrompt == "2 terminals are running a process. Quit anyway?")
        for _ in 0..<50 { await Task.yield() }
        #expect(replies.isEmpty)
    }

    @Test func oneBusyUsesSingularText() {
        let (_, model, _) = busyRig(1)
        _ = model.shutdownRequested { _ in }
        #expect(model.quitPrompt == "1 terminal is running a process. Quit anyway?")
    }

    @Test func confirmQuitContinuesShutdown() async {
        let (rig, model, _) = busyRig(2)
        var hookRuns = 0
        rig.workspace.addStopHook { hookRuns += 1 }
        var replies: [Bool] = []
        _ = model.shutdownRequested { replies.append($0) }
        model.answerQuitPrompt(true)
        #expect(model.quitPrompt == nil)
        await settled(replies.count)
        #expect(replies == [true])
        #expect(hookRuns == 1)
        #expect(rig.workspace.isShuttingDown)
    }

    @Test func cancelRepliesFalseAndDoesNotStop() async {
        let (rig, model, _) = busyRig(2)
        var hookRuns = 0
        rig.workspace.addStopHook { hookRuns += 1 }
        var replies: [Bool] = []
        _ = model.shutdownRequested { replies.append($0) }
        model.answerQuitPrompt(false)
        #expect(replies == [false])
        #expect(model.quitPrompt == nil)
        for _ in 0..<100 { await Task.yield() }
        #expect(!rig.workspace.isShuttingDown)
        #expect(hookRuns == 0)
        // A later quit asks again.
        _ = model.shutdownRequested { _ in }
        #expect(model.quitPrompt != nil)
    }

    @Test func secondRequestWhileAskingDoesNotStackAlerts() async {
        let (_, model, _) = busyRig(2)
        var a: [Bool] = []
        var b: [Bool] = []
        #expect(model.shutdownRequested { a.append($0) } == .later)
        let prompt = model.quitPrompt
        #expect(model.shutdownRequested { b.append($0) } == .later)
        #expect(model.quitPrompt == prompt)
        model.answerQuitPrompt(false)
        #expect(a == [false])
        #expect(b == [false])
    }

    @Test func windowCloseUsesTheSameCheck() throws {
        let (rig, model, _) = busyRig(1)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: model, center: testCenter(for: model)) }
        installWindowShutdown(on: window.window, model: model)
        window.tick()
        // The root view installs its own store; stand in for its busy panes.
        rig.workspace.busyTerminalCount = { 1 }
        #expect(window.requestClose() == false)
        #expect(model.quitPrompt != nil)
        #expect(!window.platformWindow.isClosed)
    }

    @Test func alertShowsInTheWindow() throws {
        let (rig, model, _) = busyRig(2)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: model, center: testCenter(for: model)) }
        window.tick()
        rig.workspace.busyTerminalCount = { 2 }
        _ = model.shutdownRequested { _ in }
        window.tick(); window.tick()
        // The headless window records alerts it would show natively.
        let alert = try #require(window.platformWindow.presentedAlerts.last)
        #expect(alert.message == "2 terminals are running a process. Quit anyway?")
        #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])
    }

    @Test func rebuiltRootKeepsTheBusyHook() throws {
        let (rig, model, _) = busyRig(1)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: model, center: testCenter(for: model)) }
        installWindowShutdown(on: window.window, model: model)
        window.tick()
        // A model change reruns the root, which builds throwaway stores.
        _ = model.shutdownRequested { _ in }; window.tick(); window.tick()
        model.answerQuitPrompt(false); window.tick(); window.tick()
        #expect(rig.workspace.busyTerminalCount?() == 1)
        #expect(window.requestClose() == false)
        #expect(model.quitPrompt != nil)
    }

    @Test func menuTogglePathClearsFocus() {
        let rig = Rig()
        let store = TerminalPanelStore(workspace: rig.workspace)
        Self.kept = [store]
        rig.workspace.toggleTerminal()
        store.hasFocus = true
        rig.workspace.toggleTerminal()
        #expect(!rig.workspace.terminalVisible && !store.hasFocus)
    }
}
