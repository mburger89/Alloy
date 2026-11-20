import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing

@MainActor
@Suite struct NewSessionMenuTests {
    @Test func newSessionMenuListsClaudeFirstThenDetectedThenAdd() async throws {
        let rig = Rig(agents: [uiFake, uiOther])
        await rig.workspace.detectAgents()
        #expect(rig.workspace.installedAgents.map(\.id) == ["fake", "other"])
        #expect(NewSessionMenu.itemIDs(rig.workspace.installedAgents)
                == ["new-session-claude", "new-session-agent-fake", "new-session-agent-other", "new-session-add-agent"])
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "new-session-menu"))
        window.tick()
        let titles = try #require(window.presentedMenu).items.map(\.title)
        #expect(titles == ["Claude", "Fake Agent", "Other", "Add agent\u{2026}"], "\(titles)")
    }

    @Test func undetectedAgentsAreNotOffered() async throws {
        let rig = Rig(agents: [uiFake])
        #expect(rig.workspace.installedAgents.isEmpty)
        #expect(NewSessionMenu.itemIDs([]) == ["new-session-claude", "new-session-add-agent"])
    }

    @Test func chosenAgentStartsAnACPSession() async throws {
        let rig = Rig(agents: [uiFake])
        await rig.workspace.detectAgents()
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "new-session-menu"))
        window.tick()
        try window.chooseMenuItem(accessibilityIdentifier: "new-session-agent-fake")
        try await window.runUntil { rig.workspace.sessions.count == 1 }
        #expect(rig.workspace.sessions[0].backend == .acp(agentID: "fake"))
        #expect(rig.workspace.sessions[0].agentName == "Fake Agent")
    }

    @Test func claudeItemStartsAClaudeSession() async throws {
        let rig = Rig(agents: [uiFake], defaultAgentID: "fake")
        await rig.workspace.detectAgents()
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "new-session-menu"))
        window.tick()
        try window.chooseMenuItem(accessibilityIdentifier: "new-session-claude")
        try await window.runUntil { rig.workspace.sessions.count == 1 }
        #expect(rig.workspace.sessions[0].backend == .claude)
    }

    @Test func addAgentCallsTheHook() async throws {
        let rig = Rig(agents: [uiFake])
        var asked = 0
        let window = try alloyWindow(rig.workspace)
        // The screen wires Settings in; a test replaces it to see the item reach the hook.
        rig.workspace.onAddAgent = { asked += 1 }
        try window.click(window.element(identifier: "new-session-menu"))
        window.tick()
        try window.chooseMenuItem(accessibilityIdentifier: "new-session-add-agent")
        for _ in 0..<50 where asked == 0 { window.tick(); await Task.yield() }
        #expect(asked == 1)
    }

    @Test func commandNUsesDefaultAgent() async throws {
        let rig = Rig(agents: [uiFake], defaultAgentID: "fake")
        #expect(rig.workspace.defaultBackend == .acp(agentID: "fake"))
        rig.workspace.startNewSession()
        try await acpUntil { rig.workspace.sessions.count == 1 }
        #expect(rig.workspace.sessions[0].backend == .acp(agentID: "fake"))
        // A default that is no longer defined falls back to Claude.
        let gone = Rig(agents: [uiOther], defaultAgentID: "fake")
        #expect(gone.workspace.defaultBackend == .claude)
        let none = Rig(agents: [uiFake])
        none.workspace.startNewSession()
        try await acpUntil { none.workspace.sessions.count == 1 }
        #expect(none.workspace.sessions[0].backend == .claude)
    }
}
