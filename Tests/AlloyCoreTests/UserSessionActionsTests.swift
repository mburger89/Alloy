import Testing
@testable import AlloyCore

/// The "+" button and ⌘N create a session and switch to it; restore and theme paths keep the old rule.
@MainActor
@Suite struct UserSessionActionsTests {
    @Test func newSessionFromUserSelectsTheNewSession() async {
        let e = Env(); defer { e.cleanup() }
        let first = await e.ws.newSessionFromUser(name: "One")
        #expect(e.ws.selectedSessionID == first.id)
        let second = await e.ws.newSessionFromUser(name: "Two")
        #expect(e.ws.selectedSessionID == second.id)
    }

    @Test func plainNewSessionStillKeepsTheSelection() async {
        let e = Env(); defer { e.cleanup() }
        let first = await e.ws.newSession(name: "One")
        _ = await e.ws.newSession(name: "Two")
        #expect(e.ws.selectedSessionID == first.id)
    }
}
