import Foundation

/// What an agent's `fs/*` request can fail with; the text reaches the agent as the JSON-RPC error message.
enum ACPFileError: Error, LocalizedError {
    case unavailable
    case notFound(String)
    case notText(String)
    case tooLarge(String)
    case denied(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Alloy is not available."
        case .notFound(let p): "No such file: \(p)"
        case .notText(let p): "\(p) is not a UTF-8 text file."
        case .tooLarge(let p): "\(p) is too large to read as text."
        case .denied(let p): "The user did not allow writing \(p)."
        case .failed(let m): m
        }
    }
}

/// The `fs/read_text_file` and `fs/write_text_file` handler of one ACP session. It does the path checks off the main
/// actor and hands the rest (open buffers, ledger, overlap, approvals) to the workspace.
final class ACPSessionFiles: ACPFileHandling, @unchecked Sendable {
    private let ref: WorkspaceRef
    private let sessionID: UUID
    let policy: ACPPathPolicy

    init(workspace: Workspace, session: UUID, root: URL) {
        ref = WorkspaceRef(workspace); sessionID = session; policy = ACPPathPolicy(root: root)
    }

    func readTextFile(path: String, line: Int?, limit: Int?) async throws -> String {
        let url = try policy.resolve(path).get()
        guard let ws = ref.workspace else { throw ACPFileError.unavailable }
        return try await ws.acpRead(session: sessionID, url: url, line: line, limit: limit, policy: policy)
    }

    func writeTextFile(path: String, content: String) async throws {
        let url = try policy.resolve(path).get()
        guard let ws = ref.workspace else { throw ACPFileError.unavailable }
        let protected = policy.isProtected(url) || policy.isProtected(policy.lexicalURL(path))
        try await ws.acpWrite(session: sessionID, url: url, content: content, protected: protected, policy: policy)
    }
}

extension Workspace {
    /// Largest file served through `fs/read_text_file`.
    nonisolated static let acpReadLimit = 16 * 1024 * 1024

    // MARK: Read

    /// The text of `url`: the open buffer's (unsaved text included), else the disk's. `line` (1-based) and `limit`
    /// pick a slice. The read joins the read index, so another session's read of the same lines is known as shared.
    func acpRead(session id: UUID, url: URL, line: Int?, limit: Int?, policy: ACPPathPolicy) async throws -> String {
        guard let s = session(id), let rel = policy.relative(url) else { throw ACPFileError.unavailable }
        let full: String
        if let doc = documents[rel], doc.state == .editable {
            let snap = doc.buffer.snapshot()
            full = String(decoding: snap.utf8(in: 0..<snap.utf8Count), as: UTF8.self)
        } else {
            let read = await Task.detached { () -> Result<String, ACPFileError> in
                var st = stat()
                guard stat(url.path, &st) == 0 else { return .failure(.notFound(rel)) }
                guard Int(st.st_size) <= Workspace.acpReadLimit else { return .failure(.tooLarge(rel)) }
                guard let data = FileManager.default.contents(atPath: url.path),
                      let text = String(data: data, encoding: .utf8) else { return .failure(.notText(rel)) }
                return .success(text)
            }.value
            full = try read.get()
        }
        let (text, range) = Self.slice(full, line: line, limit: limit)
        await noteACPRead(rel, lines: range, by: s)
        return text
    }

    /// Lines `line...` (1-based), at most `limit` of them; the lines read, nil for the whole file.
    nonisolated static func slice(_ text: String, line: Int?, limit: Int?) -> (String, ClosedRange<Int>?) {
        guard line != nil || limit != nil else { return (text, nil) }
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        let total = lines.count
        let start = max(line ?? 1, 1)
        let count = max(limit ?? Int.max, 0)
        guard start <= total, count > 0 else { return ("", nil) }
        let end = count >= total - start + 1 ? total : start + count - 1
        let body = lines[(start - 1)..<end].joined(separator: "\n")
        let text = end == total && !endsWithNewline ? body : body + "\n"
        return (text, start == 1 && end == total ? nil : start...end)
    }

    private func noteACPRead(_ rel: String, lines: ClosedRange<Int>?, by s: Session) async {
        let root = projectRoot, scope = knowledgeScope
        let found = await Task.detached { Self.keyAndStamp(rel, root: root, scope: scope) }.value
        guard let (_, stamp, canonical) = found, !isShuttingDown else { return }
        refreshKnowledge()
        let generation = compactionGeneration[s.id, default: 0]
        let seen = readIndex.current(path: canonical, stamp: stamp).contains {
            ($0.session != s.id || $0.generation == generation) && ReadIndex.covers($0.lines, lines)
        }
        if seen || hasCurrentNote(canonical, stamp) {
            s.redundantReads += 1
            redundantReads += 1
        }
        recordRead(ReadEntry(session: s.id, path: canonical, lines: lines, stamp: stamp, date: now(), generation: generation,
                             authorName: s.name, project: knowledgeScope.ownRoot), resolved: true)
    }

    // MARK: Write

    /// Writes `content` to `url` for the session: after the user approves it when the path is protected, after the
    /// overlap check, then records the change in the ledger as the session's and merges it into an open buffer.
    func acpWrite(session id: UUID, url: URL, content: String, protected: Bool, policy: ACPPathPolicy) async throws {
        guard let s = session(id), let rel = policy.relative(url), !isShuttingDown else { throw ACPFileError.unavailable }
        // The file as it is now, for the ledger's baseline and the approval's diff.
        let before = await Task.detached { () -> (exists: Bool, text: String?) in
            guard FileManager.default.fileExists(atPath: url.path) else { return (false, nil) }
            return (true, FileManager.default.contents(atPath: url.path).flatMap { String(data: $0, encoding: .utf8) })
        }.value
        if protected {
            let allowed = await askACPProtectedWrite(session: s, path: rel, url: url, content: content)
            guard allowed else { throw ACPFileError.denied(rel) }
            guard !isShuttingDown, session(id) != nil else { throw ACPFileError.unavailable }
        }
        // The proposal goes in first so a session writing the same lines meanwhile hears of it.
        let toolID = "acp-fs-\(UUID().uuidString)"
        refreshClaims(session: s.id, path: rel)
        let change = (currentText(of: rel) ?? before.text).flatMap {
            ProposedChange.from(session: s.id, toolUseID: toolID, path: rel, toolName: "Write",
                                input: .object(["content": .string(content)]), currentText: $0, date: now())
        }
        if let advice = overlapAdvice(for: s, path: rel, change: change, toolUseID: toolID) {
            acpOverlapContext[s.id, default: []].append(advice)
        }
        defer { overlapIndex.resolve(toolUseID: toolID) }
        let failure = await Task.detached { () -> String? in
            do {
                let fm = FileManager.default
                let mode = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: .atomic)
                if let mode { try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
                return nil
            } catch { return error.localizedDescription }
        }.value
        if let failure { throw ACPFileError.failed("Could not write \(rel): \(failure)") }
        let fileCount = ledger.files.count
        let recs = ledger.record(.write(filePath: url.path, isCreate: !before.exists, content: content,
                                        originalFile: before.text, hunks: []),
                                 author: .session(s.id), toolUseID: nil, date: now())
        if !recs.isEmpty {
            let mine = recs.filter { $0.author == .session(s.id) }
            let path = recs[0].path
            reindex(path)
            noteFileChanged(path)
            syncOpenBuffer(path, by: s)
            if let newest = mine.last { followEdit(newest, by: s) }
            if !mine.isEmpty {
                let lines = diffLines(path: path)
                for rec in mine { editDiffs[rec.id] = DiffSlice.visible(lines, editIDs: [rec.id]) }
            }
        } else if documents[rel] != nil {
            syncOpenBuffer(rel, by: s)
        }
        if !recs.isEmpty || ledger.files.count != fileCount { persistLedger() }
        if !recs.isEmpty, !overlapTold.isEmpty { persistOverlapTold() }
    }

    /// The overlap warnings an agent's writes raised since its last prompt, as one block for that prompt; nil when none.
    func takeACPOverlapContext(for id: UUID) -> String? {
        guard let texts = acpOverlapContext.removeValue(forKey: id), !texts.isEmpty else { return nil }
        return "Alloy noticed while you were writing files:\n" + texts.joined(separator: "\n\n")
    }

    // MARK: Approval

    /// Shows a permission card for a write to a protected path and waits for the answer. False when denied, cancelled
    /// (Stop, the session ending) or Alloy quits.
    private func askACPProtectedWrite(session s: Session, path rel: String, url: URL, content: String) async -> Bool {
        acpFsCounter += 1
        let rid = "acp-fs-\(acpFsCounter)"
        let input: JSONValue = .object(["file_path": .string(url.path), "content": .string(content)])
        let request = ControlRequest(requestID: rid, kind: .canUseTool(
            toolName: "Write", input: input,
            description: "\(s.name) wants to write the protected file \(rel)", toolUseID: nil, suggestions: []))
        return await withCheckedContinuation { continuation in
            acpFsApprovals[rid] = (s.id, continuation)
            s.handle(.message(.controlRequest(request)))
        }
    }

    /// Denies the session's open protected-write approvals and closes their cards.
    func cancelACPFsApprovals(session id: UUID) {
        let mine = acpFsApprovals.filter { $0.value.session == id }
        guard !mine.isEmpty else { return }
        for (rid, waiting) in mine {
            acpFsApprovals.removeValue(forKey: rid)
            session(id)?.handle(.message(.controlCancel(requestID: rid)))
            waiting.continuation.resume(returning: false)
        }
    }
}
