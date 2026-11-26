import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

@Suite struct ResumeTests {
    private func restore(_ c: inout ACPLaunchConfiguration) { c.acpSessionID = "saved1"; c.resume = .resume }

    @Test func wakeUsesResumeThenLoadThenNewWithNotice() async throws {
        // 1. The agent offers resume: it is used, nothing is replayed, no new session.
        let a = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"loadSession":true,"sessionCapabilities":{"resume":{}}}"#),
            #"{"expect":"session/resume"}"#, hsOK, #"{"sleep":3000}"#,
        ], configure: { restore(&$0) })
        #expect(await waitUntil { a.events.hasSystemInit })
        #expect(a.lines("session/resume").count == 1 && a.lines("session/load").isEmpty && a.lines("session/new").isEmpty)
        #expect(a.lines("session/resume")[0].contains(#""sessionId":"saved1""#))
        if case .systemInit(let i)? = a.events.messages.first(where: { if case .systemInit = $0 { true } else { false } }) {
            #expect(i.sessionID == "saved1")
        }
        #expect(!a.events.notices.contains { $0.contains("doesn't remember") })
        await a.stop()

        // 2. Only load: it is used.
        let b = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"loadSession":true}"#),
            #"{"expect":"session/load"}"#, hsOK, #"{"sleep":3000}"#,
        ], configure: { restore(&$0) })
        #expect(await waitUntil { b.events.hasSystemInit })
        #expect(b.lines("session/load").count == 1 && b.lines("session/new").isEmpty)
        await b.stop()

        // 3. Neither: a new session, and the user is told.
        let c = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit("{}"),
            #"{"expect":"session/new"}"#, hsNew, #"{"sleep":3000}"#,
        ], configure: { restore(&$0) })
        #expect(await waitUntil { c.events.hasSystemInit })
        #expect(c.lines("session/resume").isEmpty && c.lines("session/load").isEmpty)
        #expect(c.events.notices.contains("This agent doesn't remember the earlier conversation"))
        if case .systemInit(let i)? = c.events.messages.first(where: { if case .systemInit = $0 { true } else { false } }) {
            #expect(i.sessionID == "new1")
        }
        await c.stop()
    }

    @Test func aFailedResumeFallsBackToNewWithTheNotice() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"sessionCapabilities":{"resume":{}}}"#),
            #"{"expect":"session/resume"}"#,
            #"{"send":{"jsonrpc":"2.0","id":"$id","error":{"code":-32002,"message":"Session not found"}}}"#,
            #"{"expect":"session/new"}"#, hsNew, #"{"sleep":3000}"#,
        ], configure: { restore(&$0) })
        #expect(await waitUntil { r.events.hasSystemInit })
        #expect(r.events.notices.contains("This agent doesn't remember the earlier conversation"))
        await r.stop()
    }

    @Test func loadReplayIsDiscardedNotDoubled() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"loadSession":true}"#),
            #"{"expect":"session/load"}"#,
            upd(#"{"sessionUpdate":"user_message_chunk","messageId":"u1","content":{"type":"text","text":"old question"}}"#),
            upd(#"{"sessionUpdate":"agent_message_chunk","messageId":"a1","content":{"type":"text","text":"old answer"}}"#),
            upd(#"{"sessionUpdate":"tool_call","toolCallId":"t0","title":"Old tool","kind":"read","status":"completed"}"#),
            upd(#"{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"review","description":"Review"}]}"#),
            hsOK,
            #"{"expect":"session/prompt"}"#,
            upd(#"{"sessionUpdate":"agent_message_chunk","messageId":"a2","content":{"type":"text","text":"fresh"}}"#),
            turnDone, #"{"sleep":3000}"#,
        ], configure: { restore(&$0) })
        #expect(await waitUntil { r.events.hasSystemInit })
        try await r.transport.send(user("next"))
        #expect(await waitUntil { r.events.results == 1 })
        #expect(r.events.text == "fresh")
        #expect(r.events.echoes == ["next"])   // the replayed "old question" is not an echo
        #expect(!r.events.messages.contains { if case .assistantBlock = $0 { true } else { false } })
        // State updates of the replay are kept.
        #expect(r.events.messages.contains { if case .commandsChanged(let c) = $0 { c.first?.name == "review" } else { false } })
        await r.stop()
    }

    // MARK: shared notes over MCP

    private let mcp = ACPMCPDescriptor(name: "alloy", url: "http://127.0.0.1:9/mcp", token: "tok-123")

    @Test func mcpDescriptorSentOnlyWithHttpCapability() async throws {
        let withHTTP = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":true}}"#),
            #"{"expect":"session/new"}"#, hsNew, #"{"sleep":3000}"#,
        ], configure: { $0.mcp = mcp })
        #expect(await waitUntil { withHTTP.events.hasSystemInit })
        let line = withHTTP.lines("session/new")[0]
        #expect(line.contains(#""type":"http""#) && line.contains(#""name":"alloy""#))
        #expect(line.contains("Bearer tok-123") && line.contains("127.0.0.1:9"))
        #expect(!withHTTP.events.notices.contains { $0.contains("Shared notes are unavailable") })
        await withHTTP.stop()
    }

    @Test func noHttpMcpSessionInfoSaysSoAndNoServerPassed() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":false,"sse":false}}"#),
            #"{"expect":"session/new"}"#, hsNew, #"{"sleep":3000}"#,
        ], configure: { $0.mcp = mcp; $0.systemPrompt = "GUIDE" })
        #expect(await waitUntil { r.events.hasSystemInit })
        let line = r.lines("session/new")[0]
        #expect(line.contains(#""mcpServers":[]"#) && !line.contains("tok-123") && !line.contains("GUIDE"))
        #expect(r.events.notices.contains { $0.contains("Shared notes are unavailable") })
        await r.stop()
    }

    @Test func themeFallbackWithoutHTTPMCP() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":false,"sse":false},"sessionCapabilities":{"systemPrompt":{}}}"#),
            #"{"expect":"session/new"}"#, hsNew, #"{"sleep":3000}"#,
        ], configure: { $0.mcp = mcp; $0.systemPrompt = "GUIDE"; $0.promptWithoutTools = "FILE"; $0.toolsUnavailableNotice = "N" })
        #expect(await waitUntil { r.events.hasSystemInit })
        let line = r.lines("session/new")[0]
        #expect(line.contains(#""mcpServers":[]"#) && line.contains("FILE") && !line.contains("GUIDE"))
        #expect(r.events.notices.filter { $0 == "N" }.count == 1)
        #expect(!r.events.notices.contains { $0.contains("Shared notes are unavailable") })
        await r.stop()
    }

    @Test func themeToolAutoAllowed() async throws {
        func steps(_ title: String) -> [String] {
            [#"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":true}}"#), #"{"expect":"session/new"}"#, hsNew,
             #"{"expect":"session/prompt"}"#,
             #"{"send":{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"\#(title)","kind":"other"},"options":[{"optionId":"yes","name":"Yes","kind":"allow_once"},{"optionId":"no","name":"No","kind":"reject_once"}]}}}"#,
             #"{"expectResponse":0}"#, turnDone, #"{"sleep":3000}"#]
        }
        let auto = try await Rig.start(steps("alloy: theme_save"), configure: { $0.mcp = mcp; $0.autoAllowThemeTools = true })
        #expect(await waitUntil { auto.events.hasSystemInit })
        try await auto.transport.send(user("go"))
        #expect(await waitUntil { auto.events.results == 1 })
        #expect(auto.events.controlRequests.isEmpty)
        #expect(auto.logText.contains(#""optionId":"yes""#))
        await auto.stop()

        let off = try await Rig.start(steps("alloy: theme_save"), configure: { $0.mcp = mcp })
        #expect(await waitUntil { off.events.hasSystemInit })
        try await off.transport.send(user("go"))
        #expect(await waitUntil { !off.events.controlRequests.isEmpty })
        await off.stop()
    }

    @Test func guidanceInSystemPromptOrFirstPromptPreface() async throws {
        // The agent takes a system prompt: it goes in session/new, and no prompt carries it.
        let a = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":true},"sessionCapabilities":{"systemPrompt":{}}}"#),
            #"{"expect":"session/new"}"#, hsNew, #"{"expect":"session/prompt"}"#, turnDone, #"{"sleep":3000}"#,
        ], configure: { $0.mcp = mcp; $0.systemPrompt = "GUIDE-TEXT" })
        #expect(await waitUntil { a.events.hasSystemInit })
        let new = a.lines("session/new")[0]
        #expect(new.contains(#""systemPrompt""#) && new.contains("GUIDE-TEXT") && new.contains(#""mode":"append""#))
        try await a.transport.send(user("first"))
        #expect(await waitUntil { a.events.results == 1 })
        #expect(!a.lines("session/prompt")[0].contains("GUIDE-TEXT"))
        await a.stop()

        // No system prompt: a preface leads the first prompt, once.
        let b = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":true}}"#),
            #"{"expect":"session/new"}"#, hsNew, #"{"expect":"session/prompt"}"#, turnDone,
            #"{"expect":"session/prompt"}"#, turnDone, #"{"sleep":3000}"#,
        ], configure: { $0.mcp = mcp; $0.systemPrompt = "GUIDE-TEXT" })
        #expect(await waitUntil { b.events.hasSystemInit })
        #expect(!b.lines("session/new")[0].contains("systemPrompt"))
        try await b.transport.send(user("first"))
        #expect(await waitUntil { b.events.results == 1 })
        try await b.transport.send(user("second"))
        #expect(await waitUntil { b.events.results == 2 })
        let prompts = b.lines("session/prompt")
        let first = prompts[0], second = prompts[1]
        let g = try #require(first.range(of: "GUIDE-TEXT")), u = try #require(first.range(of: "first"))
        #expect(g.lowerBound < u.lowerBound)
        #expect(!second.contains("GUIDE-TEXT"))
        #expect(b.events.echoes == ["first", "second"])   // the preface is not the user's text
        await b.stop()
    }

    @Test func alloyToolPermissionAutoAllowedUnlessAskBeforeSharedNotes() async throws {
        func steps() -> [String] {
            [#"{"expect":"initialize"}"#, hsInit(#"{"mcpCapabilities":{"http":true}}"#), #"{"expect":"session/new"}"#, hsNew,
             #"{"expect":"session/prompt"}"#,
             #"{"send":{"jsonrpc":"2.0","id":0,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"alloy: notes_lookup","kind":"other"},"options":[{"optionId":"yes","name":"Yes","kind":"allow_once"},{"optionId":"no","name":"No","kind":"reject_once"}]}}}"#,
             #"{"expectResponse":0}"#, turnDone, #"{"sleep":3000}"#]
        }
        let auto = try await Rig.start(steps(), configure: { $0.mcp = mcp; $0.autoAllowAlloyTools = true })
        #expect(await waitUntil { auto.events.hasSystemInit })
        try await auto.transport.send(user("go"))
        #expect(await waitUntil { auto.events.results == 1 })
        #expect(auto.events.controlRequests.isEmpty)
        #expect(auto.logText.contains(#""optionId":"yes""#))
        await auto.stop()

        let ask = try await Rig.start(steps(), configure: { $0.mcp = mcp; $0.autoAllowAlloyTools = false })
        #expect(await waitUntil { ask.events.hasSystemInit })
        try await ask.transport.send(user("go"))
        #expect(await waitUntil { !ask.events.controlRequests.isEmpty })
        #expect(ask.events.results == 0)
        if case .canUseTool(_, _, _, _, _)? = ask.events.controlRequests.first?.kind {} else { Issue.record("no card") }
        await ask.stop()

        // A tool that is not Alloy's is never auto-allowed.
        var other = steps()
        other[5] = other[5].replacingOccurrences(of: "alloy: notes_lookup", with: "Run rm -rf")
        let foreign = try await Rig.start(other, configure: { $0.mcp = mcp; $0.autoAllowAlloyTools = true })
        #expect(await waitUntil { foreign.events.hasSystemInit })
        try await foreign.transport.send(user("go"))
        #expect(await waitUntil { !foreign.events.controlRequests.isEmpty })
        await foreign.stop()
    }
}
