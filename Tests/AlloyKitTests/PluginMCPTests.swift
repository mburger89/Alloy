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
private func waitFor(_ timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@MainActor
@Suite(.serialized) struct PluginMCPTests {
    private let urlSession = URLSession(configuration: .ephemeral)
    private static let notes = "dev.example.todo"

    private static func contributes(_ tool: String = "notes_search") -> JSONValue {
        .object(["mcpTools": .array([.object(["name": .string(tool), "description": .string("Search the notes"),
                                              "inputSchema": .object(["type": .string("object")])])])])
    }

    private static func reply(_ result: JSONValue, hold: Bool = false) -> JSONValue {
        .object(["replies": .object(["mcp/call": .array([hold ? .object(["hold": .bool(true)]) : .object(["result": result])])])])
    }

    private func make(limits: PluginLimits = PluginLimits(), script: JSONValue? = nil, id: String = notes,
                      rig: Rig = Rig()) async throws -> PluginRig {
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], limits: limits)
        try p.fake(id, script: script ?? Self.reply(.object(["text": .string("found 3")])), permissions: ["mcp.tools"],
                   contributes: Self.contributes())
        await p.coordinator.settleMCP()
        return p
    }

    private func name(_ id: String = notes) -> String { PluginToolNaming.name(pluginID: id, tool: "notes_search") }

    private func token(_ p: PluginRig, scopes: Set<MCPToolScope>) async throws -> (URL, String) {
        let ws = p.rig.workspace
        let token = try #require(await ws.mcpToken(for: UUID(), scopes: scopes))
        return (try #require(ws.serverURL), token)
    }

    private func rpc(_ url: URL, _ token: String, _ json: String) async throws -> JSONValue? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await urlSession.data(for: request)
        return JSONValue.parse(data)
    }

    private func call(_ url: URL, _ token: String, _ tool: String) async throws -> JSONValue? {
        try await rpc(url, token, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(tool)","arguments":{}}}"#)
    }

    private func text(_ answer: JSONValue?) -> String? { answer?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue }

    private func methods(_ folder: URL) -> [String] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue }
    }

    @Test func shortHashIsStable() {
        #expect(PluginToolNaming.short("dev.example.todo") == "c73409")
        #expect(PluginToolNaming.short("dev.example.other") == "0dec9a")
        #expect(PluginToolNaming.short("com.acme.fmt") == "f9e2bc")
        #expect(PluginToolNaming.name(pluginID: "dev.example.todo", tool: "notes_search") == "p_c73409_notes_search")
    }

    @Test func claudeLaunchHoldsPluginScope() async throws {
        let p = try await make()
        let ws = p.rig.workspace
        let s = await ws.newSession(name: "a")
        await ws.settle()
        let scopes = await ws.localServer?.scopes(for: s.id)
        #expect(scopes == [.shared, .plugin(Self.notes)])
        let allowed = ws.launchAllowedTools[s.id] ?? []
        #expect(!allowed.contains { $0.contains("__p_") })
        await ws.stopAll()
        await p.coordinator.shutdown()
    }

    @Test func acpLaunchGetsServerForPluginScopeEvenWithSharingOff() async throws {
        let p = try await make(rig: Rig(agents: [uiFake]))
        let ws = p.rig.workspace
        var settings = ws.settings
        settings.shareKnowledge = false
        try ws.updateSettings(settings)
        let s = await ws.newSession(name: "a", backend: .acp(agentID: "fake"))
        await ws.settle()
        #expect(await ws.localServer?.scopes(for: s.id) == [.plugin(Self.notes)])
        #expect(ws.serverURL != nil)
        await ws.stopAll()
        await p.coordinator.shutdown()
    }

    @Test func pluginToolsAreNeverPreApproved() {
        let name = name()
        #expect(name == "p_c73409_notes_search")
        #expect(!Guidance.isAlloyToolTitle("mcp__alloy__\(name)", server: "alloy"))
        #expect(!Guidance.isAlloyToolTitle("alloy: \(name)", server: "alloy"))
        #expect(Guidance.isAlloyToolTitle("mcp__alloy__notes_lookup", server: "alloy"))
        #expect(!Guidance.isAlloyToolTitle("alloy: p_c73409_theme_preview", server: "alloy", includeTheme: true))
        #expect(!Guidance.alloyToolNames.contains { $0.contains("p_c73409") })
        #expect(!Guidance.themeToolNames.contains { $0.contains("p_c73409") })
    }

    @Test func callStartsPluginAndReturnsText() async throws {
        let p = try await make()
        let folder = p.paths.plugins.appendingPathComponent(Self.notes)
        #expect(methods(folder).isEmpty)
        let (url, token) = try await token(p, scopes: [.plugin(Self.notes)])
        let listed = try await rpc(url, token, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(listed?["result"]?["tools"]?.arrayValue?.first?["name"]?.stringValue == name())
        #expect(methods(folder).isEmpty, "listing starts nothing")
        let answer = try await call(url, token, name())
        #expect(text(answer) == "found 3")
        let sent = methods(folder)
        #expect(sent.first == "initialize" && sent.contains("mcp/call"))
        await p.coordinator.shutdown()
    }

    @Test func timeoutReturnsIsError() async throws {
        var limits = PluginLimits()
        limits.requestTimeout = .milliseconds(200)
        let p = try await make(limits: limits, script: Self.reply(.null, hold: true))
        let (url, token) = try await token(p, scopes: [.plugin(Self.notes)])
        let answer = try await call(url, token, name())
        #expect(answer?["result"]?["isError"]?.boolValue == true)
        #expect(text(answer) == "The plugin did not answer in time.")
        await p.coordinator.shutdown()
    }

    @Test func disableRevokesLiveTokens() async throws {
        let p = try await make()
        let (url, token) = try await token(p, scopes: [.plugin(Self.notes)])
        #expect(text(try await call(url, token, name())) == "found 3")
        try p.coordinator.disable(Self.notes)
        await p.coordinator.settleMCP()
        let after = try await call(url, token, name())
        #expect(after?["error"]?["message"]?.stringValue?.contains("Unknown tool") == true)
        #expect(p.coordinator.pluginToolScopes.isEmpty)
        await p.coordinator.shutdown()
    }

    @Test func rowNotesSessionsRestart() async throws {
        let p = try await make()
        #expect(p.row(Self.notes)?.notes.contains(PluginCoordinator.mcpRowNote) == true)
        await p.coordinator.shutdown()
    }

    @Test func toolListIsNotRebuiltPerCall() async throws {
        let p = try await make()
        let (url, token) = try await token(p, scopes: [.plugin(Self.notes)])
        let server = try #require(p.rig.workspace.localServer)
        let before = await server.pluginToolSetCount
        for _ in 0..<100 { _ = try await call(url, token, name()) }
        #expect(await server.pluginToolSetCount == before)
        await p.coordinator.shutdown()
    }

    private final class Keeper { var rigs: [PluginRig] = [] }

    @Test func typingWithAnMCPPluginHoldsTheChatGuard() async throws {
        let keeper = Keeper()
        let perf = CodeModePerformanceTests()
        try await perf.guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, install: { rig in
            let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"])
            keeper.rigs.append(p)
            _ = try? p.fake(Self.notes, permissions: ["mcp.tools"], contributes: Self.contributes())
        })
        #expect(keeper.rigs.first?.coordinator.pluginToolScopes == [.plugin(Self.notes)])
        for p in keeper.rigs { await p.coordinator.shutdown() }
    }
}
