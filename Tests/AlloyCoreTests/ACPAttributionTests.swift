@testable import AlloyCore
import AlloyTestSupport
import Foundation
import MetalUICodeBuffer
import Testing

private final class Rig: @unchecked Sendable {
    private let lock = NSLock()
    private var _transports: [ScriptedTransport] = []
    private var _configs: [ACPLaunchConfiguration] = []
    var transports: [ScriptedTransport] { lock.withLock { _transports } }
    var configs: [ACPLaunchConfiguration] { lock.withLock { _configs } }
    var factory: ACPTransportFactory {
        { [self] c in let t = ScriptedTransport(); lock.withLock { _transports.append(t); _configs.append(c) }; return t }
    }
}

private let fakeAgent = AgentDefinition(id: "fake", name: "Fake", command: "/abs/fake-agent", args: ["acp"])

/// A workspace over a temp project with ACP sessions on scripted transports and a manual clock.
@MainActor
private final class AEnv {
    let root: URL
    let base: URL
    let rig = Rig()
    let clock = ManualClock()
    let changes = ScriptedChangeSource()
    let baseDate = Date()
    let ws: Workspace
    private var stamps = 0

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-acpf-\(UUID().uuidString)")
        let project = base.appendingPathComponent("p"), support = base.appendingPathComponent("s")
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        root = project.resolvingSymlinksInPath()
        let rig = rig, source = changes, c = clock, baseTime = baseDate
        ws = Workspace(projectRoot: root, appSupport: support, settings: AlloySettings(),
                       locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                       makeTransport: { _ in ScriptedTransport() }, makeACPTransport: rig.factory,
                       agentDefinitions: { [fakeAgent] },
                       agentDetector: AgentDetector(resolve: { _ in [:] }, isExecutable: { _ in true }, home: "/nohome",
                                                    helpRunner: { _ in nil }),
                       now: { baseTime.addingTimeInterval(c.now) },
                       home: base.appendingPathComponent("home"),
                       autosaveClock: clock, changes: { _ in source })
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }
    func write(_ name: String, _ text: String) {
        try? FileManager.default.createDirectory(at: url(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url(name), atomically: true, encoding: .utf8)
        // The file's date follows the workspace's manual clock, as the watcher's attribution reads it.
        stamps += 1
        let date = baseDate.addingTimeInterval(clock.now + Double(stamps) * 0.001)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(name).path)
    }
    func read(_ name: String) -> String? { try? String(contentsOf: url(name), encoding: .utf8) }

    /// Starts an ACP session and brings it to idle.
    func start(_ name: String) async -> (session: Session, transport: ScriptedTransport, files: any ACPFileHandling) {
        let s = await ws.newSession(name: name, backend: .acp(agentID: "fake"))
        let i = rig.transports.count - 1
        await rig.transports[i].emit(.systemInit(SystemInit(model: "", permissionMode: "", sessionID: "ses_\(i)", tools: [], slashCommands: [])))
        await waitUntil("idle") { s.status == .idle }
        return (s, rig.transports[i], rig.configs[i].fileService!)
    }

    func authors(_ name: String) -> [Author] { ws.ledger.files[name]?.edits.map(\.author) ?? [] }

    func pendingPermission(_ s: Session) -> PermissionBlock? {
        for case .permission(let p) in s.transcript.blocks where p.state == .pending { return p }
        return nil
    }
}

@MainActor @Suite struct ACPAttributionTests {
    @Test func readServesUnsavedBufferText() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\n")
        let a = await e.start("A")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<3, with: "ONE")
        #expect(doc.isDirty)
        let text = try await a.files.readTextFile(path: e.url("a.txt").path, line: nil, limit: nil)
        #expect(text == "ONE\ntwo\n")
        #expect(e.read("a.txt") == "one\ntwo\n")
        // Not open: the disk's text; a relative path counts from the project root.
        e.write("b.txt", "disk\n")
        #expect(try await a.files.readTextFile(path: "b.txt", line: nil, limit: nil) == "disk\n")
        await #expect(throws: (any Error).self) { _ = try await a.files.readTextFile(path: "missing.txt", line: nil, limit: nil) }
        await #expect(throws: (any Error).self) { _ = try await a.files.readTextFile(path: "/etc/hosts", line: nil, limit: nil) }
    }

    @Test func readFeedsReadIndexSoSecondReadIsRedundant() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\nthree\n")
        let a = await e.start("A"), b = await e.start("B")
        _ = try await a.files.readTextFile(path: "a.txt", line: nil, limit: nil)
        #expect(e.ws.readIndex.entries(of: a.session.id).count == 1)
        #expect(a.session.redundantReads == 0)
        _ = try await b.files.readTextFile(path: "a.txt", line: nil, limit: nil)
        #expect(b.session.redundantReads == 1)
        #expect(e.ws.redundantReads == 1)
    }

    @Test func readHonoursLineAndLimit() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write("a.txt", "a\nb\nc\nd\n")
        let a = await e.start("A")
        #expect(try await a.files.readTextFile(path: "a.txt", line: 2, limit: 2) == "b\nc\n")
        #expect(try await a.files.readTextFile(path: "a.txt", line: 3, limit: nil) == "c\nd\n")
        #expect(try await a.files.readTextFile(path: "a.txt", line: nil, limit: 1) == "a\n")
        #expect(try await a.files.readTextFile(path: "a.txt", line: 9, limit: 1) == "")
        let b = await e.start("B")
        _ = try await b.files.readTextFile(path: "a.txt", line: 2, limit: 2)
        #expect(e.ws.readIndex.entries(of: b.session.id).map(\.lines) == [2...3])
        #expect(Workspace.slice("x\ny", line: 2, limit: 5).0 == "y")
    }

    @Test func writeOutsideRootIsRefused() async throws {
        let e = AEnv(); defer { e.cleanup() }
        let a = await e.start("A")
        let outside = e.base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: e.url("link"), withDestinationURL: outside)
        for path in ["../x.txt", outside.path + "/y.txt", "link/z.txt", "/etc/alloy-test-never"] {
            await #expect(throws: (any Error).self) { try await a.files.writeTextFile(path: path, content: "bad") }
        }
        #expect(!FileManager.default.fileExists(atPath: e.base.appendingPathComponent("x.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("y.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("z.txt").path))
        #expect(e.ws.ledger.files.isEmpty)
    }

    @Test func writeCreatesMissingFileAndAttributesLines() async throws {
        let e = AEnv(); defer { e.cleanup() }
        let a = await e.start("A")
        try await a.files.writeTextFile(path: e.url("src/new/n.txt").path, content: "one\ntwo\n")
        #expect(e.read("src/new/n.txt") == "one\ntwo\n")
        #expect(e.authors("src/new/n.txt") == [.session(a.session.id)])
        // An edit of an existing file: only the changed line belongs to the session.
        e.write("m.txt", "keep\nold\nkeep2\n")
        try await a.files.writeTextFile(path: "m.txt", content: "keep\nnew\nkeep2\n")
        #expect(e.read("m.txt") == "keep\nnew\nkeep2\n")
        let file = try #require(e.ws.ledger.files["m.txt"])
        let owners = file.lineOwners().map { o in o.flatMap { id in file.edits.first { $0.id == id }?.author } }
        #expect(owners == [nil, .session(a.session.id), nil])
        #expect(!e.ws.changedFiles.isEmpty)
    }

    @Test func writeMergesIntoDirtyBuffer() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write("a.txt", "one\ntwo\nthree\n")
        let a = await e.start("A")
        await e.ws.open("a.txt")
        let doc = try #require(e.ws.document("a.txt"))
        _ = doc.buffer.replace(0..<3, with: "ONE")
        try await a.files.writeTextFile(path: "a.txt", content: "one\ntwo\nthree\nfour\n")
        await e.ws.settle()
        #expect(e.read("a.txt") == "ONE\ntwo\nthree\nfour\n")
        #expect(!doc.isDirty)
        // A clean open buffer simply follows the disk.
        try await a.files.writeTextFile(path: "a.txt", content: "ONE\ntwo\nthree\nfive\n")
        await e.ws.settle()
        let snap = doc.buffer.snapshot()
        #expect(String(decoding: snap.utf8(in: 0..<snap.utf8Count), as: UTF8.self) == "ONE\ntwo\nthree\nfive\n")
    }

    @Test func protectedPathsNeedApproval() async throws {
        let e = AEnv(); defer { e.cleanup() }
        let a = await e.start("A")
        let paths = [".git/config", ".env", ".env.local", "opencode.json", ".claude/x", ".codex/x", ".goose/x",
                     ".gemini/x", ".vscode/x", ".git/hooks/pre-commit", ".mcp.json"]
        for path in paths {
            let files = a.files
            let task = Task { @MainActor in try await files.writeTextFile(path: path, content: "data \(path)\n") }
            await waitUntil("approval card for \(path)") { e.pendingPermission(a.session) != nil }
            let card = try #require(e.pendingPermission(a.session))
            #expect(a.session.status == .awaitingPermission)
            #expect(card.summary.contains(path.split(separator: "/").first.map(String.init) ?? path))
            #expect(!FileManager.default.fileExists(atPath: e.url(path).path), "\(path) written before approval")
            await e.ws.answerPermission(session: a.session.id, requestID: card.requestID, allow: true)
            try await task.value
            #expect(e.read(path) == "data \(path)\n")
            #expect(a.session.status != .awaitingPermission)
        }
    }

    @Test func deniedProtectedWriteWritesNothing() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write(".env", "SECRET=1\n")
        let a = await e.start("A")
        let files = a.files
        let task = Task { @MainActor in try await files.writeTextFile(path: ".env", content: "SECRET=2\n") }
        await waitUntil("card") { e.pendingPermission(a.session) != nil }
        let card = try #require(e.pendingPermission(a.session))
        await e.ws.answerPermission(session: a.session.id, requestID: card.requestID, allow: false)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(e.read(".env") == "SECRET=1\n")
        #expect(e.ws.ledger.files[".env"] == nil)
        // Stop answers an open card as denied too.
        let second = Task { @MainActor in try await files.writeTextFile(path: ".env.local", content: "x") }
        await waitUntil("second card") { e.pendingPermission(a.session) != nil }
        await e.ws.interrupt(a.session.id)
        await #expect(throws: (any Error).self) { try await second.value }
        #expect(!FileManager.default.fileExists(atPath: e.url(".env.local").path))
        #expect(e.pendingPermission(a.session) == nil)
    }

    @Test func diffToolContentAttributesLinesWithoutFsCall() async throws {
        // Codex writes straight to disk and reports a diff in the tool call: no fs request is involved.
        let e = AEnv(); defer { e.cleanup() }
        e.write("c.txt", "one\ntwo\nthree\n")
        let a = await e.start("A")
        await a.transport.emit(.assistantBlock(messageID: "acp-tool-t1", block: .toolUse(
            id: "t1", name: "Edit c.txt", input: .object(["acpKind": .string("edit"), "path": .string(e.url("c.txt").path)]))))
        e.write("c.txt", "one\nTWO\nthree\n")
        await a.transport.emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "",
            result: .write(filePath: e.url("c.txt").path, isCreate: false, content: "one\nTWO\nthree\n",
                           originalFile: "one\ntwo\nthree\n", hunks: []))))
        await waitUntil("ledger") { e.ws.ledger.files["c.txt"] != nil }
        let file = try #require(e.ws.ledger.files["c.txt"])
        let owners = file.lineOwners().map { o in o.flatMap { id in file.edits.first { $0.id == id }?.author } }
        #expect(owners == [nil, .session(a.session.id), nil])
    }

    @Test func overlapWarningShownInBothSessionsAndInNextPromptContext() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write("o.txt", "one\ntwo\nthree\nfour\n")
        let a = await e.start("Ann"), b = await e.start("Bob")
        try await a.files.writeTextFile(path: "o.txt", content: "one\nTWO by ann\nthree\nfour\n")
        try await b.files.writeTextFile(path: "o.txt", content: "one\nTWO by bob\nthree\nfour\n")
        func notices(_ s: Session) -> [String] {
            s.transcript.blocks.compactMap { if case .notice(_, .warning, let t) = $0 { t } else { nil } }
        }
        #expect(notices(b.session).contains { $0.contains("Ann") && $0.contains("o.txt") })
        #expect(notices(a.session).contains { $0.contains("Bob") && $0.contains("o.txt") })
        // Bob's next prompt carries the warning to the agent.
        await e.ws.send("continue", to: b.session.id)
        let sent = await b.transport.sent
        let text = sent.compactMap { m -> String? in
            if case .user(let content, _, _) = m { return content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined(separator: "\n") }
            return nil
        }.joined(separator: "\n")
        #expect(text.contains("Ann") && text.contains("continue"))
        // Told once: the following prompt has nothing more.
        #expect(e.ws.takeACPOverlapContext(for: b.session.id) == nil)
    }

    @Test func executeToolOpensShellAttributionWindow() async throws {
        let e = AEnv(); defer { e.cleanup() }
        e.write("s.txt", "one\ntwo\n")
        await e.ws.open("s.txt")
        let doc = try #require(e.ws.document("s.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        try await e.ws.save("s.txt")
        await e.ws.close("s.txt")
        let a = await e.start("A")
        await a.transport.emit(.assistantBlock(messageID: "acp-tool-x1", block: .toolUse(
            id: "x1", name: "Run sed", input: .object(["acpKind": .string("execute"), "rawInput": .object(["command": .string("sed -i x s.txt")])]))))
        await waitUntil("window") { e.ws.shellWindowCount == 1 }
        e.write("s.txt", "xone\ntwo\nthree\n")
        e.ws.startWatching()
        e.changes.send([e.url("s.txt").path])
        await waitUntil("batch queued") { !e.ws.pendingOutside.isEmpty }
        e.clock.advance(by: 0.15)
        await e.ws.settle()
        #expect(e.authors("s.txt").contains(.session(a.session.id)))
        #expect(!e.authors("s.txt").contains(.outside))
    }
}
