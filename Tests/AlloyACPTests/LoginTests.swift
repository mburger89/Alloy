import AlloyCore
import Foundation
import Testing
@testable import AlloyACP

@Suite struct LoginTests {
    private let authErr = #"{"send":{"jsonrpc":"2.0","id":"$id","error":{"code":-32000,"message":"Authentication required"}}}"#

    private func answer(_ rig: Rig, label: String) async throws -> String {
        #expect(await waitUntil { !rig.events.controlRequests.isEmpty })
        let req = try #require(rig.events.controlRequests.last)
        guard case .canUseTool(let name, let input, _, _, _) = req.kind else { Issue.record("not a card"); return "" }
        #expect(name == "AskUserQuestion")
        let question = input["questions"]?.arrayValue?.first?["question"]?.stringValue ?? ""
        try await rig.transport.send(.allow(requestID: req.requestID,
                                            updatedInput: .object(["answers": .object([question: .string(label)])])))
        return req.requestID
    }

    @Test func authRequiredShowsCardAndAuthenticateRetries() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#,
            hsInit("{}", auth: #"[{"id":"m1","name":"Sign in with the agent"},{"id":"m2","name":"Use a key"}]"#),
            #"{"expect":"session/new"}"#, authErr,
            #"{"expect":"authenticate"}"#, hsOK,
            #"{"expect":"session/new"}"#, hsNew, #"{"sleep":3000}"#,
        ])
        #expect(await waitUntil { !r.events.controlRequests.isEmpty })
        let card = try #require(r.events.controlRequests.first)
        guard case .canUseTool(_, let input, _, _, _) = card.kind else { return }
        let labels = input["questions"]?.arrayValue?.first?["options"]?.arrayValue?.compactMap { $0["label"]?.stringValue }
        #expect(labels == ["Sign in with the agent", "Use a key"])
        #expect(!r.events.hasSystemInit)
        _ = try await answer(r, label: "Use a key")
        #expect(await waitUntil { r.events.hasSystemInit })
        #expect(r.lines("authenticate").count == 1 && r.lines("authenticate")[0].contains(#""methodId":"m2""#))
        #expect(r.lines("session/new").count == 2)
        await r.stop()
    }

    @Test func authRequiredWithNoMethodsIsAPlainError() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit("{}"), #"{"expect":"session/new"}"#, authErr, #"{"sleep":3000}"#,
        ])
        #expect(await waitUntil { r.events.notices.contains { $0.contains("needs you to sign in") } })
        #expect(r.events.controlRequests.isEmpty)
        await r.stop()
    }

    @Test func cancellingTheCardLeavesNoSession() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit("{}", auth: #"[{"id":"m1","name":"Sign in"}]"#),
            #"{"expect":"session/new"}"#, authErr, #"{"sleep":3000}"#,
        ])
        #expect(await waitUntil { !r.events.controlRequests.isEmpty })
        try await r.transport.send(.deny(requestID: r.events.controlRequests[0].requestID, message: "no"))
        #expect(await waitUntil { r.events.notices.contains { $0.contains("Sign-in cancelled") } })
        #expect(!r.events.hasSystemInit)
        await r.stop()
    }

    @Test func terminalMethodOpensTerminalTabAndReinitializes() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#,
            hsInit("{}", auth: #"[{"id":"t1","name":"Log in","type":"terminal","args":["login"],"env":{"AGENT_HOME":"/x"}}]"#),
            #"{"expect":"session/new"}"#, authErr, #"{"sleep":3000}"#,
        ])
        _ = try await answer(r, label: "Log in")
        #expect(await waitUntil { !r.events.otherRequests("acp_auth_terminal").isEmpty })
        let body = try #require(r.events.otherRequests("acp_auth_terminal").first)
        let command = body["command"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(command.last == "login" && command.first == fakeAgentPath)
        #expect(body["env"]?["AGENT_HOME"]?.stringValue == "/x")
        // The agent is not told to authenticate: the terminal does that.
        #expect(r.lines("authenticate").isEmpty)
        #expect(r.events.otherRequests("acp_reinitialize").isEmpty)
        // Back from the terminal: a second card, and answering it asks the workspace to re-initialize.
        _ = try await answer(r, label: "I've signed in")
        #expect(await waitUntil { !r.events.otherRequests("acp_reinitialize").isEmpty })
        await r.stop()
    }

    @Test func authFailureOnAPromptOffersTheCardAndSaysToSendAgain() async throws {
        let r = try await Rig.start([
            #"{"expect":"initialize"}"#, hsInit("{}", auth: #"[{"id":"m1","name":"Sign in"}]"#),
            #"{"expect":"session/new"}"#, hsNew,
            #"{"expect":"session/prompt"}"#, authErr,
            #"{"expect":"authenticate"}"#, hsOK, #"{"sleep":3000}"#,
        ])
        #expect(await waitUntil { r.events.hasSystemInit })
        try await r.transport.send(user("hello"))
        _ = try await answer(r, label: "Sign in")
        #expect(await waitUntil { r.events.notices.contains { $0.contains("Send your message again") } })
        await r.stop()
    }
}
