import Testing
import Foundation
@testable import BenchCore

@Suite struct SitePageTests {
    static func entry(_ r: RunResult, partial: Bool = false) -> PublishedEntry {
        PublishedEntry(stem: Report.fileStem(r), date: r.environment.date, harnessSHA: r.harnessSHA,
                       apps: r.apps, partial: partial, verdicts: [:])
    }

    static func page(_ runs: [RunResult], partial: Bool = false) -> String {
        var idx = PublishedIndex()
        for (i, r) in runs.enumerated() {
            var e = entry(r, partial: partial); e.stem = "run\(i)"; idx.upsert(e)
        }
        return SitePage.render(index: idx, runs: runs)
    }

    /// 7 metrics; alloy equals zed except those overridden.
    static func run(date: String = "2026-11-08", alloy: [Metric: Outcome] = [:]) -> RunResult {
        var r = PublishTests.complete()
        r.environment.date = date
        for m in Metric.allCases { r.outcomes["alloy"]?[m] = ParityTests.m(100, 120) ; r.outcomes["zed"]?[m] = ParityTests.m(100, 120) }
        for (m, o) in alloy { r.outcomes["alloy"]?[m] = o }
        return r
    }

    @Test func emptyIndexSaysNoResults() {
        let html = SitePage.render(index: PublishedIndex(), runs: [])
        #expect(html.contains("No published results yet."))
        #expect(!html.contains("<table"))
    }

    @Test func headlineCountsVerdicts() {
        // 7 metrics: 2 behind, 1 unjudged (zed not measured), 4 judged of which 2 are par.
        var r = Self.run(alloy: [.startup: ParityTests.m(300, 320), .memory: ParityTests.m(300, 320)])
        r.outcomes["zed"]?[.idleCPU] = .notMeasured("no zed")
        r.outcomes["zed"]?[.memoryIdle] = .notMeasured("no zed")
        r.outcomes["zed"]?[.largeFileOpen] = .notMeasured("no zed")
        let html = Self.page([r])
        #expect(html.contains("2 of 4 measured metrics"))
        let ok = Self.page([Self.run(alloy: [.startup: ParityTests.m(300, 320)])])
        #expect(ok.contains("6 of 7 measured metrics"))
    }

    @Test func missingRowShowsReason() {
        let r = Self.run(alloy: [.startup: .notMeasured("all runs failed: x")])
        let html = Self.page([r])
        #expect(html.contains("not measured — all runs failed: x"))
        #expect(html.contains("class=\"verdict missing\">missing"))
    }

    @Test func partialRunIsLabelled() {
        #expect(Self.page([Self.run()], partial: true).contains("partial run"))
        #expect(!Self.page([Self.run()]).contains("partial run"))
    }

    @Test func escapesHTML() {
        var r = Self.run()
        r.outcomes["alloy"]?[.startup] = .measured(Summary(count: 1, median: 1, p95: 1, min: 1, max: 1, unit: "ms"),
                                                    samples: [1], notes: ["<b>&"], failures: [])
        #expect(Self.page([r]).contains("&lt;b&gt;&amp;"))
    }

    @Test func noScriptsOrExternalResources() {
        let html = Self.page([Self.run(date: "2026-11-01"), Self.run(date: "2026-11-08")])
        for bad in ["<script", "http://", "https://"] { #expect(!html.contains(bad)) }
        for bad in ["<script", "http://", "https://"] { #expect(!SitePage.render(index: PublishedIndex(), runs: []).contains(bad)) }
    }

    @Test func chartNeedsTwoRuns() {
        #expect(SiteChart.svg(metric: .startup, runs: [Self.run()]) == nil)
        let svg = SiteChart.svg(metric: .startup, runs: [Self.run(date: "2026-11-01"), Self.run(date: "2026-11-08")])
        #expect(svg?.hasPrefix("<svg") == true)
        var noAlloy = Self.run(date: "2026-11-08"); noAlloy.outcomes["alloy"]?[.startup] = .notMeasured("x")
        #expect(SiteChart.svg(metric: .startup, runs: [Self.run(date: "2026-11-01"), noAlloy]) == nil)
    }

    @Test func deterministic() {
        let runs = [Self.run(date: "2026-11-01"), Self.run(date: "2026-11-08")]
        #expect(Self.page(runs) == Self.page(runs))
    }

    @Test func publishesOnlyTrimmedEnvironment() {
        let html = Self.page([Self.run()])
        #expect(html.contains("Mac16,1"))
        #expect(!html.contains("thermal") && !html.contains("battery"))
    }

    @Test func committedSiteIsCurrent() throws {
        let bench = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let (index, runs) = try SitePage.load(publishedDir: bench.appendingPathComponent("published"))
        let committed = try String(contentsOf: bench.appendingPathComponent("site/index.html"), encoding: .utf8)
        #expect(SitePage.render(index: index, runs: runs) == committed,
                "Bench/site is stale: run swift run --package-path Bench alloy-bench site")
    }

    @Test func missingFolderIsAnError() {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        do { _ = try SitePage.load(publishedDir: gone); Issue.record("no throw") }
        catch { #expect("\(error)".hasPrefix("no published results folder at ")) }
    }

    @Test func existingFolderWithoutIndexIsEmpty() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let (index, runs) = try SitePage.load(publishedDir: d)
        #expect(index.runs.isEmpty && runs.isEmpty)
    }

    @Test func rawSamplesBulletNeedsRuns() {
        #expect(!SitePage.render(index: PublishedIndex(), runs: []).contains("linked below"))
        #expect(Self.page([Self.run()]).contains("linked below"))
    }

    @Test func repoRootWalksUpAndFailsOutside() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("repo-\(UUID().uuidString)")
        let nested = base.appendingPathComponent("Bench/Sources/x")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: base.appendingPathComponent("Bench/Package.swift"))
        defer { try? fm.removeItem(at: base) }
        let want = base.standardizedFileURL.path
        #expect(RepoPaths.root(from: nested)?.path == want)
        #expect(RepoPaths.root(from: base.appendingPathComponent("Bench"))?.path == want)
        #expect(try RepoPaths.resolve(nil, fallback: "Bench/site", cwd: nested).path == want + "/Bench/site")
        let rel = try RepoPaths.resolve("out", fallback: "Bench/site", cwd: nested).path
        #expect(rel == nested.standardizedFileURL.path + "/out", "got \(rel)")
        let outside = fm.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        #expect(RepoPaths.root(from: outside) == nil)
        #expect(throws: RepoPaths.NotFound.self) { try RepoPaths.resolve(nil, fallback: "Bench/site", cwd: outside) }
    }
}
