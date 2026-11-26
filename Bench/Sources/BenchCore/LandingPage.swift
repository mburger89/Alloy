import Foundation

/// One bar in a race lane.
public struct RaceLane: Sendable, Equatable {
    public var name: String
    public var value: Double
    public var text: String
    /// 0...100, proportional to the largest lane of the test.
    public var width: Double
    public var isAlloy: Bool
}

/// One test the landing page may race: Alloy against every editor measured for it, listed only where
/// Alloy is ahead of Zed by the parity bar and strictly the fastest (lowest median) of all of them.
public struct RaceTest: Sendable, Equatable {
    public var metric: Metric
    public var tab: String
    public var lanes: [RaceLane]
}

public enum RaceData {
    static func tab(_ m: Metric) -> String {
        switch m {
        case .startup: return "Start up"
        case .typingLatency: return "Type"
        case .scrollFrames: return "Scroll"
        case .memory: return "Memory, 2 MB file open"
        case .memoryIdle: return "Memory, idle"
        case .largeFileOpen: return "Open a 2 MB file"
        case .idleCPU: return "Idle CPU"
        }
    }

    /// Formats a published value with its unit (ms, MiB, %); the digits are the JSON's, rounded for display.
    static func format(_ v: Double, unit: String) -> String {
        switch unit {
        case "ms": return String(format: v < 100 ? "%.1f" : "%.0f", v) + " ms"
        case "MiB": return String(format: "%.0f", v) + " MiB"
        case "%": return String(format: v >= 0.1 ? "%.2f" : "%.3f", v) + " %"
        default: return String(format: "%.1f", v) + " " + unit
        }
    }

    /// The tests where Alloy is ahead of Zed by the benchmark's own parity bar (median and p95, beyond tolerance)
    /// and its median is strictly the lowest of every measured editor; a tie or a loss to any editor is never offered.
    /// Each test has one lane per editor measured with Alloy's unit: Alloy first, then the others by median ascending.
    public static func wins(from run: RunResult) -> [RaceTest] {
        var out: [RaceTest] = []
        for m in Metric.allCases {
            guard Parity.judge(run, metric: m) == .ahead,
                  case .measured(let a, _, _, _)? = run.outcomes["alloy"]?[m] else { continue }
            var others: [(String, Summary)] = []
            for (id, name) in EditorCatalog.all where id != "alloy" {
                if case .measured(let s, _, _, _)? = run.outcomes[id]?[m], s.unit == a.unit { others.append((name, s)) }
            }
            guard others.allSatisfy({ a.median < $0.1.median }) else { continue }
            others.sort { $0.1.median < $1.1.median }   // stable, so equal medians keep catalogue order
            let rows: [(String, Summary, Bool)] = [("Alloy", a, true)] + others.map { ($0.0, $0.1, false) }
            let top = max(rows.map { $0.1.median }.max() ?? 1, 0.000_001)
            let lanes = rows.map { name, s, alloy in
                RaceLane(name: name, value: s.median, text: format(s.median, unit: s.unit),
                         width: max(1.5, (s.median / top * 1000).rounded() / 10), isAlloy: alloy)
            }
            out.append(RaceTest(metric: m, tab: tab(m), lanes: lanes))
        }
        return out
    }
}

/// Renders the landing page (`/index.html`). Static HTML and CSS, no scripts, no external resources; deterministic.
public enum LandingPage {
    /// Names of the files in `<site>/assets`, for `LandingContent.assets`.
    public static func assetNames(in dir: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    static let esc = SitePage.escape

    public static func render(index: PublishedIndex, runs: [RunResult], content c: LandingContent) -> String {
        // Headline from the newest complete run; if every run is partial, the newest, labelled as partial.
        let pairs = Array(zip(index.runs, runs))
        let chosen = pairs.last { !$0.0.partial } ?? pairs.last
        let latest = chosen?.1
        let partial = chosen?.0.partial ?? false
        let wins = latest.map(RaceData.wins(from:)) ?? []
        var body = nav(c) + hero(c)
        if let latest { body += proofStrip(latest, wins: wins, c) }
        if let latest, !wins.isEmpty { body += race(latest, wins: wins, c, partial: partial) }
        body += agents(c) + notes(c) + features(c) + editor(c) + themes(c) + languages(c) + built(c) + privacy(c) + faq(c) + closing(c) + footer(c)
        return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            + "<title>Alloy — the native code editor for any AI coding agent</title>\n"
            + "<meta name=\"description\" content=\"\(esc(c.heroLead))\">\n"
            + "<meta name=\"color-scheme\" content=\"dark light\">\n"
            + "<link rel=\"icon\" href=\"assets/icon.svg\" type=\"image/svg+xml\">\n"
            + "<link rel=\"icon\" href=\"assets/icon-64.png\" type=\"image/png\" sizes=\"64x64\">\n"
            + "<link rel=\"apple-touch-icon\" href=\"assets/icon-180.png\">\n"
            + "<style>\n\(css(c, wins: wins))</style>\n</head>\n<body>\n\(body)</body>\n</html>\n"
    }

    // MARK: sections

    private static func nav(_ c: LandingContent) -> String {
        """
        <nav aria-label="Main"><div class="wrap">
        <a class="brand" href="./"><img src="assets/icon-64.png" alt="" width="26" height="26"><b>Alloy</b></a>
        <div class="links"><a class="opt" href="#features">Features</a><a class="opt" href="#editor">Editor</a><a class="opt" href="#agents">Agents</a><a class="opt" href="#notes">Shared notes</a><a class="opt" href="#themes">Themes</a><a class="opt" href="benchmarks/">Benchmarks</a><a class="opt" href="#faq">FAQ</a><a class="opt" href="\(esc(c.repoURL))">GitHub</a>\(download(c, cls: "dl", label: "Download", soon: "Coming soon"))</div>
        </div></nav>
        <main>

        """
    }

    private static func hero(_ c: LandingContent) -> String {
        var media: String
        let hasPoster = c.assets.contains(c.heroPoster)
        let posterImg = "<img class=\"poster\" src=\"assets/\(esc(c.heroPoster))\" alt=\"\(esc(c.heroAlt))\" fetchpriority=\"high\">"
        if c.assets.contains(c.heroVideo) {
            // Autoplays muted and looping; under prefers-reduced-motion the CSS hides the video and shows the poster.
            media = "<video autoplay muted loop playsinline\(hasPoster ? " poster=\"assets/\(esc(c.heroPoster))\"" : "") aria-label=\"\(esc(c.heroAlt))\"><source src=\"assets/\(esc(c.heroVideo))\" type=\"video/mp4\"></video>"
            if hasPoster { media += posterImg }
        } else if hasPoster {
            media = posterImg
        } else {
            media = "<div class=\"ph\" role=\"img\" aria-label=\"\(esc(c.heroAlt))\"><span>Alloy</span></div>"
        }
        let cls = c.assets.contains(c.heroVideo) && hasPoster ? "app has-poster" : "app"
        return """
        <header class="hero"><div class="wrap">
        <h1>\(esc(c.heroTitle))</h1>
        <p class="lead">\(esc(c.heroLead))</p>
        <p>\(download(c, cls: "btn p", label: "Download for Mac", soon: "Coming soon"))<a class="btn s" href="\(esc(c.repoURL))">View on GitHub</a></p>
        <p class="meta">\(esc(c.downloadAvailable ? c.heroMeta : c.heroMetaSoon))</p>
        <figure class="\(cls)">\(media)</figure>
        </div></header>

        """
    }

    private static func proofStrip(_ r: RunResult, wins: [RaceTest], _ c: LandingContent) -> String {
        let verdicts = Metric.allCases.map { Parity.judge(r, metric: $0) }
        let judged = verdicts.filter { if case .unjudged = $0 { return false } else { return true } }
        let ahead = verdicts.filter { $0 == .ahead }.count
        var items: [(String, String)] = []
        if !judged.isEmpty { items.append(("\(ahead) of \(judged.count)", "benchmarks ahead of Zed")) }
        // The second figure: memory with the 2 MB file open when Alloy wins it, otherwise the first other win.
        let pick = wins.first { $0.metric == .memory } ?? wins.first
        if let pick, let lane = pick.lanes.first {
            items.append((lane.text, label(pick.metric)))
        }
        items.append(("0", "web views"))
        return "<section class=\"strip\" aria-label=\"Headline numbers\"><div class=\"wrap\">"
            + items.map { "<div><b class=\"n\">\(esc($0.0))</b><span>\(esc($0.1))</span></div>" }.joined()
            + "</div></section>\n"
    }

    private static func label(_ m: Metric) -> String {
        switch m {
        case .memory: return "memory with a 2 MB file open"
        case .startup: return "median start up"
        case .largeFileOpen: return "median to open a 2 MB file"
        case .typingLatency: return "median typing latency"
        case .scrollFrames: return "median scroll frame time"
        case .memoryIdle: return "memory when idle"
        case .idleCPU: return "idle CPU"
        }
    }

    private static func race(_ r: RunResult, wins: [RaceTest], _ c: LandingContent, partial: Bool) -> String {
        let checked = wins.firstIndex { $0.metric == .startup } ?? 0
        var s = "<section id=\"speed\"><div class=\"wrap\">\n<div class=\"tag\">Speed</div><h2>\(esc(c.raceTitle))</h2><p class=\"sub\">\(esc(c.raceSub))</p>\n<div class=\"race\">\n"
        for i in wins.indices {
            s += "<input class=\"vh\" type=\"radio\" name=\"race\" id=\"race-\(i)\"\(i == checked ? " checked" : "")>\n"
        }
        s += "<div class=\"tabs\">"
        for (i, t) in wins.enumerated() { s += "<label for=\"race-\(i)\">\(esc(t.tab))</label>" }
        s += "</div>\n<div class=\"panels\">\n"
        for (i, t) in wins.enumerated() {
            s += "<div class=\"panel p\(i)\" role=\"group\" aria-label=\"\(esc(t.tab))\">\n"
            for l in t.lanes {
                s += "<div class=\"lane\"><div class=\"n\">\(esc(l.name))</div><div class=\"t\"><div class=\"f\(l.isAlloy ? " alloy" : "")\" style=\"width:\(String(format: "%g", l.width))%\"></div></div><div class=\"v\">\(esc(l.text))</div></div>\n"
            }
            s += "<p class=\"note\">Shorter is better.</p>\n</div>\n"
        }
        let e = r.environment
        var versions = ""
        for (id, name) in EditorCatalog.present(in: r) where id != "alloy" {
            if let v = r.apps[id] { versions += ", \(name) \(v)" }
        }
        s += "</div></div>\n<p class=\"foot\">\(esc(e.machine)) · macOS \(esc(e.macOS)) · \(String(format: "%g", e.refreshHz)) Hz display · \(esc(e.date))\(esc(versions))\(partial ? " (partial run)" : ""). Medians of repeated runs, measured from outside the apps. <a href=\"benchmarks/\">Every number and method →</a></p>\n</div></section>\n"
        return s
    }

    private static func notes(_ c: LandingContent) -> String {
        """
        <section id="notes"><div class="wrap">
        <div class="tag">Shared notes</div><h2>\(esc(c.notesTitle))</h2><p class="sub">\(esc(c.notesSub))</p>
        <ol class="flow">
        <li class="step s1"><b style="color:var(--pink)">● api-refactor</b>reads <code>auth.rs</code><br><small>and leaves a short note</small></li>
        <li class="arrow" aria-hidden="true">→</li>
        <li class="step mid s2"><b style="color:var(--accent)">Alloy's shared notes</b><code>auth.rs</code> · unchanged<br><small>summary + the exact lines</small></li>
        <li class="arrow" aria-hidden="true">→</li>
        <li class="step s3"><b style="color:var(--cyan)">● tests</b>asks the notes first<br><small>no second read</small></li>
        </ol>
        <div class="ben">\(c.notesBenefits.map { "<div><b>\(esc($0.0))</b><span>\(esc($0.1))</span></div>" }.joined())</div>
        <p class="promise">\(esc(c.notesPromise))</p>
        </div></section>

        """
    }

    private static func agents(_ c: LandingContent) -> String {
        """
        <section id="agents"><div class="wrap">
        <div class="tag">Agents</div><h2>\(esc(c.agentsTitle))</h2><p class="sub">\(esc(c.agentsSub))</p>
        <div class="ben">\(c.agentsPoints.map { "<div><b>\(esc($0.0))</b><span>\(esc($0.1))</span></div>" }.joined())</div>
        \(featureRows(c.agentsImages, c))</div></section>

        """
    }

    private static func featureRows(_ rows: [LandingContent.Feature], _ c: LandingContent) -> String {
        var s = ""
        for (i, f) in rows.enumerated() {
            let shot = c.assets.contains(f.image)
                ? "<img src=\"assets/\(esc(f.image))\" alt=\"\(esc(f.alt))\" loading=\"lazy\">"
                : "<div class=\"ph\" role=\"img\" aria-label=\"\(esc(f.alt))\"></div>"
            s += "<div class=\"feat\(i % 2 == 1 ? " r" : "")\"><div class=\"txt\"><h3>\(esc(f.title))</h3><p>\(esc(f.text))</p></div><figure class=\"shot\">\(shot)</figure></div>\n"
        }
        return s
    }

    private static func features(_ c: LandingContent) -> String {
        "<section id=\"features\"><div class=\"wrap\">\n<h2 class=\"sr\">Features</h2>\n" + featureRows(c.features, c) + "</div></section>\n"
    }

    private static func editor(_ c: LandingContent) -> String {
        """
        <section id="editor"><div class="wrap">
        <div class="tag">Code mode</div><h2>\(esc(c.editorTitle))</h2><p class="sub">\(esc(c.editorSub))</p>
        <div class="caps">\(c.editorCapabilities.map { "<div><b>\(esc($0.0))</b><span>\(esc($0.1))</span></div>" }.joined())</div>
        </div></section>

        """
    }

    private static func themes(_ c: LandingContent) -> String {
        var s = "<section id=\"themes\"><div class=\"wrap\"><div class=\"themes\">\n<div class=\"tag\">Themes</div><h2>\(esc(c.themesTitle))</h2><p class=\"sub\">\(esc(c.themesSub))</p>\n"
        for i in c.themes.indices { s += "<input class=\"vh\" type=\"radio\" name=\"theme\" id=\"th-\(i)\"\(i == 0 ? " checked" : "")>\n" }
        s += "<div class=\"sw\">"
        for (i, t) in c.themes.enumerated() {
            s += "<label for=\"th-\(i)\" class=\"sw\(i)\" style=\"background:\(t.background);color:\(t.text)\"><i style=\"background:\(t.keyword)\"></i><i style=\"background:\(t.string)\"></i><i style=\"background:\(t.function)\"></i>\(esc(t.name))</label>"
        }
        s += "<span class=\"mine\">+ yours</span></div>\n"
        s += """
        <div class="preview" role="img" aria-label="A code sample drawn in the chosen theme"><div class="bar2"></div><pre><span class="c">// Auth.swift</span>
        <span class="k">func</span> <span class="f">login</span>(_ user: User, token: Token) <span class="k">throws</span> {
          <span class="k">let</span> claims = <span class="k">try</span> token.<span class="f">verify</span>()
          <span class="f">log</span>(<span class="s">"signed in as \\(claims.subject)"</span>)
        }</pre></div>
        <p class="foot">Hover or pick a swatch to preview a theme.</p>
        </div></div></section>

        """
        return s
    }

    private static func languages(_ c: LandingContent) -> String {
        let sub = c.hasLanguageServers
            ? "\(c.languages.count) built in with tree-sitter, and anything with a language server you already have installed."
            : "\(c.languages.count) built in with tree-sitter highlighting."
        return """
        <section id="languages"><div class="wrap">
        <div class="tag">Languages</div><h2>\(esc(c.languagesTitle))</h2><p class="sub">\(esc(sub))</p>
        <ul class="pills">\(c.languages.map { "<li>\(esc($0))</li>" }.joined())</ul>
        </div></section>

        """
    }

    private static func built(_ c: LandingContent) -> String {
        let parts = c.stack.map { "<div>\(esc($0.0))<small>\(esc($0.1))</small></div>" }.joined(separator: "<span aria-hidden=\"true\">→</span>")
        return """
        <section><div class="wrap">
        <div class="tag">How it's built</div><h2>\(esc(c.builtTitle))</h2><p class="sub">\(esc(c.builtSub))</p>
        <div class="stack">\(parts)</div>
        </div></section>

        """
    }

    private static func privacy(_ c: LandingContent) -> String {
        """
        <section><div class="wrap">
        <div class="tag">Privacy</div><h2>\(esc(c.privacyTitle))</h2>
        <ul class="plain">\(c.privacyLines.map { "<li>\(esc($0))</li>" }.joined())</ul>
        </div></section>

        """
    }

    private static func faq(_ c: LandingContent) -> String {
        var s = "<section class=\"faq\" id=\"faq\"><div class=\"wrap\">\n<div class=\"tag\">FAQ</div><h2>Questions</h2>\n"
        for (i, q) in c.faq.enumerated() {
            s += "<details\(i == 0 ? " open" : "")><summary>\(esc(q.q))</summary><p>\(esc(q.a))</p></details>\n"
        }
        return s + "</div></section>\n"
    }

    private static func closing(_ c: LandingContent) -> String {
        """
        <section class="end"><div class="wrap">
        <h2>\(esc(c.downloadAvailable ? c.closingTitle : c.closingTitleSoon))</h2><p class="sub">\(esc(c.downloadAvailable ? c.closingSub : c.closingSubSoon))</p>
        <p>\(download(c, cls: "btn p", label: "Download for Mac", soon: "Coming soon"))</p>
        <p class="meta">\(c.downloadAvailable ? "<a href=\"\(esc(c.releasesURL))\">Release notes</a> · " : "")<a href="\(esc(c.repoURL))">Source on GitHub</a> · <a href="\(esc(c.issuesURL))">Issues</a> · Needs a supported coding agent</p>
        </div></section>
        </main>

        """
    }

    /// A download control: the real link once `downloadAvailable`, otherwise an inactive "Coming soon" with the same look
    /// (no href, not focusable, `aria-disabled`).
    static func download(_ c: LandingContent, cls: String, label: String, soon: String) -> String {
        c.downloadAvailable
            ? "<a class=\"\(cls)\" href=\"\(esc(c.downloadURL))\">\(label)</a>"
            : "<span class=\"\(cls) soon\" aria-disabled=\"true\">\(soon)</span>"
    }

    private static func releasesLink(_ c: LandingContent) -> String {
        c.downloadAvailable ? " · <a href=\"\(esc(c.releasesURL))\">Releases</a>" : ""
    }

    private static func footer(_ c: LandingContent) -> String {
        "<footer><div class=\"wrap\"><span>Alloy · MIT</span><span><a href=\"benchmarks/\">Benchmarks</a> · <a href=\"\(esc(c.repoURL))\">GitHub</a> · <a href=\"\(esc(c.issuesURL))\">Issues</a>\(releasesLink(c))</span></div></footer>\n"
    }

    // MARK: style

    static func css(_ c: LandingContent, wins: [RaceTest]) -> String {
        var s = base
        for i in wins.indices {
            s += "#race-\(i):checked ~ .panels .p\(i){display:block}\n"
            s += "#race-\(i):checked ~ .tabs label[for=race-\(i)]{background:var(--accent);color:var(--btn);border-color:var(--accent)}\n"
            s += "#race-\(i):focus-visible ~ .tabs label[for=race-\(i)]{outline:2px solid var(--cyan);outline-offset:2px}\n"
        }
        func vars(_ t: LandingContent.Theme) -> String {
            "--pb:\(t.background);--ps:\(t.surface);--pf:\(t.text);--pk:\(t.keyword);--ps2:\(t.string);--pc:\(t.comment);--pn:\(t.function)"
        }
        for (i, t) in c.themes.enumerated() {
            s += ".themes:has(#th-\(i):checked) .preview{\(vars(t))}\n"
            s += ".themes:has(#th-\(i):checked) label.sw\(i){outline:2px solid var(--accent);outline-offset:2px}\n"
            s += ".themes:has(#th-\(i):focus-visible) label.sw\(i){outline:2px solid var(--cyan);outline-offset:2px}\n"
        }
        for (i, t) in c.themes.enumerated() { s += ".themes:has(label.sw\(i):hover) .preview{\(vars(t))}\n" }
        return s
    }

    private static let base = """
    :root{color-scheme:dark light;--bg:#0e0e12;--panel:#17171d;--card:#1d1d24;--ink:#ececf1;--mute:#a3a3b3;--accent:#bd93f9;--green:#50fa7b;--pink:#ff79c6;--cyan:#8be9fd;--line:#26262f;--btn:#111111;--glow:#2b2240;--bar:#7a7a8e;--navbg:#0e0e12d9;--midbg:#211d2c}
    @media (prefers-color-scheme:light){:root{--bg:#fafafc;--panel:#f0f0f5;--card:#ffffff;--ink:#17171c;--mute:#5a5a6a;--accent:#6b3fc4;--green:#17692f;--pink:#b8267f;--cyan:#0b6a82;--line:#dcdce4;--btn:#ffffff;--glow:#e9e1fa;--bar:#7d7d8f;--navbg:#fafafcd9;--midbg:#f2ecfd}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
    a{color:inherit;text-decoration:none}a:focus-visible,summary:focus-visible{outline:2px solid var(--cyan);outline-offset:2px;border-radius:4px}
    code{font:0.9em ui-monospace,Menlo,monospace}.wrap{max-width:1080px;margin:0 auto;padding:0 24px}
    .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap}
    .vh{position:absolute;opacity:0;width:1px;height:1px;pointer-events:none}
    nav{position:sticky;top:0;z-index:5;background:var(--navbg);-webkit-backdrop-filter:blur(10px);backdrop-filter:blur(10px);border-bottom:1px solid var(--line)}
    nav .wrap{display:flex;justify-content:space-between;align-items:center;height:56px;font-size:14px}
    .brand{display:flex;align-items:center;gap:8px;font-size:16px}.brand img{border-radius:6px}
    nav .links a{margin-left:20px;color:var(--mute)}nav .links a:hover{color:var(--ink)}nav .links a.dl{color:var(--accent);font-weight:600}
    .btn{display:inline-block;padding:12px 22px;border-radius:10px;font-weight:700}.btn.p{background:var(--accent);color:var(--btn)}.btn.s{border:1px solid var(--line);margin-left:8px}
    .soon{cursor:default;user-select:none}.btn.p.soon{background:var(--panel);color:var(--mute);border:1px dashed var(--mute);padding:11px 21px}nav .links .dl.soon{margin-left:20px;color:var(--mute);font-weight:600;border:1px dashed var(--mute);border-radius:6px;padding:2px 8px}
    .hero{text-align:center;padding:84px 0 40px;background:radial-gradient(ellipse 70% 60% at 50% 0,var(--glow),transparent)}
    .hero h1{font-size:clamp(40px,8vw,64px);line-height:1.05;margin:0;letter-spacing:-.02em}.hero .lead{font-size:clamp(17px,2.4vw,20px);color:var(--mute);margin:14px 0 28px}
    .meta{font-size:13px;color:var(--mute);margin-top:12px}.meta a{text-decoration:underline}
    .app{margin:44px auto 0;max-width:960px;border-radius:14px;border:1px solid #44475a;box-shadow:0 30px 120px #bd93f940;overflow:hidden;background:#282a36}
    .app img,.app video{display:block;width:100%;height:auto}.app.has-poster .poster{display:none}
    .ph{aspect-ratio:16/10;display:flex;align-items:center;justify-content:center;background:#282a36;color:#6272a4;font-weight:700;font-size:28px}
    .strip{border-top:1px solid var(--line);border-bottom:1px solid var(--line);margin-top:56px}.strip .wrap{display:flex;justify-content:space-around;flex-wrap:wrap;gap:16px;padding-top:22px;padding-bottom:22px;text-align:center}
    .strip b{display:block;font-size:30px;color:var(--green)}.strip span{font-size:13px;color:var(--mute)}
    section{padding:84px 0;border-bottom:1px solid var(--line)}h2{font-size:clamp(28px,5vw,40px);line-height:1.15;margin:0 0 8px;letter-spacing:-.01em}.sub{font-size:19px;color:var(--mute);margin:0 0 30px}
    .tag{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--mute);margin-bottom:10px}
    .tabs{display:flex;flex-wrap:wrap;gap:6px}.tabs label{padding:6px 14px;border-radius:20px;border:1px solid var(--line);font-size:13px;color:var(--mute);cursor:pointer}
    .panel{display:none}.lane{margin:14px 0;display:flex;align-items:center;gap:12px}.lane .n{width:56px;font-size:13px;color:var(--mute)}
    .lane .t{flex:1;background:var(--card);border-radius:6px;height:30px;overflow:hidden}.lane .f{height:100%;border-radius:6px;background:var(--bar);animation:grow 1.8s ease-out both}.lane .f.alloy{background:var(--green)}
    @keyframes grow{from{width:0}}.lane .v{width:96px;text-align:right;font-variant-numeric:tabular-nums;font-size:14px}
    .note{font-size:12px;color:var(--mute);margin:4px 0 0}.foot{font-size:13px;color:var(--mute);margin-top:14px}.foot a{color:var(--accent)}
    .flow{list-style:none;padding:0;display:flex;align-items:stretch;gap:14px;margin:10px 0 0}.step{flex:1;background:var(--card);border-radius:12px;padding:18px;border:1px solid var(--line);animation:glow 6s infinite}
    .step.mid{border-color:var(--accent);background:var(--midbg)}.s1{animation-delay:0s}.s2{animation-delay:2s}.s3{animation-delay:4s}
    @keyframes glow{0%,33%{box-shadow:0 0 0 2px var(--accent)}34%,100%{box-shadow:0 0 0 0 transparent}}
    .arrow{align-self:center;color:var(--mute);font-size:22px}.step b{display:block;margin-bottom:6px}.step small{color:var(--mute)}
    .ben{display:flex;gap:14px;margin-top:22px}.ben div{flex:1;background:var(--card);border-radius:12px;padding:18px}.ben b{display:block;font-size:17px}.ben span{color:var(--mute);font-size:14px}
    .caps{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:14px;margin-top:22px}.caps div{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px}.caps b{display:block;font-size:17px;margin-bottom:4px}.caps span{color:var(--mute);font-size:14px}
    .promise{margin-top:18px;font-size:15px;color:var(--mute)}
    .feat{display:flex;gap:40px;align-items:center;margin:54px 0}.feat.r{flex-direction:row-reverse}.feat .txt{flex:1}.feat h3{font-size:26px;margin:0 0 8px}.feat p{color:var(--mute);margin:0}
    .shot{flex:1.2;margin:0;border-radius:12px;overflow:hidden;border:1px solid #44475a;background:#282a36}.shot img{display:block;width:100%;height:auto}.shot .ph{aspect-ratio:3/2}
    .sw{display:flex;flex-wrap:wrap;gap:12px;margin-top:20px}.sw label,.sw .mine{flex:1;min-width:130px;height:90px;border-radius:12px;display:flex;flex-direction:column;justify-content:flex-end;gap:4px;padding:10px;font-size:13px;cursor:pointer;border:1px solid var(--line)}
    .sw label i{display:inline-block;width:26px;height:6px;border-radius:3px}.sw .mine{border:1px dashed var(--mute);color:var(--mute);justify-content:center;align-items:center;cursor:default}
    .preview{--pb:#20222B;--ps:#282A36;--pf:#F8F8F2;--pk:#FF79C6;--ps2:#F1FA8C;--pc:#97A2C3;--pn:#50FA7B;margin-top:20px;border-radius:12px;background:var(--pb);border:1px solid var(--line);overflow:hidden;transition:background .25s}
    .preview pre{margin:0;padding:18px;background:var(--ps);color:var(--pf);font:13px/1.7 ui-monospace,Menlo,monospace;overflow-x:auto}.preview .bar2{height:10px;background:var(--pb)}
    .preview .k{color:var(--pk)}.preview .s{color:var(--ps2)}.preview .c{color:var(--pc)}.preview .f{color:var(--pn)}
    .pills,.plain{list-style:none;padding:0;margin:0}.pills li{display:inline-block;background:var(--card);border:1px solid var(--line);border-radius:20px;padding:6px 14px;margin:0 6px 8px 0;font-size:14px}
    .plain li{font-size:18px;color:var(--mute);margin:0 0 10px;max-width:46em}
    .stack{display:flex;flex-wrap:wrap;align-items:center;gap:12px}.stack div{background:var(--card);border-radius:12px;padding:16px 20px;border:1px solid var(--line)}.stack small{display:block;color:var(--mute)}
    .faq details{border-bottom:1px solid var(--line);padding:14px 0}.faq summary{cursor:pointer;font-weight:600}.faq p{color:var(--mute);margin:8px 0 0}
    .end{text-align:center;padding:96px 0;background:radial-gradient(ellipse 60% 70% at 50% 100%,var(--glow),transparent);border:0}
    footer{padding:26px 0;color:var(--mute);font-size:13px}footer .wrap{display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}footer a:hover{color:var(--ink)}
    @media (max-width:720px){nav .links a.opt{display:none}.wrap{padding:0 16px}.flow,.ben{flex-direction:column}.arrow{transform:rotate(90deg)}.feat,.feat.r{flex-direction:column;gap:20px;margin:36px 0}section{padding:56px 0}.hero{padding:48px 0 24px}.btn.s{margin:8px 0 0}.lane .n{width:44px}.lane .v{width:78px;font-size:13px}}
    @media (prefers-reduced-motion:reduce){.app.has-poster video{display:none}.app.has-poster .poster{display:block}*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}

    """
}
