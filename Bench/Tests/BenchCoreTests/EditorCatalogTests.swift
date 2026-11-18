import Testing
import Foundation
@testable import BenchCore
@testable import BenchScenarios

@Suite struct EditorCatalogTests {
    /// The existing complete zed+alloy run plus extra editors measured on every metric.
    static func run(date: String = "2026-11-08", extras: [String] = []) -> RunResult {
        var r = SitePageTests.run(date: date)
        for id in extras {
            r.apps[id] = "9.9"
            r.outcomes[id] = [:]
            for m in Metric.allCases { r.outcomes[id]?[m] = ParityTests.m(150, 170) }
        }
        return r
    }

    // MARK: CLI

    @Test func resolvesAllNewEditorIdsInOrder() throws {
        let ids = try CLIArguments.resolveApps("vscode,cursor,sublime,idea", alloyBuild: nil).map(\.id)
        #expect(ids == ["vscode", "cursor", "sublime", "idea"])
    }

    @Test func defaultsStayZedAndDelta() throws {
        #expect(try CLIArguments.resolveApps(nil, alloyBuild: nil).map(\.id) == ["zed", "delta"])
        #expect(try CLIArguments.resolveApps(nil, alloyBuild: "/x").map(\.id) == ["zed", "delta", "alloy"])
    }

    @Test func unknownIdErrorListsAllSevenIds() {
        do { _ = try CLIArguments.resolveApps("bogus", alloyBuild: nil); Issue.record("should throw") }
        catch {
            let text = "\(error)"
            for id in ["zed", "delta", "vscode", "cursor", "sublime", "idea", "alloy"] { #expect(text.contains(id), "\(text)") }
        }
    }

    // MARK: catalogue

    @Test func catalogueOrder() {
        #expect(EditorCatalog.all.map(\.id) == ["zed", "delta", "vscode", "cursor", "sublime", "idea", "alloy"])
        #expect(EditorCatalog.all.map(\.name) == ["Zed", "Delta", "VS Code", "Cursor", "Sublime Text", "IntelliJ IDEA", "Alloy"])
    }

    @Test func catalogueNamesMatchTheAdapters() {
        for t in TargetApp.editors {
            #expect(EditorCatalog.all.first { $0.id == t.id }?.name == t.displayName)
        }
    }

    @Test func presentAlwaysHasTheOldThreeAndAddsMeasuredEditorsInOrder() {
        let old = RunResult(environment: ResultsTests.env, apps: [:], outcomes: [:])
        #expect(EditorCatalog.present(in: old).map(\.id) == ["zed", "delta", "alloy"])
        var r = Self.run(extras: ["idea", "vscode"])
        r.apps["sublime"] = "4215"
        #expect(EditorCatalog.present(in: r).map(\.id) == ["zed", "delta", "vscode", "sublime", "idea", "alloy"])
    }

    // MARK: markdown

    @Test func markdownGainsAColumnForMeasuredEditors() {
        let md = Report.markdown(Self.run(extras: ["vscode"]))
        #expect(md.contains("| Metric | Zed | Delta | VS Code | Alloy | Note |"))
        #expect(md.contains("VS Code 9.9"))
    }

    @Test func markdownOfOldResultsKeepsTheThreeColumns() {
        let md = Report.markdown(Self.run())
        #expect(md.contains("| Metric | Zed | Delta | Alloy | Note |"))
        #expect(!md.contains("VS Code"))
    }

    @Test func newEditorOnlyResultRendersEverywhere() {
        let r = RunResult(environment: ResultsTests.env, apps: ["idea": "2026.3"],
                          outcomes: ["idea": [.startup: ParityTests.m(900, 950)]])
        let md = Report.markdown(r)
        #expect(md.contains("IntelliJ IDEA"))
        #expect(md.contains("900.0 ms"))
        for line in md.split(separator: "\n") where line.hasPrefix("|") {
            #expect(line.filter { $0 == "|" }.count == 7, "\(line)")
        }
        let html = SitePageTests.page([r, r])
        #expect(html.contains("<th>IntelliJ IDEA</th>"))
        #expect(SiteChart.svg(metric: .startup, runs: [r, r]) == nil)
    }

    // MARK: site page

    @Test func siteTableAndEnvironmentListSublimeAndIdea() {
        let html = SitePageTests.page([Self.run(extras: ["sublime", "idea"])])
        #expect(html.contains("<th>Zed</th><th>Delta</th><th>Sublime Text</th><th>IntelliJ IDEA</th><th>Alloy</th><th>Verdict</th>"))
        #expect(html.contains("<dt>Sublime Text version</dt><dd>9.9</dd>"))
        #expect(html.contains("<dt>IntelliJ IDEA version</dt><dd>9.9</dd>"))
        #expect(html.contains("150.0 ms (p95 170.0)"))
    }

    @Test func siteOfOldResultsKeepsTheOldTableAndLead() {
        let html = SitePageTests.page([Self.run()])
        #expect(html.contains("<thead><tr><th>Metric</th><th>Zed</th><th>Delta</th><th>Alloy</th><th>Verdict</th></tr></thead>"))
        #expect(html.contains("measured against Zed and Delta on the same Mac"))
        #expect(html.contains("<span class=\"key zed\">Zed median</span> <span class=\"key alloy\">Alloy median</span></p>")
                || SiteChart.svg(metric: .startup, runs: [Self.run()]) == nil)
    }

    @Test func leadNamesThePresentEditors() {
        let html = SitePageTests.page([Self.run(extras: ["vscode"])])
        #expect(html.contains("measured against Zed, Delta and VS Code on the same Mac"))
        let two = SitePageTests.page([Self.run(extras: ["vscode", "idea"])])
        #expect(two.contains("measured against Zed, Delta, VS Code and IntelliJ IDEA on the same Mac"))
    }

    @Test func notesLoopCoversNewEditors() {
        var r = Self.run(extras: ["idea"])
        r.outcomes["idea"]?[.startup] = .measured(
            Summary(count: 5, median: 900, p95: 950, min: 900, max: 950, unit: "ms"),
            samples: [900], notes: ["indexing finished first"], failures: ["run 3 timed out"])
        let html = SitePageTests.page([r])
        #expect(html.contains("IntelliJ IDEA Startup: indexing finished first"))
        #expect(html.contains("IntelliJ IDEA Startup, failed run: run 3 timed out"))
    }

    // MARK: chart

    @Test func chartAddsASeriesOnlyForEditorsMeasuredInEveryPlottedRun() {
        let a = Self.run(date: "2026-11-01", extras: ["vscode"]), b = Self.run(date: "2026-11-08", extras: ["vscode"])
        let with = SiteChart.svg(metric: .startup, runs: [a, b])
        #expect(with?.contains("class=\"series vscode\"") == true)
        #expect(with?.contains("class=\"dot vscode\"") == true)
        #expect(with?.contains("class=\"series zed\"") == true)
        // Missing in one plotted run: no series.
        let c = Self.run(date: "2026-11-08")
        let without = SiteChart.svg(metric: .startup, runs: [a, c])
        #expect(without?.contains("vscode") == false)
        #expect(SiteChart.svg(metric: .startup, runs: [Self.run(date: "2026-11-01"), c])?.contains("series vscode") == false)
    }

    @Test func historyLegendListsPlottedEditors() {
        let html = SitePageTests.page([Self.run(date: "2026-11-01", extras: ["vscode"]), Self.run(date: "2026-11-08", extras: ["vscode"])])
        #expect(html.contains("<span class=\"key vscode\">VS Code median</span>"))
    }

    @Test func cssDefinesEveryEditorColourInBothPalettes() {
        let html = SitePageTests.page([Self.run()])
        for id in ["vscode", "cursor", "sublime", "idea"] {
            #expect(html.components(separatedBy: "--\(id):").count == 3, "\(id) needs a light and a dark colour")
            #expect(html.contains(".series.\(id)"))
            #expect(html.contains(".dot.\(id)"))
            #expect(html.contains(".key.\(id)"))
        }
    }
}
