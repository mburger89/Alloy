import Foundation

/// One metric of one app.
///
/// JSON shape (explicit, `schemaVersion` 1):
/// `{"status":"measured","summary":{...},"samples":[...],"notes":[...],"failures":[...]}`,
/// `{"status":"notApplicable","reason":"..."}` or `{"status":"notMeasured","reason":"..."}`.
/// `failures` lists failed runs only; everything informational goes in `notes`.
public enum Outcome: Codable, Sendable, Equatable {
    case measured(Summary, samples: [Double], notes: [String], failures: [String])
    case notApplicable(String)
    case notMeasured(String)

    private enum CodingKeys: String, CodingKey { case status, summary, samples, notes, failures, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .status) {
        case "measured":
            self = .measured(try c.decode(Summary.self, forKey: .summary),
                             samples: try c.decode([Double].self, forKey: .samples),
                             notes: try c.decode([String].self, forKey: .notes),
                             failures: try c.decode([String].self, forKey: .failures))
        case "notApplicable": self = .notApplicable(try c.decode(String.self, forKey: .reason))
        case "notMeasured": self = .notMeasured(try c.decode(String.self, forKey: .reason))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .status, in: c, debugDescription: "Unknown status '\(other)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .measured(let s, let samples, let notes, let failures):
            try c.encode("measured", forKey: .status)
            try c.encode(s, forKey: .summary)
            try c.encode(samples, forKey: .samples)
            try c.encode(notes, forKey: .notes)
            try c.encode(failures, forKey: .failures)
        case .notApplicable(let why):
            try c.encode("notApplicable", forKey: .status); try c.encode(why, forKey: .reason)
        case .notMeasured(let why):
            try c.encode("notMeasured", forKey: .status); try c.encode(why, forKey: .reason)
        }
    }

    /// The same outcome with `extra` appended to the notes (measured outcomes only).
    public func addingNotes(_ extra: [String]) -> Outcome {
        guard case .measured(let s, let samples, let notes, let failures) = self, !extra.isEmpty else { return self }
        return .measured(s, samples: samples, notes: notes + extra, failures: failures)
    }
}

/// Runs requested vs runs that contributed to the published result.
public struct RunCount: Codable, Sendable, Equatable {
    public var requested: Int
    public var completed: Int
    public init(requested: Int, completed: Int) { self.requested = requested; self.completed = completed }
}

public struct Environment: Codable, Sendable, Equatable {
    public var date: String
    /// Local time of the run start, `HHmmss` (part of the result file name).
    public var time: String
    public var machine: String
    public var macOS: String
    public var refreshHz: Double
    public var scale: Double
    public var onBattery: Bool
    public var cold: Bool
    /// `ProcessInfo.thermalState` at the start of the run: nominal, fair, serious or critical.
    public var thermalState: String

    public init(date: String, machine: String, macOS: String, refreshHz: Double,
                scale: Double, onBattery: Bool, cold: Bool, time: String = "000000", thermalState: String = "unknown") {
        self.date = date; self.machine = machine; self.macOS = macOS
        self.refreshHz = refreshHz; self.scale = scale; self.onBattery = onBattery; self.cold = cold
        self.time = time; self.thermalState = thermalState
    }

    private enum CodingKeys: String, CodingKey {
        case date, time, machine, macOS, refreshHz, scale, onBattery, cold, thermalState
    }

    /// Published copies omit scale, battery, cold and thermal state; they decode to neutral defaults.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? "000000"
        machine = try c.decode(String.self, forKey: .machine)
        macOS = try c.decode(String.self, forKey: .macOS)
        refreshHz = try c.decode(Double.self, forKey: .refreshHz)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 0
        onBattery = try c.decodeIfPresent(Bool.self, forKey: .onBattery) ?? false
        cold = try c.decodeIfPresent(Bool.self, forKey: .cold) ?? false
        thermalState = try c.decodeIfPresent(String.self, forKey: .thermalState) ?? "unknown"
    }
}

public struct RunResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// `git rev-parse --short HEAD` of the harness checkout, or "unknown".
    public var harnessSHA: String
    public var environment: Environment
    /// app id -> version
    public var apps: [String: String]
    /// app id -> metric -> outcome
    public var outcomes: [String: [Metric: Outcome]]
    /// app id -> metric -> requested vs completed runs (absent for not-applicable metrics)
    public var runCounts: [String: [Metric: RunCount]]
    /// Run-level notes, e.g. leftover-process warnings.
    public var notes: [String]
    /// True when the run was made with `--attribute` (triage only; never published). Absent in older JSON.
    public var attributed: Bool
    /// True when the run recorded Instruments traces (`--trace`; timings include profiler overhead, never published).
    public var traced: Bool
    /// The kind of trace recorded, when `traced`.
    public var traceKind: TraceKind?

    public init(environment: Environment, apps: [String: String], outcomes: [String: [Metric: Outcome]],
                harnessSHA: String = "unknown", runCounts: [String: [Metric: RunCount]] = [:], notes: [String] = [], attributed: Bool = false,
                traced: Bool = false, traceKind: TraceKind? = nil,
                schemaVersion: Int = RunResult.currentSchemaVersion) {
        self.schemaVersion = schemaVersion; self.harnessSHA = harnessSHA
        self.environment = environment; self.apps = apps; self.outcomes = outcomes
        self.runCounts = runCounts; self.notes = notes; self.attributed = attributed
        self.traced = traced; self.traceKind = traceKind
    }

    // Swift encodes dictionaries with non-String/Int keys as flat arrays; use string keys for a readable JSON object.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, harnessSHA, environment, apps, runCounts, outcomes, notes, attributed, traced, traceKind
    }

    private static func metricKeyed<T>(_ raw: [String: T], _ c: KeyedDecodingContainer<CodingKeys>,
                                       _ key: CodingKeys) throws -> [Metric: T] {
        var out: [Metric: T] = [:]
        for (k, v) in raw {
            guard let m = Metric(rawValue: k) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Unknown metric '\(k)'")
            }
            out[m] = v
        }
        return out
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        harnessSHA = try c.decode(String.self, forKey: .harnessSHA)
        environment = try c.decode(Environment.self, forKey: .environment)
        apps = try c.decode([String: String].self, forKey: .apps)
        notes = try c.decode([String].self, forKey: .notes)
        attributed = try c.decodeIfPresent(Bool.self, forKey: .attributed) ?? false
        traced = try c.decodeIfPresent(Bool.self, forKey: .traced) ?? false
        traceKind = try c.decodeIfPresent(TraceKind.self, forKey: .traceKind)
        outcomes = try c.decode([String: [String: Outcome]].self, forKey: .outcomes)
            .mapValues { try Self.metricKeyed($0, c, .outcomes) }
        runCounts = try c.decode([String: [String: RunCount]].self, forKey: .runCounts)
            .mapValues { try Self.metricKeyed($0, c, .runCounts) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(harnessSHA, forKey: .harnessSHA)
        try c.encode(environment, forKey: .environment)
        try c.encode(apps, forKey: .apps)
        try c.encode(notes, forKey: .notes)
        if attributed { try c.encode(true, forKey: .attributed) }
        if traced { try c.encode(true, forKey: .traced) }
        try c.encodeIfPresent(traceKind, forKey: .traceKind)
        try c.encode(outcomes.mapValues { inner in Dictionary(uniqueKeysWithValues: inner.map { ($0.key.rawValue, $0.value) }) },
                     forKey: .outcomes)
        try c.encode(runCounts.mapValues { inner in Dictionary(uniqueKeysWithValues: inner.map { ($0.key.rawValue, $0.value) }) },
                     forKey: .runCounts)
    }
}

public enum Report {
    static let columns: [(id: String, name: String)] = [("zed", "Zed"), ("delta", "Delta"), ("alloy", "Alloy")]

    public static func fileStem(_ r: RunResult) -> String {
        "\(r.environment.date)-\(r.environment.time)-\(r.environment.machine)"
    }

    public static func markdown(_ r: RunResult) -> String {
        let e = r.environment
        var lines: [String] = []
        lines.append("# Alloy benchmark \(e.date) \(e.time)")
        lines.append("")
        lines.append("- Machine: \(e.machine), macOS \(e.macOS), thermal state \(e.thermalState)")
        lines.append("- Display: \(format(e.refreshHz)) Hz, scale \(format(e.scale))")
        lines.append("- Power: \(e.onBattery ? "battery" : "AC"), \(e.cold ? "cold" : "warm")")
        lines.append("- Harness: \(r.harnessSHA), schema \(r.schemaVersion)")
        let versions = columns.compactMap { c in r.apps[c.id].map { "\(c.name) \($0)" } }
        if !versions.isEmpty { lines.append("- Versions: " + versions.joined(separator: ", ")) }
        if r.traced {
            lines.append("- Traced (\(r.traceKind?.rawValue ?? "unknown")): timings include profiler overhead; not publishable")
        }
        lines.append("")
        lines.append("| Metric | " + columns.map(\.name).joined(separator: " | ") + " | Note |")
        lines.append("|---|" + columns.map { _ in "---|" }.joined() + "---|")
        let verdicts = Parity.judgeAll(r)
        for m in Metric.allCases {
            let note = verdicts[m].map(noteText) ?? ""
            lines.append("| \(m.rawValue) | " + columns.map { cell(r.outcomes[$0.id]?[m]) }.joined(separator: " | ") + " | \(note) |")
        }
        var detail: [String] = []
        for c in columns {
            for m in Metric.allCases {
                guard let o = r.outcomes[c.id]?[m] else { continue }
                if case .measured(_, _, let notes, let failures) = o {
                    for n in notes { detail.append("- \(c.name) \(m.rawValue): \(escape(n))") }
                    for f in failures { detail.append("- \(c.name) \(m.rawValue) FAILED: \(escape(f))") }
                }
                if let rc = r.runCounts[c.id]?[m], rc.completed != rc.requested {
                    detail.append("- \(c.name) \(m.rawValue): \(rc.completed) of \(rc.requested) runs completed")
                }
            }
        }
        for n in r.notes { detail.append("- \(escape(n))") }
        if !detail.isEmpty { lines.append(""); lines.append("## Notes"); lines.append(""); lines += detail }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func noteText(_ v: Verdict) -> String {
        switch v {
        case .ahead: return "ahead"
        case .par: return "par"
        case .behind(let why): return escape("⚠ behind Zed: \(why)")
        case .missing(let why): return escape("⚠ missing: \(why)")
        case .unjudged(let why): return escape("unjudged: \(why)")
        }
    }

    /// Cell text must not contain a raw `|` or a newline, or GFM breaks the row.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func cell(_ o: Outcome?) -> String {
        switch o {
        case nil: return "-"
        case .measured(let s, _, _, let failures)?:
            var t = "\(format(s.median)) \(s.unit) (p95 \(format(s.p95)))"
            if !failures.isEmpty { t += ", \(failures.count) failed" }
            return escape(t)
        case .notApplicable(let why)?: return escape("n/a (\(why))")
        case .notMeasured(let why)?: return escape("not measured (\(why))")
        }
    }

    private static func format(_ v: Double) -> String { String(format: "%.1f", v) }
}
