import Foundation

/// One session's reads of one file: the unit the pool stores and the workspace diffs.
struct ReadGroup: Hashable {
    var session: UUID
    /// Absolute path.
    var path: String
}

extension Workspace {
    var generationsURL: URL { storeDirectory.appendingPathComponent("generations.json") }
    var poolURL: URL { appSupport.appendingPathComponent("Alloy/Shared/knowledge.sqlite") }

    private var isolated: Bool { !settings.shareKnowledge || !settings.shareAcrossProjects }

    // MARK: Opening

    /// Opens the shared pool, registers this project and imports 5a-era files once. A pool that cannot open is
    /// reported once; knowledge then stays in memory for the run.
    func loadKnowledge() {
        do {
            let opened = try KnowledgePool(url: poolURL, busyTimeoutMS: poolBusyTimeoutMS) { [weak self] message in
                Task { @MainActor [weak self] in self?.reportPoolFailure(message) }
            }
            pool = opened
        } catch {
            poolErrorReported = true
            report("Could not open shared knowledge: \(error)")
            loadLegacyIntoMemory()
            return
        }
        guard let pool else { return }
        let own = knowledgeScope.ownRoot
        pool.register(KnownProject(root: own, name: (own as NSString).lastPathComponent))
        pool.setShared(own, !isolated)
        importLegacyFiles(into: pool)
        pool.pruneReads(olderThan: now().addingTimeInterval(-NotesStore.staleExpiry))
        poolVersion = pool.dataVersion()
        reloadView(from: pool)
        if notes.expire(before: now().addingTimeInterval(-NotesStore.staleExpiry)) { persistNotes() }
    }

    /// A pool failure after it opened: the window hears of it once per run, the first message kept.
    private func reportPoolFailure(_ message: String) {
        guard !poolErrorReported else { return }
        poolErrorReported = true
        report("Shared knowledge: \(message)")
    }

    /// Without a pool, the 5a files are read into memory as 5a did, and left where they are.
    private func loadLegacyIntoMemory() {
        if let store = loadFile(notesURL, { try JSONDecoder().decode(NotesStore.self, from: $0) }) {
            let scope = knowledgeScope
            notes = NotesStore(notes: store.all.map { n in
                var n = n
                if case .file(let p) = n.subject { n.subject = .file(Self.canonicalReadKey(p, scope: scope)) }
                return n
            })
        }
        if let file = loadFile(readsURL, { try ReadsFile.decode($0) }) {
            let scope = knowledgeScope
            readIndex = ReadIndex(entries: file.index.allEntries.map { e in
                var e = e; e.path = Self.canonicalReadKey(e.path, scope: scope); return e
            })
            for (k, v) in file.generations {
                if let id = UUID(uuidString: k), compactionGeneration[id] == nil { compactionGeneration[id] = v }
            }
        }
        if notes.expire(before: now().addingTimeInterval(-NotesStore.staleExpiry)) { persistNotes() }
    }

    /// Moves `notes.json` and `reads.json` into the pool, once per project. The files are renamed and the project is
    /// marked imported only when every write of the import succeeded; otherwise the next open tries again.
    private func importLegacyFiles(into pool: KnowledgePool) {
        let own = knowledgeScope.ownRoot, scope = knowledgeScope
        guard !pool.isImported(own) else { return }
        let failuresBefore = pool.failureCount
        let names = Dictionary(records.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        func absolute(_ rel: String) -> String { rel.hasPrefix("/") ? rel : own + "/" + rel }
        // A read or note of a file reached through a link is stored under the file it resolves to.
        func resolved(_ rel: String) -> String {
            guard let real = NotePath.realPath(absolute(rel)) else { return absolute(rel) }
            // A link out of every known project keeps its own path rather than a real path no project owns.
            return scope.key(forReal: real) == nil && scope.key(forReal: absolute(rel)) != nil ? absolute(rel) : real
        }
        var renames: [URL] = []
        var importedNotes: [Note] = [], importedGroups: [ReadGroupWrite] = []
        var legacyGenerations: [UUID: Int] = [:]
        if let store = loadFile(notesURL, { try JSONDecoder().decode(NotesStore.self, from: $0) }) {
            let imported = store.all.map { n -> Note in
                var n = n
                if case .file(let p) = n.subject { n.subject = .file(resolved(p)) }
                n.project = own
                n.authorName = n.authorName ?? names[n.author]
                return n
            }
            importedNotes = imported
            renames.append(notesURL)
        }
        if let file = loadFile(readsURL, { try ReadsFile.decode($0) }) {
            var groups: [ReadGroup: [ReadEntry]] = [:]
            for e in file.index.allEntries {
                var e = e
                e.path = resolved(e.path)
                e.project = own
                e.authorName = e.authorName ?? names[e.session]
                groups[ReadGroup(session: e.session, path: e.path), default: []].append(e)
            }
            importedGroups = groups.map { ReadGroupWrite(session: $0.key.session, path: $0.key.path, entries: $0.value) }
            for (k, v) in file.generations { if let id = UUID(uuidString: k) { legacyGenerations[id] = v } }
            renames.append(readsURL)
        }
        pool.apply(upserts: importedNotes, reads: importedGroups)
        pool.flush()
        _ = pool.takeFailedInserts()
        _ = pool.takeFailedDeletes()
        guard pool.failureCount == failuresBefore else { return }
        for (id, v) in legacyGenerations where compactionGeneration[id] == nil { compactionGeneration[id] = v }
        if !legacyGenerations.isEmpty { persistGenerations() }
        for url in renames {
            let dest = url.appendingPathExtension("imported")
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: url, to: dest) } catch {
                report("\(url.lastPathComponent) was imported but could not be renamed: \(error.localizedDescription)")
            }
        }
        pool.markImported(own)
    }

    // MARK: Reload

    /// Picks up other windows' writes: when the pool changed since the last load, this workspace's own unsent changes
    /// are written first and the view is rebuilt from the pool.
    func refreshKnowledge() {
        guard loaded, let pool else { return }
        let version = pool.dataVersion()
        guard version != poolVersion else { return }
        poolVersion = version
        pool.flush()
        flushSync(notes: true, reads: .full)
        reloadView(from: pool)
    }

    /// A change of what the settings let this window see: write what is pending, then rebuild the view.
    func reloadKnowledgeAfterSettingsChange() {
        guard loaded, let pool else { return }
        pool.setShared(knowledgeScope.ownRoot, !isolated)
        // A write still in flight may fail: wait for it, so flushSync hears of the failure and sends it again
        // before the view is rebuilt from the pool.
        pool.flush()
        flushSync(notes: true, reads: .full)
        poolVersion = pool.dataVersion()
        reloadView(from: pool)
    }

    /// Rebuilds `notes`, `readIndex` and the scope from the pool: own-project paths become relative keys, other known
    /// projects' absolute ones, anything else is dropped. Isolated, only rows this project wrote are kept.
    private func reloadView(from pool: KnowledgePool) {
        // Waits for the writes a sync just queued, so the failures peeked below include theirs.
        pool.flush()
        let own = knowledgeScope.ownRoot
        let alone = isolated
        let known = alone ? [] : pool.knownProjects()
        let scope = KnowledgeScope(ownRoot: projectRoot.path, known: known)
        // Rows written by a project that switched sharing off are dropped: only this project and the shared ones stay.
        let sharedRoots = Set(known.map(\.root))
        func visible(_ project: String?) -> Bool {
            guard let project else { return !alone }
            return project == own || sharedRoots.contains(project)
        }
        knowledgeScope = scope
        // Writes that failed again since the last sync are still owed: a delete keeps its note out of the view, an
        // insert keeps its note in it (the pool does not have it), until a later sync gets them through.
        let owedDeletes = pool.peekFailedDeletes(), owedInserts = pool.peekFailedInserts()
        let local = Dictionary(self.notes.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var viewNotes: [Note] = [], noteBase: [UUID: Note] = [:]
        for row in pool.loadNotes() where visible(row.project) && !owedDeletes.contains(row.id) {
            var n = row
            if case .file(let p) = row.subject {
                guard let key = scope.key(forReal: p) else { continue }
                n.subject = .file(key)
            }
            viewNotes.append(n)
            noteBase[row.id] = row
        }
        let inView = Set(viewNotes.map(\.id))
        for id in owedInserts where !inView.contains(id) && !owedDeletes.contains(id) {
            if let n = local[id] { viewNotes.append(n) }
        }
        var viewReads: [ReadEntry] = [], readBase: [ReadGroup: [ReadEntry]] = [:]
        for row in pool.loadReads() where visible(row.project) {
            guard let key = scope.key(forReal: row.path) else { continue }
            var e = row
            e.path = key
            viewReads.append(e)
            readBase[ReadGroup(session: row.session, path: row.path), default: []].append(row)
        }
        notes = NotesStore(notes: viewNotes)
        readIndex = ReadIndex(entries: viewReads)
        syncedNotes = noteBase
        syncedReads = readBase
    }

    // MARK: Writing

    /// The pool form of a view note: an absolute path, stamped with its writer where that is still missing.
    private func poolForm(_ note: Note) -> Note {
        var n = note
        if case .file(let key) = n.subject { n.subject = .file(knowledgeScope.absolute(key)) }
        if n.project == nil { n.project = knowledgeScope.ownRoot }
        if n.authorName == nil { n.authorName = session(n.author)?.name }
        return n
    }

    /// Writes what changed in `notes` since the last sync: upserts for new and changed notes, deletes for removed ones.
    func persistNotes() { flushSync(notes: true, reads: .none) }

    private enum ReadSync { case none, dirty, full }

    /// Writes what changed since the last sync as one pool transaction: the notes diff and/or the read groups.
    private func flushSync(notes syncNotes: Bool, reads: ReadSync) {
        guard let pool else { return }
        // An insert the pool could not make is forgotten, so this sync inserts that note again.
        for id in pool.takeFailedInserts() { syncedNotes[id] = nil }
        var upserts: [Note] = [], updates: [Note] = [], deletes: [UUID] = [], groups: [ReadGroupWrite] = []
        if syncNotes {
            var current: [UUID: Note] = [:]
            for n in self.notes.all {
                let p = poolForm(n)
                current[p.id] = p
                guard syncedNotes[p.id] != p else { continue }
                // A note already in the baseline is only updated, so a row another window deleted is never recreated.
                if syncedNotes[p.id] == nil { upserts.append(p) } else { updates.append(p) }
            }
            deletes = syncedNotes.keys.filter { current[$0] == nil }
            // A delete the pool rolled back is sent again, unless the note is back (then it is simply kept).
            deletes += pool.takeFailedDeletes().filter { !deletes.contains($0) }
            syncedNotes = current
        }
        if reads != .none { groups = collectReadChanges(full: reads == .full) }
        pool.apply(upserts: upserts, updates: updates, deletes: deletes, reads: groups)
    }

    /// Notes that a read group (one session, one file key) changed and needs writing.
    func markReadDirty(session: UUID, key: String) {
        dirtyReads.insert(ReadGroup(session: session, path: knowledgeScope.absolute(key)))
    }

    /// Records a read and queues its group for writing.
    func recordRead(_ entry: ReadEntry, resolved: Bool = false) {
        refreshKnowledge()
        // Indexed under the real-path key, so `link/x` and `real/x` are one file whatever a session typed. A caller
        // that already resolved it (off the main actor) says so.
        var entry = entry
        if !resolved { entry.path = canonicalReadKey(entry.path) }
        readIndex.record(entry)
        markReadDirty(session: entry.session, key: entry.path)
        persistReads()
    }

    /// Writes the read groups changed since the last call, and the compaction generations.
    func persistReads() {
        flushSync(notes: false, reads: .dirty)
        persistGenerations()
    }

    /// The key a read of `key` is indexed under: symlinks resolved, then own-relative or absolute as the scope keys it.
    nonisolated static func canonicalReadKey(_ key: String, scope: KnowledgeScope) -> String {
        guard let real = NotePath.realPath(scope.absolute(key)), let canonical = scope.key(forReal: real) else { return key }
        return canonical
    }

    func canonicalReadKey(_ key: String) -> String { Self.canonicalReadKey(key, scope: knowledgeScope) }

    /// The pool's path for a read key. Read keys are canonical (real-path) already, so this is only a join.
    private func poolPath(forKey key: String) -> String { knowledgeScope.absolute(key) }

    private func poolForm(_ e: ReadEntry) -> ReadEntry {
        var p = e
        p.path = poolPath(forKey: e.path)
        if let local = session(e.session) { p.authorName = local.name; p.project = knowledgeScope.ownRoot }
        if p.project == nil { p.project = knowledgeScope.ownRoot }
        return p
    }

    private func collectReadChanges(full: Bool) -> [ReadGroupWrite] {
        var writes: [ReadGroupWrite] = []
        if full {
            var current: [ReadGroup: [ReadEntry]] = [:]
            for e in readIndex.allEntries {
                let p = poolForm(e)
                current[ReadGroup(session: p.session, path: p.path), default: []].append(p)
            }
            for (group, entries) in current where syncedReads[group] != entries {
                writes.append(ReadGroupWrite(session: group.session, path: group.path, entries: entries))
            }
            for group in syncedReads.keys where current[group] == nil {
                writes.append(ReadGroupWrite(session: group.session, path: group.path, entries: []))
            }
            syncedReads = current
            dirtyReads.removeAll()
            return writes
        }
        let dirty = dirtyReads
        dirtyReads.removeAll()
        for group in dirty {
            let key = knowledgeScope.key(forReal: group.path) ?? group.path
            let entries = readIndex.readers(path: key).filter { $0.session == group.session }.map(poolForm)
            // The group is stored under the resolved path (a link's reads join those of the real file).
            let stored = group
            if entries.isEmpty {
                if syncedReads[stored] != nil { writes.append(ReadGroupWrite(session: stored.session, path: stored.path, entries: [])) }
                syncedReads[stored] = nil
            } else if syncedReads[stored] != entries {
                writes.append(ReadGroupWrite(session: stored.session, path: stored.path, entries: entries))
                syncedReads[stored] = entries
            }
        }
        return writes
    }

    /// Writes `generations.json` off the main actor when the generations changed; writes run one after another.
    func persistGenerations() {
        let snapshot = Dictionary(uniqueKeysWithValues: compactionGeneration.map { ($0.key.uuidString, $0.value) })
        guard snapshot != generationsSnapshot else { return }
        generationsSnapshot = snapshot
        let url = generationsURL, previous = generationsWrite
        generationsWrite = Task.detached { [weak self] in
            await previous?.value
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                let message = "Could not save read history: \(error.localizedDescription)"
                await self?.report(message)
            }
        }
    }
}
