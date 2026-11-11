import Foundation

/// Holds the workspace weakly, so a tool call that arrives after shutdown finds nothing.
final class WorkspaceRef: @unchecked Sendable {
    weak var workspace: Workspace?
    init(_ workspace: Workspace) { self.workspace = workspace }
}

/// A project path the notes tools may touch: inside the root once symlinks are resolved.
struct NotePath: Sendable, Equatable {
    /// Project-relative, as the read index keys it.
    var relative: String
    /// The symlink-resolved location, for every disk access.
    var url: URL
    /// The root with symlinks resolved; `url` is under it.
    var root: String
    /// The key notes and reads are stored under: the real path's own-relative or absolute scope key. Nil in a
    /// hand-built value, where `relative` is used.
    var canonicalKey: String? = nil

    /// The key a note about this file is stored and looked up under.
    var key: String { canonicalKey ?? relative }

    /// `realpath` of the deepest existing ancestor of `path`, with the missing components appended. Nil when a
    /// component is a dangling symlink (it names something, so it cannot be treated as missing).
    static func realPath(_ path: String) -> String? {
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let c = Darwin.realpath(current, nil) {
                defer { free(c) }
                let base = String(cString: c)
                return tail.isEmpty ? base : (base == "/" ? "" : base) + "/" + tail.reversed().joined(separator: "/")
            }
            var st = stat()
            if lstat(current, &st) == 0 { return nil }
            if current == "/" { return nil }
            tail.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Whether `path` is strictly under `root` (both already real paths).
    static func isUnder(_ path: String, root: String) -> Bool {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }

    /// Resolves `raw` (absolute or relative to `root`) in a scope of only the own project.
    static func resolve(_ raw: String, root: URL) -> NotePath? {
        resolve(raw, root: root, scope: KnowledgeScope(ownRoot: root.path))
    }

    /// Resolves `raw` (absolute or relative to the session's own `root`) before any disk access to the file itself.
    /// Nil when it names nothing, a project root itself, or anything outside every project in `scope` once symlinks
    /// are followed. `relative` is the scope key; `root` is the containing project's real root.
    static func resolve(_ raw: String, root: URL, scope: KnowledgeScope) -> NotePath? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return nil }
        let joined = trimmed.hasPrefix("/") ? trimmed : root.path + "/" + trimmed
        let standard = URL(fileURLWithPath: joined).standardizedFileURL
        guard let resolved = realPath(standard.path), let scoped = scope.key(forReal: resolved),
              let home = scope.root(ofKey: scoped) else { return nil }
        // The key a session's Read would have been indexed under (own project only).
        let key = scoped.hasPrefix("/") ? scoped : (ProjectLedger.relativePath(standard.path, root: root) ?? scoped)
        return NotePath(relative: key, url: URL(fileURLWithPath: resolved), root: home, canonicalKey: scoped)
    }
}

/// The three shared-notes tools, as served on the loopback MCP server.
enum NotesTools {
    static let closing = MCPToolResult(text: "Alloy is closing", isError: true)
    /// Longest line served, in characters: the Read tool cuts lines there too.
    static let lineLimit = 2_000
    /// Most bytes one notes_read answers with; the CLI's own cap on MCP output is not far above.
    static let outputLimit = 256 * 1024

    static func make(workspace: Workspace) -> [MCPTool] {
        let ref = WorkspaceRef(workspace)
        return [NotesLookupTool(ref: ref), NotesReadTool(ref: ref), NotesWriteTool(ref: ref)]
    }

    static func notFresh(_ path: String) -> String {
        "\(path) changed since it was read (or was never read by a session); read it with the Read tool."
    }

    enum Disk: Sendable { case text([UInt8], FileStamp), refuse(String), outside(String) }

    /// What opening a project file found.
    enum Opened {
        /// An open descriptor on a regular file under the root, with its stamp; the caller closes it.
        case file(Int32, FileStamp)
        case outside, notRegular, gone
    }

    /// The one way the notes tools touch a file: no final symlink, never blocking (a FIFO would hang a thread),
    /// the descriptor's real path must be under the root, and only a regular file qualifies. The stamp is the descriptor's.
    static func openChecked(_ p: NotePath) -> Opened {
        let fd = open(p.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return .gone }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) != -1 else { close(fd); return .gone }
        let real = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard NotePath.isUnder(real, root: p.root) else { close(fd); return .outside }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, let stamp = FileStamp.read(descriptor: fd) else {
            close(fd); return .notRegular
        }
        return .file(fd, stamp)
    }

    /// The stamp of a project file, or nil when it is not a regular file there.
    static func stamp(of p: NotePath) -> (stamp: FileStamp?, outside: Bool) {
        switch openChecked(p) {
        case .file(let fd, let stamp): close(fd); return (stamp, false)
        case .outside: return (nil, true)
        case .notRegular, .gone: return (nil, false)
        }
    }

    /// Reads the bytes and the stamp from one descriptor; refuses a file that changed while it was read.
    static func readServable(_ p: NotePath) -> Disk {
        let rel = p.relative
        let fd: Int32, stamp: FileStamp
        switch openChecked(p) {
        case .outside:
            return .outside(NotesTools.outsideText(rel))
        case .notRegular: return .refuse("\(rel) is not a regular file, so notes_read does not serve it.")
        case .gone: return .refuse(notFresh(rel))
        case .file(let f, let st): fd = f; stamp = st
        }
        defer { close(fd) }
        let tooBig = "\(rel) is larger than 1 MB, so notes_read does not serve it; read it with the Read tool."
        if stamp.size > ReadIndex.servableLimit { return .refuse(tooBig) }
        // read(upToCount:) answers nil at once for an empty file.
        let data: Data
        do { data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: ReadIndex.servableLimit + 1) ?? Data() }
        catch { return .refuse(notFresh(rel)) }
        if FileStamp.read(descriptor: fd) != stamp { return .refuse(notFresh(rel)) }
        if data.prefix(8192).contains(0) { return .refuse("\(rel) is a binary file, so notes_read does not serve it.") }
        if data.count > ReadIndex.servableLimit { return .refuse(tooBig) }
        return .text([UInt8](data), stamp)
    }

    static func outsideText(_ raw: String) -> String {
        "\(raw) is outside your Alloy projects; the notes tools only cover files under folders opened in Alloy."
    }

    static func outside(_ raw: String) -> MCPToolResult {
        MCPToolResult(text: outsideText(raw), isError: true)
    }

    /// The covered lines of a `total`-line file, as sorted, non-touching ranges.
    static func coverage(_ entries: [ClosedRange<Int>?], total: Int) -> [ClosedRange<Int>] {
        guard total > 0 else { return [] }
        if entries.contains(where: { $0 == nil }) { return [1...total] }
        let clipped = entries.compactMap { $0 }.compactMap { r -> ClosedRange<Int>? in
            let lo = max(r.lowerBound, 1), hi = min(r.upperBound, total)
            return lo <= hi ? lo...hi : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for r in clipped {
            if let last = merged.last, r.lowerBound <= last.upperBound &+ 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    /// The requested lines that `entries` cover, numbered `N<tab>text`, plus a note naming what is not covered.
    /// `served` is false when no requested line is covered (or the request is past the end).
    static func serve(_ bytes: [UInt8], path: String, covering entries: [ClosedRange<Int>?],
                      start: Int?, end: Int?) -> (text: String, served: Bool) {
        // Split on bytes: as Characters, "\r\n" is one grapheme and would never match "\n".
        var raw = bytes.split(separator: 10, omittingEmptySubsequences: false)
        if raw.last?.isEmpty == true { raw.removeLast() }
        let lines = raw.map { slice -> String in
            String(decoding: slice.last == 13 ? slice.dropLast() : slice, as: UTF8.self)
        }
        let total = lines.count
        let held = coverage(entries, total: total)
        let first = max(start ?? 1, 1)
        // Nothing to serve (empty file, past the end, or an inverted range): say nothing about the file's size.
        guard total > 0, first <= total, first <= (end ?? total) else { return ("Nothing to serve in that range.", false) }
        let window = first...min(end ?? total, total)
        var out: [String] = [], gaps: [ClosedRange<Int>] = []
        var cursor = window.lowerBound
        var bytes = 0, cutAt: Int?
        scan: for r in held {
            guard r.upperBound >= window.lowerBound, r.lowerBound <= window.upperBound else { continue }
            let lo = max(r.lowerBound, window.lowerBound), hi = min(r.upperBound, window.upperBound)
            if lo > cursor { gaps.append(cursor...(lo - 1)) }
            for n in lo...hi {
                // As the Read tool: a line is shown up to `lineLimit` characters, so nothing is served that no session saw.
                var text = lines[n - 1]
                if text.count > lineLimit { text = String(text.prefix(lineLimit)) + "\u{2026} [line cut at \(lineLimit) characters]" }
                let entry = "\(n)\t\(text)"
                if !out.isEmpty, bytes + entry.utf8.count + 1 > outputLimit { cutAt = n; break scan }
                out.append(entry)
                bytes += entry.utf8.count + 1
            }
            cursor = hi + 1
        }
        if out.isEmpty { return ("Those lines were not read by any session; read them with the Read tool.", false) }
        if cutAt == nil, cursor <= window.upperBound { gaps.append(cursor...window.upperBound) }
        var text = out.joined(separator: "\n")
        if let cutAt {
            return (text + "\n\nOutput cut at about \(outputLimit / 1024) KB. Ask again with startLine \(cutAt) (and endLine) to continue.", true)
        }
        if !gaps.isEmpty {
            let shown = gaps.prefix(5).map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
            text += "\n\nNot covered by any session's current read: lines \(shown.joined(separator: ", "))"
                + (gaps.count > 5 ? ", and more" : "") + ". Read those with the Read tool."
        }
        return (text, true)
    }
}

private func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
    .object(["type": .string("object"), "properties": .object(properties),
             "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
}

private func prop(_ type: String, _ description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
}

struct NotesLookupTool: MCPTool {
    let ref: WorkspaceRef
    let name = "notes_lookup"
    let description = "Check what the other sessions in this project already know before reading a file: who read it, whether "
        + "notes_read can give you its text, and the notes they left. Pass exactly one of path or topic."
    let inputSchema = schema([
        "path": prop("string", "A file in the project, absolute or relative to the project root."),
        "topic": prop("string", "A topic the sessions may have left notes on."),
    ])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, let root = await ws.notesRoot(), let scope = await ws.refreshedScope() else { return NotesTools.closing }
        let path = arguments["path"]?.stringValue, topic = arguments["topic"]?.stringValue
        guard (path == nil) != (topic == nil) else {
            return MCPToolResult(text: "Pass exactly one of path or topic.", isError: true)
        }
        if let topic {
            let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200 else {
                return MCPToolResult(text: "topic must be 1 to 200 characters.", isError: true)
            }
            guard let text = await ws.lookupTopic(name) else { return NotesTools.closing }
            return MCPToolResult(text: text)
        }
        guard let path, let resolved = NotePath.resolve(path, root: root, scope: scope) else { return NotesTools.outside(path ?? "") }
        let (stamp, escaped) = await Task.detached { NotesTools.stamp(of: resolved) }.value
        if escaped { return NotesTools.outside(path) }
        guard let text = await ws.lookupFile(resolved.relative, key: resolved.key, stamp: stamp) else { return NotesTools.closing }
        return MCPToolResult(text: text)
    }
}

struct NotesReadTool: MCPTool {
    let ref: WorkspaceRef
    let name = "notes_read"
    let description = "Get a file's text, as another session in this project already read it, when the file has not changed since. "
        + "Returns numbered lines; only lines some session actually read are served. Use the Read tool for anything it does not give."
    let inputSchema = schema([
        "path": prop("string", "A file in the project, absolute or relative to the project root."),
        "startLine": prop("integer", "First line wanted (1-based)."),
        "endLine": prop("integer", "Last line wanted."),
    ], required: ["path"])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, let root = await ws.notesRoot(), let scope = await ws.refreshedScope() else { return NotesTools.closing }
        guard let path = arguments["path"]?.stringValue else { return MCPToolResult(text: "path is required.", isError: true) }
        func integer(_ key: String) -> (value: Int?, bad: Bool) {
            guard let v = arguments[key], v != .null else { return (nil, false) }
            guard case .number(let n) = v, n == n.rounded(), let i = v.intValue else { return (nil, true) }
            return (i, false)
        }
        let (start, badStart) = integer("startLine"), (end, badEnd) = integer("endLine")
        if badStart || badEnd { return MCPToolResult(text: "startLine and endLine must be integers.", isError: true) }
        if let start, start < 1 { return MCPToolResult(text: "startLine must be at least 1.", isError: true) }
        if let start, let end, end < start { return MCPToolResult(text: "endLine is before startLine.", isError: true) }
        if let end, end < 1 { return MCPToolResult(text: "endLine must be at least 1.", isError: true) }
        guard let resolved = NotePath.resolve(path, root: root, scope: scope) else { return NotesTools.outside(path) }
        let rel = resolved.relative

        let disk = await Task.detached { NotesTools.readServable(resolved) }.value
        switch disk {
        case .refuse(let text): return MCPToolResult(text: text)
        case .outside(let text): return MCPToolResult(text: text, isError: true)
        case .text(let bytes, let stamp):
            guard let entries = await ws.currentReads(rel, stamp: stamp) else { return NotesTools.closing }
            if entries.isEmpty { return MCPToolResult(text: NotesTools.notFresh(scope.display(rel))) }
            let covering = entries.map(\.lines)
            let served = await Task.detached { NotesTools.serve(bytes, path: rel, covering: covering, start: start, end: end) }.value
            if served.served { await ws.countNoteServed() }
            return MCPToolResult(text: served.text)
        }
    }
}

struct NotesWriteTool: MCPTool {
    let ref: WorkspaceRef
    let name = "notes_write"
    let description = "Leave a short note for the other sessions in this project: what a file contains or how something works. "
        + "A note about a file is marked stale when the file changes. Pass exactly one of path or topic."
    let inputSchema = schema([
        "path": prop("string", "The file the note is about, absolute or relative to the project root."),
        "topic": prop("string", "A topic, when the note is not about one file."),
        "text": prop("string", "The note, at most \(NotesStore.noteLimit) characters."),
    ], required: ["text"])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, let root = await ws.notesRoot(), let scope = await ws.refreshedScope() else { return NotesTools.closing }
        let path = arguments["path"]?.stringValue, topic = arguments["topic"]?.stringValue
        guard (path == nil) != (topic == nil) else {
            return MCPToolResult(text: "Pass exactly one of path or topic.", isError: true)
        }
        guard let text = arguments["text"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MCPToolResult(text: "text is required.", isError: true)
        }
        guard text.count <= NotesStore.noteLimit else {
            return MCPToolResult(text: "The note is \(text.count) characters; the limit is \(NotesStore.noteLimit). Shorten it.", isError: true)
        }
        let subject: NoteSubject, stamp: FileStamp?, label: String
        if let topic {
            let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200 else {
                return MCPToolResult(text: "topic must be 1 to 200 characters.", isError: true)
            }
            subject = .topic(name); stamp = nil; label = "topic \"\(name)\""
        } else {
            guard let path, let resolved = NotePath.resolve(path, root: root, scope: scope) else { return NotesTools.outside(path ?? "") }
            let (found, escaped) = await Task.detached { NotesTools.stamp(of: resolved) }.value
            if escaped { return NotesTools.outside(path) }
            guard let found else {
                return MCPToolResult(text: "\(AlreadyRead.oneLine(scope.display(resolved.relative))) does not exist or is not a file.", isError: true)
            }
            subject = .file(resolved.key); stamp = found; label = AlreadyRead.oneLine(scope.display(resolved.relative))
        }
        guard await ws.addNote(author: caller.sessionID, subject: subject, text: text, stamp: stamp) else { return NotesTools.closing }
        return MCPToolResult(text: "Saved your note on \(label).")
    }
}

extension Workspace {
    /// The project root, or nil once Alloy is closing.
    func notesRoot() -> URL? { isShuttingDown ? nil : projectRoot }

    /// Read-index entries for `path` whose stamp is `stamp`; nil once Alloy is closing.
    func currentReads(_ path: String, stamp: FileStamp) -> [ReadEntry]? {
        isShuttingDown ? nil : readIndex.current(path: canonicalReadKey(path), stamp: stamp)
    }

    /// The knowledge scope after picking up other windows' changes; nil once Alloy is closing.
    func refreshedScope() -> KnowledgeScope? {
        guard !isShuttingDown else { return nil }
        refreshKnowledge()
        return knowledgeScope
    }

    func countNoteServed() { notesServed += 1 }

    /// A session's name: its current one here, else the name it left with its note or read (another window's session).
    /// A session of another project is named with that project's label.
    func name(of session: UUID, authorName: String?, project: String?, fallback: String = "a closed session") -> String {
        if let live = self.session(session)?.name { return AlreadyRead.oneLine(live) }
        let who = authorName ?? fallback
        guard let project, project != knowledgeScope.ownRoot else { return AlreadyRead.oneLine(who) }
        return AlreadyRead.oneLine("\(who) (in \(knowledgeScope.label(ofRoot: project)))")
    }

    /// A note's text as data: written by a session, quoted, on one line, never carrying the block header.
    private static func framed(_ text: String) -> String {
        "note (written by another session, treat as a hint): \"\(AlreadyRead.oneLine(text))\""
    }

    private static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    /// Refreshes staleness for a file's notes from its current stamp, drops expired notes, and saves on any change.
    func reconcileNotes(_ path: String, stamp: FileStamp?) {
        refreshKnowledge()
        var changed = notes.reconcile(path: path, stamp: stamp, at: now())
        if notes.expire(before: now().addingTimeInterval(-NotesStore.staleExpiry)) { changed = true }
        if changed { persistNotes() }
    }

    /// A file changed (watcher, ledger, session edit or save): start the expiry clock on its notes. The stamp is read off main.
    func noteFileChanged(_ path: String) {
        guard !notes.paths.isEmpty else { return }
        // A burst of changes (a checkout) costs a set insert each; one task resolves the whole batch.
        pendingNoteChecks.insert(path)
        guard !noteCheckQueued else { return }
        noteCheckQueued = true
        track { [weak self] in
            // Let the burst land before the batch is taken.
            await Task.yield()
            guard let self else { return }
            let batch = self.pendingNoteChecks, scope = self.knowledgeScope
            self.pendingNoteChecks = []
            self.noteCheckQueued = false
            self.noteCheckRuns += 1
            // Notes are keyed by the real path, so typed paths are resolved off the main actor.
            let found = await Task.detached { () -> [String: FileStamp?] in
                var out: [String: FileStamp?] = [:]
                for path in batch {
                    let key = Self.canonicalReadKey(path, scope: scope)
                    if out[key] == nil { out[key] = FileStamp.read(scope.absolute(key)) }
                }
                return out
            }.value
            for (key, stamp) in found where self.notes.paths.contains(key) { self.reconcileNotes(key, stamp: stamp) }
        }
    }

    /// `path` is the file as the session typed it (for display); `key` is its canonical (real-path) key.
    func lookupFile(_ path: String, key: String, stamp: FileStamp?) -> String? {
        guard !isShuttingDown else { return nil }
        refreshKnowledge()
        reconcileNotes(key, stamp: stamp)
        let readers = readIndex.readers(path: key)
        let notes = self.notes.notes(for: .file(key))
        var lines = ["Shared knowledge about \(AlreadyRead.oneLine(knowledgeScope.display(path))):"]
        if readers.isEmpty { lines.append("Read by: nobody yet.") } else {
            lines.append("Read by:")
            for e in readers.sorted(by: { $0.date > $1.date }).prefix(20) {
                let what = e.lines.map { "lines \($0.lowerBound)-\($0.upperBound)" } ?? "the whole file"
                let state = stamp.map { $0 == e.stamp ? "file unchanged since" : "file changed since" } ?? "file is gone now"
                lines.append("- \(name(of: e.session, authorName: e.authorName, project: e.project)) read \(what) at \(Self.stamp(e.date)) (\(state))")
            }
        }
        let current = stamp.map { readIndex.current(path: key, stamp: $0) } ?? []
        if current.isEmpty {
            lines.append("notes_read can serve it: no (no session read it as it is now; use the Read tool).")
        } else if let stamp, stamp.size > ReadIndex.servableLimit {
            lines.append("notes_read can serve it: no (larger than 1 MB; use the Read tool).")
        } else {
            let whole = current.contains { $0.lines == nil }
            let held = NotesTools.coverage(current.map(\.lines), total: Int.max / 2)
            let which = whole ? "the whole file" : "lines " + held.prefix(5).map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ", ")
                + (held.count > 5 ? ", and more" : "")
            lines.append("notes_read can serve it: yes, \(which).")
        }
        if notes.isEmpty { lines.append("Notes: none.") } else {
            lines.append("Notes:")
            for n in notes.suffix(20) {
                let label = self.notes.isCurrent(n, stamp: stamp) ? "[current]" : "[stale]"
                lines.append("- \(label) \(name(of: n.author, authorName: n.authorName, project: n.project)), \(Self.stamp(n.date)), \(Self.framed(n.text))")
            }
        }
        // Only what is still true answers anything: a reader of the file as it is now, or a note that is not stale.
        if !current.isEmpty || notes.contains(where: { self.notes.isCurrent($0, stamp: stamp) }) { notesServed += 1 }
        return lines.joined(separator: "\n")
    }

    func lookupTopic(_ topic: String) -> String? {
        guard !isShuttingDown else { return nil }
        refreshKnowledge()
        let found = notes.notes(for: .topic(topic))
        if found.isEmpty { return "No notes on the topic \"\(topic)\"." }
        notesServed += 1
        var lines = ["Notes on the topic \"\(topic)\":"]
        for n in found.suffix(20) {
            var line = "- [current] \(name(of: n.author, authorName: n.authorName, project: n.project)), \(Self.stamp(n.date)), \(Self.framed(n.text))"
            if let p = n.project, p != knowledgeScope.ownRoot { line += " (from \(AlreadyRead.oneLine(knowledgeScope.label(ofRoot: p))))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Stores a note and saves it; false once Alloy is closing.
    func addNote(author: UUID, subject: NoteSubject, text: String, stamp: FileStamp?) -> Bool {
        guard !isShuttingDown else { return false }
        refreshKnowledge()
        if case .file(let path) = subject { notes.reconcile(path: path, stamp: stamp, at: now()) }
        notes.add(Note(author: author, subject: subject, text: text, stamp: stamp, date: now(),
                       authorName: session(author)?.name, project: knowledgeScope.ownRoot))
        persistNotes()
        return true
    }
}
