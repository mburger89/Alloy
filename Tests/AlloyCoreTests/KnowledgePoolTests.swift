import Testing
import Foundation
import SQLite3
@testable import AlloyCore

@Suite struct KnowledgePoolTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kp-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("knowledge.sqlite")
    }
    private func pool(_ url: URL, _ onError: @escaping @Sendable (String) -> Void = { _ in }) throws -> KnowledgePool {
        try KnowledgePool(url: url, onError: onError)
    }
    private func note(_ subject: NoteSubject, _ text: String = "t") -> Note {
        Note(author: UUID(), subject: subject, text: text,
             stamp: { if case .file = subject { FileStamp(modified: Date(timeIntervalSince1970: 100), size: 5) } else { nil } }(),
             date: Date(timeIntervalSince1970: 200), authorName: "Ann", project: "/r")
    }
    private func entry(_ s: UUID, _ gen: Int) -> ReadEntry {
        ReadEntry(session: s, path: "/r/a.swift", lines: 1...3, stamp: FileStamp(modified: Date(timeIntervalSince1970: 1), size: 9),
                  date: Date(timeIntervalSince1970: 2), generation: gen)
    }

    @Test func notesRoundTrip() throws {
        let p = try pool(tempFile())
        let a = note(.file("/r/a.swift")), b = note(.topic("Auth"))
        p.upsert(notes: [a, b])
        #expect(Set(p.loadNotes().map(\.id)) == [a.id, b.id])
        #expect(p.loadNotes().contains(a) && p.loadNotes().contains(b))
        p.delete(noteIDs: [a.id])
        #expect(p.loadNotes() == [b])
    }

    @Test func pruneReadsDropsOnlyGroupsWhoseNewestEntryIsOld() throws {
        let p = try pool(tempFile())
        let s = UUID()
        var old = entry(s, 0), fresh = entry(s, 0)
        old.date = Date(timeIntervalSince1970: 100); fresh.date = Date(timeIntervalSince1970: 1000)
        p.replaceReads(session: s, path: "/r/old.swift", with: [old])
        p.replaceReads(session: s, path: "/r/new.swift", with: [old, fresh])
        p.pruneReads(olderThan: Date(timeIntervalSince1970: 500))
        #expect(p.loadReads() == [old, fresh])
    }

    @Test func updateNeverRecreatesADeletedNote() throws {
        let p = try pool(tempFile())
        var a = note(.file("/r/a.swift")), b = note(.topic("t"))
        p.upsert(notes: [a, b])
        p.delete(noteIDs: [a.id])
        a.text = "edited"; b.text = "edited"
        p.update(notes: [a, b])
        #expect(p.loadNotes() == [b])
    }

    @Test func readsReplaceGroup() throws {
        let p = try pool(tempFile())
        let s = UUID()
        let e1 = entry(s, 1), e2 = entry(s, 2), e3 = entry(s, 3)
        p.replaceReads(session: s, path: "/r/a.swift", with: [e1, e2])
        p.replaceReads(session: s, path: "/r/a.swift", with: [e3])
        #expect(p.loadReads() == [e3])
        p.replaceReads(session: s, path: "/r/a.swift", with: [])
        #expect(p.loadReads().isEmpty)
    }

    @Test func twoConnectionsLoseNothing() async throws {
        let url = tempFile()
        let a = try pool(url), b = try pool(url)
        await withTaskGroup(of: Void.self) { group in
            for p in [a, b] {
                group.addTask { for _ in 0..<200 { p.upsert(notes: [Note(author: UUID(), subject: .topic("t"), text: "x", stamp: nil, date: Date())]) } }
            }
        }
        a.flush(); b.flush()
        #expect(try pool(url).loadNotes().count == 400)
    }

    @Test func crossProcessWritersLoseNothing() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return }
        let url = tempFile()
        let a = try pool(url)
        let before = a.dataVersion()
        // 200 rows inserted by a separate OS process, one autocommit statement each.
        let encoder = JSONEncoder()
        var sql = "PRAGMA busy_timeout=10000;\n"
        for i in 0..<200 {
            let n = Note(author: UUID(), subject: .topic("outside \(i)"), text: "from sqlite3", stamp: nil, date: Date(timeIntervalSince1970: 300))
            let json = String(decoding: try encoder.encode(n), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
            sql += "INSERT INTO notes(id, key, project, body) VALUES('\(n.id.uuidString)', 'topic:outside \(i)', '/r', CAST('\(json)' AS BLOB));\n"
        }
        let script = url.deletingLastPathComponent().appendingPathComponent("insert.sql")
        try sql.write(to: script, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        proc.arguments = [url.path, ".read \(script.path)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        for i in 0..<200 {
            a.upsert(notes: [Note(author: UUID(), subject: .topic("inside \(i)"), text: "from pool", stamp: nil, date: Date())])
        }
        a.flush()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)
        #expect(try pool(url).loadNotes().count == 400)
        #expect(a.dataVersion() != before)
    }

    @Test func setSharedHidesAProjectFromTheRegistry() throws {
        let p = try pool(tempFile())
        let r = KnownProject(root: "/r", name: "r"), q = KnownProject(root: "/q", name: "q")
        p.register(r); p.register(q)
        #expect(p.knownProjects() == [r, q])
        p.setShared("/q", false)
        #expect(p.knownProjects() == [r])
        #expect(p.knownProjects(includeUnshared: true) == [r, q])
        p.setShared("/q", true)
        #expect(p.knownProjects() == [r, q])
    }

    @Test func versionOnePoolGainsTheSharedColumn() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        let old = """
            CREATE TABLE notes(id TEXT PRIMARY KEY, key TEXT NOT NULL, project TEXT, body BLOB NOT NULL);
            CREATE TABLE reads(session TEXT, path TEXT, project TEXT, body BLOB NOT NULL, PRIMARY KEY(session, path));
            CREATE TABLE projects(root TEXT PRIMARY KEY, name TEXT, imported INTEGER DEFAULT 0);
            INSERT INTO projects(root, name) VALUES('/old', 'old');
            PRAGMA user_version = 1;
            """
        #expect(sqlite3_exec(db, old, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let p = try pool(url)
        #expect(p.knownProjects() == [KnownProject(root: "/old", name: "old")])
        p.setShared("/old", false)
        #expect(p.knownProjects().isEmpty)
        _ = try pool(url)   // a second open of the migrated file is fine
    }

    @Test func aFailedInsertIsReportedForRetry() throws {
        let url = tempFile()
        let p = try pool(url)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TRIGGER blocked BEFORE INSERT ON notes BEGIN SELECT RAISE(ABORT, 'blocked'); END", nil, nil, nil) == SQLITE_OK)
        let a = note(.topic("a")), b = note(.topic("b"))
        p.apply(upserts: [a, b])
        p.flush()
        #expect(p.takeFailedInserts() == [a.id, b.id])
        #expect(p.takeFailedInserts().isEmpty)
        #expect(sqlite3_exec(db, "DROP TRIGGER blocked", nil, nil, nil) == SQLITE_OK)
        p.apply(upserts: [a])
        p.flush()
        #expect(p.loadNotes() == [a])
    }

    @Test func dataVersionMovesOnOtherWriter() throws {
        let url = tempFile()
        let a = try pool(url), b = try pool(url)
        let before = a.dataVersion()
        b.upsert(notes: [note(.topic("x"))]); b.flush()
        #expect(a.dataVersion() != before)
    }

    @Test func registryIsIdempotent() throws {
        let p = try pool(tempFile())
        let k = KnownProject(root: "/r", name: "r")
        p.register(k); p.register(k)
        #expect(p.knownProjects() == [k])
        p.markImported("/r")
        #expect(p.isImported("/r"))
        #expect(!p.isImported("/other"))
    }

    @Test func corruptFileIsMovedAside() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not a database".write(to: url, atomically: true, encoding: .utf8)
        let messages = Locked<[String]>([])
        let p = try pool(url) { m in messages.mutate { $0.append(m) } }
        #expect(messages.value.count == 1 && messages.value[0].contains("corrupt"))
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.contains { $0.hasPrefix("knowledge.sqlite.corrupt-") })
        #expect(p.loadNotes().isEmpty)
        p.upsert(notes: [note(.topic("x"))])
        #expect(p.loadNotes().count == 1)
    }

    @Test func parentPathIsAFileThrowsWithoutMovingAnything() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("blocker")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { _ = try KnowledgePool(url: blocker.appendingPathComponent("knowledge.sqlite"), onError: { _ in }) }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files == ["blocker"])
    }

    @Test func keyColumnAndRelativeRejection() throws {
        let url = tempFile()
        let errors = Locked<[String]>([])
        let p = try pool(url) { m in errors.mutate { $0.append(m) } }
        p.upsert(notes: [note(.file("/r/a.swift")), note(.topic("  Auth ")), note(.file("rel.swift"))])
        p.replaceReads(session: UUID(), path: "rel.swift", with: [entry(UUID(), 1)])
        p.flush()
        #expect(errors.value.count == 2)
        #expect(p.loadNotes().count == 2)
        #expect(p.loadReads().isEmpty)
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT key FROM notes ORDER BY key", -1, &stmt, nil)
        var keys: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { keys.append(String(cString: sqlite3_column_text(stmt, 0))) }
        sqlite3_finalize(stmt); sqlite3_close(db)
        #expect(keys == ["/r/a.swift", "topic:auth"])
    }

    @Test func markImportedDoesNotRegister() throws {
        let p = try pool(tempFile())
        p.markImported("/x")
        #expect(p.isImported("/x"))
        #expect(p.knownProjects().isEmpty)
        p.register(KnownProject(root: "/x", name: "x"))
        #expect(p.knownProjects().count == 1 && p.isImported("/x"))
    }

    @Test func fiveANotesDecode() throws {
        let n = note(.topic("x"))
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(n)) as! [String: Any]
        obj.removeValue(forKey: "authorName"); obj.removeValue(forKey: "project")
        let decoded = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(decoded.authorName == nil && decoded.project == nil)
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&v) }
}
