import Foundation

/// How close the candidate must be to the baseline to count as level with it.
public struct ParityBar: Sendable, Equatable {
    /// Fraction of the baseline value tolerated either way.
    public var relative: Double
    /// Unit -> absolute floor, so tiny baselines do not demand sub-noise precision.
    public var floors: [String: Double]
    /// Whether p95 must also be within tolerance (median alone otherwise).
    public var judgeP95: Bool

    public init(relative: Double, floors: [String: Double], judgeP95: Bool) {
        self.relative = relative; self.floors = floors; self.judgeP95 = judgeP95
    }

    public static let `default` = ParityBar(relative: 0.05, floors: ["ms": 1.0, "MiB": 2.0, "%": 0.1], judgeP95: true)

    public func tolerance(baseline: Double, unit: String) -> Double {
        max(relative * baseline, floors[unit] ?? 0)
    }
}

public enum Verdict: Sendable, Equatable {
    /// Median and (if judged) p95 strictly below baseline minus tolerance.
    case ahead
    /// Within tolerance, not ahead.
    case par
    /// Which statistic, both values, e.g. "median 14.2 ms vs Zed 12.1 ms".
    case behind(String)
    /// Baseline measured, candidate not: the candidate's reason.
    case missing(String)
    /// Baseline not measured: its reason.
    case unjudged(String)
}

public enum Parity {
    public static func judge(_ r: RunResult, metric: Metric, candidate: String = "alloy",
                             baseline: String = "zed", bar: ParityBar = .default) -> Verdict {
        let base = r.outcomes[baseline]?[metric]
        guard case .measured(let b, _, _, _)? = base else {
            return .unjudged(reason(base, who: baseline))
        }
        let cand = r.outcomes[candidate]?[metric]
        guard case .measured(let c, _, _, _)? = cand else {
            return .missing(reason(cand, who: candidate))
        }
        let name = baseline.prefix(1).uppercased() + baseline.dropFirst()
        let unit = b.unit
        func line(_ stat: String, _ cv: Double, _ bv: Double) -> String {
            "\(stat) \(f(cv)) \(unit) vs \(name) \(f(bv)) \(unit)"
        }
        let medTol = bar.tolerance(baseline: b.median, unit: unit)
        if c.median > b.median + medTol { return .behind(line("median", c.median, b.median)) }
        let p95Tol = bar.tolerance(baseline: b.p95, unit: unit)
        if bar.judgeP95, c.p95 > b.p95 + p95Tol { return .behind(line("p95", c.p95, b.p95)) }
        let medAhead = c.median < b.median - medTol
        let p95Ahead = !bar.judgeP95 || c.p95 < b.p95 - p95Tol
        return medAhead && p95Ahead ? .ahead : .par
    }

    public static func judgeAll(_ r: RunResult, bar: ParityBar = .default) -> [Metric: Verdict] {
        var out: [Metric: Verdict] = [:]
        for m in Metric.allCases where r.outcomes["zed"]?[m] != nil && r.outcomes["alloy"]?[m] != nil {
            out[m] = judge(r, metric: m, bar: bar)
        }
        return out
    }

    public static func isShortfall(_ v: Verdict) -> Bool {
        switch v {
        case .behind, .missing: return true
        case .ahead, .par, .unjudged: return false
        }
    }

    private static func reason(_ o: Outcome?, who: String) -> String {
        switch o {
        case nil: return "\(who) has no result"
        case .notMeasured(let why)?: return why
        case .notApplicable(let why)?: return "n/a: \(why)"
        case .measured?: return "measured"
        }
    }

    private static func f(_ v: Double) -> String { String(format: "%.1f", v) }
}
