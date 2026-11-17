import AlloyCore
import AlloyTerminal
import Foundation
import MetalUI

/// The terminal panel's shell state. The layout itself lives in `Workspace.terminalLayout`; this holds what is not persisted
/// (focus) and the actions the panel and the menu share. `visible` reads a flag of its own on the workspace, so the island
/// row reruns when the panel appears or disappears, never when a tab changes.
@MainActor @Observable
final class TerminalPanelStore {
    @ObservationIgnored let workspace: Workspace
    /// True while a terminal pane has keyboard focus. Set by the pane's focus change, not by keys.
    var hasFocus = false

    /// Per-pane transient state. Plain storage plus one observed `revision`, bumped only when a value changes, so repeating
    /// a title (or spamming alternating ones inside one frame) costs at most one rerun.
    @ObservationIgnored private var titles: [UUID: String] = [:]
    @ObservationIgnored private var states: [UUID: TerminalPaneState] = [:]
    private(set) var revision = 0
    /// Called by `restart(_:)`; the manager's restart is installed by the owning store. Nothing restarts on its own.
    @ObservationIgnored var onRestart: ((UUID) -> Void)?
    @ObservationIgnored lazy var splitStore = UIStateSplitStore(workspace: workspace)
    /// The last notice per pane (spawn failure, fallback cwd); no view reads it yet.
    @ObservationIgnored private var notices: [UUID: String] = [:]

    /// Owns the shells of this window. Nil on a store that did not become the hooks owner.
    @ObservationIgnored private(set) var manager: TerminalManager?

    init(workspace: Workspace, spawner: any PtySpawner = LivePtySpawner(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         graceBeforeKill: Duration = .seconds(1)) {
        self.workspace = workspace
        // AlloyScreen.init builds a store on every rebuild and State keeps only the first, so a later store must not
        // replace the hooks of the live one.
        if workspace.terminalHooksOwner == nil {
            workspace.terminalHooksOwner = self
            let manager = TerminalManager(
                spawner: spawner, settings: { [weak workspace] in workspace?.settings.terminal ?? TerminalSettings() },
                projectRoot: workspace.projectRoot.path, environment: environment, graceBeforeKill: graceBeforeKill,
                delegate: .init(
                    title: { [weak self] pane, title in self?.setTitle(title, for: pane) },
                    workingDirectory: { [weak self] pane, path in self?.setWorkingDirectory(path, for: pane) },
                    exited: { [weak self] pane, status in self?.markExited(pane, status: status) },
                    notice: { [weak self] pane, text in self?.setNotice(text, for: pane) }))
            self.manager = manager
            workspace.busyTerminalCount = { manager.busyPanes().count }
            workspace.onTerminalHidden = { [weak self] in self?.hasFocus = false }
            workspace.onTerminalLayoutChanged = { [weak self] layout in self?.spawn(layout) }
            workspace.addStopHook { await manager.shutdown() }
            onRestart = { [weak self] pane in
                guard let self else { return }
                manager.restart(pane, cwd: self.lastCwd(of: pane))
            }
        }
    }

    private func lastCwd(of pane: UUID) -> String {
        for tab in workspace.terminalLayout.tabs { if let cwd = tab.panes[pane]?.lastCwd { return cwd } }
        return workspace.terminalDefaultCwd
    }

    /// Spawns what the layout says needs a shell now, then records it as spawned.
    private func spawn(_ layout: TerminalLayout) {
        guard let manager else { return }
        let panes = layout.panesToSpawn()
        guard !panes.isEmpty else { return }
        manager.spawnIfNeeded(panes.map { (id: $0, cwd: lastCwd(of: $0)) })
        for pane in panes { workspace.terminalLayout.markSpawned(pane) }
    }

    func notice(of pane: UUID) -> String? { notices[pane] }

    private func setNotice(_ text: String, for pane: UUID) {
        guard notices[pane] != text else { return }
        notices[pane] = text
        revision &+= 1
    }

    private func setWorkingDirectory(_ path: String, for pane: UUID) {
        guard lastCwd(of: pane) != path else { return }
        workspace.terminalLayout.setCwd(path, for: pane)
    }

    static let titleLimit = 256

    /// The shell's name: the last path component of the configured shell, else `$SHELL`, else `zsh`.
    var shellName: String {
        let path = workspace.settings.terminal.shellPath ?? ProcessInfo.processInfo.environment["SHELL"] ?? "zsh"
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? "zsh" : name
    }

    func title(of pane: UUID) -> String { titles[pane] ?? shellName }

    func setTitle(_ title: String?, for pane: UUID) {
        let capped = title.map { String($0.prefix(Self.titleLimit)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard titles[pane] != capped else { return }
        titles[pane] = capped
        revision &+= 1
    }

    func paneState(_ pane: UUID) -> TerminalPaneState { states[pane] ?? .running }

    func markExited(_ pane: UUID, status: Int32) {
        guard states[pane] != .exited(status) else { return }
        states[pane] = .exited(status)
        revision &+= 1
    }

    func restart(_ pane: UUID) {
        guard case .exited = paneState(pane) else { return }
        states[pane] = nil
        revision &+= 1
        onRestart?(pane)
    }

    /// One summary per tab: its title is its focused pane's, it shows as exited when that pane has.
    var tabSummaries: [TerminalTabSummary] {
        _ = revision
        return workspace.terminalLayout.tabs.map { tab in
            var exited = false
            if case .exited = paneState(tab.focusedPane) { exited = true }
            return TerminalTabSummary(id: tab.id, title: title(of: tab.focusedPane), exited: exited)
        }
    }

    func selectTab(_ id: UUID) { mutate { $0.selectTab(id) } }
    func focusPane(_ id: UUID) { mutate { $0.focusPane(id) } }
    func closeTab(_ id: UUID) { mutate { $0.closeTab(id) }; prune(); if !visible { hide() } }
    func closePane(_ id: UUID) { mutate { $0.closePane(id) }; prune(); if !visible { hide() } }
    func splitActive(axis: SplitAxis) { mutate { $0.split(axis: axis) } }

    private func mutate(_ body: (inout TerminalLayout) -> Void) {
        var layout = workspace.terminalLayout
        body(&layout)
        workspace.terminalLayout = layout
    }

    /// Forgets transient state of panes that no longer exist.
    private func prune() {
        let live = Set(workspace.terminalLayout.tabs.flatMap { $0.tree.paneIDs })
        let before = titles.count + states.count + notices.count
        titles = titles.filter { live.contains($0.key) }
        states = states.filter { live.contains($0.key) }
        notices = notices.filter { live.contains($0.key) }
        manager?.retain(only: live)
        if titles.count + states.count + notices.count != before { revision &+= 1 }
    }

    var visible: Bool { workspace.terminalVisible }

    func toggle() {
        workspace.toggleTerminal()
    }

    func newTab() { workspace.newTerminalTab() }

    private func hide() {
        hasFocus = false
        workspace.focusGroup(id: workspace.codeLayout.focusedGroupID)
    }
}

extension Workspace {
    /// The shell's working directory for a new tab.
    var terminalDefaultCwd: String { projectRoot.path }

    func toggleTerminal() {
        var layout = terminalLayout
        layout.toggle(defaultCwd: terminalDefaultCwd)
        terminalLayout = layout
        if !terminalVisible { hideTerminalFocus() }
    }

    /// Returns keyboard focus to the editor group and tells the panel it lost focus.
    func hideTerminalFocus() {
        onTerminalHidden?()
        focusGroup(id: codeLayout.focusedGroupID)
    }

    func newTerminalTab() {
        var layout = terminalLayout
        layout.addTab(cwd: terminalDefaultCwd)
        terminalLayout = layout
    }
}

struct TerminalTabSummary: Equatable, Sendable {
    var id: UUID
    var title: String
    var exited: Bool
}

enum TerminalPaneState: Equatable, Sendable {
    case running
    case exited(Int32)
}
