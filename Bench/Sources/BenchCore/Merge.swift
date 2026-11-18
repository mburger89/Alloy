import Foundation

/// Combines two result files into one publishable result (`alloy-bench merge`).
public enum ResultMerger {
    public static let dropNote = "first timed launch excluded as warm-up (same for every app)"

    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case schema(Int), attributed(String), traced(String)
        case environment(String)
        case unknownApp(String)

        public var description: String {
            switch self {
            case .schema(let v): return "unsupported result schemaVersion \(v) (expected \(RunResult.currentSchemaVersion))"
            case .attributed(let which): return "the \(which) result was made with --attribute (triage only); cannot merge it"
            case .traced(let which): return "the \(which) result was made with --trace (profiler overhead); cannot merge it"
            case .environment(let why): return "environments differ (\(why)); results from different setups are not comparable"
            case .unknownApp(let app): return "app '\(app)' is not in the override result"
            }
        }
    }

    /// Fields that must be equal for two runs to be comparable; empty when they match.
    static func environmentMismatches(_ a: Environment, _ b: Environment) -> [String] {
        var out: [String] = []
        if a.machine != b.machine { out.append("machine \(a.machine) vs \(b.machine)") }
        if a.macOS != b.macOS { out.append("macOS \(a.macOS) vs \(b.macOS)") }
        if a.refreshHz != b.refreshHz { out.append("refresh \(a.refreshHz) Hz vs \(b.refreshHz) Hz") }
        if a.scale != b.scale { out.append("scale \(a.scale) vs \(b.scale)") }
        if a.onBattery != b.onBattery { out.append("power \(a.onBattery ? "battery" : "AC") vs \(b.onBattery ? "battery" : "AC")") }
        if a.cold != b.cold { out.append("\(a.cold ? "cold" : "warm") vs \(b.cold ? "cold" : "warm")") }
        return out
    }

    /// `base` with `apps` (default: every app in `override`) taken wholesale from `override`.
    public static func merge(base: RunResult, override: RunResult, apps: [String]? = nil,
                             dropFirstStartup: Bool) throws(Refusal) -> RunResult {
        for (name, r) in [("base", base), ("override", override)] {
            guard r.schemaVersion == RunResult.currentSchemaVersion else { throw .schema(r.schemaVersion) }
            if r.attributed { throw .attributed(name) }
            if r.traced { throw .traced(name) }
        }
        let mismatches = environmentMismatches(base.environment, override.environment)
        if !mismatches.isEmpty { throw .environment(mismatches.joined(separator: "; ")) }

        let taken = apps ?? override.apps.keys.sorted()
        for app in taken where override.apps[app] == nil && override.outcomes[app] == nil { throw .unknownApp(app) }

        let overrideIsLater = (override.environment.date, override.environment.time) >= (base.environment.date, base.environment.time)
        let later = overrideIsLater ? override : base
        var out = base
        out.environment = later.environment
        out.harnessSHA = base.harnessSHA
        var notes = base.notes
        if base.harnessSHA != override.harnessSHA {
            out.harnessSHA = later.harnessSHA
            notes.append("harness differs between runs: \(Report.fileStem(base)) used \(base.harnessSHA), "
                         + "\(Report.fileStem(override)) used \(override.harnessSHA); kept \(later.harnessSHA)")
        }
        for app in taken {
            out.apps[app] = override.apps[app]
            out.outcomes[app] = override.outcomes[app]
            out.runCounts[app] = override.runCounts[app]
        }
        notes.append("merged from \(Report.fileStem(base)) and \(Report.fileStem(override)): \(taken.joined(separator: ", ")) from the latter")
        out.notes = notes
        out.attributed = false; out.traced = false; out.traceKind = nil
        if dropFirstStartup { dropFirstStartupSample(&out) }
        return out
    }

    /// Removes the first startup sample of every measured startup outcome that has no warm-up launch of its own.
    static func dropFirstStartupSample(_ r: inout RunResult) {
        for app in r.outcomes.keys.sorted() {
            guard case .measured(let summary, let samples, let notes, let failures)? = r.outcomes[app]?[.startup],
                  !notes.contains(RunMarkers.warmUpNote), !notes.contains(dropNote) else { continue }
            let rest = Array(samples.dropFirst())
            let old = r.runCounts[app]?[.startup]
            // Startup is strict (every run must survive), so the only minimum is one sample.
            if let s = Stats.summarize(rest, unit: summary.unit) {
                r.outcomes[app]?[.startup] = .measured(s, samples: rest, notes: notes + [dropNote], failures: failures)
                if let old { r.runCounts[app]?[.startup] = RunCount(requested: max(old.requested - 1, 0), completed: max(old.completed - 1, 0)) }
            } else {
                r.outcomes[app]?[.startup] = .notMeasured("no samples left after excluding the first timed launch as warm-up")
                if let old { r.runCounts[app]?[.startup] = RunCount(requested: max(old.requested - 1, 0), completed: 0) }
            }
        }
    }
}
