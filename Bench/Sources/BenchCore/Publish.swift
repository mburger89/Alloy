import Foundation

/// Message prefixes the runner puts on outcomes it did not attempt; the publisher treats them as partial.
public enum RunMarkers {
    public static let refusedPrefix = "preflight refused: "
    public static let abortedPrefix = "not run, aborted: "
    public static func isRefusalOrAbort(_ why: String) -> Bool {
        why.hasPrefix(refusedPrefix) || why.hasPrefix(abortedPrefix)
    }
}

/// Removes machine-specific paths from result strings and detects what is left over.
public struct Scrubber: Sendable {
    let home: String
    let userName: String

    public init(home: String, userName: String) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.userName = userName
    }

    private static let tmpPattern = #"(?<![\w.~/-])(?:/private)?/(?:var/folders|tmp)(?:/[^\s'"`)\]>,;]*)?"#

    /// The home path at a path-component boundary only (not /home/testerX).
    static func homePattern(_ home: String) -> String {
        NSRegularExpression.escapedPattern(for: home) + #"(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])"#
    }

    public func scrub(_ s: String) -> String {
        var out = s
        if home.count > 1, let hre = try? NSRegularExpression(pattern: Self.homePattern(home)) {
            out = hre.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "~")
        }
        guard let re = try? NSRegularExpression(pattern: Self.tmpPattern) else { return out }
        return re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "<tmp>")
    }

    public func scrub(_ o: Outcome) -> Outcome {
        switch o {
        case .measured(let s, let samples, let notes, let failures):
            return .measured(s, samples: samples, notes: notes.map(scrub), failures: failures.map(scrub))
        case .notApplicable(let why): return .notApplicable(scrub(why))
        case .notMeasured(let why): return .notMeasured(scrub(why))
        }
    }

    public func scrub(_ r: RunResult) -> RunResult {
        var out = r
        out.notes = r.notes.map(scrub)
        out.apps = r.apps.mapValues(scrub)
        out.outcomes = r.outcomes.mapValues { $0.mapValues(scrub) }
        return out
    }

    /// Remaining hits (the matching text) that must not be published.
    public func leaks(in text: String) -> [String] {
        var hits: [String] = []
        func collect(_ pattern: String, options: NSRegularExpression.Options = []) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range, in: text) { hits.append(String(text[r])) }
            }
        }
        if !userName.isEmpty { collect(#"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: userName) + #"(?![A-Za-z0-9])"#, options: [.caseInsensitive]) }
        collect(#"/Users/[A-Za-z]\S*"#)
        if home.count > 1 { collect(Self.homePattern(home) + #"\S*"#) }
        collect(#"claude\.ai/code/\S*"#)
        collect(#"session_[A-Za-z0-9]{8,}"#)
        var seen = Set<String>()
        return hits.filter { seen.insert($0).inserted }
    }
}

public struct PublishedEntry: Codable, Sendable, Equatable {
    public var stem: String
    public var date: String
    public var harnessSHA: String
    public var apps: [String: String]
    public var partial: Bool
    /// metric rawValue -> "ahead" | "par" | "behind" | "missing" | "unjudged"
    public var verdicts: [String: String]

    public init(stem: String, date: String, harnessSHA: String, apps: [String: String],
                partial: Bool, verdicts: [String: String]) {
        self.stem = stem; self.date = date; self.harnessSHA = harnessSHA
        self.apps = apps; self.partial = partial; self.verdicts = verdicts
    }
}

public struct PublishedIndex: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Sorted by stem ascending, unique by stem.
    public var runs: [PublishedEntry]

    public init(schemaVersion: Int = 1, runs: [PublishedEntry] = []) {
        self.schemaVersion = schemaVersion; self.runs = runs
    }

    public mutating func upsert(_ e: PublishedEntry) {
        runs.removeAll { $0.stem == e.stem }
        runs.append(e)
        runs.sort { $0.stem < $1.stem }
    }
}

public enum Publisher {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case partial(String), leak([String]), schema(Int), encoding(String), attributed, traced

        public var description: String {
            switch self {
            case .partial(let why): return "refusing partial run: \(why) (use --allow-partial to publish anyway)"
            case .leak(let hits): return "refusing to publish, remaining private text: " + hits.joined(separator: ", ")
            case .attributed: return "runs made with --attribute are for triage only; rerun without it to publish"
            case .traced: return "runs made with --trace include profiler overhead; rerun without it to publish"
            case .encoding(let why): return "cannot encode result: \(why)"
            case .schema(let v): return "unsupported result schemaVersion \(v) (expected \(RunResult.currentSchemaVersion))"
            }
        }
    }

    /// Why the run is incomplete, or nil. Every metric is considered, so an absent result counts.
    static func partialReason(_ r: RunResult) -> String? {
        for m in Metric.allCases {
            for app in ["zed", "alloy"] {
                switch r.outcomes[app]?[m] {
                case nil: return "\(app) has no \(m.rawValue) result"
                case .notMeasured(let why)? where RunMarkers.isRefusalOrAbort(why): return "\(app) \(m.rawValue): \(why)"
                default: break
                }
            }
        }
        return nil
    }

    /// Published environment keeps model, macOS, refresh rate, date, time and cold (method).
    static func publishedJSON(_ r: RunResult, encoder: JSONEncoder) throws -> Data {
        let raw = try encoder.encode(r)
        guard var obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var env = obj["environment"] as? [String: Any] else { return raw }
        for k in ["scale", "onBattery", "thermalState"] { env[k] = nil }
        obj["environment"] = env
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func word(_ v: Verdict) -> String {
        switch v {
        case .ahead: return "ahead"
        case .par: return "par"
        case .behind: return "behind"
        case .missing: return "missing"
        case .unjudged: return "unjudged"
        }
    }

    /// Belt and braces: attribution notes never reach a published outcome.
    static func stripAttribution(_ o: Outcome) -> Outcome {
        guard case .measured(let s, let samples, let notes, let failures) = o else { return o }
        return .measured(s, samples: samples, notes: notes.filter { !$0.hasPrefix(FrameTimingSummary.notePrefix) }, failures: failures)
    }

    /// Scrubs `result`, checks it, and returns the JSON to write plus the index entry.
    public static func prepare(_ result: RunResult, scrubber: Scrubber,
                               allowPartial: Bool) throws(Refusal) -> (json: Data, entry: PublishedEntry) {
        guard result.schemaVersion == RunResult.currentSchemaVersion else { throw .schema(result.schemaVersion) }
        guard !result.attributed else { throw .attributed }
        guard !result.traced else { throw .traced }
        var clean = scrubber.scrub(result)
        clean.outcomes = clean.outcomes.mapValues { $0.mapValues(stripAttribution) }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json: Data
        do { json = try publishedJSON(clean, encoder: enc) } catch { throw .encoding("\(error)") }
        let hits = scrubber.leaks(in: String(decoding: json, as: UTF8.self))
        if !hits.isEmpty { throw .leak(hits) }
        let why = partialReason(clean)
        if let why, !allowPartial { throw .partial(why) }
        var verdicts: [String: String] = [:]
        for m in Metric.allCases { verdicts[m.rawValue] = word(Parity.judge(clean, metric: m)) }
        let entry = PublishedEntry(stem: Report.fileStem(clean), date: clean.environment.date,
                                   harnessSHA: clean.harnessSHA, apps: clean.apps,
                                   partial: why != nil, verdicts: verdicts)
        return (json, entry)
    }
}
