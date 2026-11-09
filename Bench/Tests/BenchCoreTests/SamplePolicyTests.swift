import Testing
import Foundation
@testable import BenchCore
@testable import BenchScenarios

/// Minimum-valid-sample rules: a median from a near-empty run is never published.
@Suite struct SamplePolicyTests {
    private struct Boom: Error, CustomStringConvertible { var description: String }

    @Test func typingBelowHalfIsNotMeasured() {
        let o = TypingLatencyScenario.outcome(samples: [12.1], total: 200, coveredBy: nil)
        #expect(o == .notMeasured("only 1 of 200 keystrokes produced a frame change"))
    }

    @Test func typingExactlyHalfIsMeasured() {
        let o = TypingLatencyScenario.outcome(samples: Array(repeating: 10, count: 100), total: 200, coveredBy: nil)
        guard case .measured(_, let samples, let notes, _) = o else { Issue.record("expected measured, got \(o)"); return }
        #expect(samples.count == 100)
        #expect(notes.contains { $0.contains("100 of 200 keystrokes produced no frame change") })
    }

    @Test func typingJustBelowHalfIsNotMeasured() {
        let o = TypingLatencyScenario.outcome(samples: Array(repeating: 10, count: 99), total: 200, coveredBy: nil)
        #expect(o == .notMeasured("only 99 of 200 keystrokes produced a frame change"))
    }

    @Test func typingCoverIsAppendedToTheReason() {
        let o = TypingLatencyScenario.outcome(samples: [], total: 200, coveredBy: "Ghostty")
        #expect(o == .notMeasured("only 0 of 200 keystrokes produced a frame change (covered by Ghostty)"))
    }

    @Test func survivorMetricsNeedThreeCompletedRuns() async {
        let o = await collect(runs: 5, unit: "ms") { i in
            if i < 3 { throw Boom(description: "boom \(i)") }
            return [1, 2, 3]
        }
        guard case .notMeasured(let why) = o else { Issue.record("expected notMeasured, got \(o)"); return }
        #expect(why.contains("only 2 of 5 runs completed (minimum 3; no median published)"))
        #expect(why.contains("run 1: boom 0") && why.contains("run 3: boom 2"))
    }

    @Test func threeCompletedRunsArePublished() async {
        let o = await collect(runs: 5, unit: "ms") { i in
            if i < 2 { throw Boom(description: "boom") }
            return [1, 2, 3]
        }
        guard case .measured(_, _, _, let failures) = o else { Issue.record("expected measured, got \(o)"); return }
        #expect(failures.count == 2)
    }

    @Test func minimumIsCappedByRequestedRuns() async {
        let o = await collect(runs: 1, unit: "ms") { _ in [4] }
        guard case .measured = o else { Issue.record("expected measured, got \(o)"); return }
        let bad = await collect(runs: 2, unit: "ms") { i in if i == 0 { throw Boom(description: "x") }; return [4] }
        guard case .notMeasured = bad else { Issue.record("expected notMeasured for 1 of 2, got \(bad)"); return }
    }

    @Test func allRunsFailedKeepsItsReason() async {
        let o = await collect(runs: 3, unit: "ms") { _ in throw Boom(description: "nope") }
        guard case .notMeasured(let why) = o else { Issue.record("expected notMeasured"); return }
        #expect(why.contains("nope"))
    }
}
