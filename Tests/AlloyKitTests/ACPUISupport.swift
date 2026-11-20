import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

let uiFake = AgentDefinition(id: "fake", name: "Fake Agent", command: "fake-agent", args: ["acp"])
let uiOther = AgentDefinition(id: "other", name: "Other", command: "other-agent", args: ["acp"])

/// An ACP session up and idle on the rig's latest scripted transport.
@MainActor
func acpIdleSession(_ rig: Rig, agent: String = "fake", name: String = "A") async throws -> (Session, ScriptedTransport) {
    let s = await rig.workspace.newSession(name: name, backend: .acp(agentID: agent))
    let t = rig.transports[rig.transports.count - 1]
    await t.emit(.systemInit(SystemInit(model: "", permissionMode: "", sessionID: "ses_\(name)", tools: [], slashCommands: [])))
    try await acpUntil { s.status == .idle }
    return (s, t)
}

@MainActor
func acpUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<50_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out")
    throw CancellationError()
}

@MainActor
func hasElement(_ window: TestWindow, _ id: String) -> Bool { ((try? window.elements(where: { $0.identifier == id }))?.isEmpty == false) }
