import Foundation

/// Small inline-SVG history chart: Zed vs Alloy medians for one metric across published runs.
/// Series colours come from the page's CSS custom properties (`--zed`, `--alloy`), so light and dark follow the page.
public enum SiteChart {
    /// nil when fewer than two runs have both Zed and Alloy measured for the metric.
    public static func svg(metric: Metric, runs: [RunResult]) -> String? {
        struct Point { var date: String; var zed: Double; var alloy: Double; var unit: String }
        var pts: [Point] = []
        for r in runs {
            guard case .measured(let z, _, _, _)? = r.outcomes["zed"]?[metric],
                  case .measured(let a, _, _, _)? = r.outcomes["alloy"]?[metric] else { continue }
            pts.append(Point(date: r.environment.date, zed: z.median, alloy: a.median, unit: z.unit))
        }
        guard pts.count >= 2 else { return nil }

        let w = 320.0, h = 120.0, left = 40.0, right = 10.0, top = 10.0, bottom = 24.0
        let top95 = max(pts.map { max($0.zed, $0.alloy) }.max() ?? 1, 0.000_001)
        func x(_ i: Int) -> Double { left + (w - left - right) * Double(i) / Double(pts.count - 1) }
        func y(_ v: Double) -> Double { top + (h - top - bottom) * (1 - v / top95) }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        func line(_ cls: String, _ get: (Point) -> Double) -> String {
            let coords = pts.indices.map { "\(f(x($0))),\(f(y(get(pts[$0]))))" }.joined(separator: " ")
            let dots = pts.indices.map {
                "<circle class=\"dot \(cls)\" cx=\"\(f(x($0)))\" cy=\"\(f(y(get(pts[$0]))))\" r=\"3\"/>"
            }.joined()
            return "<polyline class=\"series \(cls)\" points=\"\(coords)\"/>" + dots
        }
        let unit = SitePage.escape(pts[0].unit)
        let label = "\(SitePage.title(metric)) median over \(pts.count) runs, Zed and Alloy, in \(pts[0].unit)"
        var s = "<svg viewBox=\"0 0 \(Int(w)) \(Int(h))\" role=\"img\" aria-label=\"\(SitePage.escape(label))\">"
        s += "<line class=\"axis\" x1=\"\(Int(left))\" y1=\"\(f(y(0)))\" x2=\"\(Int(w - right))\" y2=\"\(f(y(0)))\"/>"
        s += "<line class=\"axis\" x1=\"\(Int(left))\" y1=\"\(Int(top))\" x2=\"\(Int(left))\" y2=\"\(f(y(0)))\"/>"
        s += "<text class=\"tick\" x=\"\(Int(left) - 4)\" y=\"\(Int(top) + 4)\" text-anchor=\"end\">\(f(top95))</text>"
        s += "<text class=\"tick\" x=\"\(Int(left) - 4)\" y=\"\(f(y(0)))\" text-anchor=\"end\">0</text>"
        s += "<text class=\"tick\" x=\"\(Int(left))\" y=\"\(Int(h) - 8)\">\(SitePage.escape(pts[0].date))</text>"
        s += "<text class=\"tick\" x=\"\(Int(w - right))\" y=\"\(Int(h) - 8)\" text-anchor=\"end\">\(SitePage.escape(pts[pts.count - 1].date))</text>"
        s += "<text class=\"tick\" x=\"\(Int(left) + 4)\" y=\"\(Int(top) + 4)\">\(unit)</text>"
        s += line("zed") { $0.zed } + line("alloy") { $0.alloy }
        return s + "</svg>"
    }
}
