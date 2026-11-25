import Foundation

/// A run of consecutive lines last changed by one commit.
public struct GitBlameRun: Equatable, Sendable {
    public var startLine: Int
    public var count: Int
    public var hash: String
    public var author: String
    public var authorTime: Date
    public var summary: String

    public init(startLine: Int, count: Int, hash: String, author: String, authorTime: Date, summary: String) {
        self.startLine = startLine; self.count = count; self.hash = hash; self.author = author
        self.authorTime = authorTime; self.summary = summary
    }

    public var shortHash: String { String(hash.prefix(7)) }

    /// Two characters: the first letters of the first two words, or the first two letters of a single word.
    public var initials: String {
        let words = author.split(whereSeparator: { $0.isWhitespace })
        let raw: String
        switch words.count {
        case 0: return "??"
        case 1: raw = String(words[0].prefix(2))
        default: raw = String(words[0].prefix(1)) + String(words[1].prefix(1))
        }
        return raw.uppercased()
    }

    public var isUncommitted: Bool { !hash.isEmpty && hash.allSatisfy { $0 == "0" } }
}

public enum GitBlameParser {
    /// Parses `git blame --porcelain`. Only a commit's first line carries its headers, so they are remembered by hash.
    public static func parse(_ data: Data) -> [GitBlameRun] {
        struct Meta { var author = "", time = 0.0, summary = "" }
        var metas: [String: Meta] = [:]
        var runs: [GitBlameRun] = []
        var currentHash: String?, currentFinal = 0
        func isHash(_ s: Substring) -> Bool { (s.count == 40 || s.count == 64) && s.allSatisfy { $0.isHexDigit } }
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let line = String(decoding: raw, as: UTF8.self)
            if line.hasPrefix("\t") {
                guard let h = currentHash else { continue }
                let m = metas[h] ?? Meta()
                if var last = runs.last, last.hash == h, last.startLine + last.count == currentFinal - 1 {
                    last.count += 1
                    runs[runs.count - 1] = last
                } else {
                    runs.append(GitBlameRun(startLine: currentFinal - 1, count: 1, hash: h, author: m.author,
                                            authorTime: Date(timeIntervalSince1970: m.time), summary: m.summary))
                }
                currentHash = nil
                continue
            }
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            if parts.count >= 3, isHash(parts[0]), let final = Int(parts[2]), Int(parts[1]) != nil {
                let hash = String(parts[0])
                currentHash = hash; currentFinal = final
                if metas[hash] == nil { metas[hash] = Meta() }
            } else if let h = currentHash {
                if line.hasPrefix("author ") { metas[h]?.author = String(line.dropFirst(7)) }
                else if line.hasPrefix("author-time ") { metas[h]?.time = Double(line.dropFirst(12)) ?? 0 }
                else if line.hasPrefix("summary ") { metas[h]?.summary = String(line.dropFirst(8)) }
            }
        }
        return runs
    }
}
