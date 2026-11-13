import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyCore

/// Claude Code in Plan mode asks about tools even when they are in `--allowedTools`; Alloy answers for its own tools.
@MainActor
@Suite struct AutoAllowAlloyToolsTests {
    private func request(_ e: Env, _ s: Session, tool: String, id: String) async {
        await e.transport(of: s).emit(.controlRequest(ControlRequest(requestID: id, kind: .canUseTool(
            toolName: tool, input: .object(["path": .string("a.txt")]), description: nil, toolUseID: "tu-" + id, suggestions: []))))
    }

    private func allowed(_ t: ScriptedTransport, _ id: String) async -> Bool {
        await t.sent.contains { if case .allow(let rid, _, _) = $0 { return rid == id } else { return false } }
    }

    private func hasCard(_ s: Session) -> Bool {
        s.transcript.blocks.contains { if case .permission = $0 { return true } else { return false } }
    }

    @Test func alloyToolIsAnsweredAllowWithoutACard() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = await e.ws.newSession(name: "A")
        await request(e, s, tool: "mcp__alloy__notes_lookup", id: "r1")
        var sent = false
        for _ in 0..<200_000 where !sent { sent = await allowed(e.transport(of: s), "r1"); await Task.yield() }
        #expect(sent)
        #expect(!hasCard(s))
        #expect(!s.hasPendingPermission)
        #expect(s.status != .awaitingPermission)
    }

    @Test func otherToolsStillPrompt() async throws {
        let e = Env(); defer { e.cleanup() }
        let s = await e.ws.newSession(name: "A")
        await request(e, s, tool: "Edit", id: "r2")
        await waitUntil("card") { s.hasPendingPermission }
        #expect(hasCard(s))
        #expect(s.status == .awaitingPermission)
        #expect(await !allowed(e.transport(of: s), "r2"))
    }

    @Test func askBeforeSharedNotesStillPromptsForAlloyTools() async throws {
        let e = Env(); defer { e.cleanup() }
        var settings = e.ws.settings
        settings.askBeforeSharedNotes = true
        try e.ws.updateSettings(settings)
        let s = await e.ws.newSession(name: "A")
        await request(e, s, tool: "mcp__alloy__notes_lookup", id: "r3")
        await waitUntil("card") { s.hasPendingPermission }
        #expect(await !allowed(e.transport(of: s), "r3"))
    }
}
