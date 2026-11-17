import Foundation

public struct TerminalPane: Codable, Equatable, Sendable {
    public var id: UUID
    public var lastCwd: String?

    public init(id: UUID, lastCwd: String? = nil) {
        self.id = id
        self.lastCwd = lastCwd
    }
}

public struct TerminalTab: Codable, Equatable, Sendable {
    public var id: UUID
    public var tree: TerminalSplitTree
    public var panes: [UUID: TerminalPane]
    public var focusedPane: UUID

    public init(id: UUID, tree: TerminalSplitTree, panes: [UUID: TerminalPane], focusedPane: UUID) {
        self.id = id
        self.tree = tree
        self.panes = panes
        self.focusedPane = focusedPane
    }
}

/// The terminal panel's tabs, splits and focus. Pure value type; spawning is the caller's job
/// (`panesToSpawn()` says which panes need a shell now, restore is lazy).
public struct TerminalLayout: Codable, Equatable, Sendable {
    public var visible: Bool
    public var tabs: [TerminalTab]
    public var activeTab: UUID?

    /// Panes whose shell has been started this run. Never persisted, never compared.
    public private(set) var spawned: Set<UUID> = []

    private enum CodingKeys: String, CodingKey { case visible, tabs, activeTab }

    public init(visible: Bool = false, tabs: [TerminalTab] = [], activeTab: UUID? = nil) {
        self.visible = visible
        self.tabs = tabs
        self.activeTab = activeTab
    }

    public static func == (a: TerminalLayout, b: TerminalLayout) -> Bool {
        a.visible == b.visible && a.tabs == b.tabs && a.activeTab == b.activeTab
    }

    public var active: TerminalTab? { tabs.first { $0.id == activeTab } }

    private var activeIndex: Int? { tabs.firstIndex { $0.id == activeTab } }

    /// Shows the panel (creating one tab when there is none) or hides it, keeping the tabs.
    public mutating func toggle(defaultCwd: String, tabID: UUID = UUID(), paneID: UUID = UUID()) {
        if visible {
            visible = false
        } else {
            if tabs.isEmpty { addTab(cwd: defaultCwd, id: tabID, paneID: paneID) }
            visible = true
        }
    }

    @discardableResult
    public mutating func addTab(cwd: String, id: UUID = UUID(), paneID: UUID = UUID()) -> UUID {
        tabs.append(TerminalTab(
            id: id, tree: .pane(paneID),
            panes: [paneID: TerminalPane(id: paneID, lastCwd: cwd)], focusedPane: paneID))
        activeTab = id
        visible = true
        return id
    }

    /// Closing the last tab hides the panel and leaves no tabs.
    public mutating func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = activeTab == id
        for p in tabs[i].tree.paneIDs { spawned.remove(p) }
        tabs.remove(at: i)
        if tabs.isEmpty {
            visible = false
            activeTab = nil
        } else if wasActive {
            activeTab = tabs[min(i, tabs.count - 1)].id
        }
    }

    public mutating func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTab = id
    }

    public mutating func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTab = tabs[index].id
    }

    /// Splits the active tab's focused pane; the new pane inherits its cwd and takes focus.
    public mutating func split(axis: SplitAxis, newPane: UUID = UUID(), newSplit: UUID = UUID()) {
        guard let i = activeIndex else { return }
        let focused = tabs[i].focusedPane
        tabs[i].tree = tabs[i].tree.splitting(focused, axis: axis, newPane: newPane, newSplit: newSplit)
        tabs[i].panes[newPane] = TerminalPane(id: newPane, lastCwd: tabs[i].panes[focused]?.lastCwd)
        tabs[i].focusedPane = newPane
    }

    /// The last pane of a tab closes the tab.
    public mutating func closePane(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.tree.paneIDs.contains(id) }) else { return }
        guard let r = tabs[i].tree.removing(id) else {
            closeTab(tabs[i].id)
            return
        }
        tabs[i].tree = r.tree
        tabs[i].panes[id] = nil
        spawned.remove(id)
        if tabs[i].focusedPane == id { tabs[i].focusedPane = r.focus }
    }

    public mutating func focusPane(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.tree.paneIDs.contains(id) }) else { return }
        tabs[i].focusedPane = id
    }

    public mutating func setCwd(_ cwd: String, for pane: UUID) {
        guard let i = tabs.firstIndex(where: { $0.panes[pane] != nil }) else { return }
        tabs[i].panes[pane]?.lastCwd = cwd
    }

    public mutating func markSpawned(_ pane: UUID) { spawned.insert(pane) }

    /// Lazy restore: only the active tab's focused pane, and only while the panel is visible.
    /// Other panes spawn when focused or when their tab is selected.
    public func panesToSpawn() -> [UUID] {
        guard visible, let tab = active, !spawned.contains(tab.focusedPane) else { return [] }
        return [tab.focusedPane]
    }

    /// Repairs a decoded layout: duplicate tab or pane ids, tabs with an empty tree, panes missing
    /// from or stale in the pane table, and a dangling `activeTab` or `focusedPane`. Nil when no tab
    /// survives.
    public func sanitized() -> TerminalLayout? {
        var seenPanes = Set<UUID>()
        var seenTabs = Set<UUID>()
        var out: [TerminalTab] = []
        for tab in tabs {
            guard seenTabs.insert(tab.id).inserted,
                  let tree = tab.tree.deduplicated(seen: &seenPanes) else { continue }
            let ids = tree.paneIDs
            var panes: [UUID: TerminalPane] = [:]
            for id in ids { panes[id] = TerminalPane(id: id, lastCwd: tab.panes[id]?.lastCwd) }
            let focus = ids.contains(tab.focusedPane) ? tab.focusedPane : ids[0]
            out.append(TerminalTab(id: tab.id, tree: tree, panes: panes, focusedPane: focus))
        }
        guard let first = out.first else { return nil }
        let active = out.contains { $0.id == activeTab } ? activeTab : first.id
        return TerminalLayout(visible: visible, tabs: out, activeTab: active)
    }
}
