import Testing
import Foundation
@testable import BenchCore
@testable import BenchScenarios

@Suite struct ResultsTests {
    static func summary(_ m: Double, p95: Double) -> Summary {
        Summary(count: 5, median: m, p95: p95, min: m, max: p95, unit: "ms")
    }
    static func measured(_ m: Double, p95: Double, notes: [String] = [], failures: [String] = []) -> Outcome {
        .measured(summary(m, p95: p95), samples: [m, p95], notes: notes, failures: failures)
    }
    static let env = Environment(date: "2026-11-08", machine: "Mac16,1", macOS: "26.0",
                                 refreshHz: 120, scale: 2, onBattery: false, cold: true,
                                 time: "143005", thermalState: "nominal")

    @Test func resultsRoundTripJSON() throws {
        let r = RunResult(environment: Self.env,
            apps: ["zed": "1.27.0", "delta": "0.1.0", "alloy": "abc"],
            outcomes: ["zed": [.startup: Self.measured(10, p95: 12, notes: ["a note"], failures: ["timeout"])],
                       "delta": [.typingLatency: .notApplicable("no editor")],
                       "alloy": [.memory: .notMeasured("purge needs sudo")]],
            harnessSHA: "abc1234",
            runCounts: ["zed": [.startup: RunCount(requested: 10, completed: 9)]],
            notes: ["leftover process: Zed pid 1"])
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(RunResult.self, from: data) == r)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"startup\""))
        #expect(json.contains("\"typingLatency\""))
    }

    @Test func jsonShapeIsExplicit() throws {
        let r = RunResult(environment: Self.env, apps: [:],
            outcomes: ["zed": [.startup: Self.measured(10, p95: 12, notes: ["n1"], failures: ["f1"])],
                       "delta": [.scrollFrames: .notApplicable("why")],
                       "alloy": [.memory: .notMeasured("because")]],
            harnessSHA: "abc1234", runCounts: ["zed": [.startup: RunCount(requested: 10, completed: 9)]])
        let obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        #expect(obj["schemaVersion"] as? Int == 1)
        #expect(obj["harnessSHA"] as? String == "abc1234")
        let rc = (obj["runCounts"] as? [String: Any])?["zed"] as? [String: Any]
        #expect((rc?["startup"] as? [String: Int]) == ["requested": 10, "completed": 9])
        let outs = try #require(obj["outcomes"] as? [String: [String: [String: Any]]])
        let m = try #require(outs["zed"]?["startup"])
        #expect(m["status"] as? String == "measured")
        #expect((m["summary"] as? [String: Any])?["median"] as? Double == 10)
        #expect(m["samples"] as? [Double] == [10, 12])
        #expect(m["notes"] as? [String] == ["n1"])
        #expect(m["failures"] as? [String] == ["f1"])
        #expect(outs["delta"]?["scrollFrames"]?["status"] as? String == "notApplicable")
        #expect(outs["delta"]?["scrollFrames"]?["reason"] as? String == "why")
        #expect(outs["alloy"]?["memory"]?["status"] as? String == "notMeasured")
        #expect(outs["alloy"]?["memory"]?["reason"] as? String == "because")
        let env = try #require(obj["environment"] as? [String: Any])
        #expect(env["thermalState"] as? String == "nominal")
    }

    @Test func markdownTableHasOneRowPerMetricAndColumnPerApp() {
        let r = RunResult(environment: Self.env, apps: [:],
            outcomes: ["zed": [.startup: Self.measured(12.3, p95: 15.0)],
                       "delta": [.startup: .notApplicable("x")]])
        let md = Report.markdown(r)
        #expect(md.contains("| Metric | Zed | Delta | Alloy | Note |"))
        #expect(md.contains("|---|---|---|---|---|"))
        #expect(md.contains("n/a (x)"))
        #expect(md.contains("12.3 ms (p95 15.0)"))
        for m in Metric.allCases { #expect(md.contains("| \(m.rawValue) |")) }
        #expect(Metric.allCases.contains(.memoryIdle))
    }

    @Test func everyRowHasTheSameColumnCountSoGFMRenders() {
        let r = RunResult(environment: Self.env, apps: [:],
            outcomes: ["zed": [.startup: Self.measured(10, p95: 11)], "alloy": [.startup: Self.measured(20, p95: 25)]])
        for line in Report.markdown(r).split(separator: "\n") where line.hasPrefix("|") {
            #expect(line.filter { $0 == "|" }.count == 6, "\(line)")
        }
    }

    @Test func noteColumnShowsVerdict() {
        let r = RunResult(environment: Self.env, apps: [:],
            outcomes: ["zed": [.startup: Self.measured(10, p95: 11), .memory: Self.measured(10, p95: 11),
                               .typingLatency: Self.measured(10, p95: 11), .scrollFrames: Self.measured(10, p95: 11)],
                       "alloy": [.startup: Self.measured(20, p95: 25), .memory: Self.measured(5, p95: 6),
                                 .typingLatency: Self.measured(10, p95: 11), .scrollFrames: .notMeasured("all runs failed")]])
        let lines = Report.markdown(r).split(separator: "\n").map(String.init)
        let startup = lines.first { $0.hasPrefix("| startup |") }!
        #expect(startup.contains("⚠ behind Zed"))
        #expect(startup.contains("median 20.0 ms vs Zed 10.0 ms"))
        #expect(lines.first { $0.hasPrefix("| memory |") }!.contains("ahead"))
        #expect(lines.first { $0.hasPrefix("| typingLatency |") }!.contains("par"))
        #expect(lines.first { $0.hasPrefix("| scrollFrames |") }!.contains("⚠ missing"))
        #expect(lines.first { $0.hasPrefix("| largeFileOpen |") }!.hasSuffix("|  |"))
    }

    @Test func notesAreNotCountedAsFailures() {
        let r = RunResult(environment: Self.env, apps: [:],
            outcomes: ["zed": [.startup: Self.measured(10, p95: 11, notes: ["window on screen: median 5 ms", "dropped"]),
                               .memory: Self.measured(10, p95: 11, failures: ["run 2: boom"])]])
        let lines = Report.markdown(r).split(separator: "\n").map(String.init)
        #expect(!lines.first { $0.hasPrefix("| startup |") }!.contains("failed"))
        #expect(lines.first { $0.hasPrefix("| memory |") }!.contains("1 failed"))
    }

    @Test func cellTextEscapesPipesAndNewlines() {
        let r = RunResult(environment: Self.env, apps: [:],
            outcomes: ["zed": [.startup: .notMeasured("a|b\nc")]])
        let line = Report.markdown(r).split(separator: "\n").first { $0.hasPrefix("| startup |") }!
        #expect(line.contains("a\\|b c"))
        #expect(line.replacingOccurrences(of: "\\|", with: "").filter { $0 == "|" }.count == 6)
    }

    @Test func fileStemIncludesTime() {
        let r = RunResult(environment: Self.env, apps: [:], outcomes: [:])
        #expect(Report.fileStem(r) == "2026-11-08-143005-Mac16,1")
    }

    @Test func schemaVersionAndEnvironmentAreInTheMarkdown() {
        let r = RunResult(environment: Self.env, apps: [:], outcomes: [:], harnessSHA: "abc1234", notes: ["leftover process: x"])
        let md = Report.markdown(r)
        #expect(md.contains("abc1234"))
        #expect(md.contains("nominal"))
        #expect(md.contains("leftover process: x"))
    }

    @Test func runCountsDeriveFromOutcomes() {
        let o: [String: [Metric: Outcome]] = [
            "zed": [.startup: Self.measured(1, p95: 2, failures: ["run 3: x"]), .memory: .notMeasured("all failed"),
                    .scrollFrames: .notApplicable("n")]]
        let c = Runner.runCounts(outcomes: o, requested: { _ in 10 })
        #expect(c["zed"]?[.startup] == RunCount(requested: 10, completed: 9))
        #expect(c["zed"]?[.memory] == RunCount(requested: 10, completed: 0))
        #expect(c["zed"]?[.scrollFrames] == nil)
    }

    @Test func idleMemoryOutcomeSharesFailuresAndNotMeasuredWhenEmpty() {
        let cpu = Self.measured(1, p95: 2, failures: ["run 2: x"])
        guard case .measured(let s, let samples, let notes, let failures) = IdleCPUScenario.memoryOutcome(cpu: cpu, samples: [100, 120]) else {
            Issue.record("expected measured"); return
        }
        #expect(s.unit == "MiB" && s.median == 110 && samples == [100, 120] && failures == ["run 2: x"] && !notes.isEmpty)
        #expect(IdleCPUScenario.memoryOutcome(cpu: .notMeasured("all runs failed"), samples: []) == .notMeasured("all runs failed"))
    }

    @Test func addingNotesAppendsToNotesNotFailures() {
        let o = Self.measured(1, p95: 2, notes: ["a"], failures: ["f"]).addingNotes(["Delta has no isolation flag"])
        guard case .measured(_, _, let notes, let failures) = o else { return }
        #expect(notes == ["a", "Delta has no isolation flag"] && failures == ["f"])
        #expect(Outcome.notApplicable("x").addingNotes(["n"]) == .notApplicable("x"))
    }
}
