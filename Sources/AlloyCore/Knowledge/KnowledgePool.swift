import Foundation
import SQLite3

/// A project Alloy has opened on this Mac.
public struct KnownProject: Sendable, Equatable {
    /// A real path.
    public var root: String
    /// The root's last path component.
    public var name: String
    public init(root: String, name: String) { self.root = root; self.name = name }
}

/// Notes and read records shared by every project window, kept in one SQLite file. Each pool owns one connection
/// guarded by a serial queue; reads are synchronous and writes queue behind earlier ones, so a read on the same pool
/// sees every earlier write.
public final class KnowledgePool: @unchecked Sendable {
    private let queue = DispatchQueue(label: "alloy.knowledge-pool")
    private let reportError: @Sendable (String) -> Void
    private let failureLock = NSLock()
    private var failures = 0
    private var failedInserts: Set<UUID> = []
    private var failedDeletes: Set<UUID> = []
    /// Reports a failure to the owner and counts it.
    private func onError(_ message: String) {
        failureLock.withLock { failures += 1 }
        reportError(message)
    }
    /// How many failures this pool has reported so far (reads, writes, skipped input). A caller that flushes its
    /// writes can compare it before and after to learn whether they all succeeded.
    public var failureCount: Int { failureLock.withLock { failures } }
    private let db: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `busyTimeoutMS` is how long a statement waits for another connection's lock; the app keeps the default.
    public init(url: URL, busyTimeoutMS: Int = 1000, onError: @escaping @Sendable (String) -> Void) throws {
        self.reportError = onError
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            db = try Self.open(url, busyTimeoutMS: busyTimeoutMS)
        } catch let error as DBError where error.code == SQLITE_NOTADB || error.code == SQLITE_CORRUPT {
            // Not a usable database: move it aside and start over. Any other failure just throws.
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: url.path + suffix)
                let to = URL(fileURLWithPath: url.path + ".corrupt-\(stamp)" + suffix)
                if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: to) }
            }
            onError("knowledge pool was corrupt (\(error)); moved aside as \(url.lastPathComponent).corrupt-\(stamp)")
            db = try Self.open(url, busyTimeoutMS: busyTimeoutMS)
        }
    }

    deinit { sqlite3_close(db) }

    private struct DBError: Error, CustomStringConvertible {
        var description: String
        var code: Int32 = SQLITE_ERROR
    }

    private static func open(_ url: URL, busyTimeoutMS: Int) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw DBError(description: "open failed: \(msg)", code: rc)
        }
        do {
            try exec(handle, "PRAGMA busy_timeout=\(busyTimeoutMS)")
            try exec(handle, "PRAGMA journal_mode=WAL")
            try exec(handle, """
                CREATE TABLE IF NOT EXISTS notes(id TEXT PRIMARY KEY, key TEXT NOT NULL, project TEXT, body BLOB NOT NULL);
                CREATE INDEX IF NOT EXISTS notes_key ON notes(key);
                CREATE TABLE IF NOT EXISTS reads(session TEXT, path TEXT, project TEXT, body BLOB NOT NULL, PRIMARY KEY(session, path));
                CREATE TABLE IF NOT EXISTS projects(root TEXT PRIMARY KEY, name TEXT, imported INTEGER DEFAULT 0, shared INTEGER NOT NULL DEFAULT 1);
                """)
            var version: Int32 = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
                version = sqlite3_column_int(stmt, 0)
            }
            sqlite3_finalize(stmt)
            if version < 2 {
                // Version 1 pools lack `projects.shared`. Checked inside the transaction so two windows migrating at once
                // add the column once.
                try exec(handle, "BEGIN IMMEDIATE")
                do {
                    var hasShared = false
                    var info: OpaquePointer?
                    if sqlite3_prepare_v2(handle, "PRAGMA table_info(projects)", -1, &info, nil) == SQLITE_OK {
                        while sqlite3_step(info) == SQLITE_ROW {
                            if sqlite3_column_text(info, 1).map({ String(cString: $0) }) == "shared" { hasShared = true }
                        }
                    }
                    sqlite3_finalize(info)
                    if !hasShared { try exec(handle, "ALTER TABLE projects ADD COLUMN shared INTEGER NOT NULL DEFAULT 1") }
                    try exec(handle, "PRAGMA user_version = 2")
                    try exec(handle, "COMMIT")
                } catch {
                    _ = try? exec(handle, "ROLLBACK")
                    throw error
                }
            }
            if version < 3 {
                try exec(handle, "BEGIN IMMEDIATE")
                do {
                    try migrateReadPaths(handle)
                    try exec(handle, "PRAGMA user_version = 3")
                    try exec(handle, "COMMIT")
                } catch {
                    _ = try? exec(handle, "ROLLBACK")
                    throw error
                }
            }
            if version < 4 {
                try exec(handle, "BEGIN IMMEDIATE")
                do {
                    try migrateNotePaths(handle)
                    try exec(handle, "PRAGMA user_version = 4")
                    try exec(handle, "COMMIT")
                } catch {
                    _ = try? exec(handle, "ROLLBACK")
                    throw error
                }
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
        return handle
    }

    /// Version 4: a file note is keyed by the real path of its file. A row stored under a link's path takes the real
    /// path as its key and in its body; topic notes are untouched. Notes are separate rows, so nothing merges.
    private static func migrateNotePaths(_ handle: OpaquePointer) throws {
        struct Row { var id: String, key: String, body: Data }
        var all: [Row] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT id, key, body FROM notes WHERE key LIKE '/%'", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(description: String(cString: sqlite3_errmsg(handle)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let n = Int(sqlite3_column_bytes(stmt, 2))
            let body = n > 0 ? Data(bytes: sqlite3_column_blob(stmt, 2), count: n) : Data()
            all.append(Row(id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                           key: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "", body: body))
        }
        sqlite3_finalize(stmt)
        var roots: [String] = []
        var rootStmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT root FROM projects", -1, &rootStmt, nil) == SQLITE_OK {
            while sqlite3_step(rootStmt) == SQLITE_ROW { if let t = sqlite3_column_text(rootStmt, 0) { roots.append(String(cString: t)) } }
        }
        sqlite3_finalize(rootStmt)
        func known(_ p: String) -> Bool { roots.contains { NotePath.isUnder(p, root: $0) } }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for row in all {
            // A link out of every known project keeps its own key rather than a real path no project owns.
            guard let real = NotePath.realPath(row.key), real != row.key, known(real) || !known(row.key),
                  var note = try? decoder.decode(Note.self, from: row.body), case .file = note.subject else { continue }
            note.subject = .file(real)
            let body = try encoder.encode(note)
            var upd: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE notes SET key = ?, body = ? WHERE id = ?", -1, &upd, nil) == SQLITE_OK else {
                throw DBError(description: String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(upd, 1, real, -1, transient)
            _ = body.withUnsafeBytes { sqlite3_bind_blob(upd, 2, $0.baseAddress, Int32(body.count), transient) }
            sqlite3_bind_text(upd, 3, row.id, -1, transient)
            let rc = sqlite3_step(upd)
            sqlite3_finalize(upd)
            guard rc == SQLITE_DONE else { throw DBError(description: String(cString: sqlite3_errmsg(handle))) }
        }
    }

    /// Version 3: read rows are keyed by the real path of the file. A row stored under a link's path moves to the
    /// real path's group (one session, one file), merging with the group already there.
    private static func migrateReadPaths(_ handle: OpaquePointer) throws {
        struct Row { var session: String, path: String, project: String?, body: Data }
        var all: [Row] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT session, path, project, body FROM reads", -1, &stmt, nil) == SQLITE_OK else {
            throw DBError(description: String(cString: sqlite3_errmsg(handle)))
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
            let n = Int(sqlite3_column_bytes(stmt, 3))
            let body = n > 0 ? Data(bytes: sqlite3_column_blob(stmt, 3), count: n) : Data()
            all.append(Row(session: text(0) ?? "", path: text(1) ?? "", project: text(2), body: body))
        }
        sqlite3_finalize(stmt)
        var byKey: [String: Row] = Dictionary(all.map { ($0.session + "\0" + $0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        for row in all {
            guard let real = NotePath.realPath(row.path), real != row.path,
                  var entries = try? decoder.decode([ReadEntry].self, from: row.body) else { continue }
            for i in entries.indices { entries[i].path = real }
            let target = row.session + "\0" + real
            if let existing = byKey[target], let old = try? decoder.decode([ReadEntry].self, from: existing.body) {
                entries = old + entries.filter { e in !old.contains(e) }
            }
            let body = try encoder.encode(entries)
            byKey[row.session + "\0" + row.path] = nil
            byKey[target] = Row(session: row.session, path: real, project: row.project, body: body)
            try exec(handle, "DELETE FROM reads WHERE session = '\(row.session)' AND path = '\(row.path.replacingOccurrences(of: "'", with: "''"))'")
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO reads(session, path, project, body) VALUES(?, ?, ?, ?)", -1, &ins, nil) == SQLITE_OK else {
                throw DBError(description: String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(ins, 1, row.session, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(ins, 2, real, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if let p = row.project { sqlite3_bind_text(ins, 3, p, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } else { sqlite3_bind_null(ins, 3) }
            _ = body.withUnsafeBytes { sqlite3_bind_blob(ins, 4, $0.baseAddress, Int32(body.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            let rc = sqlite3_step(ins)
            sqlite3_finalize(ins)
            guard rc == SQLITE_DONE else { throw DBError(description: String(cString: sqlite3_errmsg(handle))) }
        }
    }

    private static func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError(description: msg, code: rc & 0xff)
        }
    }

    // MARK: Statements

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError(description: String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(stmt, index, text, -1, transient) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bind(_ stmt: OpaquePointer, _ index: Int32, data: Data) {
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient) }
    }

    private func run(_ sql: String, _ binder: (OpaquePointer) -> Void = { _ in }) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError(description: String(cString: sqlite3_errmsg(db))) }
    }

    private func rows(_ sql: String, _ binder: (OpaquePointer) -> Void = { _ in }, _ row: (OpaquePointer) -> Void) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt) } else if rc == SQLITE_DONE { break } else {
                throw DBError(description: String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, col)))
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    /// Writes run queued, in one `BEGIN IMMEDIATE` transaction.
    private func write(_ what: String, _ body: @escaping @Sendable () throws -> Void) {
        queue.async { [self] in
            do {
                try run("BEGIN IMMEDIATE")
                do { try body(); try run("COMMIT") } catch { try? run("ROLLBACK"); throw error }
            } catch {
                onError("knowledge pool \(what) failed: \(error)")
            }
        }
    }

    /// Waits for queued writes.
    public func flush() { queue.sync {} }

    // MARK: Registry

    public func register(_ project: KnownProject) {
        write("register") { [self] in
            try run("INSERT INTO projects(root, name) VALUES(?, ?) ON CONFLICT(root) DO UPDATE SET name = excluded.name") {
                bind($0, 1, project.root); bind($0, 2, project.name)
            }
        }
    }

    /// Whether this project's knowledge is visible to other windows (`false` after its owner switched sharing off).
    public func setShared(_ root: String, _ shared: Bool) {
        write("setShared") { [self] in
            try run("INSERT INTO projects(root, shared) VALUES(?, ?) ON CONFLICT(root) DO UPDATE SET shared = excluded.shared") {
                bind($0, 1, root); sqlite3_bind_int($0, 2, shared ? 1 : 0)
            }
        }
    }

    /// The registered projects; by default only those that share their knowledge.
    public func knownProjects(includeUnshared: Bool = false) -> [KnownProject] {
        queue.sync {
            var out: [KnownProject] = []
            do {
                let filter = includeUnshared ? "" : " AND shared != 0"
                try rows("SELECT root, name FROM projects WHERE name IS NOT NULL\(filter) ORDER BY rowid") {
                    out.append(KnownProject(root: text($0, 0), name: text($0, 1)))
                }
            } catch { onError("knowledge pool read failed: \(error)") }
            return out
        }
    }

    public func isImported(_ root: String) -> Bool {
        queue.sync {
            var imported = false
            do {
                try rows("SELECT imported FROM projects WHERE root = ?", { bind($0, 1, root) }) {
                    imported = sqlite3_column_int($0, 0) != 0
                }
            } catch { onError("knowledge pool read failed: \(error)") }
            return imported
        }
    }

    public func markImported(_ root: String) {
        write("markImported") { [self] in
            // An unregistered root gets a nameless row, which `knownProjects()` leaves out.
            try run("INSERT INTO projects(root, imported) VALUES(?, 1) ON CONFLICT(root) DO UPDATE SET imported = 1") {
                bind($0, 1, root)
            }
        }
    }

    /// `PRAGMA data_version`: changes when another connection commits.
    public func dataVersion() -> Int64 {
        queue.sync {
            var v: Int64 = 0
            do { try rows("PRAGMA data_version") { v = sqlite3_column_int64($0, 0) } } catch {
                onError("knowledge pool read failed: \(error)")
            }
            return v
        }
    }

    // MARK: Notes

    /// The `key` column: the absolute path of a file note, `topic:<topicKey>` for a topic; nil for a relative path.
    static func key(_ note: Note) -> String? {
        switch note.subject {
        case .topic(let t): return "topic:" + NotesStore.topicKey(t)
        case .file(let path): return path.hasPrefix("/") ? path : nil
        }
    }

    public func loadNotes() -> [Note] {
        queue.sync {
            var out: [Note] = []
            let decoder = JSONDecoder()
            do {
                try rows("SELECT body FROM notes ORDER BY rowid") {
                    do { out.append(try decoder.decode(Note.self, from: blob($0, 0))) } catch {
                        onError("knowledge pool could not decode a note: \(error)")
                    }
                }
            } catch { onError("knowledge pool read failed: \(error)") }
            return out
        }
    }

    /// File notes must carry absolute paths; a relative one is skipped and reported.
    public func upsert(notes: [Note]) { apply(upserts: notes) }

    /// Rewrites notes that already exist; an id with no row (another window deleted it) is left absent.
    public func update(notes: [Note]) { apply(updates: notes) }

    public func delete(noteIDs: [UUID]) { apply(deletes: noteIDs) }

    /// Ids whose insert failed since the last call. A caller drops them from its synced baseline so the next sync
    /// inserts them again.
    public func takeFailedInserts() -> Set<UUID> {
        failureLock.withLock { defer { failedInserts = [] }; return failedInserts }
    }

    /// As `takeFailedInserts()`, without clearing: for a view rebuild that must not lose them.
    public func peekFailedInserts() -> Set<UUID> { failureLock.withLock { failedInserts } }

    /// As `takeFailedDeletes()`, without clearing.
    public func peekFailedDeletes() -> Set<UUID> { failureLock.withLock { failedDeletes } }

    /// Notes whose deletion did not commit (the whole transaction was rolled back) since the last call; a delete is
    /// safe to send again.
    public func takeFailedDeletes() -> Set<UUID> {
        failureLock.withLock { defer { failedDeletes = [] }; return failedDeletes }
    }

    // MARK: Reads

    /// Every group's entries; file paths are absolute.
    public func loadReads() -> [ReadEntry] {
        queue.sync {
            var out: [ReadEntry] = []
            let decoder = JSONDecoder()
            do {
                try rows("SELECT body FROM reads ORDER BY rowid") {
                    do { out.append(contentsOf: try decoder.decode([ReadEntry].self, from: blob($0, 0))) } catch {
                        onError("knowledge pool could not decode reads: \(error)")
                    }
                }
            } catch { onError("knowledge pool read failed: \(error)") }
            return out
        }
    }

    /// Deletes every read group whose newest entry is older than `date`.
    public func pruneReads(olderThan date: Date) {
        write("pruneReads") { [self] in
            var stale: [(String, String)] = []
            let decoder = JSONDecoder()
            try rows("SELECT session, path, body FROM reads") {
                guard let entries = try? decoder.decode([ReadEntry].self, from: blob($0, 2)) else { return }
                if (entries.map(\.date).max() ?? .distantPast) < date { stale.append((text($0, 0), text($0, 1))) }
            }
            for (session, path) in stale {
                try run("DELETE FROM reads WHERE session = ? AND path = ?") { bind($0, 1, session); bind($0, 2, path) }
            }
        }
    }

    /// Replaces the group of entries one session holds for one file; empty `entries` deletes it. Paths must be
    /// absolute; a relative one is skipped and reported.
    public func replaceReads(session: UUID, path: String, with entries: [ReadEntry]) {
        apply(reads: [ReadGroupWrite(session: session, path: path, entries: entries)])
    }

    // MARK: Batch

    /// One sync as ONE transaction on the pool queue: new notes (insert or replace), edited notes (only where the row
    /// still exists), deletions and read groups. A statement that fails is reported and skipped; the rest still commit.
    /// A failed insert is listed by `takeFailedInserts()`.
    public func apply(upserts: [Note] = [], updates: [Note] = [], deletes: [UUID] = [], reads: [ReadGroupWrite] = []) {
        let encoder = JSONEncoder()
        func encode(_ notes: [Note]) -> [(Note, String, Data)] {
            var out: [(Note, String, Data)] = []
            for n in notes {
                guard let key = Self.key(n) else {
                    onError("knowledge pool skipped note \(n.id): file path is not absolute"); continue
                }
                do { out.append((n, key, try encoder.encode(n))) } catch {
                    onError("knowledge pool could not encode note \(n.id): \(error)")
                }
            }
            return out
        }
        let inserts = encode(upserts), edits = encode(updates)
        var groups: [(UUID, String, String?, Data?)] = []
        for g in reads {
            guard g.path.hasPrefix("/"), g.entries.allSatisfy({ $0.path.hasPrefix("/") }) else {
                onError("knowledge pool skipped reads of \(g.path): file path is not absolute"); continue
            }
            if g.entries.isEmpty { groups.append((g.session, g.path, nil, nil)); continue }
            do { groups.append((g.session, g.path, g.entries.first?.project, try encoder.encode(g.entries))) } catch {
                onError("knowledge pool could not encode reads of \(g.path): \(error)")
            }
        }
        guard !inserts.isEmpty || !edits.isEmpty || !deletes.isEmpty || !groups.isEmpty else { return }
        let insertBatch = inserts, editBatch = edits, readBatch = groups
        queue.async { [self] in
            var failed: Set<UUID> = []
            func attempt(_ what: String, _ body: () throws -> Void) {
                do { try body() } catch { onError("knowledge pool \(what) failed: \(error)") }
            }
            do { try run("BEGIN IMMEDIATE") } catch {
                onError("knowledge pool apply failed: \(error)")
                noteFailed(inserts: Set(insertBatch.map(\.0.id)), deletes: Set(deletes))
                return
            }
            for (n, key, data) in insertBatch {
                do {
                    try run("INSERT INTO notes(id, key, project, body) VALUES(?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET key = excluded.key, project = excluded.project, body = excluded.body") {
                        bind($0, 1, n.id.uuidString); bind($0, 2, key); bind($0, 3, n.project); bind($0, 4, data: data)
                    }
                } catch { failed.insert(n.id); onError("knowledge pool upsert failed: \(error)") }
            }
            for (n, key, data) in editBatch {
                attempt("update") {
                    try run("UPDATE notes SET key = ?, project = ?, body = ? WHERE id = ?") {
                        bind($0, 1, key); bind($0, 2, n.project); bind($0, 3, data: data); bind($0, 4, n.id.uuidString)
                    }
                }
            }
            for id in deletes { attempt("delete") { try run("DELETE FROM notes WHERE id = ?") { bind($0, 1, id.uuidString) } } }
            for (session, path, project, data) in readBatch {
                attempt("replaceReads") {
                    if let data {
                        try run("INSERT OR REPLACE INTO reads(session, path, project, body) VALUES(?, ?, ?, ?)") {
                            bind($0, 1, session.uuidString); bind($0, 2, path); bind($0, 3, project); bind($0, 4, data: data)
                        }
                    } else {
                        try run("DELETE FROM reads WHERE session = ? AND path = ?") {
                            bind($0, 1, session.uuidString); bind($0, 2, path)
                        }
                    }
                }
            }
            do { try run("COMMIT") } catch {
                try? run("ROLLBACK")
                onError("knowledge pool apply failed: \(error)")
                failed = Set(insertBatch.map(\.0.id))
                noteFailed(inserts: failed, deletes: Set(deletes))
                return
            }
            noteFailed(inserts: failed, deletes: [])
        }
    }

    private func noteFailed(inserts: Set<UUID>, deletes: Set<UUID>) {
        guard !inserts.isEmpty || !deletes.isEmpty else { return }
        failureLock.withLock { failedInserts.formUnion(inserts); failedDeletes.formUnion(deletes) }
    }
}

/// One session's reads of one file, to be written as a group; empty `entries` deletes the group.
public struct ReadGroupWrite: Sendable {
    public var session: UUID
    public var path: String
    public var entries: [ReadEntry]
    public init(session: UUID, path: String, entries: [ReadEntry]) {
        self.session = session; self.path = path; self.entries = entries
    }
}
