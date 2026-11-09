@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionMessageViewTests {
    private func shown(_ w: TestWindow, _ id: String) throws -> String? {
        let e = try w.element(identifier: id)
        return e.value ?? e.label
    }

    @Test func titlesNameTheOtherSession() {
        #expect(SessionMessageRow.title(.from, peer: "Ada") == "From Ada")
        #expect(SessionMessageRow.title(.to, peer: "Bea") == "To Bea")
        #expect(SessionMessageRow.title(.from, peer: "Alloy") == "From Alloy")
    }

    @Test func aSystemRowNeverTakesASessionColour() async {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        a.name = "Alloy"   // a legacy name that predates the reservation
        let sessions = rig.workspace.sessions
        #expect(SessionMessageRow.colorIndex(.system, peer: "Alloy", peerID: nil, sessions: sessions) == nil)
        #expect(SessionMessageRow.colorIndex(.from, peer: "Alloy", peerID: a.id, sessions: sessions) == a.colorIndex)
        #expect(SessionMessageRow.title(.system, peer: "Alloy") == "From Alloy")
    }

    @Test func bothChatsRenderTheRow() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        let b = await rig.workspace.newSession(name: "Bea")
        if case .failure(let e) = rig.workspace.deliverSessionMessage(from: a.id, to: b.id, text: "hello Bea") { Issue.record("\(e)") }
        await rig.workspace.settle()
        let rowID = try #require(b.transcript.blocks.first?.id)
        #expect(rowID.hasPrefix("session-message-"))
        rig.workspace.selectedSessionID = b.id
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "block-\(rowID)")) != nil }
        #expect(try shown(window, "session-message-title-\(rowID)") == "From Ada")
        #expect(try shown(window, "session-message-text-\(rowID)") == "hello Bea")
        let mineID = try #require(a.transcript.blocks.first?.id)
        rig.workspace.selectedSessionID = a.id
        try await window.runUntil { (try? window.element(identifier: "block-\(mineID)")) != nil }
        #expect(try shown(window, "session-message-title-\(mineID)") == "To Bea")
    }
}
