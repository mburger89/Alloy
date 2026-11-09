import Foundation

/// Case-insensitive subsequence matching for the `@file` list and, later, the quick-open palette.
public enum FuzzyMatch {
    private static let slash = UInt8(ascii: "/")

    /// nil when `query` is not a subsequence of `candidate`. Otherwise higher is better: contiguous runs, matches right
    /// after `/ _ - .` (or at the start) and matches inside the file name score more. An empty query matches with 0.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        score(Array(query.utf8).map(lower), Array(candidate.utf8))
    }

    /// The best `limit` candidates, best first; equal scores sort the shorter path first, then alphabetically.
    public static func top(_ query: String, in candidates: [String], limit: Int = 50) -> [String] {
        let q = Array(query.utf8).map(lower)
        var scored: [(score: Int, path: String)] = []
        for (i, path) in candidates.enumerated() {
            if i & 4095 == 0, Task.isCancelled { return [] }
            if let s = score(q, Array(path.utf8)) { scored.append((s, path)) }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path.utf8.count != $1.path.utf8.count { return $0.path.utf8.count < $1.path.utf8.count }
            return $0.path < $1.path
        }
        return scored.prefix(limit).map(\.path)
    }

    @inline(__always) private static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }

    private static func score(_ q: [UInt8], _ raw: [UInt8]) -> Int? {
        if q.isEmpty { return 0 }
        let n = raw.count
        guard n >= q.count else { return nil }
        let c = raw.map(lower)
        // Cheap reject: a plain subsequence scan.
        var qi = 0
        for b in c where qi < q.count && b == q[qi] { qi += 1 }
        guard qi == q.count else { return nil }

        let nameStart = (raw.lastIndex(of: slash) ?? -1) + 1
        // dp[j]: best score with the current query char matched at candidate index j (nil: impossible).
        let none = Int.min
        var prev = [Int](repeating: none, count: n)
        var cur = [Int](repeating: none, count: n)
        for (i, qc) in q.enumerated() {
            var bestBefore = none   // max prev[k] for k < j - 1
            for j in 0..<n {
                cur[j] = none
                if j >= 2, prev[j - 2] != none { bestBefore = max(bestBefore, prev[j - 2]) }
                guard c[j] == qc else { continue }
                var bonus = 1
                if j == 0 || isBoundary(raw[j - 1]) { bonus += 10 }
                if j >= nameStart { bonus += 8 }
                if i == 0 {
                    cur[j] = bonus
                } else {
                    var best = bestBefore
                    if j >= 1, prev[j - 1] != none { best = max(best, prev[j - 1] + 8) }
                    if best != none { cur[j] = best + bonus }
                }
            }
            swap(&prev, &cur)
        }
        let best = prev.max() ?? none
        return best == none ? nil : best
    }

    @inline(__always) private static func isBoundary(_ b: UInt8) -> Bool {
        b == slash || b == UInt8(ascii: "_") || b == UInt8(ascii: "-") || b == UInt8(ascii: ".")
    }
}
