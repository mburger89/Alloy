import Foundation
import Testing
@testable import AlloyCore

/// One edit can overlap several of another session's earlier edits; the other session's chat hears it once per minute.
@MainActor
@Suite struct OverlapNoticeDedupTests {
    private func setup() async -> (Env, editor: Session, other: Session) {
        let e = Env()
        let a = await e.ws.newSession(name: "Editor")
        let b = await e.ws.newSession(name: "Other")
        return (e, a, b)
    }

    private func item(_ key: String, _ lines: ClosedRange<Int>, other: Session) -> OverlapNotice.Item {
        OverlapNotice.Item(key: key, text: "t", other: .session(other.id), lines: lines)
    }

    private func notices(_ s: Session) -> [String] {
        s.transcript.blocks.compactMap { if case .notice(_, _, let t) = $0, t.contains("is editing") { t } else { nil } }
    }

    @Test func severalItemsInOneCallGiveOneNotice() async {
        let (e, a, b) = await setup(); defer { e.cleanup() }
        e.ws.recordOverlapWarnings(editor: a, path: "f.swift", told: [item("e1", 47...49, other: b), item("e2", 47...49, other: b),
                                                                      item("e3", 47...49, other: b)], lines: 47...49, tool: "Edit")
        #expect(notices(b).count == 1)
        #expect(e.ws.overlapWarnings.count == 3)      // the warning records are untouched
    }

    @Test func aRepeatWithinASixtySecondsStaysOneAndAfterItGivesASecond() async {
        let (e, a, b) = await setup(); defer { e.cleanup() }
        func tell(_ key: String) { e.ws.recordOverlapWarnings(editor: a, path: "f.swift", told: [item(key, 47...49, other: b)], lines: 47...49, tool: "Edit") }
        tell("e1")
        e.clock.advance(by: 30)
        tell("e2")
        #expect(notices(b).count == 1)
        e.clock.advance(by: 31)      // 61 s after the first
        tell("e3")
        #expect(notices(b).count == 2)
    }

    @Test func aDifferentSpanOrPathGetsItsOwnNotice() async {
        let (e, a, b) = await setup(); defer { e.cleanup() }
        e.ws.recordOverlapWarnings(editor: a, path: "f.swift", told: [item("e1", 47...49, other: b)], lines: 47...49, tool: "Edit")
        e.ws.recordOverlapWarnings(editor: a, path: "f.swift", told: [item("e2", 10...12, other: b)], lines: 10...12, tool: "Edit")
        e.ws.recordOverlapWarnings(editor: a, path: "g.swift", told: [item("e3", 47...49, other: b)], lines: 47...49, tool: "Edit")
        #expect(notices(b).count == 3)
    }
}
