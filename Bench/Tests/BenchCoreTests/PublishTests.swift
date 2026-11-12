import Testing
import Foundation
@testable import BenchCore

@Suite struct PublishTests {
    static let scrubber = Scrubber(home: "/home/tester", userName: "tester")

    static func complete(notes: [String] = []) -> RunResult {
        var outcomes: [String: [Metric: Outcome]] = ["zed": [:], "alloy": [:]]
        for m in Metric.allCases {
            outcomes["zed"]?[m] = ParityTests.m(248.5, 268.2)
            outcomes["alloy"]?[m] = ParityTests.m(248.5, 268.2)
        }
        outcomes["alloy"]?[.startup] = ParityTests.m(193.5, 232.6)
        return RunResult(environment: ResultsTests.env, apps: ["zed": "1.0", "alloy": "abc"],
                         outcomes: outcomes, harnessSHA: "abc1234", notes: notes)
    }

    @Test func scrubsHomeAndTempPaths() {
        let s = Self.scrubber
        #expect(s.scrub("leftover process: Alloy pid 9 (/home/tester/dev/Alloy/.build/release/Alloy) x")
                == "leftover process: Alloy pid 9 (~/dev/Alloy/.build/release/Alloy) x")
        #expect(s.scrub("run 2: cannot read /private/var/folders/ab/xyz/T/bench-1/small.rs")
                == "run 2: cannot read <tmp>")
        #expect(s.scrub("in /tmp/bench-2/a.swift and /var/folders/q/T/z, /private/tmp/y") == "in <tmp> and <tmp>, <tmp>")
    }

    @Test func scrubsEveryStringInAResult() {
        var r = Self.complete(notes: ["at /home/tester/x"])
        r.outcomes["zed"]?[.memory] = .measured(Summary(count: 1, median: 1, p95: 1, min: 1, max: 1, unit: "MiB"),
            samples: [1], notes: ["n /home/tester/a"], failures: ["f /tmp/b"])
        r.outcomes["zed"]?[.idleCPU] = .notMeasured("why /home/tester/c")
        let s = Self.scrubber.scrub(r)
        #expect(s.notes == ["at ~/x"])
        #expect(s.outcomes["zed"]?[.idleCPU] == .notMeasured("why ~/c"))
        guard case .measured(_, _, let n, let f)? = s.outcomes["zed"]?[.memory] else { Issue.record("x"); return }
        #expect(n == ["n ~/a"]); #expect(f == ["f <tmp>"])
    }

    @Test func refusesAttributedRuns() throws {
        var r = Self.complete()
        r.attributed = true
        do { _ = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: true); Issue.record("no throw") }
        catch {
            #expect(error == .attributed)
            #expect(error.description == "runs made with --attribute are for triage only; rerun without it to publish")
        }
        // The flag survives a JSON round trip; older JSON without it decodes as not attributed.
        let back = try JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(r))
        #expect(back.attributed)
        #expect(try !JSONDecoder().decode(RunResult.self, from: JSONEncoder().encode(Self.complete())).attributed)
    }

    @Test func stripsAttributionNotesFromPublishedOutcomes() throws {
        var r = Self.complete()
        let s = Summary(count: 1, median: 1, p95: 1, min: 1, max: 1, unit: "ms")
        r.outcomes["alloy"]?[.typingLatency] = .measured(s, samples: [1],
            notes: [FrameTimingSummary.notePrefix + "key, 3 frames): build 3.0 ms median", "kept"], failures: [])
        let p = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: false)
        let text = String(decoding: p.json, as: UTF8.self)
        #expect(!text.contains("Alloy internal"))
        #expect(text.contains("kept"))
    }

    @Test func refusesWhenUserNameRemains() {
        let r = Self.complete(notes: ["covered by Tester's window"])
        do { _ = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: false); Issue.record("no throw") }
        catch { guard case .leak(let hits) = error else { Issue.record("wrong \(error)"); return }
            #expect(hits.contains { $0.lowercased().contains("tester") }) }
    }

    @Test func leaksFindsSessionLinksAndOtherHomes() {
        let s = Self.scrubber
        #expect(!s.leaks(in: "see https://" + "claude.ai" + "/code/" + "session_" + "abc12345").isEmpty)
        #expect(!s.leaks(in: "/Us" + "ers/someone/x").isEmpty)
        #expect(!s.leaks(in: "/home/tester/x").isEmpty)
        #expect(s.leaks(in: "~/dev and <tmp> and /Users/ alone").isEmpty)
    }

    @Test func refusesPartialRunByDefault() throws {
        var noAlloy = Self.complete(); noAlloy.outcomes["alloy"] = nil
        var noIdle = Self.complete(); noIdle.outcomes["zed"]?[.idleCPU] = nil
        for r in [noAlloy, noIdle] {
            do { _ = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: false); Issue.record("no throw") }
            catch { guard case .partial = error else { Issue.record("wrong \(error)"); return } }
            let ok = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: true)
            #expect(ok.entry.partial)
        }
        let full = try Publisher.prepare(Self.complete(), scrubber: Self.scrubber, allowPartial: false)
        #expect(!full.entry.partial)
    }

    @Test func refusesCoverRefusedAndAbortedRuns() {
        var refused = Self.complete()
        for m in Metric.allCases { refused.outcomes["zed"]?[m] = .notMeasured(RunMarkers.refusedPrefix + "window covered") }
        var aborted = Self.complete()
        aborted.outcomes["alloy"]?[.memory] = .notMeasured(RunMarkers.abortedPrefix + "window covered")
        for r in [refused, aborted] {
            do { _ = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: false); Issue.record("no throw") }
            catch { guard case .partial = error else { Issue.record("wrong \(error)"); return } }
        }
    }

    @Test func alloyShortfallIsNotPartial() throws {
        var r = Self.complete()
        r.outcomes["alloy"]?[.scrollFrames] = .notApplicable("no scroll")
        r.outcomes["alloy"]?[.memory] = .notMeasured("all runs failed")
        let e = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: false).entry
        #expect(!e.partial)
        #expect(e.verdicts["scrollFrames"] == "missing")
        #expect(e.verdicts["memory"] == "missing")
    }

    @Test func publishedEnvironmentIsTrimmed() throws {
        let p = try Publisher.prepare(Self.complete(), scrubber: Self.scrubber, allowPartial: false)
        let obj = try #require(JSONSerialization.jsonObject(with: p.json) as? [String: Any])
        let env = try #require(obj["environment"] as? [String: Any])
        #expect(Set(env.keys) == ["date", "time", "machine", "macOS", "refreshHz", "cold"])
        let back = try JSONDecoder().decode(RunResult.self, from: p.json)
        #expect(back.environment.machine == "Mac16,1")
        #expect(back.environment.cold == true)
    }

    @Test func boundariesAndKeys() {
        let s = Self.scrubber
        #expect(s.scrub("/home/testerX/a /home/tester") == "/home/testerX/a ~")
        #expect(s.scrub("/foo/tmp/x") == "/foo/tmp/x")
        #expect(s.leaks(in: "{\"testers\": \"contested\"}").isEmpty)
        #expect(!s.leaks(in: "{\"k\": \"by Tester\"}").isEmpty)
    }

    @Test func trailingSentencePeriodIsABoundary() throws {
        let s = Self.scrubber
        #expect(s.scrub("see /home/tester. Then /home/tester/a.txt, and /home/tester.bak") == "see ~. Then ~/a.txt, and /home/tester.bak")
        let r = Self.complete(notes: ["failed under /home/tester."])
        let e = try Publisher.prepare(r, scrubber: s, allowPartial: false)
        #expect(!String(decoding: e.json, as: UTF8.self).contains("/home/tester"))
    }

    @Test func refusesUnknownSchema() {
        var r = Self.complete(); r.schemaVersion = 2
        do { _ = try Publisher.prepare(r, scrubber: Self.scrubber, allowPartial: true); Issue.record("no throw") }
        catch { #expect(error == .schema(2)) }
    }

    @Test func entryCarriesVerdicts() throws {
        let e = try Publisher.prepare(Self.complete(), scrubber: Self.scrubber, allowPartial: false).entry
        #expect(e.verdicts["startup"] == "ahead")
        #expect(e.verdicts["memory"] == "par")
        #expect(e.stem == Report.fileStem(Self.complete()))
        #expect(e.date == "2026-11-08")
        #expect(e.verdicts.count == Metric.allCases.count)
    }

    @Test func upsertSortsAndReplaces() {
        func e(_ s: String, _ sha: String) -> PublishedEntry {
            PublishedEntry(stem: s, date: "d", harnessSHA: sha, apps: [:], partial: false, verdicts: [:])
        }
        var i = PublishedIndex(schemaVersion: 1, runs: [])
        i.upsert(e("b", "1")); i.upsert(e("a", "1")); i.upsert(e("b", "2"))
        #expect(i.runs.map(\.stem) == ["a", "b"])
        #expect(i.runs[1].harnessSHA == "2")
    }

    @Test func publishedFolderHasNoLeaks() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("published")
        let s = Scrubber(home: NSHomeDirectory(), userName: NSUserName())
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for f in files where f.lastPathComponent != ".gitkeep" {
            let text = String(decoding: try Data(contentsOf: f), as: UTF8.self)
            #expect(s.leaks(in: text).isEmpty, "\(f.lastPathComponent)")
        }
    }
}
