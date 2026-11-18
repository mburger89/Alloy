import Testing
import Foundation
@testable import BenchCore

@Suite struct MergeTests {
    static let scrubber = Scrubber(home: "/home/tester", userName: "tester")

    static func startup(_ samples: [Double], notes: [String] = []) -> Outcome {
        .measured(Stats.summarize(samples, unit: "ms")!, samples: samples, notes: notes, failures: [])
    }

    static func env(date: String = "2026-11-08", time: String = "143005", machine: String = "Mac16,1",
                    onBattery: Bool = false) -> Environment {
        Environment(date: date, machine: machine, macOS: "26.0", refreshHz: 120, scale: 2,
                    onBattery: onBattery, cold: false, time: time, thermalState: "nominal")
    }

    static func counts(_ r: [String: [Metric: Outcome]]) -> [String: [Metric: RunCount]] {
        var out: [String: [Metric: RunCount]] = [:]
        for (app, by) in r { for (m, o) in by {
            if case .measured(_, let samples, _, _) = o {
                let n = m == .startup ? samples.count : 5
                out[app, default: [:]][m] = RunCount(requested: n, completed: n)
            }
        } }
        return out
    }

    /// base: zed, alloy, delta (delta startup n/a etc.); override: delta, alloy re-measured.
    static func base() -> RunResult {
        var o: [String: [Metric: Outcome]] = [:]
        for app in ["zed", "alloy", "delta"] {
            for m in Metric.allCases { o[app, default: [:]][m] = ParityTests.m(100, 120) }
        }
        o["zed"]?[.startup] = startup([300, 200, 210, 190, 220, 205])
        o["alloy"]?[.startup] = startup([400, 100, 120, 140, 160])
        o["delta"]?[.startup] = .notMeasured("window never appeared")
        o["delta"]?[.typingLatency] = .notApplicable("no editor")
        return RunResult(environment: env(), apps: ["zed": "1.0", "alloy": "aaa", "delta": "0.1"],
                         outcomes: o, harnessSHA: "sha1", runCounts: counts(o), notes: ["base note"])
    }

    static func override() -> RunResult {
        var o: [String: [Metric: Outcome]] = [:]
        for app in ["delta", "alloy"] {
            for m in Metric.allCases { o[app, default: [:]][m] = ParityTests.m(50, 60) }
        }
        o["delta"]?[.startup] = startup([90, 80, 70], notes: [RunMarkers.warmUpNote])
        o["alloy"]?[.startup] = startup([900, 800, 700, 600])
        return RunResult(environment: env(date: "2026-11-18", time: "091500"), apps: ["delta": "0.2", "alloy": "bbb"],
                         outcomes: o, harnessSHA: "sha1", runCounts: counts(o))
    }

    @Test func overrideTakesAllOutcomesForListedApps() throws {
        let b = Self.base(), o = Self.override()
        let m = try ResultMerger.merge(base: b, override: o, apps: ["delta"], dropFirstStartup: false)
        #expect(m.outcomes["delta"] == o.outcomes["delta"])
        #expect(m.apps["delta"] == "0.2")
        #expect(m.runCounts["delta"] == o.runCounts["delta"])
        // base kept for the others, including alloy (not listed)
        #expect(m.outcomes["zed"] == b.outcomes["zed"])
        #expect(m.outcomes["alloy"] == b.outcomes["alloy"])
        #expect(m.apps["alloy"] == "aaa")
    }

    @Test func defaultAppsAreEveryAppInOverride() throws {
        let o = Self.override()
        let m = try ResultMerger.merge(base: Self.base(), override: o, dropFirstStartup: false)
        #expect(m.outcomes["delta"] == o.outcomes["delta"])
        #expect(m.outcomes["alloy"] == o.outcomes["alloy"])
        #expect(m.apps["alloy"] == "bbb")
        #expect(m.outcomes["zed"] == Self.base().outcomes["zed"])
    }

    @Test func unknownAppRefused() {
        #expect(throws: ResultMerger.Refusal.unknownApp("vscode")) {
            try ResultMerger.merge(base: Self.base(), override: Self.override(), apps: ["vscode"], dropFirstStartup: false)
        }
    }

    @Test func environmentMismatchRefused() {
        for bad in [Self.env(date: "2026-11-18", time: "091500", machine: "Mac99,9"),
                    Self.env(date: "2026-11-18", time: "091500", onBattery: true)] {
            var o = Self.override(); o.environment = bad
            #expect(throws: (any Error).self) {
                try ResultMerger.merge(base: Self.base(), override: o, dropFirstStartup: false)
            }
        }
        var o = Self.override(); o.environment.refreshHz = 60
        #expect(throws: (any Error).self) { try ResultMerger.merge(base: Self.base(), override: o, dropFirstStartup: false) }
        o = Self.override(); o.environment.macOS = "26.1"
        #expect(throws: (any Error).self) { try ResultMerger.merge(base: Self.base(), override: o, dropFirstStartup: false) }
        o = Self.override(); o.environment.scale = 1
        #expect(throws: (any Error).self) { try ResultMerger.merge(base: Self.base(), override: o, dropFirstStartup: false) }
    }

    @Test func tracedAndAttributedRefused() {
        var o = Self.override(); o.traced = true
        #expect(throws: ResultMerger.Refusal.traced("override")) { try ResultMerger.merge(base: Self.base(), override: o, dropFirstStartup: true) }
        var b = Self.base(); b.attributed = true
        #expect(throws: ResultMerger.Refusal.attributed("base")) { try ResultMerger.merge(base: b, override: Self.override(), dropFirstStartup: true) }
    }

    @Test func firstSampleDroppedAndSummaryRecomputed() throws {
        let m = try ResultMerger.merge(base: Self.base(), override: Self.override(), apps: ["delta"], dropFirstStartup: true)
        // zed [300,200,210,190,220,205] -> [200,210,190,220,205]: sorted 190,200,205,210,220
        guard case .measured(let z, let zs, let zn, _)? = m.outcomes["zed"]?[.startup] else { Issue.record("zed"); return }
        #expect(zs == [200, 210, 190, 220, 205])
        #expect(z.count == 5); #expect(z.median == 205); #expect(z.p95 == 220); #expect(z.min == 190); #expect(z.max == 220)
        #expect(zn.contains(ResultMerger.dropNote))
        // alloy [400,100,120,140,160] -> [100,120,140,160]: median 130, p95 rank 4 -> 160
        guard case .measured(let a, _, _, _)? = m.outcomes["alloy"]?[.startup] else { Issue.record("alloy"); return }
        #expect(a.count == 4); #expect(a.median == 130); #expect(a.p95 == 160); #expect(a.min == 100)
    }

    @Test func warmedUpOutcomesAndOtherOutcomesUntouched() throws {
        let b = Self.base(), o = Self.override()
        let m = try ResultMerger.merge(base: b, override: o, apps: ["delta"], dropFirstStartup: true)
        #expect(m.outcomes["delta"]?[.startup] == o.outcomes["delta"]?[.startup])   // already warmed up
        #expect(m.runCounts["delta"]?[.startup] == o.runCounts["delta"]?[.startup])
        var all = Metric.allCases; all.removeAll { $0 == .startup }
        for app in ["zed", "alloy"] { for metric in all { #expect(m.outcomes[app]?[metric] == b.outcomes[app]?[metric]) } }
        let z = try ResultMerger.merge(base: b, override: o, apps: ["delta"], dropFirstStartup: true)
        #expect(z.outcomes["delta"]?[.typingLatency] == o.outcomes["delta"]?[.typingLatency])
        // base's own notMeasured / n/a outcomes survive when kept from base
        let m2 = try ResultMerger.merge(base: b, override: Self.override(), apps: ["alloy"], dropFirstStartup: true)
        #expect(m2.outcomes["delta"]?[.startup] == .notMeasured("window never appeared"))
        #expect(m2.outcomes["delta"]?[.typingLatency] == .notApplicable("no editor"))
    }

    @Test func runCountsStayConsistent() throws {
        let m = try ResultMerger.merge(base: Self.base(), override: Self.override(), apps: ["delta"], dropFirstStartup: true)
        #expect(m.runCounts["zed"]?[.startup] == RunCount(requested: 5, completed: 5))
        #expect(m.runCounts["alloy"]?[.startup] == RunCount(requested: 4, completed: 4))
        #expect(m.runCounts["delta"]?[.startup] == RunCount(requested: 3, completed: 3))  // warmed up: untouched
        #expect(m.runCounts["zed"]?[.memory] == RunCount(requested: 5, completed: 5))
        for (app, by) in m.outcomes { for (metric, o) in by {
            if case .measured(let s, let samples, _, _) = o, metric == .startup {
                #expect(m.runCounts[app]?[metric]?.completed == samples.count); #expect(s.count == samples.count)
            }
        } }
    }

    @Test func singleSampleBecomesNotMeasured() throws {
        var b = Self.base()
        b.outcomes["zed"]?[.startup] = Self.startup([250])
        b.runCounts["zed"]?[.startup] = RunCount(requested: 1, completed: 1)
        let m = try ResultMerger.merge(base: b, override: Self.override(), apps: ["delta"], dropFirstStartup: true)
        guard case .notMeasured? = m.outcomes["zed"]?[.startup] else { Issue.record("expected notMeasured"); return }
        #expect(m.runCounts["zed"]?[.startup] == RunCount(requested: 0, completed: 0))
    }

    @Test func notesAndMetadata() throws {
        var o = Self.override(); o.harnessSHA = "sha2"
        let m = try ResultMerger.merge(base: Self.base(), override: o, apps: ["delta", "alloy"], dropFirstStartup: false)
        #expect(m.notes.contains("base note"))
        #expect(m.notes.contains("merged from 2026-11-08-143005-Mac16,1 and 2026-11-18-091500-Mac16,1: delta, alloy from the latter"))
        #expect(m.notes.contains { $0.contains("sha1") && $0.contains("sha2") })
        #expect(m.harnessSHA == "sha2")
        #expect(m.environment.date == "2026-11-18"); #expect(m.environment.time == "091500")
        let same = try ResultMerger.merge(base: Self.base(), override: Self.override(), dropFirstStartup: false)
        #expect(!same.notes.contains { $0.hasPrefix("harness differs") })
        let d = try ResultMerger.merge(base: Self.base(), override: Self.override(), apps: ["delta"], dropFirstStartup: true)
        let startupNotes = d.outcomes.values.compactMap { by -> [String]? in
            if case .measured(_, _, let n, _)? = by[.startup] { return n } else { return nil } }
        #expect(startupNotes.filter { $0.contains(ResultMerger.dropNote) }.count == 2)  // zed, alloy; delta was warmed up
    }

    @Test func mergedResultRoundTripsPublishesAndRenders() throws {
        let m = try ResultMerger.merge(base: Self.base(), override: Self.override(), dropFirstStartup: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let back = try JSONDecoder().decode(RunResult.self, from: enc.encode(m))
        #expect(back == m)
        let prepared = try Publisher.prepare(back, scrubber: Self.scrubber, allowPartial: false)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pub = tmp.appendingPathComponent("pub"), site = tmp.appendingPathComponent("site")
        try FileManager.default.createDirectory(at: pub, withIntermediateDirectories: true)
        try prepared.json.write(to: pub.appendingPathComponent(prepared.entry.stem + ".json"))
        try enc.encode(PublishedIndex(runs: [prepared.entry])).write(to: pub.appendingPathComponent("index.json"))
        #expect(try SiteGenerator.generate(publishedDir: pub, out: site, iconSVG: nil) == 1)
        let html = try String(contentsOf: site.appendingPathComponent("benchmarks/index.html"), encoding: .utf8)
        #expect(html.contains("first timed launch excluded as warm-up"))
    }
}
