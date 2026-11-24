@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyRPC
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite(.serialized) struct PluginProjectTests {
    private static let id = "dev.test.project"

    private func make(files: [String: String] = ["notes.txt": "one\n"]) async throws -> PluginRig {
        let rig = Rig()
        for (name, text) in files {
            let url = rig.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"])
        await rig.workspace.restoreUIState()
        return p
    }

    private func read(_ p: PluginRig, _ path: String) async -> Result<JSONValue, JSONRPCError> {
        await p.coordinator.answerRequest(from: Self.id, "project/read", .object(["path": .string(path)]))
    }

    private func write(_ p: PluginRig, _ path: String, _ text: String = "new\n") async -> Result<JSONValue, JSONRPCError> {
        await p.coordinator.answerRequest(from: Self.id, "project/write", .object(["path": .string(path), "text": .string(text)]))
    }

    private func reason(_ result: Result<JSONValue, JSONRPCError>) -> (code: Int, reason: String?)? {
        guard case .failure(let e) = result else { return nil }
        return (e.code, e.data?["reason"]?.stringValue)
    }

    private func disk(_ p: PluginRig, _ path: String) -> String? {
        try? String(contentsOf: p.rig.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Delivers the watcher's event for `path` and runs its coalescing window.
    private func fire(_ p: PluginRig, _ path: String) async {
        let ws = p.rig.workspace
        ws.startWatching()
        p.rig.changes.send([p.rig.root.appendingPathComponent(path).path])
        for _ in 0..<500_000 where ws.pendingOutside.isEmpty { await Task.yield() }
        // The coalescing task may not have reached its sleep yet (a clock advance before that wakes nothing and the task then
        // waits for ever), so the clock keeps moving until the window has run.
        for _ in 0..<5_000 where !ws.pendingOutside.isEmpty {
            p.rig.clock.advance(by: 0.15)
            await Task.yield()
        }
        await ws.settle()
    }

    @Test func readReturnsDiskText() async throws {
        let p = try await make(files: ["sub/a.txt": "héllo\n"])
        guard case .success(let value) = await read(p, "sub/a.txt") else { Issue.record("read failed"); return }
        #expect(value["text"]?.stringValue == "héllo\n")
    }

    @Test func readMissingIsMinus32012() async throws {
        let p = try await make()
        let r = reason(await read(p, "nope.txt"))
        #expect(r?.code == -32012)
        #expect(r?.reason == "missing")
    }

    @Test func readBinaryAndHugeAreRefused() async throws {
        let p = try await make()
        try Data([0xff, 0xfe, 0x00, 0xc3, 0x28]).write(to: p.rig.root.appendingPathComponent("b.bin"))
        let r = reason(await read(p, "b.bin"))
        #expect(r?.code == -32012)
        #expect(r?.reason == "binary")
        let big = p.rig.root.appendingPathComponent("big.txt")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(PluginCoordinator.maxReadBytes + 1))
        try handle.close()
        #expect(reason(await read(p, "big.txt"))?.reason == "tooLarge")
    }

    @Test func readAllowsClaudeAndGitButNotOutside() async throws {
        let p = try await make(files: [".claude/settings.json": "{}\n", ".git/HEAD": "ref\n"])
        #expect(reason(await read(p, ".claude/settings.json")) == nil)
        #expect(reason(await read(p, ".git/HEAD")) == nil)
        #expect(reason(await read(p, "../x"))?.reason == "outsideProject")
        #expect(reason(await read(p, "/etc/hosts"))?.reason == "outsideProject")
    }

    @Test func writeLandsAndReloadsCleanBuffer() async throws {
        let p = try await make()
        let ws = p.rig.workspace
        await ws.open("notes.txt")
        let doc = try #require(ws.document("notes.txt"))
        // A saved edit puts the file in the ledger, so the outside change is recorded there.
        _ = doc.buffer.replace(0..<0, with: "x")
        try await ws.save("notes.txt")
        #expect(!doc.isDirty)
        guard case .success = await write(p, "notes.txt", "two\n") else { Issue.record("write refused"); return }
        #expect(disk(p, "notes.txt") == "two\n")
        #expect(doc.buffer.snapshot().text == "xone\n", "the buffer is not touched by the write itself")
        await fire(p, "notes.txt")
        #expect(doc.buffer.snapshot().text == "two\n")
        #expect(!doc.isDirty)
        #expect(ws.ledger.files["notes.txt"]?.edits.map(\.author).contains(.outside) == true)
    }

    @Test func writeCreatesNewFilesInNewFolders() async throws {
        let p = try await make()
        guard case .success = await write(p, "gen/out.txt", "made\n") else { Issue.record("write refused"); return }
        #expect(disk(p, "gen/out.txt") == "made\n")
    }

    @Test func writeRefusedWhenDirty() async throws {
        let p = try await make()
        let ws = p.rig.workspace
        await ws.open("notes.txt")
        let doc = try #require(ws.document("notes.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        let r = reason(await write(p, "notes.txt"))
        #expect(r?.code == -32010)
        #expect(r?.reason == "dirty")
        #expect(disk(p, "notes.txt") == "one\n")
    }

    @Test func writeRefusedWhileClaudeProposes() async throws {
        let p = try await make()
        let ws = p.rig.workspace
        ws.overlapIndex.propose(ProposedChange(session: UUID(), toolUseID: "t1", range: LineRange(path: "notes.txt", lines: 1...1),
                                               date: Date(), diff: "-a\n+b"))
        let r = reason(await write(p, "notes.txt"))
        #expect(r?.code == -32010)
        #expect(r?.reason == "claudeEditing")
        #expect(disk(p, "notes.txt") == "one\n")
        ws.overlapIndex.resolve(toolUseID: "t1")
        #expect(reason(await write(p, "notes.txt")) == nil)
    }

    @Test func writeRefusedOutside() async throws {
        let p = try await make()
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try FileManager.default.createSymbolicLink(at: p.rig.root.appendingPathComponent("link"), withDestinationURL: elsewhere)
        for path in ["../x", "/etc/x", "a/../../x", "link/x.txt", "link"] {
            let r = reason(await write(p, path))
            #expect(r?.code == -32010, "\(path)")
            #expect(r?.reason == "outsideProject", "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("x.txt").path))
    }

    @Test func writeRefusedIntoClaudeAndGit() async throws {
        let p = try await make(files: ["real/.claude/keep": "k\n"])
        let root = p.rig.root
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sneaky"),
                                                   withDestinationURL: root.appendingPathComponent(".claude"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sneaky2"),
                                                   withDestinationURL: root.appendingPathComponent(".CLAUDE"))
        for path in [".claude/settings.json", "sub/.claude/x", ".git/hooks/pre-commit", "sneaky/settings.json", "./.git/config",
                     ".GIT/hooks/pre-commit", ".Claude/settings.json", "sneaky2/settings.json", "sub/.GiT/config"] {
            let r = reason(await write(p, path))
            #expect(r?.code == -32010, "\(path)")
            #expect(r?.reason == "protectedPath", "\(path)")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/hooks/pre-commit").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude/settings.json").path))
    }

    @Test func aProjectInsideAClaudeOrGitFolderRefusesWrites() throws {
        for name in [".claude", ".Claude", ".GIT"] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-in-\(UUID().uuidString)")
            let root = base.appendingPathComponent(name).appendingPathComponent("proj")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: base) }
            let workspace = Workspace(projectRoot: root, appSupport: base.appendingPathComponent("support"), settings: AlloySettings(),
                                      locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: { _ in ScriptedTransport() })
            #expect(workspace.pluginWriteRefusal(for: "a.txt") == .protectedPath, "\(name)")
        }
    }

    @Test func readRefusesANonRegularFile() async throws {
        let p = try await make()
        let fifo = p.rig.root.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o644) == 0)
        let r = reason(await read(p, "pipe"))
        #expect(r?.code == -32012)
        #expect(r?.reason == "missing")
        // A link to a regular file still reads.
        try FileManager.default.createSymbolicLink(at: p.rig.root.appendingPathComponent("alias.txt"),
                                                   withDestinationURL: p.rig.root.appendingPathComponent("notes.txt"))
        if case .success(let v) = await read(p, "alias.txt") { #expect(v["text"]?.stringValue == "one\n") } else { Issue.record("alias unreadable") }
    }

    @Test func missingGrantIsMinus32003() async throws {
        let p = try await make()
        let request = JSONValue.object(["method": .string("project/write"), "id": .number(5),
                                        "params": .object(["path": .string("notes.txt"), "text": .string("hacked\n")])])
        let folder = try p.fake(Self.id, script: .object(["afterInitialized": .array([request])]), permissions: ["project.read"])
        _ = await p.coordinator.activate(plugin: Self.id, .command)
        let log = folder.appendingPathComponent("log.jsonl")
        var answer: JSONValue?
        for _ in 0..<1000 where answer == nil {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            answer = text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }.first { $0["id"]?.intValue == 5 }
            if answer == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(answer?["error"]?["code"]?.intValue == -32003)
        #expect(disk(p, "notes.txt") == "one\n")
        await p.coordinator.shutdown()
    }

    @Test func stateRoundTripsAndPersistsPerProject() async throws {
        let p = try await make()
        let set = await p.coordinator.answerRequest(from: Self.id, "state/set", .object(["key": .string("k"), "value": .number(4)]))
        guard case .success = set else { Issue.record("set failed"); return }
        guard case .success(let got) = await p.coordinator.answerRequest(from: Self.id, "state/get", .object(["key": .string("k")])) else {
            Issue.record("get failed"); return
        }
        #expect(got["value"] == .number(4))
        guard case .success(let missing) = await p.coordinator.answerRequest(from: Self.id, "state/get", .object(["key": .string("z")])) else {
            Issue.record("get failed"); return
        }
        #expect(missing["value"] == .null)
        await p.coordinator.shutdown()
        let file = p.rig.workspace.projectStoreDirectory.appendingPathComponent("plugin-state/\(Self.id).json")
        #expect(FileManager.default.fileExists(atPath: file.path), "shutdown flushes the state")
        let tooBig = await p.coordinator.answerRequest(from: Self.id, "state/set",
                                                       .object(["key": .string("big"), "value": .string(String(repeating: "x", count: 70_000))]))
        guard case .failure(let e) = tooBig else { Issue.record("expected refusal"); return }
        #expect(e.code == -32011)
        await p.coordinator.shutdown()
    }

    // MARK: Guard

    /// The write itself costs no frame work: idle frames after it request no elements; only the frame that reloads the
    /// buffer, once the watcher fires, does.
    @Test func writeCostsNoFrameWorkUntilTheWatcherFires() async throws {
        final class Keeper { var rigs: [PluginRig] = [] }
        let keeper = Keeper()
        let perf = CodeModePerformanceTests()
        let (rig, window, _) = try await perf.rigged(.code1, install: { rig in
            let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"])
            keeper.rigs.append(p)
        })
        let p = try #require(keeper.rigs.first)
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(!doc.isDirty)
        func idleRequests(_ frames: Int) async -> Int {
            window.resetFrameWork()
            for _ in 0..<frames { window.tick(); await Task.yield() }
            return window.frameWork.reduce(0) { $0 + $1.elementRequests }
        }
        #expect(await idleRequests(20) == 0, "idle before the write")
        guard case .success = await write(p, "login.swift", "let reloaded = 1\n") else { Issue.record("write refused"); return }
        #expect(await idleRequests(20) == 0, "idle frames after the write, before the watcher")
        window.resetFrameWork()
        await fire(p, "login.swift")
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let reload = window.frameWork.reduce(0) { $0 + $1.elementRequests }
        print("PROJECT-WRITE reload-frame element requests=\(reload)")
        #expect(doc.buffer.snapshot().text == "let reloaded = 1\n")
        #expect(reload > 0, "the watcher-driven reload frame does the work")
        #expect(await idleRequests(20) == 0, "idle again after the reload")
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
    }
}
