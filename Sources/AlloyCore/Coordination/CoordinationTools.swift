import Foundation

/// The four tools that let a session see, message and mark out its neighbours. They act only on Alloy's own state.
enum CoordinationTools {
    static let messageLimit = 2_000

    static func make(workspace: Workspace) -> [MCPTool] {
        let ref = WorkspaceRef(workspace)
        return [SessionsChangesTool(ref: ref), SendMessageTool(ref: ref), ClaimRegionTool(ref: ref), ReleaseRegionTool(ref: ref)]
    }

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    static func prop(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    static func fail(_ text: String) -> MCPToolResult { MCPToolResult(text: text, isError: true) }

    /// A whole-number argument: `.missing` when absent, `.bad` when present but not an integer.
    enum Integer { case value(Int), missing, bad }
    static func integer(_ arguments: JSONValue, _ key: String) -> Integer {
        guard let v = arguments[key], v != .null else { return .missing }
        guard case .number(let n) = v, n == n.rounded(), let i = v.intValue else { return .bad }
        return .value(i)
    }

    static func span(_ r: ClosedRange<Int>) -> String { OverlapNotice.span(r) }

    /// Lines joined by newlines within `limit` characters; what does not fit becomes "…and N more".
    static func capped(_ lines: [String], limit: Int = Overlap.maxMessageCharacters) -> String {
        func more(_ n: Int) -> String { "\n\u{2026}and \(n) more" }
        var text = "", included = 0
        for (i, line) in lines.enumerated() {
            let candidate = text.isEmpty ? line : text + "\n" + line
            let rest = lines.count - i - 1
            if candidate.count + (rest > 0 ? more(rest).count : 0) <= limit {
                text = candidate; included = i + 1
            } else if i == 0 {
                text = String(line.prefix(max(limit - more(rest).count - 1, 0))) + "\u{2026}"; included = 1
            } else { break }
        }
        if included < lines.count { text += more(lines.count - included) }
        return text
    }
}

struct SessionsChangesTool: MCPTool {
    let ref: WorkspaceRef
    let name = "sessions_changes"
    let readOnly = true
    let description = "See what the other sessions in this project are doing: for each, its status, the files and lines it "
        + "has changed (not yet kept or reverted), and the regions it has claimed. Check this before a large edit."
    let inputSchema = CoordinationTools.schema([:])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, let text = await ws.sessionsChangesText(for: caller.sessionID) else { return NotesTools.closing }
        return MCPToolResult(text: text)
    }
}

struct SendMessageTool: MCPTool {
    let ref: WorkspaceRef
    let name = "send_message"
    let description = "Send a short message to another session in this project, by its name (see sessions_changes). "
        + "It arrives as that session's next input. Messages are rate limited (5 per minute between two sessions, 10 per minute per sender)."
    let inputSchema = CoordinationTools.schema([
        "to": CoordinationTools.prop("string", "The other session's name."),
        "text": CoordinationTools.prop("string", "The message, at most \(CoordinationTools.messageLimit) characters."),
    ], required: ["to", "text"])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, await ws.notesRoot() != nil else { return NotesTools.closing }
        guard let to = arguments["to"]?.stringValue, let text = arguments["text"]?.stringValue else {
            return CoordinationTools.fail("to and text are required strings.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CoordinationTools.fail("text is required.")
        }
        guard text.count <= CoordinationTools.messageLimit else {
            return CoordinationTools.fail("The message is \(text.count) characters; the limit is \(CoordinationTools.messageLimit). Shorten it.")
        }
        return await ws.sendSessionMessage(from: caller.sessionID, to: to, text: text)
    }
}

struct ClaimRegionTool: MCPTool {
    let ref: WorkspaceRef
    let name = "claim_region"
    let description = "Tell the other sessions you are working on lines of a file. Advisory: it never blocks anyone, it shows in "
        + "their overlap messages, and it expires \(Int(Claims.expiry / 60)) minutes after your last edit of the file."
    let inputSchema = CoordinationTools.schema([
        "path": CoordinationTools.prop("string", "A file in the project, absolute or relative to the project root."),
        "startLine": CoordinationTools.prop("integer", "First line claimed (1-based)."),
        "endLine": CoordinationTools.prop("integer", "Last line claimed."),
        "note": CoordinationTools.prop("string", "What you are doing there, at most \(Claims.noteLimit) characters."),
    ], required: ["path", "startLine", "endLine"])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, let root = await ws.notesRoot() else { return NotesTools.closing }
        guard let path = arguments["path"]?.stringValue else { return CoordinationTools.fail("path is required.") }
        guard case .value(let start) = CoordinationTools.integer(arguments, "startLine"),
              case .value(let end) = CoordinationTools.integer(arguments, "endLine") else {
            return CoordinationTools.fail("startLine and endLine are required integers.")
        }
        guard start >= 1, end >= start, end <= Claims.maxLine else {
            return CoordinationTools.fail("Lines must satisfy 1 <= startLine <= endLine <= \(Claims.maxLine).")
        }
        var note = ""
        if let n = arguments["note"], n != .null {
            guard let s = n.stringValue else { return CoordinationTools.fail("note must be a string.") }
            guard s.count <= Claims.noteLimit else {
                return CoordinationTools.fail("The note is \(s.count) characters; the limit is \(Claims.noteLimit). Shorten it.")
            }
            note = s
        }
        guard let resolved = NotePath.resolve(path, root: root) else { return NotesTools.outside(path) }
        guard await ws.claim(session: caller.sessionID, path: resolved.relative, lines: start...end, note: note) else {
            return NotesTools.closing
        }
        return MCPToolResult(text: "Claimed \(resolved.relative) \(CoordinationTools.span(start...end)). "
            + "Other sessions see it until you release it or \(Int(Claims.expiry / 60)) minutes pass without an edit from you.")
    }
}

struct ReleaseRegionTool: MCPTool {
    let ref: WorkspaceRef
    let name = "release_region"
    let description = "Release your claim on a file, or only on the claims touching startLine to endLine."
    let inputSchema = CoordinationTools.schema([
        "path": CoordinationTools.prop("string", "A file in the project, absolute or relative to the project root."),
        "startLine": CoordinationTools.prop("integer", "First line to release (1-based)."),
        "endLine": CoordinationTools.prop("integer", "Last line to release."),
    ], required: ["path"])

    func call(_ arguments: JSONValue, caller: MCPCaller) async -> MCPToolResult {
        guard let ws = ref.workspace, let root = await ws.notesRoot() else { return NotesTools.closing }
        guard let path = arguments["path"]?.stringValue else { return CoordinationTools.fail("path is required.") }
        let start = CoordinationTools.integer(arguments, "startLine"), end = CoordinationTools.integer(arguments, "endLine")
        var lines: ClosedRange<Int>?
        switch (start, end) {
        case (.bad, _), (_, .bad): return CoordinationTools.fail("startLine and endLine must be integers.")
        case (.missing, .missing): break
        case (.value(let s), .missing): lines = s...max(s, s)
        case (.missing, .value(let e)): lines = 1...max(e, 1)
        case (.value(let s), .value(let e)): lines = s...max(s, e)
        }
        if let lines, lines.lowerBound < 1 { return CoordinationTools.fail("Lines start at 1.") }
        if case .value(let s) = start, case .value(let e) = end, e < s { return CoordinationTools.fail("endLine is before startLine.") }
        guard let resolved = NotePath.resolve(path, root: root) else { return NotesTools.outside(path) }
        guard let n = await ws.release(session: caller.sessionID, path: resolved.relative, lines: lines) else { return NotesTools.closing }
        return MCPToolResult(text: n == 0 ? "You had no claim on \(resolved.relative)\(lines.map { " " + CoordinationTools.span($0) } ?? "")."
                             : "Released \(n) claim\(n == 1 ? "" : "s") on \(resolved.relative).")
    }
}

extension Workspace {
    private func quoted(_ name: String) -> String { "\"\(AlreadyRead.oneLine(name))\"" }

    private func statusText(_ s: SessionStatus) -> String {
        switch s {
        case .dormant: "dormant"
        case .starting: "starting"
        case .idle: "idle"
        case .working: "working"
        case .awaitingPermission: "waiting for permission"
        case .exited: "exited"
        case .failedToLaunch: "failed to launch"
        }
    }

    /// One line per other session; nil once Alloy is closing.
    func sessionsChangesText(for caller: UUID) -> String? {
        guard !isShuttingDown else { return nil }
        let claimed = activeClaims()
        let others = sessions.filter { $0.id != caller }
        guard !others.isEmpty else { return "There are no other sessions in this project." }
        let paths = ledger.files.keys.sorted()
        let lines = others.map { s -> String in
            var parts: [String] = []
            var changed: [String] = []
            for path in paths {
                // A file this session has no live edit in needs no line runs (building them can be a whole-file pass).
                guard ledger.files[path]?.edits.contains(where: { $0.state == .live && $0.author == .session(s.id) }) == true else { continue }
                let runs = overlapIndex.liveRuns(path: path, session: s.id)
                if runs.isEmpty { continue }
                let shown = runs.prefix(5).map { CoordinationTools.span($0).replacingOccurrences(of: "lines ", with: "").replacingOccurrences(of: "line ", with: "") }
                changed.append("\"\(TugOfWar.clean(path))\" lines \(shown.joined(separator: ", "))" + (runs.count > 5 ? ", and more" : ""))
            }
            if changed.isEmpty { parts.append("no changes") } else { parts.append("changed " + changed.joined(separator: "; ")) }
            let mine = claimed.filter { $0.session == s.id }
            if !mine.isEmpty {
                parts.append("claimed " + mine.map { c in
                    "\"\(TugOfWar.clean(c.path))\" \(CoordinationTools.span(c.lines))" + (c.note.isEmpty ? "" : ": \"\(TugOfWar.clean(c.note))\"")
                }.joined(separator: "; "))
            }
            return "\(quoted(s.name)) (\(statusText(s.status))): " + parts.joined(separator: "; ")
        }
        return CoordinationTools.capped(lines)
    }

    /// Resolves the recipient by name and hands the message to `deliverSessionMessage`.
    func sendSessionMessage(from: UUID, to name: String, text: String) -> MCPToolResult {
        guard !isShuttingDown else { return NotesTools.closing }
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = sessions.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted }
        let valid = Array(NSOrderedSet(array: sessions.filter { $0.id != from }.map { quoted($0.name) })) as? [String] ?? []
        let list = valid.isEmpty ? "There are no other sessions." : "Valid names: " + valid.joined(separator: ", ") + "."
        if matches.count > 1 {
            return CoordinationTools.fail("More than one session is named \(quoted(name)), so it is ambiguous. \(list)")
        }
        guard let target = matches.first else { return CoordinationTools.fail("No session is named \(quoted(name)). \(list)") }
        if target.id == from { return CoordinationTools.fail("You cannot message yourself. \(list)") }
        switch deliverSessionMessage(from: from, to: target.id, text: text) {
        case .success: return MCPToolResult(text: "Message sent to \(quoted(target.name)).")
        case .failure(let e): return CoordinationTools.fail(e.text)
        }
    }

    func claim(session: UUID, path: String, lines: ClosedRange<Int>, note: String) -> Bool {
        guard !isShuttingDown else { return false }
        addClaim(session: session, path: path, lines: lines, note: note)
        return true
    }

    func release(session: UUID, path: String, lines: ClosedRange<Int>?) -> Int? {
        guard !isShuttingDown else { return nil }
        return releaseClaims(session: session, path: path, lines: lines)
    }
}
