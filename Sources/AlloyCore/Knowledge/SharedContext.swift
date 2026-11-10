import Foundation

/// What a built-but-undelivered message will have told its session.
struct PendingTold {
    var token = UUID()
    var session: UUID
    var updates: [String: ToldEntry]
}

extension Workspace {
    var toldURL: URL { storeDirectory.appendingPathComponent("told.json") }

    // MARK: Ordering

    /// Waits for this session's turn at building a message's shared context. Turns run in arrival order.
    func acquireContext(_ id: UUID) async {
        if contextBusy.insert(id).inserted { return }
        await withCheckedContinuation { contextWaiters[id, default: []].append($0) }
    }

    /// Hands the turn to the next waiting send, or frees it.
    func releaseContext(_ id: UUID) {
        if var waiting = contextWaiters[id], !waiting.isEmpty {
            let next = waiting.removeFirst()
            contextWaiters[id] = waiting.isEmpty ? nil : waiting
            next.resume()
        } else {
            contextBusy.remove(id)
        }
    }

    // MARK: Building

    /// The "already read" block for a message about to be sent to `s`, or nil when the master switch is off or there
    /// is nothing new to tell. Stamps are read off the main actor in one batch; the block itself is built here.
    func sharedContext(for s: Session, message: String) async -> (text: String, files: [SharedFile], pending: PendingTold)? {
        guard settings.shareKnowledge else { return nil }
        refreshKnowledge()
        guard readIndex.hasReads(excluding: s.id) else { return nil }
        let recent = recentFiles(of: s.id)
        let root = projectRoot, scope = knowledgeScope
        let prepared = await Task.detached { Self.prepareCandidates(message: message, recent: recent, root: root, scope: scope) }.value
        guard !prepared.candidates.isEmpty, !isShuttingDown else { return nil }
        var names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Readers in other windows are not sessions here; the name they left with their read stands in, with its project.
        for c in prepared.candidates {
            for e in readIndex.readers(path: prepared.canonical[c] ?? c) where names[e.session] == nil {
                names[e.session] = name(of: e.session, authorName: e.authorName, project: e.project, fallback: "another session")
            }
        }
        let ledger = self.ledger
        let canonicalKeys = prepared.canonical
        let canonical = { (key: String) in canonicalKeys[key] ?? key }
        var table = told[s.id] ?? [:]
        for p in inflightTold where p.session == s.id { table.merge(p.updates) { _, new in new } }
        let built = AlreadyRead.block(for: s.id, candidates: prepared.candidates, index: readIndex, notes: notes,
                                      stamps: prepared.stamps, names: names, canonical: canonical,
                                      changedBy: { path, read in
                                          ledger.files[path]?.edits.last { $0.date > read }?.author
                                      },
                                      display: { scope.display($0) }, told: table, generation: compactionGeneration[s.id, default: 0])
        guard let built else { return nil }
        let pending = PendingTold(session: s.id, updates: built.told)
        inflightTold.append(pending)
        return (built.text, built.files, pending)
    }

    /// Ends a built message's claim: when it was delivered its files become told (and are saved); when it was
    /// dropped they stay untold.
    func settleTold(_ pending: PendingTold?, sent: Bool) {
        guard let pending, let i = inflightTold.firstIndex(where: { $0.token == pending.token }) else { return }
        inflightTold.remove(at: i)
        guard sent else { return }
        told[pending.session, default: [:]].merge(pending.updates) { _, new in new }
        persistTold()
    }

    /// The paths `id` read or edited, newest first, at most `AlreadyRead.maxRecent`.
    func recentFiles(of id: UUID) -> [String] {
        var latest: [String: Date] = [:]
        for e in readIndex.entries(of: id) { latest[e.path] = max(latest[e.path] ?? .distantPast, e.date) }
        for (path, file) in ledger.files {
            if let edit = file.edits.last(where: { $0.author == .session(id) }) {
                latest[path] = max(latest[path] ?? .distantPast, edit.date)
            }
        }
        return latest.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(AlreadyRead.maxRecent).map(\.key)
    }

    /// Resolves the files a message names (at most `maxCandidates`) and the session's recent files, and reads their
    /// stamps. Runs off the main actor. Nothing outside the project root is examined: a path is checked lexically
    /// against the root before any disk access, and a symlink out of the root is refused by `NotePath`.
    nonisolated static func prepareCandidates(message: String, recent: [String], root: URL)
        -> (candidates: [String], stamps: [String: FileStamp?], canonical: [String: String]) {
        prepareCandidates(message: message, recent: recent, root: root, scope: KnowledgeScope(ownRoot: root.path))
    }

    /// As above, across every project in `scope`; candidates are scope keys.
    nonisolated static func prepareCandidates(message: String, recent: [String], root: URL, scope: KnowledgeScope)
        -> (candidates: [String], stamps: [String: FileStamp?], canonical: [String: String]) {
        var candidates: [String] = []
        var stamps: [String: FileStamp?] = [:]
        var canonical: [String: String] = [:]
        let rootForms = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path] + scope.spellings
        func add(_ raw: String) {
            let joined = raw.hasPrefix("/") ? raw : root.path + "/" + raw
            let standard = URL(fileURLWithPath: joined).standardizedFileURL.path
            guard rootForms.contains(where: { standard.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }),
                  let path = NotePath.resolve(raw, root: root, scope: scope) else { return }
            guard stamps[path.relative] == nil else { return }
            let (stamp, _) = NotesTools.stamp(of: path)
            guard let stamp else { return }
            stamps[path.relative] = stamp
            candidates.append(path.relative)
            canonical[path.relative] = scope.key(forReal: path.url.path) ?? path.relative
        }
        var named = 0
        var seenRaw = Set<String>()
        for raw in AlreadyRead.mentions(in: message) + AlreadyRead.bareTokens(in: message) where seenRaw.insert(raw).inserted {
            if named >= AlreadyRead.maxCandidates { break }
            named += 1
            add(raw)
        }
        for path in recent { add(path) }
        return (candidates, stamps, canonical)
    }

    /// A fork starts with what its source had been told.
    func copyTold(from source: UUID, to fork: UUID) {
        // Only what the source still has in context (its current generation), restated for the fork's generation.
        let current = compactionGeneration[source, default: 0], forkGeneration = compactionGeneration[fork, default: 0]
        guard let table = told[source] else { return }
        told[fork] = table.filter { $0.value.generation == current }.mapValues { e in
            var c = e; c.generation = forkGeneration; return c
        }
        persistTold()
    }

    // MARK: Persistence

    /// Writes `told.json` off the main actor, chained and coalesced like `persistReads`.
    func persistTold() {
        toldSnapshot = Dictionary(uniqueKeysWithValues: told.map { ($0.key.uuidString, $0.value) })
        guard !toldWriteQueued else { return }
        toldWriteQueued = true
        let url = toldURL, previous = toldWrite
        toldWrite = Task.detached { [weak self] in
            await previous?.value
            guard let snapshot = await self?.takeToldSnapshot() else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                let message = "Could not save the record of shared notes: \(error.localizedDescription)"
                await self?.report(message)
            }
        }
    }

    private func takeToldSnapshot() -> [String: [String: ToldEntry]]? {
        toldWriteQueued = false
        defer { toldSnapshot = nil }
        return toldSnapshot
    }
}
