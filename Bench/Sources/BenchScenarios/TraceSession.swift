import Foundation
import BenchCore

/// State of one `--trace` run: which kind, where traces go, which (app, metric) pairs were already traced, and the
/// notes to attach to each. Carried to `Harness.withApp` as a task-local, like `AttributionCollector`.
public final class TraceSession: @unchecked Sendable {
    @TaskLocal static var current: TraceSession?
    @TaskLocal static var metric: Metric?

    public let kind: TraceKind
    /// `Bench/traces/<stem>/`
    public let directory: String
    private struct State { var traced: Set<String> = []; var notes: [String: [String]] = [:] }
    private let state = Box(State())

    public init(kind: TraceKind, directory: String) { self.kind = kind; self.directory = directory }

    private static func key(_ app: String, _ metric: Metric) -> String { "\(app)-\(metric.rawValue)" }

    /// True the first time it is asked for an (app, metric); later runs of the same pair are measured normally.
    public func shouldTrace(app: String, metric: Metric) -> Bool {
        let k = Self.key(app, metric)
        var first = false
        state.update { first = $0.traced.insert(k).inserted }
        return first
    }

    public func fileName(app: String, metric: Metric) -> String { Self.key(app, metric) + ".trace" }
    public func path(app: String, metric: Metric) -> String { directory + "/" + fileName(app: app, metric: metric) }

    public func addNote(_ note: String, app: String, metric: Metric) {
        state.update { $0.notes[Self.key(app, metric), default: []].append(note) }
    }
    public func notes(app: String, metric: Metric) -> [String] { state.value.notes[Self.key(app, metric)] ?? [] }

    public static func unavailableNote(app displayName: String, metric: Metric, reason: String) -> String {
        "trace unavailable for \(displayName) \(metric.rawValue): \(reason)"
    }
    public static func unsupportedNote(app displayName: String, metric: Metric) -> String {
        "trace not supported for \(displayName) \(metric.rawValue): launch is measured from the first frame, before an attach could start"
    }
    public func savedNote(app: String, metric: Metric, partialReason: String? = nil) -> String {
        var n = "trace: \(fileName(app: app, metric: metric)) (\(kind.rawValue); attached after launch, so launch work before the attach is missing)"
        if let partialReason { n += partialReason.contains("may be partial") ? "; \(partialReason)" : "; may be partial: \(partialReason)" }
        return n
    }

    func within<T>(metric: Metric, _ body: () async -> T) async -> T {
        await Self.$current.withValue(self) { await Self.$metric.withValue(metric) { await body() } }
    }
}
