import Foundation

/// A clickable span found in one terminal row. `range` is in `Character`
/// offsets of the row string.
public struct TerminalLink: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file(path: String, line: Int?, column: Int?)
        case url(String)
    }

    public var range: Range<Int>
    public var kind: Kind

    public init(range: Range<Int>, kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// Finds `path:line`, `path:line:col`, `path(line,col)`, `path, line N` and
/// `http(s)://` links in a row of terminal text. Syntactic only: no file I/O
/// except through the closure given to `resolve`.
public enum LinkDetector {
    private static let leadingTrim: Set<Character> = ["(", "[", "{", "<", "'", "\"", "`"]
    private static let trailingTrim: Set<Character> = [".", ",", ";", ":", ")", "]", "}", ">", "'", "\"", "`"]
    private static let urlTrailingTrim: Set<Character> = [".", ",", ";", ":", ")", "]", "}", ">", "'", "\"", "`", "!", "?"]

    public static func candidates(in row: String) -> [TerminalLink] {
        let chars = Array(row)
        // Whitespace-delimited chunks as (start, end) character offsets.
        var chunks: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            let start = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            chunks.append(start..<i)
        }

        var links: [TerminalLink] = []
        var idx = 0
        while idx < chunks.count {
            let chunk = chunks[idx]
            var lo = chunk.lowerBound
            var hi = chunk.upperBound
            while lo < hi, leadingTrim.contains(chars[lo]) { lo += 1 }

            // URL
            if isURLStart(chars, lo, hi) {
                while hi > lo, urlTrailingTrim.contains(chars[hi - 1]) { hi -= 1 }
                if hi - lo > 8 {
                    links.append(TerminalLink(range: lo..<hi, kind: .url(String(chars[lo..<hi]))))
                }
                idx += 1
                continue
            }

            // path(line[,col])
            if let link = parenForm(chars, lo, hi) {
                links.append(link)
                idx += 1
                continue
            }

            while hi > lo, trailingTrim.contains(chars[hi - 1]) { hi -= 1 }
            guard lo < hi else { idx += 1; continue }

            // path:line[:col]
            if let link = colonForm(chars, lo, hi) {
                links.append(link)
                idx += 1
                continue
            }

            // path, line N  (the path chunk ends with a comma or quote+comma)
            if idx + 2 < chunks.count,
               chars[chunk.upperBound - 1] == ",",
               String(chars[chunks[idx + 1]]) == "line" {
                let numChunk = chunks[idx + 2]
                var nhi = numChunk.upperBound
                while nhi > numChunk.lowerBound, trailingTrim.contains(chars[nhi - 1]) { nhi -= 1 }
                if let n = Int(String(chars[numChunk.lowerBound..<nhi])), nhi > numChunk.lowerBound,
                   looksLikePath(chars, lo, hi) {
                    links.append(TerminalLink(range: lo..<nhi,
                                              kind: .file(path: String(chars[lo..<hi]), line: n, column: nil)))
                    idx += 3
                    continue
                }
            }
            idx += 1
        }
        return links
    }

    public static func link(at column: Int, in row: String) -> TerminalLink? {
        candidates(in: row).first { $0.range.contains(column) }
    }

    public static func resolve(
        _ path: String,
        bases: [String],
        projectRoot: String,
        fileExists: (String) -> Bool
    ) -> String? {
        let root = URL(fileURLWithPath: projectRoot).standardized.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var tried = Set<String>()
        let joined: [String] = path.hasPrefix("/") ? [path] : bases.map { $0 + "/" + path }
        for raw in joined {
            let full = URL(fileURLWithPath: raw).standardized.path
            guard full.hasPrefix(prefix) else { continue }
            guard tried.insert(full).inserted else { continue }
            if fileExists(full) {
                return String(full.dropFirst(prefix.count))
            }
        }
        return nil
    }

    // MARK: - Scanning helpers

    private static func isURLStart(_ c: [Character], _ lo: Int, _ hi: Int) -> Bool {
        for scheme in ["https://", "http://"] {
            let s = Array(scheme)
            if hi - lo >= s.count, Array(c[lo..<(lo + s.count)]) == s { return true }
        }
        return false
    }

    /// A path needs a letter or digit and a separator or an extension dot,
    /// so `12`, `error` and `:` never qualify.
    private static func looksLikePath(_ c: [Character], _ lo: Int, _ hi: Int) -> Bool {
        guard lo < hi else { return false }
        let s = c[lo..<hi]
        guard s.contains(where: { $0.isLetter }) else { return false }
        return s.contains("/") || s.contains("\\") || s.contains(".")
    }

    private static func parenForm(_ c: [Character], _ lo: Int, _ hi: Int) -> TerminalLink? {
        var end = hi
        while end > lo, [".", ",", ";", ":"].contains(c[end - 1]) { end -= 1 }
        guard end - lo > 3, c[end - 1] == ")" else { return nil }
        guard let open = (lo..<end).last(where: { c[$0] == "(" }), open > lo else { return nil }
        let inner = String(c[(open + 1)..<(end - 1)])
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let line = Int(parts[0]) else { return nil }
        let col = parts.count == 2 ? Int(parts[1]) : nil
        guard looksLikePath(c, lo, open) else { return nil }
        return TerminalLink(range: lo..<end, kind: .file(path: String(c[lo..<open]), line: line, column: col))
    }

    private static func colonForm(_ c: [Character], _ lo: Int, _ hi: Int) -> TerminalLink? {
        var nums: [Int] = []
        var end = hi
        while nums.count < 2 {
            var j = end
            while j > lo, c[j - 1].isASCII, c[j - 1].isNumber { j -= 1 }
            guard j < end, j > lo, c[j - 1] == ":", let n = Int(String(c[j..<end])) else { break }
            nums.append(n)
            end = j - 1
        }
        guard !nums.isEmpty, looksLikePath(c, lo, end) else { return nil }
        let line = nums.last!
        let col = nums.count == 2 ? nums[0] : nil
        return TerminalLink(range: lo..<hi, kind: .file(path: String(c[lo..<end]), line: line, column: col))
    }
}
