import AlloyCore
import Foundation
import Testing

/// Opt-in check of the whole shared-knowledge feature against the real CLI. Skipped unless `ALLOY_LIVE=1`, so the
/// normal `swift test` never touches the network or the real CLI. Costs a few cents on the cheapest model.
/// Model tool choice is guidance, not enforcement: a missed tool call is recorded, not faked. Results go to
/// `$ALLOY_LIVE_LOG` (default: live-knowledge.log in the scratch directory).
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
    var all: [Recorder] { lock.withLock { list } }
    func make() -> Recorder { let r = Recorder(); lock.withLock { list.append(r) }; return r }
}

private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-plan5-live").path
private let notesPrefix = "mcp__alloy__notes_"

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ALLOY_LIVE"] == "1"))
struct LiveKnowledgeTests {
    private static func log(_ s: String) {
        let path = ProcessInfo.processInfo.environment["ALLOY_LIVE_LOG"] ?? "\(scratch)/live-knowledge.log"
        let line = Data((s + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: line) }
        print("LIVE: \(s)")
    }

    @MainActor private static func tools(_ s: Session, _ prefix: String = "") -> [ToolBlock] {
        s.transcript.blocks.compactMap { if case .tool(let t) = $0, t.name.hasPrefix(prefix) { return t } else { return nil } }
    }

    @MainActor private static func lastAssistantText(_ s: Session) -> String {
        for b in s.transcript.blocks.reversed() { if case .assistantText(_, let t) = b { return t } }
        return ""
    }

    /// Sends one message and waits for the turn to end, answering any non-notes permission prompt with allow.
    @MainActor private static func turn(_ ws: Workspace, _ s: Session, _ text: String, _ rec: Recorder,
                                        seconds: Double = 240) async -> Bool {
        let before = rec.results
        await ws.send(text, to: s.id)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if rec.results > before, s.status == .idle { await ws.settle(); return true }
            if s.status == .awaitingPermission {
                for b in s.transcript.blocks {
                    if case .permission(let p) = b, p.state == .pending, !p.toolName.hasPrefix(notesPrefix) {
                        await ws.answerPermission(session: s.id, requestID: p.requestID, allow: true)
                    }
                }
            }
            if case .exited = s.status { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    @Test @MainActor func sharedKnowledgeAgainstTheRealCLI() async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: scratch).appendingPathComponent("repo-\(UUID().uuidString.prefix(8))")
        let support = URL(fileURLWithPath: scratch).appendingPathComponent("support-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo); try? fm.removeItem(at: support) }
        try """
        def greet(name):
            return "hello, " + name

        def main():
            print(greet("world"))

        main()
        """.write(to: repo.appendingPathComponent("hello.py"), atomically: true, encoding: .utf8)
        try "def add(a, b):\n    return a + b\n".write(to: repo.appendingPathComponent("util.py"), atomically: true, encoding: .utf8)
        for args in [["init", "-q"], ["add", "."], ["-c", "user.email=a@b.c", "-c", "user.name=t", "commit", "-qm", "init"]] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
            p.currentDirectoryURL = repo; try p.run(); p.waitUntilExit()
        }

        let recorders = Recorders()
        let ws = Workspace(projectRoot: repo, appSupport: support, settings: AlloySettings(),
                           makeTransport: { cfg in
                               RecordingTransport(inner: ClaudeProcess(configuration: cfg), recorder: recorders.make())
                           })
        Self.log("=== run \(Date()) repo=\(repo.path)")
        var summary: [String] = []
        func verdict(_ name: String, _ ok: Bool?, _ detail: String) {
            let v = ok == nil ? "NOT OBSERVED" : (ok! ? "PASS" : "FAIL")
            summary.append("\(v): \(name) -- \(detail)")
            Self.log("\(v): \(name) -- \(detail)")
        }

        // Session A: read hello.py, write a note.
        let a = await ws.newSession(name: "A")
        await ws.send("/model haiku", to: a.id)
        let recA = recorders.all[0]
        let hello = "hello.py"
        var okTurn = await Self.turn(ws, a, "Read \(hello), then call mcp__alloy__notes_write with a one-sentence summary of it. Reply done.", recA)
        var noteWritten = Self.tools(a, notesPrefix).contains { $0.name == notesPrefix + "write" }
        if !noteWritten {
            okTurn = await Self.turn(ws, a, "You must call the tool mcp__alloy__notes_write now (subject hello.py, text: one sentence about what hello.py does). Do it.", recA)
            noteWritten = Self.tools(a, notesPrefix).contains { $0.name == notesPrefix + "write" }
            Self.log("A needed a firmer prompt for notes_write")
        }
        Self.log("A model=\(a.model ?? "?") turnOK=\(okTurn)")
        let readIndexed = ws.readIndex.entries(of: a.id).contains { $0.path == hello }
        verdict("A's Read is indexed", readIndexed, "entries=\(ws.readIndex.entries(of: a.id).map(\.path))")
        let aNotes = ws.notes.all.filter { $0.author == a.id }
        verdict("note exists, author is A", noteWritten ? !aNotes.isEmpty : nil,
                "noteToolCalled=\(noteWritten) notes=\(ws.notes.all.count) authorA=\(aNotes.count) subject=\(aNotes.first.map { "\($0.subject)" } ?? "-") text=\(aNotes.first?.text ?? "-")")

        // Session B: lookup then read, no permission prompt.
        let b = await ws.newSession(name: "B")
        await ws.send("/model haiku", to: b.id)
        let recB = recorders.all[1]
        _ = await Self.turn(ws, b, "Call mcp__alloy__notes_lookup for hello.py, then mcp__alloy__notes_read with path hello.py, startLine 1 and endLine 3, and reply with what you got.", recB)
        var bTools = Self.tools(b, notesPrefix)
        if !bTools.contains(where: { $0.name == notesPrefix + "lookup" }) || !bTools.contains(where: { $0.name == notesPrefix + "read" }) {
            Self.log("B needed a firmer prompt")
            _ = await Self.turn(ws, b, "You must call the tools mcp__alloy__notes_lookup (path hello.py) and then mcp__alloy__notes_read (path hello.py, startLine 1, endLine 3). Call both now.", recB)
            bTools = Self.tools(b, notesPrefix)
        }
        let bNames = Set(bTools.map(\.name))
        let bBothCalled = bNames.contains(notesPrefix + "lookup") && bNames.contains(notesPrefix + "read")
        // A call the server refuses for a wrong argument name is fine as long as the model's retry succeeds.
        let bOK = [notesPrefix + "lookup", notesPrefix + "read"].allSatisfy { name in bTools.contains { $0.name == name && $0.status == .succeeded } }
        let bPrompts = b.transcript.blocks.filter { if case .permission(let p) = $0 { return p.toolName.hasPrefix(notesPrefix) } else { return false } }.count
        let bTexts = bTools.map { "\($0.name.dropFirst(notesPrefix.count)):\($0.status):\($0.resultText.prefix(160))" }
        verdict("B's notes tools succeed", bBothCalled ? bOK : nil, "calls=\(bTexts)")
        verdict("no permission request for notes tools", bTools.isEmpty ? nil : bPrompts == 0, "permissionBlocks=\(bPrompts)")
        Self.log("B reply: \(Self.lastAssistantText(b))")

        // B's first message named hello.py after A had read it, so it carries the shared block on the wire; the block
        // is told once, so B's next message about the same file does not repeat it.
        let firstWire = recB.sent.first { $0.contains("\"type\":\"user\"") } ?? ""
        verdict("B's first message carries 'Shared by other sessions (via Alloy):'",
                firstWire.contains("Shared by other sessions (via Alloy):"), "wire=\(firstWire.prefix(400))")
        let before = recB.sent.count
        _ = await Self.turn(ws, b, "Briefly, what does hello.py print?", recB)
        let secondWire = recB.sent.dropFirst(before).first { $0.contains("\"type\":\"user\"") } ?? ""
        verdict("B's repeat message does not re-tell the same file", !secondWire.contains("Shared by other sessions"),
                "wire=\(secondWire.prefix(200))")

        // Fork of A.
        let fork = await ws.fork(a.id, name: "A fork")
        if let fork {
            let recF = recorders.all[2]
            _ = await Self.turn(ws, fork, "What file did you summarise? Answer with just the file name.", recF)
            let reply = Self.lastAssistantText(fork)
            verdict("fork of A names hello.py", reply.contains("hello.py"), "reply=\(reply.prefix(200)) sourceId=\(fork.cliSessionID != a.cliSessionID)")
        } else { verdict("fork of A names hello.py", false, "fork returned nil") }

        // Redundancy and compaction, on a file with no note and no fork copy (util.py), so only A's own generation
        // can decide. hello.py is excluded on purpose: it has a current note and the fork holds a copy.
        let util = "util.py"
        let readPrompt = "Use the Read tool on \(util) and reply with the word ok. Do not write any notes."
        let firm = "You must call the Read tool with file_path \(util) right now, even if you remember the file. Do not write any notes."
        func utilReads() -> Int { Self.tools(a).filter { $0.kind == .read && $0.input["file_path"]?.stringValue?.hasSuffix(util) == true }.count }
        func readUtil() async {
            let n = utilReads()
            _ = await Self.turn(ws, a, readPrompt, recA)
            if utilReads() == n { Self.log("A needed a firmer prompt for \(util)"); _ = await Self.turn(ws, a, firm, recA) }
        }
        await readUtil()
        let r0 = a.redundantReads
        await readUtil()
        let r1 = a.redundantReads
        Self.log("redundantReads first util read -> repeat (no compact): \(r0) -> \(r1)")
        let compactOK = await Self.turn(ws, a, "/compact", recA, seconds: 240)
        let compacted = a.transcript.blocks.contains { if case .notice(_, .compacted, _) = $0 { return true } else { return false } }
        for e in recA.events { let d = "\(e)"; if d.contains("compactBoundary") { Self.log("A event: \(d.prefix(200))") } }
        let readsBefore = utilReads()
        await readUtil()
        let readsAfter = utilReads()
        let r2 = a.redundantReads
        // A current note on the file also makes a read redundant (by design), which would hide the generation check.
        let utilNoted = ws.notes.all.contains { $0.subject == .file(util) }
        verdict("after /compact a re-read is not redundant", (compacted && readsAfter > readsBefore && !utilNoted) ? r2 == r1 : nil,
                "compactTurnEnded=\(compactOK) compactedNotice=\(compacted) utilNoted=\(utilNoted) util reads \(readsBefore)->\(readsAfter) redundant \(r1)->\(r2)")
        verdict("baseline: repeat read before compact counts redundant", (r1 > r0) ? true : nil, "redundant \(r0)->\(r1)")

        // Dump evidence and cost.
        let cost = [a, b, fork].compactMap { $0 }.map { String(format: "%@=$%.4f tok=%d", $0.name, $0.costUSD, $0.totalTokens) }
        Self.log("COST: \(cost)")
        var dump = ""
        for (name, s) in [("A", a), ("B", b)] {
            for t in Self.tools(s, notesPrefix) {
                let obj: [String: Any] = ["session": name, "tool": t.name, "status": "\(t.status)",
                                          "input": String(decoding: (try? JSONEncoder().encode(t.input)) ?? Data(), as: UTF8.self),
                                          "result": String(t.resultText.prefix(400))]
                dump += String(decoding: (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data(), as: UTF8.self) + "\n"
            }
        }
        if let w = recB.sent.first(where: { $0.contains("Shared by other sessions") }) { dump += w }
        try? dump.write(toFile: "\(scratch)/live-excerpts.jsonl", atomically: true, encoding: .utf8)
        Self.log("SUMMARY\n" + summary.joined(separator: "\n"))

        await ws.stopAll()
        #expect(!summary.contains { $0.hasPrefix("FAIL") }, "see \(scratch)/live-knowledge.log")
    }
    /// Two windows on two repositories sharing one application-support folder: a note written for a file in `api` reaches
    /// a session in `app` that asks about that file. Pass: the `app` session called notes_lookup on `api`'s absolute path
    /// and the result carried the note, or its first message carried the shared block naming `api`.
    @Test @MainActor func crossProjectNoteReachesOtherWindow() async throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: scratch).appendingPathComponent("cross-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        let app = base.appendingPathComponent("app"), api = base.appendingPathComponent("api")
        let support = base.appendingPathComponent("support")
        for d in [app, api, support] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: base) }
        try "struct Routes {\n    static let users = \"/users\"\n    static let orders = \"/orders\"\n}\n"
            .write(to: api.appendingPathComponent("Routes.swift"), atomically: true, encoding: .utf8)
        try "print(\"app\")\n".write(to: app.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        for repo in [app, api] {
            for args in [["init", "-q"], ["add", "."], ["-c", "user.email=a@b.c", "-c", "user.name=t", "commit", "-qm", "init"]] {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = args
                p.currentDirectoryURL = repo; try p.run(); p.waitUntilExit()
            }
        }

        let recorders = Recorders()
        func window(_ root: URL) -> Workspace {
            Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                      makeTransport: { cfg in RecordingTransport(inner: ClaudeProcess(configuration: cfg), recorder: recorders.make()) })
        }
        // Both windows are open (and registered in the pool) before either session starts.
        let wsApi = window(api), wsApp = window(app)
        await wsApi.settle(); await wsApp.settle()
        Self.log("=== cross-project run \(Date()) app=\(app.path) api=\(api.path)")
        var summary: [String] = []
        func verdict(_ name: String, _ ok: Bool?, _ detail: String) {
            let v = ok == nil ? "NOT OBSERVED" : (ok! ? "PASS" : "FAIL")
            summary.append("\(v): \(name) -- \(detail)")
            Self.log("\(v): \(name) -- \(detail)")
        }

        // Session in api: read Routes.swift, write a note.
        let a = await wsApi.newSession(name: "Reader")
        await wsApi.send("/model haiku", to: a.id)
        let recA = recorders.all[0]
        _ = await Self.turn(wsApi, a, "Read Routes.swift, then call mcp__alloy__notes_write with a one-sentence summary of it. Reply done.", recA)
        var noteWritten = Self.tools(a, notesPrefix).contains { $0.name == notesPrefix + "write" }
        if !noteWritten {
            _ = await Self.turn(wsApi, a, "You must call the tool mcp__alloy__notes_write now (subject Routes.swift, text: one sentence about what Routes.swift does). Do it.", recA)
            noteWritten = Self.tools(a, notesPrefix).contains { $0.name == notesPrefix + "write" }
            Self.log("api session needed a firmer prompt for notes_write")
        }
        await wsApi.settle()
        let note = wsApi.notes.all.first { $0.author == a.id }
        verdict("api session wrote a note", noteWritten ? note != nil : nil, "text=\(note?.text ?? "-")")

        // Session in app asks about api's file.
        let b = await wsApp.newSession(name: "Asker")
        await wsApp.send("/model haiku", to: b.id)
        let recB = recorders.all[1]
        let routes = api.appendingPathComponent("Routes.swift").path
        _ = await Self.turn(wsApp, b, "What does ../api/Routes.swift do? Check the shared notes first.", recB)
        let lookups = Self.tools(b, notesPrefix).filter { $0.name == notesPrefix + "lookup" }
        let noteText = note?.text ?? "\u{0}"
        let lookupHit = lookups.contains { $0.resultText.contains(noteText) && ($0.input["path"]?.stringValue == routes) }
        let firstWire = recB.sent.first { $0.contains("\"type\":\"user\"") } ?? ""
        let told = firstWire.contains("Routes.swift") && firstWire.contains("(in api)")
        Self.log("app lookups=\(lookups.map { "\($0.input):\($0.status):\($0.resultText.prefix(200))" })")
        Self.log("app first wire=\(firstWire.prefix(600))")
        Self.log("app reply: \(Self.lastAssistantText(b))")
        verdict("app session reached api's note", noteWritten ? (lookupHit || told) : nil,
                "lookupHit=\(lookupHit) toldInFirstMessage=\(told) path=\(routes)")
        Self.log("COST: \([a, b].map { String(format: "%@=$%.4f", $0.name, $0.costUSD) })")
        await wsApi.stopAll(); await wsApp.stopAll()
        #expect(!summary.contains { $0.hasPrefix("FAIL") || $0.hasPrefix("NOT OBSERVED") }, "see \(scratch)/live-knowledge.log")
    }
}
