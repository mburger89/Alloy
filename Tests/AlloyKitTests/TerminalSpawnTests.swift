@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyTerminal
import AlloyTestSupport
import Foundation
import MetalUITerminal
import Testing

@MainActor
@Suite struct TerminalSpawnTests {
    private final class Keep { nonisolated(unsafe) static var stores: [TerminalPanelStore] = [] }

    private func rig(grace: Duration = .seconds(1)) -> (Rig, TerminalPanelStore, ScriptedPtySpawner) {
        let rig = Rig()
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"],
                                       graceBeforeKill: grace)
        Keep.stores.append(store)
        return (rig, store, spawner)
    }

    private func settle(_ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func quiet() async { for _ in 0..<50 { await Task.yield() }; try? await Task.sleep(nanoseconds: 50_000_000) }

    private func tab(_ cwd: String, _ pane: UUID = UUID()) -> TerminalTab {
        TerminalTab(id: UUID(), tree: .pane(pane), panes: [pane: TerminalPane(id: pane, lastCwd: cwd)], focusedPane: pane)
    }

    @Test func hiddenPanelSpawnsNothing() async {
        let (rig, _, spawner) = rig()
        let a = tab("/tmp"), b = tab("/tmp")
        rig.workspace.terminalLayout = TerminalLayout(visible: false, tabs: [a, b], activeTab: a.id)
        await quiet()
        #expect(spawner.requests.isEmpty)
    }

    @Test func showingThePanelSpawnsOneShellInTheProjectRoot() async {
        let (rig, _, spawner) = rig()
        rig.workspace.toggleTerminal()
        #expect(spawner.requests.count == 1)
        #expect(spawner.requests[0].cwd == rig.workspace.projectRoot.path)
        rig.workspace.toggleTerminal(); rig.workspace.toggleTerminal()
        await quiet()
        #expect(spawner.requests.count == 1)
    }

    @Test func newTabSpawnsItsPane() {
        let (rig, _, spawner) = rig()
        rig.workspace.toggleTerminal()
        rig.workspace.newTerminalTab()
        #expect(spawner.requests.count == 2)
    }

    @Test func selectingATabSpawnsItsFocusedPaneOnce() async {
        let (rig, store, spawner) = rig()
        let a = tab(rig.workspace.projectRoot.path), b = tab(rig.workspace.projectRoot.path)
        rig.workspace.terminalLayout = TerminalLayout(visible: true, tabs: [a, b], activeTab: a.id)
        #expect(spawner.requests.count == 1)
        store.selectTab(b.id)
        #expect(spawner.requests.count == 2)
        store.selectTab(a.id); store.selectTab(b.id)
        await quiet()
        #expect(spawner.requests.count == 2)
    }

    @Test func relaunchRestoresLazily() async {
        let (rig, store, spawner) = rig()
        let dir = FileManager.default.temporaryDirectory.path
        let a = tab(dir), b = tab(dir), c = tab(dir)
        rig.workspace.terminalLayout = TerminalLayout(visible: true, tabs: [a, b, c], activeTab: b.id)
        #expect(spawner.requests.count == 1)
        #expect(spawner.requests[0].cwd == dir)
        store.selectTab(c.id)
        #expect(spawner.requests.count == 2)
    }

    @Test func splitSpawnsTheNewPane() {
        let (rig, store, spawner) = rig()
        rig.workspace.toggleTerminal()
        store.splitActive(axis: .horizontal)
        #expect(spawner.requests.count == 2)
    }

    @Test func closingAPaneTerminatesItsSessionAndDropsStaleExit() async throws {
        let (rig, store, spawner) = rig()
        rig.workspace.toggleTerminal()
        store.splitActive(axis: .horizontal)
        let ids = try #require(rig.workspace.terminalLayout.active).tree.paneIDs
        store.closePane(ids[1])
        #expect(await settle { spawner.spawned[1].signals.first == .hangup })
        spawner.spawned[1].finish(.exited(5))
        await quiet()
        #expect(store.paneState(ids[1]) == .running)
        #expect(store.manager?.session(for: ids[1]) == nil)
    }

    @Test func titleAndExitFlowIntoTheStore() async throws {
        let (rig, store, spawner) = rig()
        rig.workspace.toggleTerminal()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let session = try #require(store.manager?.session(for: pane))
        let before = store.revision
        session.apply([.title("vim")])
        #expect(await settle { store.title(of: pane) == "vim" })
        #expect(store.revision == before + 1)
        store.restart(pane)   // running: nothing
        #expect(spawner.requests.count == 1)
        spawner.spawned[0].finish(.exited(3))
        #expect(await settle { store.paneState(pane) == .exited(3) })
        store.restart(pane)
        #expect(spawner.requests.count == 2)
        #expect(store.paneState(pane) == .running)
    }

    @Test func workingDirectoryUpdatesLastCwdOnlyWhenChanged() async throws {
        let (rig, store, _) = rig()
        rig.workspace.toggleTerminal()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let session = try #require(store.manager?.session(for: pane))
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        session.apply([.workingDirectory(URL(fileURLWithPath: dir))])
        #expect(await settle { rig.workspace.terminalLayout.active?.panes[pane]?.lastCwd == dir })
        let writes = rig.workspace.uiStateWriteCount
        session.apply([.workingDirectory(URL(fileURLWithPath: dir))])
        await quiet()
        #expect(rig.workspace.uiStateWriteCount == writes)
    }

    @Test func stopAllRunsTheTerminalHook() async {
        let (rig, _, spawner) = rig()
        rig.workspace.toggleTerminal()
        rig.workspace.newTerminalTab()
        var other = 0
        rig.workspace.addStopHook { other += 1 }
        await rig.workspace.stopAll()
        #expect(spawner.spawned.count == 2)
        #expect(spawner.spawned.allSatisfy { $0.signals.first == .hangup })
        #expect(other == 1)
    }

    @Test func aSecondStoreDoesNotReplaceTheLiveManager() async {
        let (rig, first, spawner) = rig()
        let second = TerminalPanelStore(workspace: rig.workspace, spawner: ScriptedPtySpawner())
        #expect(first.manager != nil && second.manager == nil)
        rig.workspace.toggleTerminal()
        await quiet()
        #expect(spawner.requests.count == 1)
    }

    @Test func busyCountComesFromTheManager() {
        let (rig, _, spawner) = rig()
        rig.workspace.toggleTerminal()
        rig.workspace.newTerminalTab()
        #expect(rig.workspace.busyTerminalCount?() == 0)
        spawner.spawned[0].foreground = spawner.spawned[0].processID + 1
        #expect(rig.workspace.busyTerminalCount?() == 1)
    }

    @Test func spawnFailureShowsExitedWithNoticeAndNoRetry() async throws {
        let (rig, store, spawner) = rig()
        spawner.failure = .openFailed(code: 2)
        rig.workspace.toggleTerminal()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        #expect(store.paneState(pane) == .exited(127))
        #expect(store.notice(of: pane) != nil)
        rig.workspace.newTerminalTab()
        await quiet()
        #expect(spawner.requests.count == 2)
    }

    private final class Tracking: PtySpawner, @unchecked Sendable {
        private let lock = NSLock()
        private var _pids: [Int32] = []
        var pids: [Int32] { lock.withLock { _pids } }
        func spawn(_ request: PtySpawnRequest) throws(PseudoTerminalError) -> any PtyHandle {
            let pty = try LivePtySpawner().spawn(request)
            lock.withLock { _pids.append(pty.processID) }
            return pty
        }
    }

    /// True when the process is gone or a zombie.
    private func isGone(_ pid: Int32) -> Bool {
        if kill(pid, 0) != 0 { return true }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "stat=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = Pipe()
        do { try ps.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let state = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return state.isEmpty || state.hasPrefix("Z")
    }

    @Test(.timeLimit(.minutes(1))) func liveShellThroughTheStore() async throws {
        let rig = Rig()
        var settings = rig.workspace.settings
        settings.terminal.shellPath = "/bin/sh"
        try rig.workspace.updateSettings(settings, persist: false)
        let tracking = Tracking()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: tracking,
                                       environment: ["PATH": "/usr/bin:/bin", "HOME": rig.root.path],
                                       graceBeforeKill: .milliseconds(200))
        Keep.stores.append(store)
        defer { for pid in tracking.pids { kill(-pid, SIGKILL); kill(pid, SIGKILL) } }
        rig.workspace.toggleTerminal()
        let pane = try #require(rig.workspace.terminalLayout.active?.focusedPane)
        let manager = try #require(store.manager)
        let session = try #require(manager.session(for: pane))
        manager.write(pane, Array("echo ok\n".utf8))
        var seen = false
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !seen {
            let rows = await session.withEmulator { e in
                (e.firstRow..<(e.firstRow + 30)).compactMap { e.rowText($0) }
            }
            seen = rows.contains { $0.trimmingCharacters(in: .whitespaces) == "ok" }
            if !seen { try await Task.sleep(nanoseconds: 20_000_000) }
        }
        #expect(seen)
        let tab = try #require(rig.workspace.terminalLayout.active).id
        store.closeTab(tab)
        await rig.workspace.stopAll()
        let pids = tracking.pids
        #expect(pids.count >= 1)
        #expect(await settle { pids.allSatisfy { self.isGone($0) } })
    }
}
