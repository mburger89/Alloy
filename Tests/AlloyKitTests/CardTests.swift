import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct CardTests {
    private static let questionRID = "40ef1a1e-119b-4077-9cb6-577187fdfd95"
    private static let planRID = "d259011a-7e47-48b0-9946-6fb1ff6ad28e"
    private static let deniedPlanRID = "19d2aa55-1a1d-40b6-8357-f365adb1bf1c"

    private func fixture(_ name: String) throws -> [Data] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { Data($0.utf8) }
    }

    /// A rig with one session that received `name.jsonl`, and a window showing element `identifier`.
    private func shown(_ name: String, waitFor identifier: String) async throws -> (Rig, TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        try await emit(try fixture(name), to: rig, session)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: identifier)) != nil }
        return (rig, window)
    }

    /// Emits a fixture followed by a sentinel text block and waits for the sentinel: the stream is ordered, so every
    /// fixture line has been applied by then and none can redraw the window while a test settles it.
    private func emit(_ lines: [Data], to rig: Rig, _ session: Session) async throws {
        let sentinel = "drained-\(UUID().uuidString)"
        await rig.transports[0].emit(fixture: lines)
        await rig.transports[0].emit(.assistantBlock(messageID: sentinel, block: .text(sentinel)))
        for _ in 0..<200_000 {
            if session.transcript.blocks.contains(where: { if case .assistantText(_, let t) = $0 { t == sentinel } else { false } }) { return }
            await Task.yield()
        }
        Issue.record("timed out draining the fixture")
        throw CancellationError()
    }

    private func click(_ window: TestWindow, _ identifier: String) throws {
        try window.click(window.element(identifier: identifier))
        window.tick()
    }

    private func lastAllowAnswers(_ rig: Rig) async -> [String: JSONValue]? {
        for message in await rig.transports[0].sent.reversed() {
            if case .allow(_, let input, _) = message { return input.objectValue?["answers"]?.objectValue }
        }
        return nil
    }

    private func texts(_ window: TestWindow, in identifier: String) throws -> [String] {
        let block = try window.element(identifier: identifier)
        return descendants(of: block, in: window).compactMap { $0.value ?? $0.label }
    }

    @Test func submitDisabledUntilAnswered() async throws {
        let rid = Self.questionRID
        let (rig, window) = try await shown("ask-question", waitFor: "q-submit-\(rid)")
        #expect(try window.element(identifier: "q-submit-\(rid)").isEnabled == false)
        try click(window, "q-opt-\(rid)-0-1")
        #expect(try window.element(identifier: "q-submit-\(rid)").isEnabled == false)
        try click(window, "q-opt-\(rid)-1-0")
        #expect(try window.element(identifier: "q-submit-\(rid)").isEnabled == true)
        #expect(await rig.transports[0].sentAfterInitialize.isEmpty)
    }

    @Test func multiSelectJoinsInOptionOrder() async throws {
        let rid = Self.questionRID
        let (rig, window) = try await shown("ask-question", waitFor: "q-submit-\(rid)")
        try click(window, "q-opt-\(rid)-0-1")
        try click(window, "q-opt-\(rid)-1-2")
        try click(window, "q-opt-\(rid)-1-0")
        try click(window, "q-submit-\(rid)")
        try await pollSent(rig, window) { $0.contains { if case .allow = $0 { true } else { false } } }
        let answers = await lastAllowAnswers(rig)
        #expect(answers?["Which language?"] == .string("Swift"))
        #expect(answers?["Which toolchains?"] == .string("pytest, mypy"))
        try await window.runUntil { (try? window.element(identifier: "q-submit-\(rid)")) == nil }
        let shown = try texts(window, in: "block-q-\(rid)")
        #expect(shown.contains { $0.contains("Swift") }, "\(shown)")
        #expect(shown.contains { $0.contains("pytest, mypy") }, "\(shown)")
    }

    @Test func singleSelectIsExclusive() async throws {
        let rid = Self.questionRID
        let (rig, window) = try await shown("ask-question", waitFor: "q-submit-\(rid)")
        try click(window, "q-opt-\(rid)-0-0")
        try click(window, "q-opt-\(rid)-0-1")
        try click(window, "q-opt-\(rid)-1-1")
        try click(window, "q-submit-\(rid)")
        try await pollSent(rig, window) { $0.contains { if case .allow = $0 { true } else { false } } }
        let answers = await lastAllowAnswers(rig)
        #expect(answers?["Which language?"] == .string("Swift"))
        #expect(answers?["Which toolchains?"] == .string("ruff"))
    }

    @Test func otherTextIsSent() async throws {
        let rid = Self.questionRID
        let (rig, window) = try await shown("ask-question", waitFor: "q-submit-\(rid)")
        try window.typeText("Rust", into: window.element(identifier: "q-other-\(rid)-0"))
        window.tick()
        try click(window, "q-opt-\(rid)-1-0")
        try window.typeText("black", into: window.element(identifier: "q-other-\(rid)-1"))
        window.tick()
        try click(window, "q-submit-\(rid)")
        try await pollSent(rig, window) { $0.contains { if case .allow = $0 { true } else { false } } }
        let answers = await lastAllowAnswers(rig)
        #expect(answers?["Which language?"] == .string("Rust"))
        #expect(answers?["Which toolchains?"] == .string("pytest, black"))
    }

    @Test func approveSendsDefaultMode() async throws {
        let rid = Self.planRID
        let (rig, window) = try await shown("plan-allow", waitFor: "plan-approve-\(rid)")
        try click(window, "plan-approve-\(rid)")
        try await pollSent(rig, window) { $0.contains { if case .allow(let id, _, _) = $0 { id == rid } else { false } } }
        #expect(await modeAfter(rig, rid) == "default")
        try await window.runUntil { (try? window.element(identifier: "plan-approve-\(rid)")) == nil }
    }

    @Test func approveWithEditsSendsAcceptEdits() async throws {
        let rid = Self.planRID
        let (rig, window) = try await shown("plan-allow", waitFor: "plan-approve-edits-\(rid)")
        try click(window, "plan-approve-edits-\(rid)")
        try await pollSent(rig, window) { $0.contains { if case .allow(let id, _, _) = $0 { id == rid } else { false } } }
        #expect(await modeAfter(rig, rid) == "acceptEdits")
    }

    private func modeAfter(_ rig: Rig, _ rid: String) async -> String? {
        for message in await rig.transports[0].sent.reversed() {
            if case .allow(let id, _, let permissions) = message, id == rid {
                return permissions?.first?.objectValue?["mode"]?.stringValue
            }
        }
        return nil
    }

    @Test func sendBackSendsFeedback() async throws {
        let rid = Self.planRID
        let (rig, window) = try await shown("plan-allow", waitFor: "plan-sendback-\(rid)")
        #expect((try? window.element(identifier: "plan-feedback-\(rid)")) == nil)
        try click(window, "plan-sendback-\(rid)")
        try await window.runUntil { (try? window.element(identifier: "plan-feedback-\(rid)")) != nil }
        try window.typeText("add tests", into: window.element(identifier: "plan-feedback-\(rid)"))
        window.tick()
        try click(window, "plan-send-\(rid)")
        try await pollSent(rig, window) { $0.last == .deny(requestID: rid, message: "Revise: add tests") }
        try await window.runUntil { (try? window.element(label: "Sent back: add tests")) != nil }
    }

    @Test func secondPlanCardAfterRevision() async throws {
        let first = Self.deniedPlanRID, second = Self.planRID
        let (rig, window) = try await shown("plan-deny", waitFor: "plan-sendback-\(first)")
        try click(window, "plan-sendback-\(first)")
        try await window.runUntil { (try? window.element(identifier: "plan-feedback-\(first)")) != nil }
        try window.typeText("shorter", into: window.element(identifier: "plan-feedback-\(first)"))
        window.tick()
        try click(window, "plan-send-\(first)")
        try await pollSent(rig, window) { $0.last == .deny(requestID: first, message: "Revise: shorter") }
        let revised = try fixture("plan-allow").filter { String(decoding: $0, as: UTF8.self).contains("control_request") }
        try await emit(revised, to: rig, rig.workspace.sessions[0])
        try await window.runUntil { (try? window.element(identifier: "plan-approve-\(second)")) != nil }
        #expect((try? window.element(identifier: "plan-approve-\(first)")) == nil)
        #expect((try? window.element(label: "Sent back: shorter")) != nil)
        try click(window, "plan-approve-\(second)")
        try await pollSent(rig, window) { $0.contains { if case .allow(let id, _, _) = $0 { id == second } else { false } } }
    }

    @Test func otherRowTapFocusesItsField() async throws {
        let rid = Self.questionRID
        let (_, window) = try await shown("ask-question", waitFor: "q-submit-\(rid)")
        try click(window, "q-other-row-\(rid)-0")
        window.typeText("Rust")
        window.tick()
        #expect(try window.element(identifier: "q-other-\(rid)-0").value == "Rust")
    }

    /// A rig with a pending question (pick + Other text) and a pending plan (feedback editor open with text).
    private func draftedRig() async throws -> (Rig, Session, TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        try await emit(try fixture("ask-question"), to: rig, session)
        let plan = try fixture("plan-allow").filter { String(decoding: $0, as: UTF8.self).contains("control_request") }
        try await emit(plan, to: rig, session)
        let window = try alloyWindow(rig.workspace)
        let q = Self.questionRID, p = Self.planRID
        try await window.runUntil { (try? window.element(identifier: "plan-sendback-\(p)")) != nil }
        #expect(try reveal(window, "q-opt-\(q)-0-1"))
        try click(window, "q-opt-\(q)-0-1")
        try click(window, "q-opt-\(q)-1-0")
        try window.typeText("black", into: window.element(identifier: "q-other-\(q)-1"))
        #expect(try reveal(window, "plan-sendback-\(p)"))
        try click(window, "plan-sendback-\(p)")
        try await window.runUntil { (try? window.element(identifier: "plan-feedback-\(p)")) != nil }
        try window.typeText("add tests", into: window.element(identifier: "plan-feedback-\(p)"))
        window.tick()
        return (rig, session, window)
    }

    /// Scrolls the transcript until `identifier` has visible area; false when neither direction gets there.
    private func reveal(_ window: TestWindow, _ identifier: String) throws -> Bool {
        func visible() -> Bool {
            guard let e = try? window.element(identifier: identifier) else { return false }
            return e.visibleFrame.size.width.value > 0 && e.visibleFrame.size.height.value > 0
        }
        let centre = Point(x: Pixels(600), y: Pixels(300))
        for dy: Float in [500, -500] {
            for _ in 0..<40 {
                if visible() { return true }
                window.scroll(at: centre, byDeltaX: 0, deltaY: dy)
                window.tick()
            }
        }
        return visible()
    }

    private func expectDraftIntact(_ window: TestWindow) throws {
        let q = Self.questionRID, p = Self.planRID
        #expect(try reveal(window, "q-submit-\(q)"))
        #expect(try window.element(identifier: "q-submit-\(q)").isEnabled == true)
        #expect(try window.element(identifier: "q-other-\(q)-1").value == "black")
        #expect(try reveal(window, "plan-feedback-\(p)"))
        #expect(try window.element(identifier: "plan-feedback-\(p)").value == "add tests")
    }

    @Test func draftsSurviveTranscriptRerender() async throws {
        let (rig, session, window) = try await draftedRig()
        try await emit([], to: rig, session)
        await rig.transports[0].emit(.assistantBlock(messageID: "m-extra", block: .text("more output")))
        try await window.runUntil { (try? window.element(label: "more output")) != nil }
        try expectDraftIntact(window)
    }

    /// Switching to another session and back rebuilds the chat column; the card drafts live above it.
    @Test func draftsSurviveASessionSwitch() async throws {
        let (rig, session, window) = try await draftedRig()
        let other = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = other.id
        window.tick(); window.tick()
        #expect((try? window.element(identifier: "q-submit-\(Self.questionRID)")) == nil)
        rig.workspace.selectedSessionID = session.id
        window.tick(); window.tick()
        try expectDraftIntact(window)
    }

    /// The drafts are owned by the parent: a second binding over the same storage (a rebuilt row) reads the value back.
    @Test func draftsAreOwnedByTheParent() {
        var storage: [String: CardDraft] = [:]
        let drafts = Binding(get: { storage }, set: { storage = $0 })
        let first = TranscriptView.draftBinding(requestID: "r1", drafts: drafts)
        first.wrappedValue.picked[0] = [1]
        first.wrappedValue.feedback = "more tests"
        let rebuilt = TranscriptView.draftBinding(requestID: "r1", drafts: drafts)
        #expect(rebuilt.wrappedValue.picked[0] == [1])
        #expect(rebuilt.wrappedValue.feedback == "more tests")
        #expect(TranscriptView.draftBinding(requestID: "r2", drafts: drafts).wrappedValue == CardDraft())
    }
}

@MainActor
private func pollSent(_ rig: Rig, _ window: TestWindow, _ predicate: ([OutboundMessage]) -> Bool) async throws {
    for _ in 0..<200_000 {
        if predicate(await rig.transports[0].sent) { return }
        window.tick()
        await Task.yield()
    }
    Issue.record("timed out waiting for outbound message")
    throw CancellationError()
}
