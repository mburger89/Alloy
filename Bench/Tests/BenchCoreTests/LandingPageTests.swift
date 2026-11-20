import Testing
import Foundation
@testable import BenchCore

@Suite struct LandingPageTests {
    /// Alloy ahead of Zed on startup and memory unless overridden; Delta measured on startup only.
    static func run(alloy: [Metric: Outcome] = [:]) -> RunResult {
        var r = PublishTests.complete()
        for m in Metric.allCases { r.outcomes["alloy"]?[m] = ParityTests.m(100, 120); r.outcomes["zed"]?[m] = ParityTests.m(100, 120) }
        r.outcomes["alloy"]?[.startup] = ParityTests.m(111, 131)
        r.outcomes["zed"]?[.startup] = ParityTests.m(222, 242)
        r.outcomes["alloy"]?[.memory] = ParityTests.m(57, 60)
        r.outcomes["zed"]?[.memory] = ParityTests.m(190, 200)
        r.outcomes["delta"] = [.startup: ParityTests.m(444, 460), .memory: .notApplicable("no")]
        for (m, o) in alloy { r.outcomes["alloy"]?[m] = o }
        return r
    }

    static func page(_ r: RunResult, assets: Set<String> = [], available: Bool = false) -> String {
        var idx = PublishedIndex()
        idx.upsert(SitePageTests.entry(r))
        var c = LandingContent(); c.assets = assets; c.downloadAvailable = available
        return LandingPage.render(index: idx, runs: [r], content: c)
    }

    @Test func raceOffersOnlyWins() {
        let r = Self.run(alloy: [.memory: ParityTests.m(300, 320)])
        let wins = RaceData.wins(from: r)
        #expect(wins.map(\.metric) == [.startup])
        let html = Self.page(r)
        #expect(!html.contains("Memory, 2 MB file open"))
        #expect(!html.contains("memory with a 2 MB file open"))
        #expect(html.contains("Start up"))
        // A tie is not a win either.
        #expect(RaceData.wins(from: Self.run(alloy: [.startup: ParityTests.m(222, 242), .memory: ParityTests.m(190, 200)])).isEmpty)
    }

    @Test func deltaOnlyWhereMeasured() {
        let wins = RaceData.wins(from: Self.run())
        #expect(wins.first { $0.metric == .startup }?.lanes.map(\.name) == ["Alloy", "Zed", "Delta"])
        #expect(wins.first { $0.metric == .memory }?.lanes.map(\.name) == ["Alloy", "Zed"])
    }

    @Test func raceListsEveryMeasuredEditorFastestFirst() {
        var r = Self.run()
        r.outcomes["vscode"] = [.startup: ParityTests.m(333, 350), .memory: ParityTests.m(500, 520)]
        r.outcomes["cursor"] = [.startup: ParityTests.m(150, 170), .memory: .notMeasured("no")]
        r.outcomes["sublime"] = [.startup: .notApplicable("no"), .memory: ParityTests.m(80, 90)]
        r.outcomes["idea"] = [.startup: ParityTests.m(900, 950, unit: "s")]
        let wins = RaceData.wins(from: r)
        #expect(wins.first { $0.metric == .startup }?.lanes.map(\.name) == ["Alloy", "Cursor", "Zed", "VS Code", "Delta"])
        #expect(wins.first { $0.metric == .memory }?.lanes.map(\.name) == ["Alloy", "Sublime Text", "Zed", "VS Code"])
        #expect(wins.first { $0.metric == .startup }?.lanes.first?.isAlloy == true)
    }

    @Test func raceSkipsTestsAnotherEditorBeatsOrTiesAlloy() {
        var r = Self.run()
        r.outcomes["sublime"] = [.startup: ParityTests.m(50, 60), .memory: ParityTests.m(57, 60)]
        #expect(RaceData.wins(from: r).isEmpty)
    }

    @Test func footerListsEveryPresentEditorVersion() {
        var r = Self.run()
        r.apps["delta"] = "2.0"; r.apps["vscode"] = "1.99"; r.apps["sublime"] = "4200"
        r.outcomes["vscode"] = [:]; r.outcomes["sublime"] = [:]
        let html = Self.page(r)
        #expect(html.contains(", Zed 1.0, Delta 2.0, VS Code 1.99, Sublime Text 4200"))
    }

    @Test func everyNumberComesFromData() throws {
        let html = Self.page(Self.run())
        func slots(_ pattern: String) throws -> [String] {
            let re = try NSRegularExpression(pattern: pattern)
            return re.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
                Range($0.range(at: 1), in: html).map { String(html[$0]) }
            }
        }
        let numeric = (try slots(#"<b class="n">([^<]*)</b>"#) + slots(#"<div class="v">([^<]*)</div>"#)).filter { $0.contains(where: \.isNumber) }
        #expect(numeric.count >= 8)
        let allowed: Set<String> = ["111 ms", "222 ms", "444 ms", "57.0 ms", "190 ms", "2 of 7", "0"]
        for n in numeric { #expect(allowed.contains(n), "unexpected figure \(n)") }
        #expect(numeric.contains("2 of 7"))   // startup and memory are the only two wins
        #expect(numeric.contains("57.0 ms") && numeric.contains("190 ms"))
        #expect(numeric.contains("111 ms") && numeric.contains("222 ms") && numeric.contains("444 ms"))
    }

    @Test func noExternalResources() throws {
        let html = Self.page(Self.run(), assets: ["hero.mp4", "hero-poster.png", "shot-sessions.png"])
        let allowed = ["https://github.com/mburger89/Alloy"]
        let re = try NSRegularExpression(pattern: #"(?:src|href|poster|action)="(https?:[^"]*)""#)
        for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let url = String(html[Range(m.range(at: 1), in: html)!])
            #expect(allowed.contains { url.hasPrefix($0) }, "external reference \(url)")
        }
        #expect(!html.contains("http://"))
        #expect(!html.contains("url(http"))
        #expect(!html.contains("@import"))
        #expect(!html.contains("<link rel=\"stylesheet\""))
        #expect(!html.contains("releases/latest/download"))
        #expect(Self.page(Self.run(), available: true).contains("https://github.com/mburger89/Alloy/releases/latest/download/Alloy.dmg"))
    }

    @Test func pageWorksWithoutScript() {
        let html = Self.page(Self.run())
        #expect(!html.contains("<script"))
        #expect(Self.page(Self.run(), available: true)
            .contains("<a class=\"btn p\" href=\"https://github.com/mburger89/Alloy/releases/latest/download/Alloy.dmg\">Download for Mac</a>"))
        // Final bar widths are in the markup: in the startup race Delta (444) is full width, Zed (222) 50%, Alloy (111) 25%.
        #expect(html.contains("style=\"width:100%\""))
        #expect(html.contains("style=\"width:50%\""))
        #expect(html.contains("style=\"width:25%\""))
    }

    @Test func reducedMotionDisablesAnimation() {
        let html = Self.page(Self.run())
        #expect(html.contains("@media (prefers-reduced-motion:reduce)"))
        #expect(html.contains("animation:none!important"))
    }

    @Test func missingAssetsRenderPlaceholders() {
        let bare = Self.page(Self.run())
        #expect(!bare.contains("<video") && !bare.contains("assets/hero") && !bare.contains("assets/shot-"))
        let full = Self.page(Self.run(), assets: ["hero.mp4", "hero-poster.png", "shot-changes.png"])
        #expect(full.contains("<video autoplay muted loop playsinline poster=\"assets/hero-poster.png\""))
        #expect(full.contains("src=\"assets/shot-changes.png\""))
        #expect(!full.contains("src=\"assets/shot-sessions.png\""))
    }

    @Test func copyFollowsTheSpec() {
        let html = Self.page(Self.run())
        for t in ["Fast. Native. Yours.", "Feel the difference.", "Stop paying to read the same file twice.",
                  "Your sessions share what they learn.",
                  "never changes your Claude Code settings — the optional theme skill is installed only when you click it",
                  "The only requests Alloy itself makes are update checks"] {
            #expect(html.contains(t), "missing \(t)")
        }
        for t in ["Dracula", "Alloy Dark", "Alloy Light", "Solarized Dark", "Solarized Light", "One Dark"] { #expect(html.contains(t)) }
        #expect(html.contains("language server you already have installed"))
        #expect(html.contains("checks for updates once a day in the background") && !html.contains("at launch and once a day"))
    }

    @Test func comingSoonReplacesEveryDownloadLink() {
        let html = Self.page(Self.run())
        #expect(!html.contains("releases") && !html.contains("Alloy.dmg") && !html.contains("Download"))
        #expect(html.components(separatedBy: "<span class=\"btn p soon\" aria-disabled=\"true\">Coming soon</span>").count == 3)
        #expect(html.contains("<span class=\"dl soon\" aria-disabled=\"true\">Coming soon</span>"))
        #expect(html.contains("Coming soon for Apple-silicon Macs") && html.contains("Alloy is coming soon for Apple-silicon Macs."))
        #expect(!html.contains("Try it in a minute.") && !html.contains("signed &amp; notarised"))
        // Nothing that says Coming soon is a link.
        #expect(!html.contains("href=\"\(LandingContent().downloadURL)\""))
    }

    @Test func downloadLinksReturnWhenAvailable() {
        let html = Self.page(Self.run(), available: true)
        #expect(!html.contains("Coming soon") && !html.contains("aria-disabled"))
        #expect(html.components(separatedBy: "Download for Mac</a>").count == 3)
        #expect(html.contains("class=\"dl\" href=\"https://github.com/mburger89/Alloy/releases/latest/download/Alloy.dmg\">Download</a>"))
        #expect(html.contains("https://github.com/mburger89/Alloy/releases\">Release notes</a>"))
        #expect(html.contains("https://github.com/mburger89/Alloy/releases\">Releases</a>"))
        #expect(html.contains("Try it in a minute.") && html.contains("signed &amp; notarised"))
    }

    @Test func noRunsStillRenders() {
        let html = LandingPage.render(index: PublishedIndex(), runs: [], content: LandingContent())
        #expect(html.contains("Fast. Native. Yours.") && !html.contains("id=\"speed\"") && !html.contains("class=\"strip\""))
    }

    @Test func themesMatchTheApp() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AlloyCore/Themes/BuiltIn")
        var all = ""
        for f in try FileManager.default.contentsOfDirectory(atPath: sources.path) where f != "BuiltInThemes.swift" {
            all += try String(contentsOf: sources.appendingPathComponent(f), encoding: .utf8)
        }
        for t in LandingContent().themes {
            #expect(all.contains("\"name\": \"\(t.name)\""), "theme \(t.name)")
            for hex in [t.background, t.surface, t.text, t.keyword, t.string, t.comment, t.function] {
                #expect(all.contains("\"\(hex)\""), "\(t.name) \(hex)")
            }
        }
        #expect(try String(contentsOf: sources.appendingPathComponent("BuiltInThemes.swift"), encoding: .utf8)
            .components(separatedBy: "(id: \"").count - 1 == LandingContent().themes.count)
    }

    @Test func benchmarksMovedAndDataStays() throws {
        let site = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("site")
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: site.appendingPathComponent("benchmarks/index.html").path))
        let (index, _) = try SitePage.load(publishedDir: site.deletingLastPathComponent().appendingPathComponent("published"))
        for e in index.runs {
            let a = try Data(contentsOf: site.appendingPathComponent("data/\(e.stem).json"))
            let b = try Data(contentsOf: site.deletingLastPathComponent().appendingPathComponent("published/\(e.stem).json"))
            #expect(a == b)
        }
        let bench = try String(contentsOf: site.appendingPathComponent("benchmarks/index.html"), encoding: .utf8)
        #expect(bench.contains("href=\"../data/"))
    }

    @Test func heroVideoAutoplaysAndReducedMotionShowsPoster() {
        let html = Self.page(Self.run(), assets: ["hero.mp4", "hero-poster.png"])
        #expect(html.contains("<figure class=\"app has-poster\">"))
        #expect(html.contains("<img class=\"poster\" src=\"assets/hero-poster.png\""))
        #expect(html.contains("@media (prefers-reduced-motion:reduce){.app.has-poster video{display:none}.app.has-poster .poster{display:block}"))
        #expect(!html.contains("preload=\"none\""))
    }

    @Test func newestCompleteRunIsTheHeadline() {
        var older = Self.run()
        var newer = Self.run(alloy: [.startup: ParityTests.m(300, 320)])   // would lose startup
        older.environment.date = "2026-11-01"; newer.environment.date = "2026-11-08"
        var idx = PublishedIndex()
        var e1 = SitePageTests.entry(older); e1.stem = "a"
        var e2 = SitePageTests.entry(newer, partial: true); e2.stem = "b"
        idx.upsert(e1); idx.upsert(e2)
        let html = LandingPage.render(index: idx, runs: [older, newer], content: LandingContent())
        #expect(html.contains("2026-11-01") && !html.contains("2026-11-08") && !html.contains("partial run"))
        var only = PublishedIndex(); only.upsert(e2)
        #expect(LandingPage.render(index: only, runs: [newer], content: LandingContent()).contains("(partial run)"))
    }

    @Test func dataDerivedStringsAreEscaped() {
        var r = Self.run()
        r.environment.machine = "<script>alert(1)</script>&"
        r.apps["zed"] = "1.0\"><b>"
        let html = Self.page(r)
        #expect(!html.contains("<script"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;&amp;"))
        #expect(html.contains("1.0&quot;&gt;&lt;b&gt;"))
    }

    @Test func languageServerWordingFollowsTheFlag() {
        var c = LandingContent(); c.hasLanguageServers = true
        let html = LandingPage.render(index: PublishedIndex(), runs: [], content: c)
        #expect(html.contains("language server you already have installed"))
        c.hasLanguageServers = false
        #expect(!LandingPage.render(index: PublishedIndex(), runs: [], content: c).contains("language server you already have installed"))
    }

    @Test func faqAnswersAreAsRuled() {
        let html = Self.page(Self.run())
        #expect(html.contains("when you choose Restart to update — never mid-session"))
        #expect(html.contains("<h2 class=\"sr\">Features</h2>"))
    }

    @Test func copyIsForAgentsNotOnlyClaude() {
        let html = Self.page(Self.run())
        #expect(html.contains("<title>Alloy — the code editor for Claude Code and other AI coding agents</title>"))
        #expect(html.contains("<p class=\"lead\">The code editor for Claude Code and other AI coding agents"))
        #expect(!html.contains("Needs the Claude Code CLI"))
        #expect(html.contains("Needs a supported coding agent"))
    }

    @Test func otherAgentsFaqNamesEveryAgent() throws {
        let q = try #require(LandingContent().faq.first { $0.q == "Does it work with other agents?" })
        for t in ["Claude Code", "Codex", "Gemini CLI", "OpenCode", "Goose", "Agent Client Protocol", "Claude Code is supported directly"] {
            #expect(q.a.contains(t), "missing \(t)")
        }
    }

    @Test func requirementFaqIsAgentNeutral() throws {
        let faq = LandingContent().faq
        #expect(!faq.contains { $0.q == "Do I need a Claude subscription?" })
        let q = try #require(faq.first { $0.q == "What do I need to run it?" })
        for t in ["at least one supported agent installed and signed in", "Apple silicon", "macOS 14 or later"] { #expect(q.a.contains(t)) }
    }

    @Test func privacyLinesFollowTheRule() {
        let html = Self.page(Self.run())
        #expect(html.contains("No telemetry and no account."))
        #expect(html.contains("The only requests Alloy itself makes are update checks"))
        #expect(html.contains("agents and language servers you run make their own connections") || html.contains("Agents and language servers you run make their own connections"))
        #expect(!html.contains("The update check is the only network call"))
    }

    @Test func issuesLinkAndDownloadStaysOff() {
        let html = Self.page(Self.run())
        #expect(html.contains("https://github.com/mburger89/Alloy/issues"))
        #expect(LandingContent().downloadAvailable == false)
        #expect(html.contains("Coming soon"))
    }

    @Test func editorSectionAndFeature() {
        let c = LandingContent()
        #expect(c.features.count == 4)
        let html = Self.page(Self.run())
        #expect(html.contains("A real code editor, too."))
        #expect(html.contains("aria-label=\"Alloy&#39;s Code mode: the file tree") || html.contains("aria-label=\"Alloy's Code mode: the file tree"))
        #expect(!html.contains("assets/shot-code.png"))
        #expect(Self.page(Self.run(), assets: ["shot-code.png"]).contains("src=\"assets/shot-code.png\""))
        #expect(html.contains("<section id=\"editor\">") && html.contains("Everything you need when you take the wheel."))
        #expect(html.contains("href=\"#editor\">Editor</a>"))
        var pos = html.range(of: "<div class=\"caps\">")!.upperBound
        for (t, l) in c.editorCapabilities {
            let item = "<b>\(SitePage.escape(t))</b><span>\(SitePage.escape(l))</span>"
            let r = html.range(of: item, range: pos..<html.endIndex)
            #expect(r != nil, "missing \(t)")
            if let r { pos = r.upperBound }
        }
        // Escaping: a hostile capability is escaped.
        var h = LandingContent(); h.editorCapabilities = [("<i>&", "\"x\"")]
        let out = LandingPage.render(index: PublishedIndex(), runs: [], content: h)
        #expect(out.contains("<b>&lt;i&gt;&amp;</b><span>&quot;x&quot;</span>"))
        // Order: features, then editor, then themes.
        let a = html.range(of: "id=\"features\"")!.lowerBound, b = html.range(of: "id=\"editor\"")!.lowerBound, d = html.range(of: "id=\"themes\"")!.lowerBound
        #expect(a < b && b < d)
    }

    // MARK: contrast of the CSS tokens

    static func luminance(_ hex: String) -> Double {
        let h = hex.dropFirst()
        let v = stride(from: 0, to: 6, by: 2).map { i -> Double in
            let a = h.index(h.startIndex, offsetBy: i)
            let c = Double(Int(h[a..<h.index(a, offsetBy: 2)], radix: 16)!) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    }
    static func ratio(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func tokens(_ block: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in block.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].hasPrefix("--") { out[String(kv[0])] = String(kv[1]) }
        }
        return out
    }

    @Test func themeTokensHaveReadableContrast() throws {
        let css = LandingPage.css(LandingContent(), wins: [])
        let dark = Self.tokens(String(css.components(separatedBy: ":root{")[1].components(separatedBy: "}")[0]))
        let lightBlock = String(css.components(separatedBy: "(prefers-color-scheme:light){:root{")[1].components(separatedBy: "}")[0])
        let light = dark.merging(Self.tokens(lightBlock)) { $1 }
        for (name, t) in [("dark", dark), ("light", light)] {
            for (fg, bg) in [("--ink", "--bg"), ("--mute", "--bg"), ("--mute", "--card"), ("--ink", "--card"), ("--mute", "--panel"), ("--accent", "--bg"), ("--btn", "--accent"),
                             ("--green", "--card"), ("--pink", "--card"), ("--cyan", "--card")] {
                #expect(Self.ratio(t[fg]!, t[bg]!) >= 4.5, "\(name) \(fg) on \(bg) = \(Self.ratio(t[fg]!, t[bg]!))")
            }
            #expect(Self.ratio(t["--bar"]!, t["--card"]!) >= 3, "\(name) race bar vs track")
        }
    }
}
