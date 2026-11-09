import Foundation

public struct Summary: Codable, Sendable, Equatable {
    public var count: Int
    public var median: Double
    public var p95: Double
    public var min: Double
    public var max: Double
    public var unit: String

    public init(count: Int, median: Double, p95: Double, min: Double, max: Double, unit: String) {
        self.count = count; self.median = median; self.p95 = p95
        self.min = min; self.max = max; self.unit = unit
    }
}

public enum Stats {
    /// nil for empty input. p95 uses nearest-rank: sorted[ceil(0.95 * n) - 1].
    public static func summarize(_ samples: [Double], unit: String) -> Summary? {
        guard !samples.isEmpty else { return nil }
        let s = samples.sorted()
        let n = s.count
        let median = n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
        let rank = Int((0.95 * Double(n)).rounded(.up))
        let p95 = s[Swift.min(Swift.max(rank, 1), n) - 1]
        return Summary(count: n, median: median, p95: p95, min: s[0], max: s[n - 1], unit: unit)
    }
}
