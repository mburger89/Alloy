import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing

@MainActor
@Suite struct ACPComposerTests {
    private let modes = [AgentChoice(id: "ask", name: "Ask"), AgentChoice(id: "code", name: "Code")]
    private let models = [AgentChoice(id: "m1", name: "Model One"), AgentChoice(id: "m2", name: "Model Two")]

    @Test func placeholderNamesAgent() async throws {
        let rig = Rig(agents: [uiFake])
        let claude = await rig.workspace.newSession(name: "C")
        #expect(ComposerModel.placeholder(for: claude) == "Message Claude")
        let (acp, _) = try await acpIdleSession(rig)
        #expect(ComposerModel.placeholder(for: acp) == "Message Fake Agent")
    }

    @Test func pickersFollowAgentOptionsAndHideWhenAbsent() async throws {
        let rig = Rig(agents: [uiFake])
        let (s, t) = try await acpIdleSession(rig)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<4 { window.tick(); await Task.yield() }
        #expect(hasElement(window, "composer"))
        #expect(!hasElement(window, "mode-picker") && !hasElement(window, "model-menu"))
        await t.emit(.agentState(.modes(current: "ask", available: modes)))
        await t.emit(.agentState(.models(current: "m1", available: models)))
        try await acpUntil { s.modes.count == 2 && s.modelOptions.count == 2 }
        try await window.runUntil { hasElement(window, "mode-picker") && hasElement(window, "model-menu") }
        try window.click(window.element(identifier: "model-menu"))
        window.tick()
        #expect(try #require(window.presentedMenu).items.map(\.title) == ["Model One", "Model Two"])
        try window.chooseMenuItem(accessibilityIdentifier: "model-choice-m2")
        for _ in 0..<2000 {
            if await t.sent.contains(where: { if case .control(_, .setModel("m2")) = $0 { true } else { false } }) { break }
            window.tick(); await Task.yield()
        }
        #expect(await t.sent.contains { if case .control(_, .setModel("m2")) = $0 { true } else { false } })
    }

    @Test func agentModeSelectionSendsTheAgentsOwnId() async throws {
        let rig = Rig(agents: [uiFake])
        let (_, t) = try await acpIdleSession(rig)
        let s = rig.workspace.sessions[0]
        await rig.workspace.setAgentMode("code", for: s.id)
        #expect(await t.sent.contains { if case .control(_, .setPermissionMode("code")) = $0 { true } else { false } })
    }

    @Test func effortHiddenForACPAndShownForClaude() async throws {
        let rig = Rig(agents: [uiFake])
        let claude = await rig.workspace.newSession(name: "C")
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                        outputTokens: 0, sessionID: "s", terminalReason: nil)))
        try await acpUntil { claude.status == .idle }
        let w1 = try alloyWindow(rig.workspace)
        for _ in 0..<3 { w1.tick(); await Task.yield() }
        let ids = (try? w1.elements(where: { $0.identifier != nil }).compactMap(\.identifier)) ?? []
        #expect(hasElement(w1, "effort-menu") && hasElement(w1, "mode-picker") && hasElement(w1, "model-menu"), "\(ids)")
        _ = claude
        let rig2 = Rig(agents: [uiFake])
        _ = try await acpIdleSession(rig2)
        let w2 = try alloyWindow(rig2.workspace)
        for _ in 0..<3 { w2.tick(); await Task.yield() }
        #expect(hasElement(w2, "composer") && !hasElement(w2, "effort-menu"))
    }

    @Test func forkRefusedAndThemeRunsOnTheSameAgentForACP() async throws {
        let rig = Rig(agents: [uiFake])
        let (s, t) = try await acpIdleSession(rig)
        // An agent that has listed its own commands gets Alloy's /theme beside them, but not /fork.
        await t.emit(.commandsChanged([SlashCommandInfo(name: "help", description: "Help", argumentHint: nil)]))
        try await acpUntil { !s.slashCommands.isEmpty }
        #expect(!s.slashCommands.contains { $0.name == "fork" })
        #expect(s.slashCommands.contains { $0.name == "theme" })
        await rig.workspace.send(OutgoingMessage(text: "/fork x", images: [], priority: nil), to: s.id)
        #expect(rig.workspace.sessions.count == 1)
        let notices = s.transcript.blocks.compactMap { b -> String? in if case .notice(_, _, let t) = b { t } else { nil } }
        #expect(notices.contains { $0.contains("/fork is not available") })
        await rig.workspace.send(OutgoingMessage(text: "/theme dark", images: [], priority: nil), to: s.id)
        #expect(rig.workspace.sessions.count == 2)
        let theme = try #require(rig.workspace.sessions.first { $0.purpose == .theme })
        #expect(theme.backend == s.backend && theme.backend.isACP, "the theme session runs on the session's own agent")
        let after = s.transcript.blocks.compactMap { b -> String? in if case .notice(_, _, let t) = b { t } else { nil } }
        #expect(!after.contains { $0.contains("/theme is not available") })
    }

    @Test func queuedBubbleShowsSendNow() async throws {
        let rig = Rig(agents: [uiFake])
        let (s, t) = try await acpIdleSession(rig)
        await t.emit(.assistantBlock(messageID: "m1", block: .text("working")))
        try await acpUntil { s.status == .working }
        await rig.workspace.send(OutgoingMessage(text: "later", images: [], priority: .later), to: s.id)
        let window = try alloyWindow(rig.workspace)
        let id = try #require(s.queued.first)
        try await window.runUntil { hasElement(window, "send-now-\(id.uuidString)") }
        // Claude's queue has no such button.
        let c = await rig.workspace.newSession(name: "C")
        await rig.transports[rig.transports.count - 1].emit(.assistantBlock(messageID: "m1", block: .text("working")))
        try await acpUntil { c.status == .working }
        await rig.workspace.send(OutgoingMessage(text: "q", images: [], priority: .later), to: c.id)
        let cid = try #require(c.queued.first)
        rig.workspace.selectedSessionID = c.id
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(!hasElement(window, "send-now-\(cid.uuidString)"))
    }
}
