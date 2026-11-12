import Foundation
import BenchCore

public struct Corpus: Sendable {
    public var small: String, medium: String, large: String
    public init(small: String, medium: String, large: String) {
        self.small = small; self.medium = medium; self.large = large
    }
    public init(directory: String) {
        self.init(small: directory + "/small.rs", medium: directory + "/medium.rs", large: directory + "/large.rs")
    }
    /// `Bench/Corpus` located relative to this source file (works for `swift run` / `swift test` from a checkout).
    public static var `default`: Corpus {
        let bench = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Corpus(directory: bench.appendingPathComponent("Corpus").path)
    }
}

public protocol Scenario: Sendable {
    var metric: Metric { get }
    func run(_ app: TargetApp, corpus: Corpus, runs: Int) async -> Outcome
}

/// A run failed; the description is recorded as the failed-sample reason.
public struct ScenarioFailure: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// Minimum completed runs for the survivor-policy metrics (scroll, memory, idle); capped by the runs requested.
let minimumCompletedRuns = 3

/// Runs `body` `runs` times; each throw becomes a failed sample with its reason. Fewer than
/// `min(minimumCompletedRuns, runs)` completed runs publish no median: the outcome is `.notMeasured` listing the failures.
func collect(runs: Int, unit: String, extraNotes: ([Double]) -> [String] = { _ in [] },
             _ body: (Int) async throws -> [Double]) async -> Outcome {
    var samples: [Double] = []
    var failures: [String] = []
    var completed = 0
    let n = max(runs, 1)
    for i in 0..<n {
        do { samples += try await body(i); completed += 1 }
        catch { failures.append("run \(i + 1): \(error)") }
    }
    let need = min(minimumCompletedRuns, n)
    if completed < need {
        let prefix = completed == 0 ? "all runs failed: " : "only \(completed) of \(n) runs completed (minimum \(need); no median published): "
        return .notMeasured(prefix + failures.joined(separator: "; "))
    }
    guard let summary = Stats.summarize(samples, unit: unit) else {
        return .notMeasured("all runs failed: " + failures.joined(separator: "; "))
    }
    return .measured(summary, samples: samples, notes: extraNotes(samples), failures: failures)
}

func ms(_ ticks: UInt64) -> Double {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    return Double(ticks) * Double(tb.numer) / Double(tb.denom) / 1e6
}
