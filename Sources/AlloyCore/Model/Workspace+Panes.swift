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
        // CSV and TSV open as a table in a Code group until the user picks another presentation (not persisted).
        if Presentation.offersTable(language: URL(fileURLWithPath: path).pathExtension.lowercased()) { return .table }
        return .plain
    }

    public func setPresentation(_ presentation: Presentation, of path: String, in pane: PaneID) {
        guard presentations[pane]?[path] != presentation else { return }
        presentations[pane, default: [:]][path] = presentation
    }

    public func requestClose(_ path: String, in pane: PaneID) {
        track { [weak self] in
            guard let self else { return }
            // An Untitled tab with text asks first; Cancel (or a cancelled save dialog) keeps it.
            if isUntitled(path), !(await resolveUntitled(path, closing: pane)) { return }
            await close(path, in: pane)
        }
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

extension Workspace {
    /// File > Save As…: writes the buffer of `path` to `target`.
    /// - Inside the project: the original is saved first (Alloy autosaves, so typing is never discarded), then the copy is
    ///   written, then the tab is replaced in place (same pane, same index, now active) by the new path and the original
    ///   document is closed, without a second tab. A `target` that is the file's own path is a plain deliberate save.
    /// - Outside the project: the copy is written and the tab stays as it is.
    /// A failed save or write throws and changes nothing further.
    public func saveAs(_ path: String, to target: URL, in pane: PaneID? = nil) async throws {
        let pane = pane ?? defaultPane
        guard let doc = documents[path] else { return }
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
        let relative = resolved.hasPrefix(root + "/") ? String(resolved.dropFirst(root.count + 1)) : nil
        if relative == path { try await save(path, format: true); return }
        if relative != nil { try await save(path) }
        try doc.buffer.snapshot().text.write(to: target, atomically: true, encoding: .utf8)
        guard let relative else { return }
        await replaceTab(path, with: relative, in: pane)
    }

    /// The pane holding `path`'s tab: the default pane when it does, else the first that does.
    public func paneHolding(_ path: String) -> PaneID? {
        let panes = panesHolding(path)
        return panes.contains(defaultPane) ? defaultPane : panes.first
    }

    /// Opens `new` in `pane`, puts its tab where `old`'s was (a tab `new` already had in `pane` is removed, not
    /// duplicated), closes `old` and makes `new` the active tab. Closing `old` does not save it: callers that need that
    /// (Save As) save first.
    public func replaceTab(_ old: String, with new: String, in pane: PaneID) async {
        let index = tabs(in: pane).firstIndex(of: old)
        await open(new, in: pane)
        // `open` appends the new tab unless the pane already held it; put it where the original was, then close the
        // original, so there is one tab for `new` either way.
        if let index, let from = tabs(in: pane).firstIndex(of: new), from != index, tabs(in: pane).indices.contains(index) {
            moveTab(from: from, to: index, in: pane)
        }
        if isUntitled(old) { dropUntitled(old, from: pane) } else { await close(old, in: pane) }
        setActive(new, in: pane)
    }

    /// First save of an Untitled document: writes its text atomically to `target`.
    /// - Inside the project, the file is opened and its tab replaces the Untitled tab in `pane` (same index, active);
    ///   returns nil.
    /// - Outside the project, the Untitled tab closes and `target` is returned for the caller to open the way Open… does.
    /// A target that is already open takes the text through its own document (a user edit, then a save); one that is
    /// read-only throws. A write error throws and changes nothing.
    public func saveUntitled(_ key: String, to target: URL, in pane: PaneID) async throws -> URL? {
        guard isUntitled(key), let doc = documents[key] else { return nil }
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
        let text = doc.buffer.snapshot().text
        if resolved.hasPrefix(root + "/") {
            let relative = String(resolved.dropFirst(root.count + 1))
            // The file is already open: its document takes the text as a user edit and saves it, so undo, the ledger and
            // the outside-edit watcher agree and no pending autosave can write the old buffer over it.
            if let open = documents[relative] {
                guard open.state == .editable else {
                    report("Can't save \(title(of: key)) over \(relative): the open file is read-only.")
                    throw CocoaError(.fileWriteNoPermission)
                }
                _ = open.buffer.replace(0..<open.buffer.snapshot().utf8Count, with: text)
                try await save(relative)
                for holder in panesHolding(key) where holder != pane { await replaceTab(key, with: relative, in: holder) }
                await replaceTab(key, with: relative, in: pane)
                return nil
            }
        }
        do { try text.write(to: target, atomically: true, encoding: .utf8) } catch {
            report("Can't save \(title(of: key)) to \(target.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
        guard resolved.hasPrefix(root + "/") else {
            for holder in panesHolding(key) { dropUntitled(key, from: holder) }
            return target
        }
        let relative = String(resolved.dropFirst(root.count + 1))
        // A split can show the same Untitled document in several groups: each becomes the file, `pane`'s last (it stays active).
        for holder in panesHolding(key) where holder != pane { await replaceTab(key, with: relative, in: holder) }
        await replaceTab(key, with: relative, in: pane)
        return nil
    }
}
