import Foundation
import Testing
@testable import AlloyCore

/// Opt-in check of Plan 5b's coordination against the real CLI. Skipped unless `ALLOY_LIVE=1`, so the normal
/// `swift test` never touches the network or the real CLI. Costs a few cents on the cheapest model.
/// Model tool choice is guidance, not enforcement: a missed tool call is recorded as NOT OBSERVED, never faked.
/// Results go to `$ALLOY_LIVE_LOG` (default: live-coordination.log in the temporary directory).
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _events: [ProcessEvent] = []
    var sent: [String] { lock.withLock { _sent } }
    var events: [ProcessEvent] { lock.withLock { _events } }
    var results: Int { events.filter { if case .message(.result) = $0 { return true } else { return false } }.count }
    func record(sent line: String) { lock.withLock { _sent.append(line) } }
    func record(_ e: ProcessEvent) { lock.withLock { _events.append(e) } }
}

private struct RecordingTransport: SessionTransport {
    let inner: ClaudeProcess
    let recorder: Recorder
    func start() async throws -> AsyncStream<ProcessEvent> {
        let upstream = try await inner.start()
        let recorder = recorder
        return AsyncStream { c in
            let task = Task {
                for await e in upstream { recorder.record(e); c.yield(e) }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func send(_ message: OutboundMessage) async throws {
        recorder.record(sent: String(decoding: message.line(), as: UTF8.self))
        try await inner.send(message)
    }
    func terminate() async { await inner.terminate() }
    func stopAndWait(timeout: Duration) async { await inner.stopAndWait(timeout: timeout) }
}

private final class Recorders: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Recorder] = []
    private var _prompts: [String] = []
    var all: [Recorder] { lock.withLock { list } }
    func make() -> Recorder { let r = Recorder(); lock.withLock { list.append(r) }; return r }
    /// Alloy tools that raised a permission card.
    var alloyPrompts: [String] { lock.withLock { _prompts } }
    func notePrompt(_ s: String) { lock.withLock { _prompts.append(s) } }
}

private let alloyPrefix = "mcp__alloy__"

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ALLOY_LIVE"] == "1"))
struct LiveCoordinationTests {
    private static func log(_ s: String) {
        let path = ProcessInfo.processInfo.environment["ALLOY_LIVE_LOG"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("live-coordination.log").path
        let line = Data((s + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: line) }
        print("LIVE: \(s)")
    }

    @MainActor private static func tools(_ s: Session, _ prefix: String = "") -> [ToolBlock] {
        s.transcript.blocks.compactMap { if case .tool(let t) = $0, t.name.hasPrefix(prefix) { return t } else { return nil } }
    }

    @MainActor private static func messageRows(_ s: Session, _ d: SessionMessageDirection) -> [String] {
        s.transcript.blocks.compactMap { if case .sessionMessage(_, let dir, let peer, _, let text) = $0, dir == d { return "\(peer): \(text)" } else { return nil } }
    }

    @MainActor private static func lastAssistantText(_ s: Session) -> String {
        for b in s.transcript.blocks.reversed() { if case .assistantText(_, let t) = b { return t } }
        return ""
    }

    /// Sends one message and waits for the turn to end. Permission cards are answered with allow so the turn can go
    /// on, but a card for an Alloy tool is recorded: the tools are meant to run without one.
    @MainActor private static func turn(_ ws: Workspace, _ s: Session, _ text: String, _ rec: Recorder, _ rs: Recorders,
                                        seconds: Double = 240) async -> Bool {
        let before = rec.results
        await ws.send(text, to: s.id)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if rec.results > before, s.status == .idle { await ws.settle(); return true }
            if s.status == .awaitingPermission {
                for b in s.transcript.blocks {
                    if case .permission(let p) = b, p.state == .pending {
                        if p.toolName.hasPrefix(alloyPrefix) { rs.notePrompt("\(s.name):\(p.toolName)") }
                        await ws.answerPermission(session: s.id, requestID: p.requestID, allow: true)
                    }
                }
            }
            if case .exited = s.status { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Waits for a condition (rows arrive as a session's next input, which may start a turn of its own).
    @MainActor private static func wait(_ seconds: Double, _ ws: Workspace, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if cond() { return true }
            await ws.settle()
            try? await Task.sleep(for: .milliseconds(300))
        }
        return cond()
    }

    private static func transcriptText(cliSessionID: String?) -> String {
        guard let id = cliSessionID else { return "" }
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return "" }
        for d in dirs {
            let f = d.appendingPathComponent("\(id).jsonl")
            if let data = try? Data(contentsOf: f) { return String(decoding: data, as: UTF8.self) }
        }
        return ""
    }

    @Test @MainActor func coordinationAgainstTheRealCLI() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("alloy-live-coord-\(UUID().uuidString.prefix(8))")
        let repo = base.appendingPathComponent("repo"), support = base.appendingPathComponent("support")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let calc = repo.appendingPathComponent("calc.py")
        try """
        def total(items):
            result = 0
            for item in items:
                result += item
            return result

        def main():
            print(total([1, 2, 3]))

        main()
        """.write(to: calc, atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.email=a@b.c", "-c", "user.name=t", "commit", "-qm", "init"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            p.currentDirectoryURL = repo; try p.run(); p.waitUntilExit()
        }

        let recorders = Recorders()
        let ws = Workspace(projectRoot: repo, appSupport: support, settings: AlloySettings(),
                           makeTransport: { cfg in
                               RecordingTransport(inner: ClaudeProcess(configuration: cfg), recorder: recorders.make())
                           })
        Self.log("=== run \(Date()) base=\(base.path)")
        var summary: [String] = []
        func verdict(_ name: String, _ ok: Bool?, _ detail: String) {
            let v = ok == nil ? "NOT OBSERVED" : (ok! ? "PASS" : "FAIL")
            summary.append("\(v): \(name) -- \(detail)")
            Self.log("\(v): \(name) -- \(detail)")
        }
        func fileText() -> String { (try? String(contentsOf: calc, encoding: .utf8)) ?? "" }

        let a = await ws.newSession(name: "A")
        await ws.send("/model haiku", to: a.id)
        let b = await ws.newSession(name: "B")
        await ws.send("/model haiku", to: b.id)
        let recA = recorders.all[0], recB = recorders.all[1]

        func editCount(_ s: Session) -> Int { Self.tools(s, "Edit").filter { $0.status == .succeeded }.count }
        /// One scripted edit: Read, then Edit one exact line. Retried once with a firmer prompt when no Edit succeeded.
        func scriptedEdit(_ s: Session, _ rec: Recorder, from old: String, to new: String) async -> Bool {
            let n = editCount(s)
            _ = await Self.turn(ws, s, "Read calc.py, then use the Edit tool to replace the exact line `\(old)` with `\(new)`. Make only that one edit and reply done.", rec, recorders)
            if editCount(s) == n {
                Self.log("\(s.name) needed a firmer prompt for \(new)")
                _ = await Self.turn(ws, s, "You must call the Read tool on calc.py and then the Edit tool right now: old_string `\(old)`, new_string `\(new)`. Do not explain.", rec, recorders)
            }
            return editCount(s) > n
        }

        // (a) Hooks: B changes `result = 0`, then A edits the same line a moment later.
        let bEdited = await scriptedEdit(b, recB, from: "    result = 0", to: "    result = 100")
        let aEdited = await scriptedEdit(a, recA, from: "    result = 100", to: "    result = 5")
        let warned = await Self.wait(20, ws) { !ws.overlapWarnings.isEmpty }
        let warns = ws.overlapWarnings.map(\.warning)
        let tA = Self.transcriptText(cliSessionID: a.cliSessionID)
        // The user's own session-start hook also produces hook_additional_context; only Alloy's overlap text (it names the file and the other session's change) counts.
        let contextLines = tA.split(separator: "\n").filter { $0.contains("hook_additional_context") && $0.contains("changed calc.py") }
        let sawContext = !contextLines.isEmpty
        func hookAttachments(_ t: String) -> [String] {
            t.split(separator: "\n").filter { $0.contains("\"attachment\"") && $0.contains("hook") }.map { line in
                let kind = line.range(of: "\"type\":\"hook_[a-z_]+\"", options: .regularExpression).map { String(line[$0]) } ?? "?"
                return "\(kind) \(line.contains("changed calc.py") ? "[Alloy text]" : "")"
            }
        }
        let reply = Self.lastAssistantText(a)
        verdict("(a) PreToolUse hook reached Alloy as session A and produced an overlap warning",
                (bEdited && aEdited) ? warned && warns.contains { $0.sessions.first == a.id } : nil,
                "bEdited=\(bEdited) aEdited=\(aEdited) warnings=\(warns.map { "\($0.path):\($0.lines.map { "\($0)" } ?? "-") \($0.summary)" })")
        verdict("(a) A received additionalContext (hook_additional_context in the CLI transcript)",
                aEdited ? sawContext : nil,
                "transcriptFound=\(!tA.isEmpty) matches=\(contextLines.count) first=\(contextLines.first.map { String($0.prefix(700)) } ?? "-")")
        verdict("(a) the edit was not blocked and applied", aEdited ? fileText().contains("    result = 5") : nil,
                "file result line: \(fileText().split(separator: "\n").first { $0.contains("result =") } ?? "-") toolStatuses=\(Self.tools(a, "Edit").map { "\($0.status)" })")
        Self.log("A last reply: \(reply.prefix(300))")
        Self.log("ledger edits on calc.py: \((ws.ledger.files["calc.py"]?.edits ?? []).map { "\($0.author) \($0.state) tool=\($0.toolUseID ?? "-")" })")
        for s in [a, b] {
            let notices = s.transcript.blocks.compactMap { if case .notice(_, let k, let t) = $0 { return "\(k): \(t)" } else { return nil } }
            Self.log("\(s.name) notices: \(notices)")
        }
        Self.log("A hook attachments in the CLI transcript: \(hookAttachments(tA))")

        // (b) send_message: A to B, no permission card, B's chat shows a From row.
        func sendTool(_ s: Session) -> [ToolBlock] { Self.tools(s, alloyPrefix + "send_message") }
        _ = await Self.turn(ws, a, "Call mcp__alloy__send_message with to \"B\" and text \"Hello from A: please leave calc.py's total function alone.\" Then reply done.", recA, recorders)
        if sendTool(a).isEmpty {
            Self.log("A needed a firmer prompt for send_message")
            _ = await Self.turn(ws, a, "You must call the tool mcp__alloy__send_message right now with to \"B\" and text \"Hello from A: please leave calc.py's total function alone.\". Do it.", recA, recorders)
        }
        let sent = sendTool(a)
        let gotFrom = await Self.wait(90, ws) { !Self.messageRows(b, .from).isEmpty }
        verdict("(b) send_message ran for A and succeeded", sent.isEmpty ? nil : sent.contains { $0.status == .succeeded },
                "calls=\(sent.map { "\($0.status):\($0.resultText.prefix(120))" })")
        verdict("(b) no permission card for send_message", sent.isEmpty ? nil : !recorders.alloyPrompts.contains { $0.contains("send_message") },
                "alloyPrompts=\(recorders.alloyPrompts)")
        verdict("(b) B's chat shows a From row", sent.isEmpty ? nil : gotFrom, "rows=\(Self.messageRows(b, .from))")
        // Let B's reaction to the message finish before the next phase.
        _ = await Self.wait(60, ws) { b.status == .idle }

        // (c) Tug-of-war: A -> B -> A on `return result`; the third edit raises the alert and tells A to stop.
        let e1 = await scriptedEdit(a, recA, from: "    return result", to: "    return result + 1")
        let e2 = await scriptedEdit(b, recB, from: "    return result + 1", to: "    return result * 2")
        let e3 = await scriptedEdit(a, recA, from: "    return result * 2", to: "    return result - 1")
        let tugged = await Self.wait(30, ws) { !ws.tugAlerts.isEmpty }
        let gotStop = await Self.wait(90, ws) { Self.messageRows(a, .system).contains { $0.contains("going back and forth") } }
        let stopWire = recA.sent.first { $0.contains("Message from Alloy itself (via Alloy):") }
        verdict("(c) tug alert raised after A, B, A", (e1 && e2 && e3) ? tugged : nil,
                "edits=\(e1),\(e2),\(e3) alerts=\(ws.tugAlerts.map { "\($0.path) \($0.lines) escalated=\($0.escalated)" })")
        verdict("(c) A got 'Message from Alloy itself (via Alloy): ...' and a System row", (e1 && e2 && e3 && tugged) ? (gotStop && stopWire != nil) : nil,
                "rows=\(Self.messageRows(a, .system)) wire=\(stopWire.map { String($0.prefix(400)) } ?? "-")")

        // Evidence and cost.
        let cost = [a, b].map { String(format: "%@=$%.4f tok=%d", $0.name, $0.costUSD, $0.totalTokens) }
        Self.log("COST: \(cost)")
        var dump = ""
        for l in contextLines.prefix(2) { dump += "A transcript: \(l)\n" }
        for (n, s) in [("A", a), ("B", b)] {
            for t in Self.tools(s, alloyPrefix) {
                dump += "\(n) \(t.name) \(t.status) input=\(String(decoding: (try? JSONEncoder().encode(t.input)) ?? Data(), as: UTF8.self)) result=\(t.resultText.prefix(300))\n"
            }
            for r in Self.messageRows(s, .from) + Self.messageRows(s, .system) { dump += "\(n) row: \(r)\n" }
        }
        if let w = stopWire { dump += "A wire: \(w)\n" }
        let excerpts = ProcessInfo.processInfo.environment["ALLOY_LIVE_EXCERPTS"] ?? fm.temporaryDirectory.appendingPathComponent("live-coordination-excerpts.txt").path
        try? dump.write(toFile: excerpts, atomically: true, encoding: .utf8)
        Self.log("SUMMARY\n" + summary.joined(separator: "\n"))

        await ws.stopAll()
        #expect(!summary.contains { $0.hasPrefix("FAIL") }, "see the live-coordination log")
    }
}
