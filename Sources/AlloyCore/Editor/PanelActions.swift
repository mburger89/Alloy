import Foundation

/// What the code panel asks of the workspace beyond keep and revert.
extension Workspace {
    /// Counts decoration rebuilds of open documents (for tests, `package` access); the panel calls ``noteDecorationBuild()``.
    package var decorationBuilds: Int { decorationBuildCount }

    package func noteDecorationBuild() { decorationBuildCount += 1 }

    /// Counts side-by-side model builds (for tests); the panel calls ``noteSideBySideBuild()``.
    package var sideBySideBuilds: Int { sideBySideBuildCount }

    package func noteSideBySideBuild() { sideBySideBuildCount += 1 }

    /// Reverts `edit` of `path` from the editor. An open document with unsaved typing is saved first (the user's
    /// text is never lost: if that save fails, nothing is reverted). The ledger and the disk change, and the open
    /// buffer is brought to the reverted text as an external edit; `settle()` waits for that reload.
    public func revertInEditor(edit: UUID, path: String) async -> RevertOutcome {
        if let doc = documents[path], doc.isDirty {
            try? await save(path)
            if doc.isDirty {
                let reason = "Could not save your changes in \(path) first."
                revertConflicts[edit] = reason
                return .conflict(reason: reason)
            }
        }
        let outcome = await revert(edit: edit, path: path)
        if case .reverted = outcome { syncOpenBuffer(path, by: nil) }
        return outcome
    }

    /// The 1-based line to reveal for `edit` in `path`: for a live edit, where it first shows in the current text
    /// (the diff is computed off the main actor); for a kept edit, which the diff no longer shows, the line its
    /// first hunk recorded (later edits may have moved it, so it is a best effort). Nil reveals nothing.
    public func firstLine(of edit: UUID, path: String) async -> Int? {
        guard let file = ledger.files[path] else { return nil }
        guard file.edits.first(where: { $0.id == edit })?.state == .live else { return file.recordedLine(of: edit) }
        return await Task.detached { file.firstLine(of: edit) }.value
    }

    /// Opens `path` for a click (chat path, sidebar row, quick-open) and activates it. `edit` reveals that edit's
    /// first changed line, `line` (1-based) a given one. The newest request wins: while an older one is still
    /// looking up its line, a newer click drops it, so two clicks never leave the older file open.
    public func requestOpen(_ path: String, edit: UUID? = nil, line: Int? = nil, mode: DiffMode? = nil) {
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
            await open(path, revealLine: reveal, mode: mode)
        }
    }

    /// Closes the active tab (saving first, as `close` does).
    public func closeActiveTab() {
        guard let path = activeTab else { return }
        requestClose(path)
    }

    /// Closes the tab for `path` in a tracked task (`settle()` waits for it); the strip's close button and ⌘W both use it.
    public func requestClose(_ path: String) {
        track { [weak self] in await self?.close(path) }
    }

    /// The author of the newest edit to `path` that a session made and that was not reverted; nil when none.
    /// Cached per path by the ledger's `version`, so the tab strip does not rescan the edits on every render.
    public func lastSessionEditor(of path: String) -> Author? {
        guard let file = ledger.files[path] else { return nil }
        let version = file.version
        if let hit = editorCache[path], hit.version == version { return hit.author }
        editorScans += 1
        let author = file.edits.last { edit in
            if case .session = edit.author { return edit.state != .reverted }
            return false
        }?.author
        editorCache[path] = (version, author)
        return author
    }

    /// Drops one notice.
    public func dismiss(_ notice: Notice) {
        if let i = notices.lastIndex(of: notice) { notices.remove(at: i) }
    }
}
