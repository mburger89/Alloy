import Foundation

/// Renders the static results page. Output is deterministic: no timestamps, fixed iteration order, no scripts and
/// no external resources.
public enum SitePage {
    public enum LoadError: Error, CustomStringConvertible {
        case missing(String), noFolder(String)
        public var description: String {
            switch self {
            case .noFolder(let path): return "no published results folder at \(path)"
            case .missing(let stem): return "index lists \(stem) but \(stem).json is not in the published directory" }
        }
    }

    /// Reads `index.json` and every run it lists. An existing folder without index.json is the empty case; a missing folder is an error.
    public static func load(publishedDir: URL) throws -> (index: PublishedIndex, runs: [RunResult]) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: publishedDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw LoadError.noFolder(publishedDir.path)
        }
        let indexURL = publishedDir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return (PublishedIndex(), []) }
        let index = try JSONDecoder().decode(PublishedIndex.self, from: data)
        var runs: [RunResult] = []
        for e in index.runs {
            guard let d = try? Data(contentsOf: publishedDir.appendingPathComponent(e.stem + ".json")) else {
                throw LoadError.missing(e.stem)
            }
            runs.append(try JSONDecoder().decode(RunResult.self, from: d))
        }
        return (index, runs)
    }

    /// `runs` are the published results in index order (oldest first); the newest is the headline.
    public static func render(index: PublishedIndex, runs: [RunResult]) -> String {
        var body = "<h1>Alloy benchmarks</h1>\n"
        body += "<p class=\"lead\">Alloy (built on MetalUI) measured against Zed and Delta on the same Mac, from outside the apps.</p>\n"
        if let latest = runs.last, let entry = index.runs.last {
            body += headline(latest, partial: entry.partial)
            body += table(latest)
            body += environment(latest)
            body += notes(latest)
            body += method(hasRuns: true)
            body += history(runs)
            body += links(index)
        } else {
            body += "<p class=\"empty\">No published results yet.</p>\n"
            body += method(hasRuns: false)
        }
        return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            + "<title>Alloy benchmarks</title>\n<style>\n\(css)</style>\n</head>\n<body>\n<main>\n\(body)</main>\n</body>\n</html>\n"
    }

    // MARK: sections

    private static func headline(_ r: RunResult, partial: Bool) -> String {
        let verdicts = Metric.allCases.map { Parity.judge(r, metric: $0) }
        let judged = verdicts.filter { if case .unjudged = $0 { return false } else { return true } }
        let good = judged.filter { $0 == .ahead || $0 == .par }.count
        var s = "<h2 class=\"headline\">Alloy is at par or ahead of Zed on \(good) of \(judged.count) measured metrics"
        if partial { s += " <span class=\"badge\">partial run</span>" }
        s += "</h2>\n"
        s += "<p class=\"muted\">Newest run: \(escape(r.environment.date)).</p>\n"
        if partial {
            s += "<p>This is a partial run: some results were not attempted, so the count above covers less than the full set.</p>\n"
        }
        return s
    }

    private static func table(_ r: RunResult) -> String {
        var s = "<div class=\"scroll\"><table>\n<thead><tr><th>Metric</th><th>Zed</th><th>Delta</th><th>Alloy</th><th>Verdict</th></tr></thead>\n<tbody>\n"
        for m in Metric.allCases {
            let v = Parity.judge(r, metric: m)
            let word = Publisher.word(v)
            var vcell = "<span class=\"verdict \(word)\">\(word)</span>"
            switch v {
            case .behind(let why), .missing(let why), .unjudged(let why): vcell += " <span class=\"why\">\(escape(why))</span>"
            case .ahead, .par: break
            }
            s += "<tr><th scope=\"row\">\(title(m))</th>"
            for app in ["zed", "delta", "alloy"] { s += "<td>\(cell(r.outcomes[app]?[m]))</td>" }
            s += "<td>\(vcell)</td></tr>\n"
        }
        return s + "</tbody>\n</table></div>\n"
    }

    private static func cell(_ o: Outcome?) -> String {
        switch o {
        case nil: return "<span class=\"muted\">no result</span>"
        case .measured(let s, _, _, _)?:
            return escape("\(num(s.median)) \(s.unit) (p95 \(num(s.p95)))")
        case .notApplicable(let why)?: return "<span class=\"muted\">\(escape("n/a — \(why)"))</span>"
        case .notMeasured(let why)?: return "<span class=\"muted\">\(escape("not measured — \(why)"))</span>"
        }
    }

    private static func environment(_ r: RunResult) -> String {
        let e = r.environment
        var rows: [(String, String)] = [
            ("Date", e.date), ("Machine", e.machine), ("macOS", e.macOS),
            ("Display refresh rate", num(e.refreshHz) + " Hz"),
            ("Start", e.cold ? "cold" : "warm"),
            ("Harness", r.harnessSHA),
        ]
        for (id, name) in [("zed", "Zed"), ("delta", "Delta"), ("alloy", "Alloy")] {
            if let v = r.apps[id] { rows.append((name + " version", v)) }
        }
        var s = "<h2>Environment and versions</h2>\n<dl>\n"
        for (k, v) in rows { s += "<dt>\(escape(k))</dt><dd>\(escape(v))</dd>\n" }
        return s + "</dl>\n"
    }

    private static func notes(_ r: RunResult) -> String {
        var items: [String] = []
        for (id, name) in [("zed", "Zed"), ("delta", "Delta"), ("alloy", "Alloy")] {
            for m in Metric.allCases {
                if case .measured(_, _, let notes, let failures)? = r.outcomes[id]?[m] {
                    for n in notes { items.append("\(name) \(title(m)): \(n)") }
                    for f in failures { items.append("\(name) \(title(m)), failed run: \(f)") }
                }
                if let rc = r.runCounts[id]?[m], rc.completed != rc.requested {
                    items.append("\(name) \(title(m)): \(rc.completed) of \(rc.requested) runs completed")
                }
            }
        }
        items += r.notes
        guard !items.isEmpty else { return "" }
        return "<h2>Run notes</h2>\n<ul>\n" + items.map { "<li>\(escape($0))</li>\n" }.joined() + "</ul>\n"
    }

    private static func method(hasRuns: Bool) -> String {
        let bar = ParityBar.default
        let floors = ["ms", "MiB", "%"].compactMap { u in bar.floors[u].map { "\(num($0)) \(u)" } }.joined(separator: ", ")
        let pct = num(bar.relative * 100)
        return """
        <h2>How this is measured</h2>
        <ul>
        <li>The harness drives each app from outside, with synthetic input, and detects changes by comparing screen captures. It does not rely on anything the apps report about themselves.</li>
        <li>Every metric is repeated and the page shows the median and the 95th percentile (p95) of the runs that survived. A run is dropped when its window never appeared, the screen changed before the window, or capture dropped frames; failures are listed in the run notes.</li>
        <li>Startup and large-file open are strict: if any run is excluded the whole metric shows as not measured, never a median of survivors.</li>
        <li>Pass bar: Alloy is at par with Zed when both its median and its p95 are within the larger of \(pct) % of Zed's value or an absolute floor (\(floors)) of Zed's. It is ahead when both are lower than Zed's by more than that margin, and behind when either is higher by more than that margin. The headline counts at par and ahead.</li>
        <li>A row is missing when Zed was measured but Alloy was not, and unjudged when Zed was not measured. Parity is judged against Zed only; Delta is shown for context.</li>
        <li>Delta has no isolated profile option, so it runs against a normal Delta profile and state.</li>
        <li>Scroll frame times cannot be lower than one display refresh period, so they floor at that value.</li>
        <li>Results come from one machine and one run each time, so treat small differences with caution.\(hasRuns ? " Raw samples are in the JSON files linked below." : "")</li>
        </ul>

        """
    }

    private static func history(_ runs: [RunResult]) -> String {
        let charts = Metric.allCases.compactMap { m in SiteChart.svg(metric: m, runs: runs).map { (m, $0) } }
        guard !charts.isEmpty else { return "" }
        var s = "<h2>History</h2>\n<p class=\"legend\"><span class=\"key zed\">Zed median</span> <span class=\"key alloy\">Alloy median</span></p>\n<div class=\"charts\">\n"
        for (m, svg) in charts { s += "<figure><figcaption>\(title(m))</figcaption>\(svg)</figure>\n" }
        return s + "</div>\n"
    }

    private static func links(_ index: PublishedIndex) -> String {
        var s = "<h2>Raw results</h2>\n<ul>\n"
        for e in index.runs.reversed() {
            s += "<li><a href=\"data/\(escape(e.stem)).json\">\(escape(e.stem)).json</a>\(e.partial ? " (partial run)" : "")</li>\n"
        }
        return s + "</ul>\n"
    }

    // MARK: helpers

    static func title(_ m: Metric) -> String {
        switch m {
        case .startup: return "Startup"
        case .typingLatency: return "Typing latency"
        case .scrollFrames: return "Scroll frame time"
        case .memory: return "Memory"
        case .memoryIdle: return "Memory, idle"
        case .largeFileOpen: return "Large file open"
        case .idleCPU: return "Idle CPU"
        }
    }

    static func num(_ v: Double) -> String { String(format: "%.1f", v) }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root { color-scheme: light dark; --bg: #ffffff; --fg: #1a1a1f; --muted: #5c5c66; --line: #d8d8de; --panel: #f5f5f8;
      --zed: #1f5fd1; --alloy: #c2410c; --good: #17692f; --bad: #b3261e; --warn: #8a5a00; }
    @media (prefers-color-scheme: dark) {
      :root { --bg: #111114; --fg: #e8e8ec; --muted: #a0a0ab; --line: #34343c; --panel: #1b1b20;
        --zed: #6cb0ff; --alloy: #ff9a5c; --good: #6fd08c; --bad: #ff8a80; --warn: #e6b84d; } }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
    main { max-width: 60rem; margin: 0 auto; padding: 24px 16px 48px; }
    h1 { font-size: 1.8rem; margin: 0 0 4px; }
    h2 { font-size: 1.2rem; margin: 32px 0 8px; }
    h2.headline { font-size: 1.35rem; margin-top: 24px; }
    .lead { color: var(--muted); margin: 0; }
    .muted, .why { color: var(--muted); }
    .empty { font-size: 1.2rem; margin-top: 32px; }
    .badge { display: inline-block; font-size: 0.8rem; font-weight: 600; padding: 1px 8px; border: 1px solid var(--warn); color: var(--warn); border-radius: 999px; vertical-align: middle; }
    .scroll { overflow-x: auto; }
    table { border-collapse: collapse; width: 100%; min-width: 40rem; }
    th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
    thead th { background: var(--panel); }
    .verdict { font-weight: 600; }
    .verdict.ahead, .verdict.par { color: var(--good); }
    .verdict.behind, .verdict.missing { color: var(--bad); }
    .verdict.unjudged { color: var(--muted); }
    dl { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; margin: 0; }
    dt { color: var(--muted); } dd { margin: 0; overflow-wrap: anywhere; }
    li { margin: 4px 0; overflow-wrap: anywhere; }
    .charts { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 16px; }
    figure { margin: 0; padding: 8px; background: var(--panel); border: 1px solid var(--line); border-radius: 6px; }
    figcaption { font-weight: 600; font-size: 0.9rem; }
    svg { width: 100%; height: auto; display: block; }
    .axis { stroke: var(--line); stroke-width: 1; }
    .tick { fill: var(--muted); font-size: 9px; }
    .series { fill: none; stroke-width: 2; }
    .series.zed { stroke: var(--zed); } .dot.zed { fill: var(--zed); }
    .series.alloy { stroke: var(--alloy); stroke-dasharray: 5 3; } .dot.alloy { fill: var(--alloy); }
    .key { font-weight: 600; margin-right: 16px; } .key.zed { color: var(--zed); } .key.alloy { color: var(--alloy); }
    a { color: var(--zed); }

    """
}
