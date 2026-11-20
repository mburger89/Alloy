import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

/// End-to-end runs against real agents, headless over stdio (no GUI app). Off by default; run with
/// `ALLOY_ACP_LIVE=1` and the agents installed and logged in (`codex-acp` on the login PATH, `opencode` with a local
/// Ollama). Each run: a prompt, an edit (permissions auto-allowed), a cancel mid-turn, a relaunch that must resume or
/// load the same agent session. Codex spends a little quota, so the prompts are tiny.
private let liveEnabled = ProcessInfo.processInfo.environment["ALLOY_ACP_LIVE"] == "1"

@Suite(.serialized, .enabled(if: liveEnabled)) struct LiveAgentTests {
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ProcessEvent] = []
        func add(_ e: ProcessEvent) { lock.withLock { items.append(e) } }
        var messages: [InboundMessage] { lock.withLock { items }.compactMap { if case .message(let m) = $0 { m } else { nil } } }
        var exited: Bool { lock.withLock { items }.contains { if case .exited = $0 { true } else { false } } }
        var results: Int { messages.filter { if case .result = $0 { true } else { false } }.count }
        var text: String { messages.compactMap { if case .delta(.text(_, let s)) = $0 { s } else { nil } }.joined() }
        var sessionID: String? {
            for m in messages { if case .systemInit(let i) = m { return i.sessionID } }
            return nil
        }
        var notices: [String] { messages.compactMap { if case .notice(_, let t) = $0 { t } else { nil } } }
    }

    private struct Live {
        var transport: ACPTransport
        var sink: Sink
    }

    private func locate(_ name: String) -> URL? {
        let path = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return path.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func launch(_ id: String, exe: URL, args: [String], project: URL, resume: String? = nil) async throws -> Live {
        var env: [String: String] = [:]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["PATH", "HOME", "USER", "LANG", "TMPDIR"] { env[key] = inherited[key] }
        let def = AgentDefinition(id: id, name: id, command: exe.path, args: args)
        let config = ACPLaunchConfiguration(agent: def, executable: exe, arguments: args, projectDirectory: project,
                                            sessionID: UUID(), acpSessionID: resume, resume: resume == nil ? .new : .resume, env: env)
        let transport = ACPTransport(configuration: config)
        let stream = try await transport.start()
        let sink = Sink()
        Task {
            for await e in stream {
                sink.add(e)
                if case .message(.controlRequest(let r)) = e, case .canUseTool = r.kind {
                    try? await transport.send(.allow(requestID: r.requestID, updatedInput: .null))
                }
            }
        }
        return Live(transport: transport, sink: sink)
    }

    private func prompt(_ live: Live, _ text: String, timeout: Duration) async throws -> Bool {
        let before = live.sink.results
        try await live.transport.send(.user(text: text, uuid: UUID(), priority: nil))
        return await waitUntil(timeout) { live.sink.results > before }
    }

    private func run(_ id: String, exe: URL, args: [String], project: URL, editPrompt: String, timeout: Duration) async throws {
        // 1. Prompt.
        var live = try await launch(id, exe: exe, args: args, project: project)
        #expect(await waitUntil(.seconds(60)) { live.sink.sessionID != nil }, "\(id): handshake")
        let saved = try #require(live.sink.sessionID)
        #expect(try await prompt(live, "Reply with exactly the word ready.", timeout: timeout), "\(id): first prompt")
        #expect(!live.sink.text.isEmpty)
        // 2. Edit (any permission request is allowed by the event loop).
        #expect(try await prompt(live, editPrompt, timeout: timeout), "\(id): edit prompt")
        let hello = project.appendingPathComponent("hello.txt")
        print("LIVE \(id): hello.txt written=\(FileManager.default.fileExists(atPath: hello.path))")
        // 3. Cancel mid-turn.
        let cancelBase = live.sink.results
        try await live.transport.send(.user(text: "Count slowly from 1 to 200, one number per line.", uuid: UUID(), priority: nil))
        _ = await waitUntil(.seconds(60)) { !live.sink.text.isEmpty && live.sink.text.count > 20 }
        try await live.transport.send(.control(requestID: "stop", .interrupt))
        #expect(await waitUntil(.seconds(30)) { live.sink.results > cancelBase }, "\(id): cancelled turn ends")
        // 4. Relaunch resuming the same agent session.
        await live.transport.stopAndWait(timeout: .seconds(3))
        #expect(await waitUntil(.seconds(10)) { live.sink.exited }, "\(id): first process gone")
        live = try await launch(id, exe: exe, args: args, project: project, resume: saved)
        #expect(await waitUntil(.seconds(60)) { live.sink.sessionID != nil }, "\(id): relaunch handshake")
        print("LIVE \(id): resumed same session=\(live.sink.sessionID == saved) forgot-notice=\(live.sink.notices.contains { $0.contains("doesn't remember") })")
        await live.transport.stopAndWait(timeout: .seconds(3))
        #expect(await waitUntil(.seconds(10)) { live.sink.exited }, "\(id): second process gone")
    }

    private func project(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("acp-live-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func codexSession() async throws {
        guard let exe = locate("codex-acp") else { Issue.record("codex-acp not installed"); return }
        let dir = try project("codex")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await run("codex", exe: exe, args: [], project: dir,
                      editPrompt: "Create a file hello.txt containing the word hi. Do not do anything else.", timeout: .seconds(120))
    }

    @Test func openCodeWithOllamaSession() async throws {
        guard let exe = locate("opencode") else { Issue.record("opencode not installed"); return }
        let model = ProcessInfo.processInfo.environment["ALLOY_ACP_LIVE_OLLAMA_MODEL"] ?? "qwen3.8:27b"
        let dir = try project("opencode")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Local Ollama only, never a cloud provider.
        let config = """
        {"$schema":"https://opencode.ai/config.json","provider":{"ollama":{"npm":"@ai-sdk/openai-compatible","name":"Ollama",\
        "options":{"baseURL":"http://localhost:11434/v1"},"models":{"\(model)":{"name":"\(model)"}}}},"model":"ollama/\(model)"}
        """
        try config.write(to: dir.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        try await run("opencode", exe: exe, args: ["acp"], project: dir,
                      editPrompt: "Use your write tool to create hello.txt containing the word hi.", timeout: .seconds(300))
    }
}
