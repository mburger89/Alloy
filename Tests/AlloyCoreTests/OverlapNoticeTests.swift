import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyCore

private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

private final class Transports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScriptedTransport] = []
    var list: [ScriptedTransport] { lock.withLock { all } }
    var factory: TransportFactory {
        { [self] _ in
            let t = ScriptedTransport()
            lock.withLock { all.append(t) }
            return t
        }
    }
}

@MainActor @Suite final class OverlapNoticeTests {
    private var dirs: [URL] = []
    deinit { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }

    static let base = (1...30).map { "line\($0)\n" }.joined()

    private func tempDir() -> URL {
        // Deliberately not symlink-resolved: /var/... while the real path is /private/var/...
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-on-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        dirs.append(u)
        return u
    }

    fileprivate struct Rig {
        let ws: Workspace
        let a: Session
        let b: Session
        let root: URL
        let clock: TestClock
        let transports: Transports
        func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }
    }

    private func rig(file: String? = "f.txt", text: String = base, support: URL? = nil) async -> Rig {
        let root = tempDir()
        if let file { try? text.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }
        let clock = TestClock(), transports = Transports()
        let ws = Workspace(projectRoot: root, appSupport: support ?? tempDir(), settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: transports.factory,
                           now: { clock.date })
        let a = await ws.newSession(name: "Ada")
        let b = await ws.newSession(name: "Bea")
        return Rig(ws: ws, a: a, b: b, root: root, clock: clock, transports: transports)
    }

    /// The session's ledger edit: `text` becomes the file's text.
    private func applied(_ r: Rig, _ author: Author, _ text: String, file: String = "f.txt", baseline: String = base) async {
        await r.ws.appendToLedger(file, saved: nil, baseline: baseline, edits: [(author, text)])
    }

    private func replaced(_ lines: [Int: String], in text: String = base) -> String {
        var l = TextLines(text)
        for (n, s) in lines { l.lines[n - 1] = s }
        return l.text
    }

    private func edit(_ r: Rig, _ s: Session, id: String, old: String, new: String, file: String = "f.txt",
                      path: String? = nil, event: HookEvent = .preToolUse) -> HookReply {
        let input: JSONValue = .object(["file_path": .string(path ?? r.path(file)), "old_string": .string(old),
                                        "new_string": .string(new)])
        let req = HookRequest(event: event, toolName: "Edit", toolUseID: id, toolInput: input, cliSessionID: "cli")
        return r.ws.handleHook(req, caller: MCPCaller(sessionID: s.id))
    }

    private func notices(_ s: Session) -> [String] {
        s.transcript.blocks.compactMap { if case .notice(_, .warning, let t) = $0 { t } else { nil } }
    }

    // MARK: Format

    @Test func overlapProducesUserExampleMessage() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5", 6: "X6"]))
        r.clock.date.addTimeInterval(180)
        let reply = edit(r, r.a, id: "t1", old: "line7\n", new: "Y\n")
        #expect(reply.additionalContext == "\"Bea\" changed f.txt lines 5\u{2013}6 3 minutes ago:\n-line5\n-line6\n+X5\n+X6")
    }

    @Test func proposedChangeMessageNamesTheSessionAndLines() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n")
        let reply = edit(r, r.a, id: "ta", old: "line11\n", new: "AAA\n")
        #expect(reply.additionalContext == "\"Bea\" is about to change f.txt line 10:\n-line10\n+BBB")
    }

    @Test func savedUserEditIsReportedAsTheUsers() async {
        let r = await rig()
        await applied(r, .user, replaced([5: "typed"]))
        r.clock.date.addTimeInterval(120)
        let reply = edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n")
        #expect(reply.additionalContext?.hasPrefix("The user changed f.txt line 5 2 minutes ago") == true)
    }

    @Test func outsideEditsAreNotReported() async {
        let r = await rig()
        await applied(r, .outside, replaced([5: "disk"]))
        #expect(edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext == nil)
    }

    @Test func unsavedUserTypingCountsAsProposed() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // the ledger holds the file
        let doc = EditorDocument(path: "f.txt", buffer: CodeBuffer(utf8: Array(Self.base.utf8)), language: nil,
                                 state: .editable, diskStamp: FileStamp(modified: nil, size: Self.base.utf8.count))
        r.ws.documents["f.txt"] = doc
        let at = Self.base.range(of: "line8")!.upperBound.utf16Offset(in: Self.base)
        _ = doc.buffer.replace(at..<at, with: " typed")
        let reply = edit(r, r.a, id: "t1", old: "line9\n", new: "Y\n")
        #expect(reply.additionalContext == "The user is editing f.txt line 8 (unsaved).")
        // The same typing is not told twice.
        #expect(edit(r, r.a, id: "t2", old: "line9\n", new: "Z\n").additionalContext == nil)
    }

    @Test func lostEditLogSaysUnsavedChanges() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)
        let doc = EditorDocument(path: "f.txt", buffer: CodeBuffer(utf8: Array(Self.base.utf8)), language: nil,
                                 state: .editable, diskStamp: FileStamp(modified: nil, size: Self.base.utf8.count))
        r.ws.documents["f.txt"] = doc
        let at = Self.base.range(of: "line8")!.upperBound.utf16Offset(in: Self.base)
        _ = doc.buffer.replace(at..<at, with: "!")
        doc.editLogLost = true
        let reply = edit(r, r.a, id: "t1", old: "line9\n", new: "Y\n")
        #expect(reply.additionalContext == "The user has unsaved changes in f.txt.")
    }

    // MARK: Told once

    @Test func toldOnceThenNotAgain() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        #expect(edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext != nil)
        #expect(edit(r, r.a, id: "t2", old: "line6\n", new: "Z\n").additionalContext == nil)
    }

    @Test func ownEditsAreNeverToldToTheirAuthor() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        #expect(edit(r, r.b, id: "t3", old: "line6\n", new: "Q\n").additionalContext == nil)
    }

    @Test func retoldAfterCompaction() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        #expect(edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext != nil)
        #expect(edit(r, r.a, id: "t2", old: "line6\n", new: "Y\n").additionalContext == nil)
        r.ws.compactionGeneration[r.a.id, default: 0] += 1
        #expect(edit(r, r.a, id: "t3", old: "line6\n", new: "Y\n").additionalContext != nil)
        #expect(edit(r, r.a, id: "t4", old: "line6\n", new: "Y\n").additionalContext == nil)
    }

    @Test func simultaneousProposalsTellBothOnce() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        #expect(edit(r, r.a, id: "ta", old: "line10\n", new: "AAA\n").additionalContext == nil)
        let toB = edit(r, r.b, id: "tb", old: "line11\n", new: "BBB\n").additionalContext
        #expect(toB?.contains("\"Ada\" is about to change f.txt line 10") == true)
        #expect(edit(r, r.b, id: "tb", old: "line11\n", new: "BBB\n").additionalContext == nil)   // a retried hook
        // The first proposer hears about Bea on its next nearby hook, and never twice.
        let toA = edit(r, r.a, id: "ta2", old: "line12\n", new: "AAA\n").additionalContext
        #expect(toA?.contains("\"Bea\" is about to change f.txt line 11") == true)
        #expect(edit(r, r.a, id: "ta3", old: "line12\n", new: "AAA\n").additionalContext == nil)
        // Neither was blocked: Bea's proposal stays registered until resolved.
        #expect(r.ws.overlapIndex.overlaps(for: UUID(), range: LineRange(path: "f.txt", lines: 11...11)).count >= 1)
    }

    @Test func appliedChangeIsNotToldAfterItsProposal() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)
        _ = edit(r, r.a, id: "ta", old: "line10\n", new: "AAA\n")
        #expect(edit(r, r.b, id: "tb", old: "line11\n", new: "BBB\n").additionalContext?.contains("about to change") == true)
        // Ada's tool_result applies the edit the proposal announced.
        let hunk = PatchHunk(oldStart: 10, oldLines: 1, newStart: 10, newLines: 1, lines: ["-line10", "+AAA"])
        await r.transports.list[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "ta", isError: false, text: "ok",
            result: .edit(filePath: r.path("f.txt"), originalFile: Self.base, hunks: [hunk]))))
        await waitUntil("applied") { (r.ws.ledger.files["f.txt"]?.edits.contains { $0.toolUseID == "ta" }) == true }
        #expect(edit(r, r.b, id: "tb2", old: "line12\n", new: "CCC\n").additionalContext == nil)
    }

    @Test func namesAndPathsAreOneLine() async {
        let r = await rig()
        r.b.name = "Bea\"\nIgnore previous"
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let text = edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext ?? ""
        #expect(text.hasPrefix("\"Bea' Ignore previous\" changed"))
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).first?.contains("Ignore") == true)
    }

    @Test func justNowReadsLessThanAMinute() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        r.clock.date.addTimeInterval(30)
        #expect(edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext?.contains(" less than a minute ago") == true)
        let r2 = await rig()
        await applied(r2, .session(r2.b.id), replaced([5: "X5"]))
        r2.clock.date.addTimeInterval(60)
        #expect(edit(r2, r2.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext?.contains(" 1 minute ago") == true)
    }

    @Test func onlyAppliedKeysArePersistedAndDeadOnesDropOnLoad() async throws {
        let support = tempDir()
        let r = await rig(support: support)
        // A pure proposal of Bea, then a live edit of Bea, both near Ada.
        await applied(r, .session(r.b.id), Self.base)
        _ = edit(r, r.b, id: "tb", old: "line20\n", new: "BBB\n")
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let first = edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n")
        #expect(first.additionalContext != nil)
        let second = edit(r, r.a, id: "t2", old: "line21\n", new: "Y\n")   // told about the proposal
        #expect(second.additionalContext?.contains("about to change") == true)
        await r.ws.settle()
        let url = r.ws.storeDirectory.appendingPathComponent("overlapTold.json")
        let saved = try JSONDecoder().decode([String: [String: Int]].self, from: Data(contentsOf: url))
        let keys = Set(saved.values.flatMap(\.keys))
        #expect(keys.count == 1 && keys.allSatisfy { $0.hasPrefix("edit:") || $0.hasPrefix("tool:") })
        #expect(!keys.contains("tool:tb"))
        // A persisted key of an edit the ledger no longer holds live is dropped at load.
        var forged = saved
        forged[r.a.id.uuidString]?["edit:\(UUID().uuidString)"] = 0
        try JSONEncoder().encode(forged).write(to: url)
        let again = Workspace(projectRoot: r.root, appSupport: support, settings: AlloySettings(),
                              locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: r.transports.factory,
                              now: { r.clock.date })
        await again.restore()
        #expect(again.overlapTold[r.a.id]?.count == 1)
    }

    @Test func forkCopiesOverlapToldAtItsGeneration() {
        let ws = Workspace(projectRoot: tempDir(), appSupport: tempDir(), settings: AlloySettings(),
                           locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: { _ in ScriptedTransport() })
        let src = UUID(), fork = UUID()
        ws.compactionGeneration[src] = 2
        ws.compactionGeneration[fork] = 5
        ws.overlapTold[src] = ["edit:a": 2, "edit:b": 1, "user:f:1-2": 2]
        ws.copyOverlapTold(from: src, to: fork)
        #expect(ws.overlapTold[fork] == ["edit:a": 5, "user:f:1-2": 5])
    }

    @Test func toldStorePersistsAndReloads() async throws {
        let support = tempDir()
        let r = await rig(support: support)
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        #expect(edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n").additionalContext != nil)
        await r.ws.settle()
        let url = r.ws.storeDirectory.appendingPathComponent("overlapTold.json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let again = Workspace(projectRoot: r.root, appSupport: support, settings: AlloySettings(),
                              locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: r.transports.factory,
                              now: { r.clock.date })
        await again.restore()
        #expect(again.overlapTold[r.a.id]?.count == 1)
    }

    // MARK: Cap

    @Test func messageIsCappedUnderFourThousand() async {
        let long = (1...60).map { "line \($0) " + String(repeating: "x", count: 100) + "\n" }.joined()
        let r = await rig(text: long)
        var texts: [(Author, String)] = []
        var cur = TextLines(long)
        for n in 1...60 { cur.lines[n - 1] = "changed \(n) " + String(repeating: "y", count: 100); texts.append((.session(r.b.id), cur.text)) }
        await r.ws.appendToLedger("f.txt", saved: nil, baseline: long, edits: texts)
        let reply = edit(r, r.a, id: "t1", old: cur.text, new: "gone\n")
        let text = reply.additionalContext ?? ""
        #expect(text.count <= Overlap.maxMessageCharacters && text.count > 3_000)
        #expect(text.range(of: "\u{2026}and ") != nil && text.hasSuffix(" more"))
        // What was cut off is still untold, and arrives with the next hook.
        let next = edit(r, r.a, id: "t2", old: cur.text, new: "again\n").additionalContext ?? ""
        #expect(next.contains("\"Bea\" changed"))
    }

    @Test func joinCapKeepsWholeMessagesAndCountsTheRest() {
        let big = (0..<5).map { "\"S\" changed f.txt lines \($0)\u{2013}\($0) 1 minute ago:\n" + String(repeating: "z", count: 1_500) }
        let out = OverlapNotice.join(big)
        #expect(out.text.count <= Overlap.maxMessageCharacters)
        #expect(out.included == 2)
        #expect(out.text.hasSuffix("\u{2026}and 3 more"))
        let huge = OverlapNotice.join([String(repeating: "q", count: 9_000)])
        #expect(huge.text.count <= Overlap.maxMessageCharacters && huge.included == 1)
    }

    // MARK: Empty, harmless

    @Test func noOverlapRepliesEmpty() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        #expect(edit(r, r.a, id: "t1", old: "line20\n", new: "Y\n").additionalContext == nil)
        // A file outside the project, a file Alloy does not hold, an unplaceable edit, an unknown session.
        #expect(edit(r, r.a, id: "t2", old: "x", new: "y", path: "/etc/hosts").additionalContext == nil)
        #expect(edit(r, r.a, id: "t3", old: "x", new: "y", file: "nowhere.txt").additionalContext == nil)
        #expect(edit(r, r.a, id: "t4", old: "nonexistent text", new: "y").additionalContext == nil)
        let stranger = HookRequest(event: .preToolUse, toolName: "Edit", toolUseID: "t5",
                                   toolInput: .object(["file_path": .string(r.path("f.txt")), "old_string": .string("line6\n"),
                                                       "new_string": .string("z")]), cliSessionID: "c")
        #expect(r.ws.handleHook(stranger, caller: MCPCaller(sessionID: UUID())).additionalContext == nil)
        // Nothing was registered for the file Alloy does not hold.
        #expect(r.ws.overlapIndex.overlaps(for: UUID(), range: LineRange(path: "nowhere.txt", lines: 1...100)).isEmpty)
    }

    @Test func otherToolsAreIgnored() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let req = HookRequest(event: .preToolUse, toolName: "Bash", toolUseID: "t1",
                              toolInput: .object(["command": .string("ls")]), cliSessionID: "c")
        #expect(r.ws.handleHook(req, caller: MCPCaller(sessionID: r.a.id)).additionalContext == nil)
    }

    @Test func hookPathsMapLexicallyThroughBothRootForms() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let real = r.root.resolvingSymlinksInPath().appendingPathComponent("sub/../f.txt").path
        #expect(edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n", path: real).additionalContext != nil)
        // ".." out of the root is outside.
        let escape = r.root.path + "/../f.txt"
        #expect(edit(r, r.a, id: "t2", old: "line6\n", new: "Y\n", path: escape).additionalContext == nil)
        #expect(r.ws.hookPathCache[real] == "f.txt")
    }

    @Test func hookReplyIsNeverABlock() async throws {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let pre = edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n")
        let body = try #require(JSONValue.parse(pre.json(for: .preToolUse)))
        #expect(body.objectKeys == ["hookSpecificOutput"])
        #expect(body["hookSpecificOutput"]?.objectKeys == ["additionalContext", "hookEventName"])
        let post = edit(r, r.a, id: "t1", old: "line6\n", new: "Y\n", event: .postToolUse)
        #expect(post == HookReply())
        #expect(post.json(for: .postToolUse) == HookReply.empty)
        let text = String(decoding: pre.json(for: .preToolUse), as: UTF8.self)
        for banned in ["permissionDecision", "\"decision\"", "updatedInput"] { #expect(!text.contains(banned)) }
    }

    @Test func proposalSurvivesPostToolUseUntilTheToolResult() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n")
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n", event: .postToolUse)
        // Between PostToolUse and the tool_result (which brings the ledger edit), Ada still hears about the change.
        let reply = edit(r, r.a, id: "ta", old: "line11\n", new: "AAA\n")
        #expect(reply.additionalContext == "\"Bea\" is about to change f.txt line 10:\n-line10\n+BBB")
        // The tool_result (or the session ending) is what ends it.
        r.ws.overlapIndex.resolve(toolUseID: "tb")
        #expect(edit(r, r.a, id: "ta2", old: "line12\n", new: "Z\n").additionalContext == nil)
    }

    @Test func cancelledHandlerRegistersNothing() async {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let req = HookRequest(event: .preToolUse, toolName: "Edit", toolUseID: "t1",
                              toolInput: .object(["file_path": .string(r.path("f.txt")), "old_string": .string("line6\n"),
                                                  "new_string": .string("z")]), cliSessionID: "c")
        let ws = r.ws, id = r.a.id
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return await ws.answerHook(req, MCPCaller(sessionID: id))
        }
        task.cancel()
        let reply = await task.value
        #expect(reply == HookReply())
        // Only Bea's applied edit; Ada's cancelled proposal was never registered.
        #expect(r.ws.overlapIndex.overlaps(for: UUID(), range: LineRange(path: "f.txt", lines: 6...6)).count == 1)
    }

    // MARK: Chat

    @Test func chatShowsTheWarningInline() async throws {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5", 20: "X20"]))
        let reply = edit(r, r.a, id: "t1", old: "line6\nline7\n", new: "Y\n")
        let text = try #require(reply.additionalContext)
        #expect(notices(r.a) == [text])
        // Told once: no second notice. The other session's chat carries a short one (Task 7), once.
        _ = edit(r, r.a, id: "t2", old: "line6\nline7\n", new: "Z\n")
        #expect(notices(r.a).count == 1)
        #expect(notices(r.b) == ["\"Ada\" is editing f.txt lines 6\u{2013}7 next to your change"])
    }

    @Test func oneNoticePerReplyNotPerOverlap() async throws {
        let r = await rig()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        await applied(r, .session(r.b.id), replaced([5: "X5", 12: "X12"]))
        let old = (5...12).map { n in n == 5 ? "X5\n" : n == 12 ? "X12\n" : "line\(n)\n" }.joined()
        let reply = edit(r, r.a, id: "t1", old: old, new: "Y\n")
        let text = try #require(reply.additionalContext)
        #expect(text.components(separatedBy: "\n\n").count == 2)
        #expect(notices(r.a) == [text])
    }

    // MARK: Lifecycle

    @Test func postToolUseLeavesTheProposalForTheToolResult() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n")
        #expect(r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).count == 1)
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n", event: .postToolUse)
        #expect(r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).count == 1)
        await r.transports.list[1].emit(.toolResult(ToolResultMessage(toolUseID: "tb", isError: true, text: "failed", result: .none)))
        await waitUntil("resolved") { r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty }
        #expect(r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
    }

    @Test func toolResultResolvesTheProposalIfPostHookWasLost() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n")
        await r.transports.list[1].emit(.toolResult(ToolResultMessage(toolUseID: "tb", isError: true, text: "failed",
                                                                result: .none)))
        await waitUntil("resolved") { r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty }
        #expect(r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
    }

    @Test func stopDropsTheSessionsProposals() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n")
        await r.ws.stop(r.b.id)
        #expect(r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty)
    }

    @Test func exitDropsTheSessionsProposals() async {
        let r = await rig()
        await applied(r, .session(r.b.id), Self.base)   // Alloy holds the file
        _ = edit(r, r.b, id: "tb", old: "line10\n", new: "BBB\n")
        await r.transports.list[1].exit(status: 0, stderr: "")
        await waitUntil("dropped") { r.ws.overlapIndex.overlaps(for: r.a.id, range: LineRange(path: "f.txt", lines: 10...10)).isEmpty }
    }

    // MARK: Server round trip and timing

    @Test func hookThroughTheServerCarriesTheContext() async throws {
        let r = await rig()
        await r.ws.restore()
        await applied(r, .session(r.b.id), replaced([5: "X5"]))
        let url = try #require(r.ws.serverURL)
        let token = try #require(r.ws.mcpTokens[r.a.id])
        let body: [String: Any] = ["session_id": "cli", "hook_event_name": "PreToolUse", "tool_name": "Edit",
                                   "tool_use_id": "t1",
                                   "tool_input": ["file_path": r.path("f.txt"), "old_string": "line6\n", "new_string": "Y\n"]]
        var req = URLRequest(url: Hooks.url(for: .preToolUse, serverURL: url))
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(JSONValue.parse(data))
        #expect(json["hookSpecificOutput"]?["additionalContext"]?.stringValue?.hasPrefix("\"Bea\" changed f.txt line 5") == true)
        await r.ws.stopAll()
    }

    @Test func hookRoundTripOnALargeFileIsUnderBudget() async {
        let big = (1...5_000).map { "let value\($0) = \($0)\n" }.joined()
        let r = await rig(text: big)
        var cur = TextLines(big)
        var edits: [(Author, String)] = []
        for i in 0..<200 {
            cur.lines[10 + i * 24] = "let edited\(i) = 0"
            edits.append((i % 2 == 0 ? .session(r.b.id) : .user, cur.text))
        }
        await r.ws.appendToLedger("f.txt", saved: nil, baseline: big, edits: edits)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for k in 0..<5 {
            r.ws.overlapIndex.invalidate(path: "f.txt")
            let old = "let value\(2_407 + k) = \(2_407 + k)\n"
            let d = clock.measure { _ = edit(r, r.a, id: "t\(k)", old: old, new: "let changed\(k)\n") }
            worst = max(worst, d)
        }
        #expect(worst < .milliseconds(50))
        let any = edit(r, r.a, id: "tx", old: "let edited50 = 0\n", new: "x\n")
        #expect(any.additionalContext != nil)
    }
}

extension JSONValue {
    fileprivate var objectKeys: [String]? {
        if case .object(let o) = self { o.keys.sorted() } else { nil }
    }
}
