import Foundation
import MetalUICodeBuffer

extension Workspace {
    /// Shows Code mode's Search tab and asks its query field for focus. `replace: true` also reveals the replace row.
    /// A single-line primary selection in the focused editor becomes the query (and runs), whatever other selections
    /// exist; anything else leaves it as it was.
    public func showSearch(replace: Bool) {
        let seed = selectedSingleLine()
        setMode(.code)
        codeLayout.sidebarTab = .search
        if replace { searchReplaceRevealed = true }
        if let seed { search.seed(seed) } else { search.requestFocus() }
    }

    /// The text of the focused editor's primary selection when it is non-empty and within a single line.
    private func selectedSingleLine() -> String? {
        let pane = defaultPane
        guard let path = activeTab(in: pane), let doc = documents[path],
              let state = selectionState(for: path, in: pane) else { return nil }
        let selection = state.primarySelection
        guard !selection.isEmpty else { return nil }
        let text = doc.buffer.snapshot().text(in: selection.range)
        return text.contains(where: \.isNewline) ? nil : text
    }

    // MARK: Replace

    /// Applies `plan`, one file at a time, inside one ledger batch. Every file's edit carries one group id.
    /// Closed files are rewritten on disk; open documents take the change through their buffer and a save.
    public func replace(_ plan: ReplacePlan) async -> ReplaceReport {
        var report = ReplaceReport(group: UUID())
        await withLedgerBatch {
            for file in plan.files {
                if isShuttingDown { break }
                let outcome: ReplaceOutcome
                if let doc = documents[file.path] {
                    outcome = await replaceOpen(file, in: doc, plan: plan, group: report.group)
                } else {
                    outcome = await replaceClosed(file, plan: plan, group: report.group)
                }
                report.perFile.append((file.path, outcome))
            }
        }
        return report
    }

    private enum ClosedRead: Sendable {
        case text([UInt8], FileStamp, truncated: Bool)
        case skipped(String)
    }

    /// Rewrites a closed file inside the path's save slot (the one `save` and `performRevert` use).
    private func replaceClosed(_ file: ReplaceFile, plan: ReplacePlan, group: UUID) async -> ReplaceOutcome {
        let path = file.path
        while let running = saving[path] { _ = try? await running.value }
        let task = Task<ReplaceOutcome, Never> { @MainActor [weak self] in
            guard let self else { return .skipped(reason: "Alloy is closing") }
            defer { saving.removeValue(forKey: path); saveEpoch[path, default: 0] += 1 }
            return await replaceClosedInSlot(file, plan: plan, group: group)
        }
        saving[path] = Task<Void, Error> { _ = await task.value }
        return await task.value
    }

    private func replaceClosedInSlot(_ file: ReplaceFile, plan: ReplacePlan, group: UUID) async -> ReplaceOutcome {
        let path = file.path
        let rootPath = projectRoot.resolvingSymlinksInPath().path
        let lexical = projectRoot.appendingPathComponent(path).standardizedFileURL
        let target = lexical.resolvingSymlinksInPath()
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let lexicalRoot = projectRoot.standardizedFileURL.path
        guard lexical.path.hasPrefix(lexicalRoot.hasSuffix("/") ? lexicalRoot : lexicalRoot + "/"),
              target.path.hasPrefix(prefix) else { return .skipped(reason: "outside the project") }
        ensureLoaded()

        // Read the file and its stamp off the main actor; a case-only rename counts as gone.
        let read = await Task.detached { () -> ClosedRead in
            let name = lexical.lastPathComponent
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: lexical.deletingLastPathComponent().path)) ?? []
            guard listing.contains(name) else { return .skipped("file is gone or renamed") }
            switch Workspace.readForEditing(url: target) {
            case .unreadable: return .skipped("file is gone or unreadable")
            case .binary: return .skipped("binary file")
            case .text(let bytes, let stamp, let truncated): return .text(bytes, stamp, truncated: truncated)
            }
        }.value
        guard case .text(let bytes, let stamp, let truncated) = read else {
            if case .skipped(let reason) = read { return .skipped(reason: reason) }
            return .skipped(reason: "unreadable")
        }
        if truncated { return .skipped(reason: "larger than 16 MB") }
        let rewrite = await Task.detached { plan.rewrite(file, bytes: bytes) }.value
        let newBytes: [UInt8]
        switch rewrite {
        case .skipped(let reason): return .skipped(reason: reason)
        case .rewritten(let b): newBytes = b
        }

        let writer = writeFile, gate = replaceWriteGate
        let moved: Bool
        do {
            moved = try await Task.detached {
                await gate?(path)
                return try writer(Data(newBytes), target, { FileStamp.read(target.path) != stamp })
            }.value
        } catch {
            return .skipped(reason: "could not write: \(error.localizedDescription)")
        }
        if moved { return .skipped(reason: "changed during replace") }

        // The disk now holds the new text; record it so the watcher finds nothing to attribute. When the ledger
        // knows the file under different text, that change reached disk unseen and is recorded as outside first.
        let oldText = String(decoding: bytes, as: UTF8.self), newText = String(decoding: newBytes, as: UTF8.self)
        // The diff awaits, so the entry is re-read until it did not change meanwhile.
        var known = ledger.files[path]
        var unseen = false
        while true {
            let snapshot = known
            unseen = await Task.detached { snapshot.map { !TextDiff.same($0.text.text, oldText) } ?? false }.value
            let current = ledger.files[path]
            if current?.version == snapshot?.version, (current == nil) == (snapshot == nil) { break }
            known = current
        }
        if unseen { await appendToLedger(path, saved: nil, edits: [(saveChangeAuthor(path, stamp.modified), oldText)]) }
        await appendToLedger(path, saved: nil, baseline: known == nil ? oldText : nil, edits: [(.user, newText)], group: group)
        return .applied(edits: file.matches.count)
    }

    // MARK: Open documents

    /// Replaces in an open document: earlier typing is saved first (its own edit), the matches are re-verified against
    /// the buffer, replaced back to front in one transaction (one undo step) and saved with the group attached.
    private func replaceOpen(_ file: ReplaceFile, in doc: EditorDocument, plan: ReplacePlan, group: UUID) async -> ReplaceOutcome {
        let path = file.path
        if case .readOnly(let reason) = doc.state {
            if reason.contains("UTF-8") { return .skipped(reason: "not valid UTF-8") }
            if reason.contains("16 MB") { return .skipped(reason: "larger than 16 MB") }
            return .skipped(reason: "read-only")
        }
        if doc.isDirty {
            do { try await save(path) } catch { return .skipped(reason: "could not save: \(error.localizedDescription)") }
        }
        guard documents[path] === doc, doc.state == .editable else { return .skipped(reason: "document closed") }
        let snapshot = doc.buffer.snapshot()
        let version = doc.buffer.version
        let bytes = snapshot.utf8(in: 0..<snapshot.utf8Count)
        let edits = await Task.detached { () -> [(range: Range<Int>, text: String)]? in
            plan.verify(file, against: bytes) ? plan.edits(for: file, in: bytes) : nil
        }.value
        guard let edits else { return .skipped(reason: "changed since search") }
        guard documents[path] === doc, doc.buffer.version == version else { return .skipped(reason: "changed since search") }
        // The focused editor's selection state acts, so one undo puts its caret back where it was.
        let apply: (CodeBuffer) -> Void = { buffer in
            for edit in edits { buffer.replace(edit.range, with: edit.text, origin: .programmatic) }
        }
        if let acting = selectionState(for: path, in: defaultPane) { acting.transaction(apply) } else { doc.buffer.transaction(apply) }
        guard doc.isDirty else { return .applied(edits: file.matches.count) }
        pendingGroup[path] = group
        do { try await save(path) } catch {
            pendingGroup.removeValue(forKey: path)
            return .skipped(reason: "could not save: \(error.localizedDescription)")
        }
        return .applied(edits: file.matches.count)
    }

    // MARK: Review

    /// The live edits of `group`, by path, oldest first.
    func liveEdits(group: UUID) -> [(path: String, ids: [UUID])] {
        ensureLoaded()
        return ledger.files.keys.sorted().compactMap { path in
            guard let edits = ledger.files[path]?.edits else { return nil }
            let ids = edits.filter { $0.group == group && $0.state == .live }.map(\.id)
            return ids.isEmpty ? nil : (path, ids)
        }
    }

    /// Whether `path` holds an edit of `group` (live or not).
    public func hasEdit(group: UUID, path: String) -> Bool {
        ledger.files[path]?.edits.contains { $0.group == group } ?? false
    }

    /// Keeps every live edit of `group`, writing the ledger once.
    public func keepAll(group: UUID) async {
        await withLedgerBatch {
            for (path, ids) in liveEdits(group: group) {
                for id in ids { keep(edit: id, path: path) }
            }
        }
    }

    /// Reverts every live edit of `group`, newest first within a file, writing the ledger once. One entry per file:
    /// a conflict on any of its edits makes the entry a conflict.
    public func revertAll(group: UUID) async -> [(path: String, outcome: RevertOutcome)] {
        var results: [(path: String, outcome: RevertOutcome)] = []
        await withLedgerBatch {
            for (path, ids) in liveEdits(group: group) {
                var outcome: RevertOutcome = .conflict(reason: "")
                var conflict: String?
                for id in ids.reversed() {
                    let o = await revert(edit: id, path: path)
                    if case .conflict(let reason) = o { conflict = conflict ?? reason } else { outcome = o }
                }
                results.append((path, conflict.map { .conflict(reason: $0) } ?? outcome))
            }
        }
        return results
    }
}
