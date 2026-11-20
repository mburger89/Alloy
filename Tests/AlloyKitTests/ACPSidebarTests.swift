import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import Testing

@MainActor
@Suite struct ACPSidebarTests {
    @Test func rowShowsAgentNameAndOnlyReportedUsage() async throws {
        let rig = Rig(agents: [uiFake])
        let (s, t) = try await acpIdleSession(rig)
        #expect(SessionRow.agentLine(s) == "Fake Agent")
        #expect(SessionRow.usageParts(s).isEmpty)
        await t.emit(.agentState(.models(current: "m1", available: [AgentChoice(id: "m1", name: "GPT-5")])))
        try await acpUntil { s.model == "m1" }
        #expect(SessionRow.agentLine(s) == "Fake Agent \u{00B7} GPT-5")
        // A local agent reports context, no cost.
        await t.emit(.agentState(.usage(SessionUsage(used: 12_300, size: 200_000))))
        try await acpUntil { s.usage != nil }
        #expect(SessionRow.usageParts(s) == ["12.3k/200.0k"])
        await t.emit(.agentState(.usage(SessionUsage(used: 500, size: 1000, cost: 0.5, currency: "USD"))))
        try await acpUntil { s.usage?.cost != nil }
        #expect(SessionRow.usageParts(s) == ["$0.50", "500/1.0k"])
    }

    @Test func forkIsDisabledForACPRowsAndClaudeRowsAreUnchanged() async throws {
        let rig = Rig(agents: [uiFake])
        let claude = await rig.workspace.newSession(name: "C")
        #expect(!claude.backend.isACP)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<3 { window.tick(); await Task.yield() }
        // The Claude row keeps its cost and token texts.
        #expect(hasElement(window, "session-tokens-\(claude.id.uuidString)"))
        #expect(!hasElement(window, "session-agent-\(claude.id.uuidString)"))
    }

    @Test func permissionCardTitleUsesAgentName() {
        #expect(PermissionCard.title(agentName: "Codex", tool: "Bash") == "Codex wants to use Bash")
        #expect(PermissionCard.title(agentName: "Claude", tool: "Bash") == "Claude wants to use Bash")
    }
}
