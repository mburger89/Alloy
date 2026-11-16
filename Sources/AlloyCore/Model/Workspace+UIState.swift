import Foundation

extension Workspace {
    var uiStateURL: URL { storeDirectory.appendingPathComponent("ui-state.json") }
    static let uiStateDelay = 0.5

    /// Switches screens. Nothing is saved, reloaded or reopened: only the mode changes and a state write is scheduled.
    public func setMode(_ mode: WorkspaceMode) {
        guard self.mode != mode else { return }
        if mode == .chat { syncChatToFocusedGroup() } else { seedEmptyGroupFromChat() }
        self.mode = mode
        noteFocus(mode == .code ? .group(codeLayout.focusedGroupID) : .chat)
        if mode == .code { loadFocusedGroupDocument() }
        // The Chat code view the flag describes is torn down by the switch (its blur never fires); Code mode's group
        // views set their own focus. Nothing is saved.
        focusedCodePane = nil
        scheduleUIStateWrite()
    }

    /// The saved sizes of the split named `name` (MetalUI's autosave name), or nil when none were saved.
    public func paneSizes(forName name: String) -> [Double]? { savedPaneSizes[name] }

    /// Keeps `sizes` for the split named `name` and schedules a state write.
    public func setPaneSizes(_ sizes: [Double], forName name: String) {
        guard savedPaneSizes[name] != sizes else { return }
        savedPaneSizes[name] = sizes
        scheduleUIStateWrite()
    }

    func currentUIState() -> UIState {
        let groups = codeLayout.tree.groupIDs.compactMap { id in
            codeLayout.groups[id].map { GroupState(id: id, tabs: $0.tabs, active: $0.activeTab) }
        }
        let layout = CodeLayoutState(tree: codeLayout.tree, groups: groups, focused: codeLayout.focusedGroupID)
        // Sizes of splits no longer in the tree are dropped.
        let live = Set(codeLayout.tree.splitIDs.map { "code-split-\($0.uuidString)" })
        let sizes = savedPaneSizes.filter { !$0.key.hasPrefix("code-split-") || live.contains($0.key) }
        return UIState(version: UIState.currentVersion, mode: mode, paneSizes: sizes,
                       chatCollapsed: codeLayout.chatCollapsed, layout: layout, expandedFolders: expandedFolders.sorted())
    }

    /// The file tree's open folders. The tree writes it (a change calls ``noteExpandedFoldersChanged()``).
    public var expandedFolders: Set<String> {
        get { fileTree.expandedPaths }
        set { fileTree.expandedPaths = newValue }
    }

    /// Schedules a state write after the file tree opened or closed a folder.
    public func noteExpandedFoldersChanged() { scheduleUIStateWrite() }

    /// Applies what needs no file check. The mode is set by the restore once the layout is installed: until then a
    /// quick-open lands in Chat, whose tab list survives the install (a group's would be replaced, orphaning the document).
    func apply(_ state: UIState) {
        savedPaneSizes = state.paneSizes
    }

    /// Which of `files` and `folders` (project-relative) exist; read off the main actor.
    nonisolated static func existing(files: Set<String>, folders: [String], under root: URL) async -> (files: Set<String>, folders: [String]) {
        await Task.detached {
            let fm = FileManager.default
            func isDirectory(_ path: String) -> Bool? {
                var dir: ObjCBool = false
                return fm.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &dir) ? dir.boolValue : nil
            }
            return (files.filter { isDirectory($0) == false }, folders.filter { isDirectory($0) == true })
        }.value
    }

    /// Replaces Code mode's groups with the saved ones, dropping tabs whose files are gone. A group left empty is
    /// pruned from the tree unless none has a tab (then one empty group stays); focus and active tabs stay valid.
    func installLayout(_ saved: CodeLayoutState, existing: Set<String>) {
        let ids = saved.tree.groupIDs
        guard !ids.isEmpty, Set(ids).count == ids.count else { return }
        let states = Dictionary(saved.groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [UUID: EditorGroup] = [:]
        for id in ids {
            var tabs: [String] = []
            for path in states[id]?.tabs ?? [] where existing.contains(path) && !tabs.contains(path) { tabs.append(path) }
            let active = states[id]?.active.flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
            groups[id] = EditorGroup(id: id, tabs: tabs, activeTab: active)
        }
        let kept = Set(ids.filter { !(groups[$0]?.tabs.isEmpty ?? true) })
        let tree: SplitTree
        if kept.isEmpty {
            let survivor = ids.contains(saved.focused) ? saved.focused : ids[0]
            tree = .group(survivor)
            groups = [survivor: groups[survivor]!]
        } else {
            tree = saved.tree.pruned(keeping: kept) ?? .group(ids[0])
            groups = groups.filter { kept.contains($0.key) }
        }
        let layout = codeLayout
        layout.groups = groups
        layout.tree = tree
        layout.focus(groups[saved.focused] != nil ? saved.focused : tree.groupIDs[0])
        for id in presentations.keys { if case .group = id { presentations.removeValue(forKey: id) } }
        // The groups' states go (their tabs were replaced); the focus log keeps the entries of groups that survive.
        for id in paneSelections.keys { if case .group = id { paneSelections.removeValue(forKey: id); selectionRevision += 1 } }
        paneFocusLog.removeAll { if case .group(let g) = $0 { return layout.groups[g] == nil } else { return false } }
    }

    /// Loads `ui-state.json`. Missing, corrupt or newer files give the defaults; a newer file is never overwritten.
    /// The saved layout and open folders are applied once their files are checked (off the main actor); only each
    /// group's active document is loaded. Nothing here waits on the file tree.
    public func restoreUIState() async {
        uiStateTimer?.cancel(); uiStateTimer = nil
        var saved = UIState.defaults
        switch UIStateFile.load(uiStateURL) {
        case .missing, .corrupt: break
        case .newer: uiStateWritable = false
        case .state(let state): saved = state
        }
        apply(saved)
        var paths = Set<String>()
        for group in saved.layout?.groups ?? [] { paths.formUnion(group.tabs) }
        let found = await Self.existing(files: paths, folders: saved.expandedFolders, under: projectRoot)
        let callback = codeLayout.onChatCollapsedChange
        codeLayout.onChatCollapsedChange = nil
        codeLayout.chatCollapsed = saved.chatCollapsed
        codeLayout.onChatCollapsedChange = callback
        if let layout = saved.layout { installLayout(layout, existing: found.files) }
        expandedFolders = Set(found.folders)
        mode = saved.mode
        uiStateRestored = true
        // Only Code mode shows groups; the focused group's document loads in the background, the others when their
        // group shows or activates. Restore never waits on a read.
        if mode == .code { loadFocusedGroupDocument() }
    }

    /// Loads `path` in the background when `pane` lists it and no document or message exists yet.
    public func loadIfNeeded(_ path: String, in pane: PaneID) {
        guard documents[path] == nil, tabMessages[path] == nil, tabs(in: pane).contains(path) else { return }
        track { [weak self] in await self?.open(path, in: pane) }
    }

    func loadFocusedGroupDocument() {
        if let active = codeLayout.focusedGroup.activeTab { loadIfNeeded(active, in: .group(codeLayout.focusedGroupID)) }
    }

    /// Writes the state 0.5 s after the last call.
    func scheduleUIStateWrite() {
        // Before the restore the state is still defaults; writing it would replace the saved file.
        guard uiStateWritable, uiStateRestored else { return }
        uiStateTimer?.cancel()
        let clock = autosaveClock
        let deadline = clock.now + Self.uiStateDelay
        uiStateTimer = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            self?.writeUIState()
        }
    }

    /// Writes a pending change now (quit and window close).
    func flushUIState() async {
        guard uiStateTimer != nil else { return }
        uiStateTimer?.cancel()
        writeUIState()
    }

    private func writeUIState() {
        uiStateTimer = nil
        guard uiStateWritable else { return }
        do {
            try UIStateFile.save(currentUIState(), to: uiStateURL)
            uiStateWriteCount += 1
        } catch { report("Could not save ui-state.json: \(error.localizedDescription)") }
    }
}
