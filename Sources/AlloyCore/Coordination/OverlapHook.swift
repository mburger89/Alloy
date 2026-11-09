import Foundation

extension Workspace {
    var overlapToldURL: URL { storeDirectory.appendingPathComponent("overlapTold.json") }

    private static let hookedTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private static let hookPathCacheLimit = 4_096
    /// A `replace_all` with more spans than this is checked by its hull, so the query stays bounded.
    private static let maxSpanQueries = 20

    // MARK: Paths

    /// The forms of `root` a hook path may start with. Computed once; this is the only place the hook path
    /// machinery touches the disk (symlink resolution).
    nonisolated static func hookRootForms(of root: URL) -> [String] {
        var forms = [lexicalPath(root.path)]
        // realpath, not `resolvingSymlinksInPath`: Foundation strips the `/private` prefix again (`/private/var` -> `/var`),
        // while the CLI reports the real path.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(root.path, &buffer) != nil {
            let resolved = lexicalPath(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            if !forms.contains(resolved) { forms.append(resolved) }
        }
        return forms
    }

    /// `.` and `..` resolved without looking at the disk.
    nonisolated static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for p in path.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { _ = parts.popLast(); continue }
            parts.append(p)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The project-relative form of a hook's path, or nil outside the project. Purely lexical, so no disk access.
    func hookRelativePath(_ raw: String) -> String? {
        if let hit = hookPathCache[raw] { return hit }
        let absolute = raw.hasPrefix("/") ? raw : projectRoot.path + "/" + raw
        let normal = Self.lexicalPath(absolute)
        for root in hookRootForms {
            let prefix = root == "/" ? "/" : root + "/"
            guard normal.hasPrefix(prefix), normal.count > prefix.count else { continue }
            let rel = String(normal.dropFirst(prefix.count))
            if hookPathCache.count >= Self.hookPathCacheLimit { hookPathCache.removeAll() }
            hookPathCache[raw] = rel
            return rel
        }
        return nil
    }

    // MARK: Hooks

    /// The server's handler: hops to the main actor, and does nothing for a request whose deadline already passed.
    func answerHook(_ request: HookRequest, _ caller: MCPCaller) async -> HookReply {
        guard !Task.isCancelled, !isShuttingDown else { return HookReply() }
        return handleHook(request, caller: caller)
    }

    /// PreToolUse: register the session's change, then tell it about overlaps it has not heard of. PostToolUse:
    /// resolve the proposal. Synchronous and in memory only; it never blocks the tool, so the worst case is `{}`.
    func handleHook(_ request: HookRequest, caller: MCPCaller) -> HookReply {
        // PostToolUse changes nothing: the proposal stays until the tool_result brings the ledger edit (or fails), or the
        // session ends, so a hook from another session that arrives in between still sees the change.
        guard request.event == .preToolUse else { return HookReply() }
        guard Self.hookedTools.contains(request.toolName), let s = session(caller.sessionID),
              let raw = (request.toolInput["file_path"] ?? request.toolInput["notebook_path"])?.stringValue,
              let rel = hookRelativePath(raw) else { return HookReply() }
        refreshClaims(session: s.id, path: rel)
        // Without the file's text in memory the change cannot be placed; claims on the file are still reported.
        let change = currentText(of: rel).flatMap {
            ProposedChange.from(session: s.id, toolUseID: request.toolUseID, path: rel, toolName: request.toolName,
                                input: request.toolInput, currentText: $0, date: now())
        }
        var overlaps: [Overlap] = []
        var spans: [ClosedRange<Int>]?
        if let change {
            overlapIndex.propose(change)
            spans = change.ranges.count <= Self.maxSpanQueries ? change.ranges : [change.range.lines]
            for span in spans! {
                overlaps += overlapIndex.overlaps(for: s.id, range: LineRange(path: rel, lines: span))
            }
        }
        let generation = compactionGeneration[s.id, default: 0]
        let told = overlapTold[s.id] ?? [:]
        let current = now()
        // A live edit that came from a tool call is the same change its proposal announced: one key for both.
        var toolIDs: [UUID: String] = [:]
        if overlaps.contains(where: { if case .active = $0.kind { true } else { false } }) {
            for e in ledger.files[rel]?.edits ?? [] { if let t = e.toolUseID { toolIDs[e.id] = t } }
        }
        let noticeItems = OverlapNotice.items(from: overlaps, path: rel, now: current, name: { [self] id in session(id)?.name ?? "Another session" },
                                       toolID: { toolIDs[$0] })
        let claimed = claimItems(for: s.id, path: rel, spans: spans)
        let items = (noticeItems + claimed).filter { told[$0.key] != generation && !$0.text.isEmpty }
        guard !items.isEmpty else { return HookReply() }

        let joined = OverlapNotice.join(items.map(\.text))
        var table = told
        if table.count > 2_000 {
            let live = liveToldKeys()
            table = table.filter { $0.value == generation && (!$0.key.hasPrefix("edit:") || live.contains($0.key)) }
        }
        for item in items.prefix(joined.included) { table[item.key] = generation }
        overlapTold[s.id] = table
        persistOverlapTold()
        s.transcript.appendNotice(kind: .warning, text: joined.text)
        let editorLines = spans.flatMap { sp in sp.map(\.lowerBound).min().flatMap { lo in sp.map(\.upperBound).max().map { lo...$0 } } }
        recordOverlapWarnings(editor: s, path: rel, told: Array(items.prefix(joined.included)), lines: editorLines, tool: request.toolUseID)
        return HookReply(additionalContext: joined.text)
    }

    /// The file's text as Alloy holds it in memory: the ledger's, else an open editable buffer's saved text.
    private func currentText(of path: String) -> String? {
        if let file = ledger.files[path] { return file.currentText }
        if let doc = documents[path], doc.state == .editable { return doc.savedSnapshot.text }
        return nil
    }

    // MARK: Persistence

    /// `edit:` and `tool:` keys of edits that are live in the ledger now.
    func liveToldKeys() -> Set<String> {
        var keys = Set<String>()
        for c in claims { keys.insert("claim:\(c.id.uuidString)") }
        for file in ledger.files.values {
            for e in file.edits where e.state == .live {
                keys.insert("edit:\(e.id.uuidString)")
                if let t = e.toolUseID { keys.insert("tool:\(t)") }
            }
        }
        return keys
    }

    /// Drops told entries whose edit is no longer live (used after loading `overlapTold.json`).
    func pruneOverlapTold() {
        let live = liveToldKeys()
        for (id, table) in overlapTold { overlapTold[id] = table.filter { live.contains($0.key) } }
        overlapTold = overlapTold.filter { !$0.value.isEmpty }
    }

    /// A fork starts with what its source had been told at the source's generation, restated for the fork's.
    func copyOverlapTold(from source: UUID, to fork: UUID) {
        let current = compactionGeneration[source, default: 0], forkGeneration = compactionGeneration[fork, default: 0]
        guard let table = overlapTold[source] else { return }
        overlapTold[fork] = table.filter { $0.value == current }.mapValues { _ in forkGeneration }
        persistOverlapTold()
    }

    /// Writes `overlapTold.json` off the main actor, chained and coalesced like `persistTold`.
    func persistOverlapTold() {
        // Only keys of applied edits last across a restart; proposals and typing live in memory.
        let live = liveToldKeys()
        var snapshot: [String: [String: Int]] = [:]
        for (id, table) in overlapTold {
            let kept = table.filter { live.contains($0.key) }
            if !kept.isEmpty { snapshot[id.uuidString] = kept }
        }
        overlapToldSnapshot = snapshot
        guard !overlapToldWriteQueued else { return }
        overlapToldWriteQueued = true
        let url = overlapToldURL, previous = overlapToldWrite
        overlapToldWrite = Task.detached { [weak self] in
            await previous?.value
            guard let snapshot = await self?.takeOverlapToldSnapshot() else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                await self?.report("Could not save the record of overlap warnings: \(error.localizedDescription)")
            }
        }
    }

    private func takeOverlapToldSnapshot() -> [String: [String: Int]]? {
        overlapToldWriteQueued = false
        defer { overlapToldSnapshot = nil }
        return overlapToldSnapshot
    }
}
