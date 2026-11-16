import Foundation

/// Code mode's editor groups: splitting, closing, focus moves, and the keys that follow the focused group.
extension Workspace {
    /// Splits the focused group along `axis`: a new group opens its active file and takes focus.
    /// Does nothing when the focused group has no active tab.
    public func splitFocused(_ axis: SplitAxis) {
        let layout = codeLayout
        let source = layout.focusedGroup
        guard let path = source.activeTab else { return }
        let group = EditorGroup(tabs: [path], activeTab: path)
        layout.groups[group.id] = group
        // A path whose document is not loaded has no caret to copy: both groups seed when it loads.
        if let doc = documents[path] {
            makeSelectionState(for: doc, in: .group(group.id), copying: selectionState(for: path, in: .group(source.id))?.selections)
        }
        layout.tree = layout.tree.splitting(source.id, axis: axis, newGroup: group.id, newSplit: UUID())
        layout.focus(group.id)
        scheduleUIStateWrite()
    }

    /// Moves focus to the neighbouring group; nothing happens at an edge. Never saves.
    public func focusGroup(_ direction: FocusDirection) {
        let layout = codeLayout
        guard let next = layout.tree.neighbour(of: layout.focusedGroupID, direction) else { return }
        layout.focus(next)
        scheduleUIStateWrite()
    }

    /// Moves focus to `id`; an id that is not a group is ignored. Never saves.
    public func focusGroup(id: UUID) {
        guard codeLayout.groups[id] != nil, codeLayout.focusedGroupID != id else { return }
        codeLayout.focus(id)
        scheduleUIStateWrite()
    }

    /// Removes group `id` once it holds no tab, unless it is the only group. Focus moves to the sibling
    /// when the removed group had it.
    func collapseGroupIfEmpty(_ id: UUID) {
        let layout = codeLayout
        guard let group = layout.groups[id], group.tabs.isEmpty,
              let removal = layout.tree.removing(id) else { return }
        layout.tree = removal.tree
        layout.groups.removeValue(forKey: id)
        presentations.removeValue(forKey: .group(id))
        dropSelectionStates(of: .group(id))
        if layout.focusedGroupID == id { layout.focus(removal.focus) }
        scheduleUIStateWrite()
    }

    /// Activates the next or previous tab of `pane`, wrapping.
    func cycleTab(_ step: Int, in pane: PaneID) {
        let list = tabs(in: pane)
        guard !list.isEmpty else { return }
        let current = activeTab(in: pane).flatMap { list.firstIndex(of: $0) } ?? (step > 0 ? -1 : 0)
        setActive(list[((current + step) % list.count + list.count) % list.count], in: pane)
        scheduleUIStateWrite()
    }

    /// Activates the `number`th tab (1-based) of `pane`; no such tab does nothing.
    func selectTab(number: Int, in pane: PaneID) {
        let list = tabs(in: pane)
        guard list.indices.contains(number - 1) else { return }
        setActive(list[number - 1], in: pane)
        scheduleUIStateWrite()
    }
}
