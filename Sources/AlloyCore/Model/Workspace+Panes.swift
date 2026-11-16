import Foundation

/// Tab lists and per-pane presentation. A document lives while any list (Chat's or a group's) holds its path.
extension Workspace {
    /// Where an open goes when no pane is named.
    public var defaultPane: PaneID { mode == .code ? .group(codeLayout.focusedGroupID) : .chat }

    /// True while Chat's tabs or any group's tabs hold `path`.
    public func holds(_ path: String) -> Bool {
        tabs.contains(path) || codeLayout.groups.values.contains { $0.tabs.contains(path) }
    }

    /// Every path some tab list holds.
    func heldPaths() -> Set<String> {
        var all = Set(tabs)
        for group in codeLayout.groups.values { all.formUnion(group.tabs) }
        return all
    }

    /// Changes when any tab list (Chat's or a group's), or a document one of them holds, changes. The always-present
    /// reconciliation in the screen watches it, so a close that finishes in the other mode still releases its views.
    public func heldSignature() -> [String] {
        let chat = "chat|" + tabs.map { "\($0)#\(document($0)?.id.uuidString ?? "")" }.joined(separator: "|")
        let groups = codeLayout.groups.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { group in
            "\(group.id)|" + group.tabs.map { "\($0)#\(document($0)?.id.uuidString ?? "")" }.joined(separator: "|")
        }
        return [chat] + groups
    }

    public func tabs(in pane: PaneID) -> [String] {
        switch pane {
        case .chat: return tabs
        case .group(let id): return codeLayout.groups[id]?.tabs ?? []
        }
    }

    public func activeTab(in pane: PaneID) -> String? {
        switch pane {
        case .chat: return activeTab
        case .group(let id): return codeLayout.groups[id]?.activeTab
        }
    }

    func addTab(_ path: String, in pane: PaneID) {
        switch pane {
        case .chat: if !tabs.contains(path) { tabs.append(path) }
        case .group(let id):
            if let g = codeLayout.groups[id], !g.tabs.contains(path) { g.tabs.append(path); scheduleUIStateWrite() }
        }
        ensureSelectionState(path, in: pane)
    }

    /// Makes `path` the pane's active tab; leaving a dirty tab saves it (Chat's `activeTab` does that itself).
    func setActive(_ path: String?, in pane: PaneID) {
        switch pane {
        case .chat: activeTab = path
        case .group(let id):
            guard let g = codeLayout.groups[id] else { return }
            let old = g.activeTab
            g.activeTab = path
            if old != path { scheduleUIStateWrite() }
            if let old, old != path, documents[old]?.isDirty == true {
                track { [weak self] in try? await self?.save(old) }
            }
        }
    }

    /// Activates an open tab of `pane` (saving the tab it leaves when dirty); loads its document if missing.
    public func activate(_ path: String, in pane: PaneID) {
        guard tabs(in: pane).contains(path) else { return }
        setActive(path, in: pane)
        if documents[path] == nil, tabMessages[path] == nil {
            track { [weak self] in await self?.open(path, in: pane) }
        }
    }

    /// Removes `path` from the pane's list and picks the neighbour as active. Nothing else is dropped.
    func removeTab(_ path: String, from pane: PaneID) {
        switch pane {
        case .chat:
            guard let index = tabs.firstIndex(of: path) else { return }
            tabs.remove(at: index)
            if activeTab == path { activeTab = tabs.indices.contains(index) ? tabs[index] : tabs.last }
        case .group(let id):
            guard let g = codeLayout.groups[id], let index = g.tabs.firstIndex(of: path) else { return }
            g.tabs.remove(at: index)
            if g.activeTab == path { g.activeTab = g.tabs.indices.contains(index) ? g.tabs[index] : g.tabs.last }
            scheduleUIStateWrite()
            if g.tabs.isEmpty { collapseGroupIfEmpty(id) }
        }
        dropSelectionState(path, from: pane)
        if presentations[pane]?[path] != nil { presentations[pane]?.removeValue(forKey: path) }
    }

    /// Moves a tab as a drag does. Out-of-range indexes do nothing.
    public func moveTab(from: Int, to: Int, in pane: PaneID) {
        switch pane {
        case .chat: moveTab(from: from, to: to)
        case .group(let id):
            guard let g = codeLayout.groups[id], from != to, g.tabs.indices.contains(from), g.tabs.indices.contains(to) else { return }
            g.tabs.insert(g.tabs.remove(at: from), at: to)
            scheduleUIStateWrite()
        }
    }

    public func presentation(of path: String, in pane: PaneID) -> Presentation {
        if let p = presentations[pane]?[path] { return p }
        if case .chat = pane { return .inline }
        return .plain
    }

    public func setPresentation(_ presentation: Presentation, of path: String, in pane: PaneID) {
        guard presentations[pane]?[path] != presentation else { return }
        presentations[pane, default: [:]][path] = presentation
    }

    public func requestClose(_ path: String, in pane: PaneID) {
        track { [weak self] in await self?.close(path, in: pane) }
    }

    public func requestOpen(_ path: String, edit: UUID? = nil, line: Int? = nil, mode: DiffMode? = nil, in pane: PaneID) {
        openRequestTicket += 1
        let ticket = openRequestTicket
        track { [weak self] in
            guard let self else { return }
            var reveal = line
            if let edit {
                await firstLineGate?(edit)
                reveal = await firstLine(of: edit, path: path)
            }
            guard ticket == openRequestTicket else { return }
            await open(path, revealLine: reveal, mode: mode, in: pane)
        }
    }
}
