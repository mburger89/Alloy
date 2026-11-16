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

    // MARK: Word scoring (command palette)

    private static let wordStartBonus = 10
    private static let runBonus = 8
    /// Added by callers for recently used commands. Smaller than one word-start bonus, so it only breaks near-ties.
    public static let recentBonus = 4

    /// Word-aware subsequence match for command titles ("View: Split Right"). Query spaces are separators and are
    /// ignored. Matching is ASCII case-insensitive and exact for other scalars, and never splits a multi-byte scalar.
    /// `matched` holds UTF-8 byte ranges into `candidate`, merged when adjacent. An empty query matches with 0.
    public static func scoreWords(_ query: String, in candidate: String) -> (score: Int, matched: [Range<Int>])? {
        let q = queryUnits(query)
        if q.isEmpty { return (0, []) }
        return scoreWords(q, Array(candidate.utf8))
    }

    /// The best `limit` candidates by `scoreWords`, best first; ties go to the shorter candidate, then the lower index.
    /// `bonus(index)` is added to each match's score. An empty query returns candidates in input order.
    public static func topIndices(
        query: String, in candidates: [String], limit: Int, bonus: ((Int) -> Int)? = nil
    ) -> [(index: Int, score: Int, matched: [Range<Int>])] {
        guard limit > 0 else { return [] }
        let q = queryUnits(query)
        if q.isEmpty {
            return candidates.indices.prefix(limit).map { (index: $0, score: bonus?($0) ?? 0, matched: []) }
        }
        var out: [(index: Int, score: Int, matched: [Range<Int>], len: Int)] = []
        for (i, cand) in candidates.enumerated() {
            if i & 4095 == 0, Task.isCancelled { return [] }
            let bytes = Array(cand.utf8)
            if let r = scoreWords(q, bytes) {
                out.append((i, r.score + (bonus?(i) ?? 0), r.matched, bytes.count))
            }
        }
        out.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.len != $1.len { return $0.len < $1.len }
            return $0.index < $1.index
        }
        return out.prefix(limit).map { (index: $0.index, score: $0.score, matched: $0.matched) }
    }

    /// Query split into scalar units (UTF-8 bytes, ASCII lowered), whitespace dropped.
    private static func queryUnits(_ query: String) -> [[UInt8]] {
        query.unicodeScalars.compactMap { sc in
            if sc.properties.isWhitespace { return nil }
            return Array(String(sc).utf8).map(lower)
        }
    }

    private static func scoreWords(_ q: [[UInt8]], _ raw: [UInt8]) -> (score: Int, matched: [Range<Int>])? {
        // Candidate units: byte offset and length of each UTF-8 scalar.
        var starts: [Int] = []
        var lens: [Int] = []
        var k = 0
        while k < raw.count {
            var l = 1
            let b = raw[k]
            if b >= 0xF0 { l = 4 } else if b >= 0xE0 { l = 3 } else if b >= 0xC0 { l = 2 }
            l = min(l, raw.count - k)
            starts.append(k); lens.append(l)
            k += l
        }
        let n = starts.count
        guard n >= q.count else { return nil }
        func unitEquals(_ j: Int, _ u: [UInt8]) -> Bool {
            guard lens[j] == u.count else { return false }
            for t in 0..<u.count where lower(raw[starts[j] + t]) != u[t] { return false }
            return true
        }
        // Cheap reject: plain subsequence scan.
        var qi = 0
        for j in 0..<n where qi < q.count && unitEquals(j, q[qi]) { qi += 1 }
        guard qi == q.count else { return nil }

        func wordStart(_ j: Int) -> Bool {
            if j == 0 { return true }
            let prev = raw[starts[j - 1]]
            if lens[j - 1] == 1, prev == UInt8(ascii: " ") { return true }
            let cur = raw[starts[j]]
            return lens[j - 1] == 1 && lens[j] == 1 && prev >= 97 && prev <= 122 && cur >= 65 && cur <= 90
        }

        let none = Int.min
        var dp = [[Int]](repeating: [Int](repeating: none, count: n), count: q.count)
        var back = [[Int]](repeating: [Int](repeating: -1, count: n), count: q.count)
        for i in 0..<q.count {
            var bestBefore = none, bestBeforeAt = -1   // best dp[i-1][k] for k < j - 1
            for j in 0..<n {
                if i > 0, j >= 2, dp[i - 1][j - 2] != none, dp[i - 1][j - 2] > bestBefore {
                    bestBefore = dp[i - 1][j - 2]; bestBeforeAt = j - 2
                }
                guard unitEquals(j, q[i]) else { continue }
                let bonus = 1 + (wordStart(j) ? wordStartBonus : 0)
                if i == 0 {
                    dp[i][j] = bonus
                } else {
                    var best = bestBefore, at = bestBeforeAt
                    if j >= 1, dp[i - 1][j - 1] != none, dp[i - 1][j - 1] + runBonus > best {
                        best = dp[i - 1][j - 1] + runBonus; at = j - 1
                    }
                    if best != none { dp[i][j] = best + bonus; back[i][j] = at }
                }
            }
        }
        var bestJ = -1, best = none
        for j in 0..<n where dp[q.count - 1][j] > best { best = dp[q.count - 1][j]; bestJ = j }
        guard bestJ >= 0 else { return nil }
        var ranges: [Range<Int>] = []
        var j = bestJ
        for i in stride(from: q.count - 1, through: 0, by: -1) {
            let r = starts[j]..<(starts[j] + lens[j])
            if let first = ranges.first, first.lowerBound == r.upperBound {
                ranges[0] = r.lowerBound..<first.upperBound
            } else {
                ranges.insert(r, at: 0)
            }
            if i > 0 { j = back[i][j] }
        }
        return (best, ranges)
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
