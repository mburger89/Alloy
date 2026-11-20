import AlloyCore
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyACP

@Suite struct FileServiceTests {
    private let scratch = Scratch()
    private var root: URL {
        let r = scratch.url.appendingPathComponent("project")
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return r.resolvingSymlinksInPath()
    }

    private func policy() -> ACPPathPolicy { ACPPathPolicy(root: root) }

    private func accepted(_ p: ACPPathPolicy, _ path: String) -> String? {
        if case .success(let u) = p.resolve(path) { return p.relative(u) }
        return nil
    }

    @Test func pathsInsideTheRootResolve() {
        let p = policy()
        #expect(accepted(p, "a.txt") == "a.txt")
        #expect(accepted(p, root.path + "/sub/new/b.txt") == "sub/new/b.txt")
        #expect(accepted(p, "sub/../c.txt") == "c.txt")
    }

    @Test func writeOutsideRootIsRefused() throws {
        let p = policy()
        let outside = scratch.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: outside.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        #expect(accepted(p, "../x") == nil)
        #expect(accepted(p, "../outside/f.txt") == nil)
        #expect(accepted(p, outside.path + "/f.txt") == nil)
        #expect(accepted(p, "/etc/hosts") == nil)
        #expect(accepted(p, "") == nil)
        // A link inside the project that leaves it: refused, also for a file that does not exist yet.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        #expect(accepted(p, "escape/f.txt") == nil)
        #expect(accepted(p, "escape/new/g.txt") == nil)
        // A link to a file outside.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"),
                                                   withDestinationURL: outside.appendingPathComponent("f.txt"))
        #expect(accepted(p, "file-link") == nil)
        // A link that stays inside is fine and names the real file.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("inner"),
                                                   withDestinationURL: root.appendingPathComponent("real"))
        #expect(accepted(p, "inner/h.txt") == "real/h.txt")
    }

    @Test func protectedPaths() {
        let p = policy()
        for rel in [".git/config", ".git/hooks/pre-commit", ".env", ".env.local", "apps/web/.env", "opencode.json",
                    ".claude/x", ".claude/settings.json", ".codex/x", ".goose/x", ".gemini/x", ".vscode/tasks.json",
                    ".mcp.json", "OPENCODE.JSON", ".Git/config"] {
            #expect(p.isProtected(root.appendingPathComponent(rel)), "\(rel) should be protected")
        }
        for rel in ["a.txt", "src/env.swift", "environment", "envrc.bak",
                    "docs/git/notes.md", "gitignore"] {
            #expect(!p.isProtected(root.appendingPathComponent(rel)), "\(rel) should not be protected")
        }
    }

    @Test func aProjectInsideAProtectedNamedFolderIsNotProtectedWholesale() throws {
        let nested = scratch.url.appendingPathComponent(".claude/worktrees/p")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let p = ACPPathPolicy(root: nested)
        #expect(!p.isProtected(nested.resolvingSymlinksInPath().appendingPathComponent("a.txt")))
        #expect(p.isProtected(nested.resolvingSymlinksInPath().appendingPathComponent(".env")))
    }

    // MARK: through the transport

    private struct Stub: ACPFileHandling {
        func readTextFile(path: String, line: Int?, limit: Int?) async throws -> String { "read \(path) \(line ?? 0) \(limit ?? 0)" }
        func writeTextFile(path: String, content: String) async throws {
            if path.hasPrefix("..") { throw ACPPathError.outsideProject }
        }
    }

    @Test func fsRequestsAreRoutedToTheFileHandler() async throws {
        let s = Scratch()
        let log = s.url.appendingPathComponent("log.txt").path
        let initReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}}}"#
        let newReply = #"{"send":{"jsonrpc":"2.0","id":"$id","result":{"sessionId":"s1"}}}"#
        let steps = [
            #"{"expect":"initialize"}"#, initReply, #"{"expect":"session/new"}"#, newReply,
            #"{"send":{"jsonrpc":"2.0","id":41,"method":"fs/read_text_file","params":{"sessionId":"s1","path":"a.txt","line":2,"limit":3}}}"#,
            #"{"expectResponse":41}"#,
            #"{"send":{"jsonrpc":"2.0","id":42,"method":"fs/write_text_file","params":{"sessionId":"s1","path":"../x","content":"c"}}}"#,
            #"{"expectResponse":42}"#,
            #"{"send":{"jsonrpc":"2.0","id":43,"method":"fs/write_text_file","params":{"sessionId":"s1","path":"ok.txt","content":"c"}}}"#,
            #"{"expectResponse":43}"#,
            #"{"sleep":3000}"#,
        ]
        let def = AgentDefinition(id: "fake", name: "Fake", command: fakeAgentPath)
        let config = ACPLaunchConfiguration(agent: def, executable: URL(fileURLWithPath: fakeAgentPath), arguments: [],
                                            projectDirectory: s.url, sessionID: UUID(),
                                            env: ["FAKE_ACP_SCRIPT": s.script(steps), "FAKE_ACP_LOG": log], fileService: Stub())
        let t = ACPTransport(configuration: config)
        let stream = try await t.start()
        Task { for await _ in stream {} }
        #expect(await waitUntil {
            ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains(#""id":43"#)
        })
        let sent = try String(contentsOfFile: log, encoding: .utf8)
        #expect(sent.contains("read a.txt 2 3"))
        #expect(sent.contains("outside the project"))
        #expect(sent.contains(#""id":43,"jsonrpc":"2.0","result":null"#) || sent.contains(#""result":null"#))
        await t.stopAndWait(timeout: .seconds(3))
    }
}
