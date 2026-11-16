import Foundation

extension Workspace {
    static let fileTreeDebounce = 0.3

    /// Feeds the tree's stored marks from the ledger; the model recomputes only when the changed files differ.
    func updateFileTreeMarks() { fileTree.setChanges(changedFiles) }

    /// The tree view (Task 13) calls this when it is shown: scans stay off until then. Scans the project once.
    public func fileTreeViewAppeared() {
        fileTreeViewCount += 1
        guard !fileTreeActive else { return }
        fileTreeActive = true
        track { [weak self] in await self?.refreshFileTreeNow() }
    }

    /// The tree view calls this when it goes away: events stop scheduling scans.
    public func fileTreeViewDisappeared() {
        fileTreeViewCount = max(0, fileTreeViewCount - 1)
        guard fileTreeViewCount == 0 else { return }
        fileTreeActive = false
        fileTreeDebounceTask?.cancel(); fileTreeDebounceTask = nil
    }

    /// View > Reveal in Tree: opens every folder above the focused group's active file, selects it and asks the tree to
    /// scroll to it, all in one go. Does nothing outside Code mode, without an active file, or for a file the tree lacks.
    public func revealInTree() {
        guard mode == .code, let path = codeLayout.focusedGroup.activeTab else { return }
        let before = fileTree.expandedPaths
        guard fileTree.reveal(path) != nil else { return }
        fileTreeSelection = path
        fileTreeScroll?(path)
        if fileTree.expandedPaths != before { noteExpandedFoldersChanged() }
    }

    /// False for events the tree never lists (under `.git` or a directory FileIndex skips) and for events on a file the
    /// tree already lists that still exists: a content change. Only creates, removals and renames change the tree.
    func affectsFileTree(_ eventPath: String) -> Bool {
        let path = relativeEventPath(eventPath) ?? eventPath
        if path.split(separator: "/").contains(where: { FileIndex.skippedDirectories.contains(String($0)) }) { return false }
        let parent = FileTreeSnapshot.parentPath(path)
        if fileTree.snapshot.children(of: parent).contains(where: { $0.path == path && !$0.isFolder }),
           FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(path).path) { return false }
        return true
    }

    /// Rebuilds the tree 0.3 s after the last file event. Does nothing outside Code mode.
    func scheduleFileTreeRefresh() {
        guard fileTreeActive, !isShuttingDown else { return }
        fileTreeDebounceTask?.cancel()
        // The deadline is taken now, so a manual clock advanced before the timer task runs still fires it.
        let deadline = autosaveClock.now + Self.fileTreeDebounce, clock = autosaveClock
        fileTreeDebounceTask = track { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, !self.isShuttingDown else { return }
            self.fileTreeDebounceTask = nil
            await self.refreshFileTreeNow()
        }
    }

    /// Rescans the project and rebuilds the tree at once (entering Code mode).
    public func refreshFileTreeNow() async {
        fileTreeRefreshCount += 1
        updateFileTreeMarks()
        await fileIndex.refresh()
        let paths = await fileIndex.paths(), truncated = await fileIndex.isTruncated
        await fileTree.update(paths: paths, truncated: truncated)
    }
}
