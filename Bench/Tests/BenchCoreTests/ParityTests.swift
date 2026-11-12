import Testing
import Foundation
@testable import BenchCore

@Suite struct ParityTests {
    static func result(zed: Outcome, alloy: Outcome, metric: Metric) -> RunResult {
        RunResult(environment: ResultsTests.env, apps: [:], outcomes: ["zed": [metric: zed], "alloy": [metric: alloy]])
    }
    static func m(_ median: Double, _ p95: Double, unit: String = "ms") -> Outcome {
        .measured(Summary(count: 5, median: median, p95: p95, min: median, max: p95, unit: unit),
                  samples: [median, p95], notes: [], failures: [])
    }

    @Test func aheadWhenBothStatsClearlyLower() {
        let r = Self.result(zed: Self.m(248.5, 268.2), alloy: Self.m(193.5, 232.6), metric: .startup)
        #expect(Parity.judge(r, metric: .startup) == .ahead)
    }

    @Test func withinFloorIsPar() {
        let r = Self.result(zed: Self.m(12.1, 12.4), alloy: Self.m(12.3, 12.6), metric: .typingLatency)
        #expect(Parity.judge(r, metric: .typingLatency) == .par)
    }

    @Test func p95BehindIsBehind() {
        let r = Self.result(zed: Self.m(12.0, 18.0), alloy: Self.m(12.0, 30.0), metric: .typingLatency)
        guard case .behind(let why) = Parity.judge(r, metric: .typingLatency) else {
            Issue.record("expected behind"); return
        }
        #expect(why.contains("p95"))
        #expect(why.contains("30.0"))
        #expect(why.contains("18.0"))
    }

    @Test func medianOnlyBarIgnoresP95() {
        let r = Self.result(zed: Self.m(12.0, 18.0), alloy: Self.m(12.0, 30.0), metric: .typingLatency)
        var bar = ParityBar.default
        bar.judgeP95 = false
        #expect(Parity.judge(r, metric: .typingLatency, bar: bar) == .par)
    }

    @Test func medianBehindMentionsMedianAndValues() {
        let r = Self.result(zed: Self.m(12.1, 12.4), alloy: Self.m(14.2, 14.5), metric: .typingLatency)
        #expect(Parity.judge(r, metric: .typingLatency) == .behind("median 14.2 ms vs Zed 12.1 ms"))
    }

    @Test func alloyMissingIsShortfall() {
        let r = Self.result(zed: Self.m(10, 11), alloy: .notMeasured("all runs failed: x"), metric: .startup)
        let v = Parity.judge(r, metric: .startup)
        guard case .missing(let why) = v else { Issue.record("expected missing"); return }
        #expect(why.contains("all runs failed"))
        #expect(Parity.isShortfall(v))
    }

    @Test func zedNotMeasuredIsUnjudged() {
        let r = Self.result(zed: .notMeasured("zed absent"), alloy: Self.m(10, 11), metric: .startup)
        let v = Parity.judge(r, metric: .startup)
        guard case .unjudged(let why) = v else { Issue.record("expected unjudged"); return }
        #expect(why.contains("zed absent"))
        #expect(!Parity.isShortfall(v))
    }

    @Test func unitFloorsApply() {
        let zed = Self.m(39.0, 39.0, unit: "MiB")
        #expect(Parity.judge(Self.result(zed: zed, alloy: Self.m(40.9, 40.9, unit: "MiB"), metric: .memory), metric: .memory) == .par)
        #expect(Parity.judge(Self.result(zed: zed, alloy: Self.m(41.5, 41.5, unit: "MiB"), metric: .memory), metric: .memory)
                == .behind("median 41.5 MiB vs Zed 39.0 MiB"))
    }

    @Test func judgeAllCoversEveryMetricWithBothSides() {
        let r = Self.result(zed: Self.m(10, 11), alloy: Self.m(10, 11), metric: .startup)
        let all = Parity.judgeAll(r)
        #expect(all[.startup] == .par)
        #expect(all[.memory] == nil)
    }
}
