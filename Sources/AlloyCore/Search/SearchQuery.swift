import Foundation

public enum SearchError: Error, Sendable, Equatable {
    case empty
    case invalidRegex(String)
}

/// What the user typed into the Search tab. Pure value; `compile()` validates it.
public struct SearchQuery: Sendable, Codable, Equatable {
    public var text: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var include: String
    public var exclude: String

    public init(
        text: String = "", caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false,
        include: String = "", exclude: String = ""
    ) {
        self.text = text
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.include = include
        self.exclude = exclude
    }

    public func compile() throws -> SearchMatcher {
        guard !text.isEmpty else { throw SearchError.empty }
        if regex {
            let source = wholeWord ? "\\b(?:\(text))\\b" : text
            do {
                let matcher = SearchMatcher(needle: [], caseSensitive: caseSensitive, wholeWord: wholeWord, regexSource: source)
                _ = try matcher.makeRegex()
                return matcher
            } catch {
                throw SearchError.invalidRegex(String(describing: error))
            }
        }
        var needle = Array(text.utf8)
        if !caseSensitive { needle = needle.map(SearchMatcher.lower) }
        return SearchMatcher(needle: needle, caseSensitive: caseSensitive, wholeWord: wholeWord, regexSource: nil)
    }
}

public struct SearchMatch: Sendable, Equatable {
    /// 1-based line number.
    public var line: Int
    /// Byte offset of the start of the line in the file.
    public var lineStart: Int
    /// File byte range of the match.
    public var range: Range<Int>
    /// Trimmed, length-capped line text without a trailing `\r`.
    public var preview: String
    /// UTF-8 offsets of the match inside `preview`.
    public var previewMatch: Range<Int>

    public init(line: Int, lineStart: Int, range: Range<Int>, preview: String, previewMatch: Range<Int>) {
        self.line = line
        self.lineStart = lineStart
        self.range = range
        self.preview = preview
        self.previewMatch = previewMatch
    }
}

public struct ScanResult: Sendable, Equatable {
    public var matches: [SearchMatch] = []
    /// Regex mode skipped at least one line over `SearchMatcher.maxRegexLine` bytes.
    public var skippedLongLines = false
    /// The regex budget ran out; the scan stopped early.
    public var overBudget = false
    /// The regex matched, but only with zero width (reported as no matches).
    public var sawOnlyEmpty = false
}

/// A compiled query. Literal and whole-word queries scan bytes with `memmem`; regex queries run
/// per line. Lines split on `\n`; a trailing `\r` is excluded from what the matcher sees.
public struct SearchMatcher: Sendable {
    public static let maxRegexLine = 64 * 1024
    public static let previewLimit = 200

    let needle: [UInt8]
    let caseSensitive: Bool
    let wholeWord: Bool
    /// `Regex` is not `Sendable`, so the matcher keeps the source and compiles once per scan.
    let regexSource: String?

    init(needle: [UInt8], caseSensitive: Bool, wholeWord: Bool, regexSource: String?) {
        self.needle = needle
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regexSource = regexSource
    }

    public var isRegex: Bool { regexSource != nil }

    func makeRegex() throws -> Regex<AnyRegexOutput>? {
        guard let regexSource else { return nil }
        let compiled = try Regex<AnyRegexOutput>(regexSource)
        return caseSensitive ? compiled : compiled.ignoresCase()
    }

    @inline(__always) static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }

    @inline(__always) static func isWord(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
    }

    // MARK: Scan

    public func scan(_ bytes: [UInt8], regexBudget: Duration? = nil, shouldStop: () -> Bool = { false }) -> ScanResult {
        var result = ScanResult()
        let started = ContinuousClock.now
        var scratch: [UInt8] = []
        let regex: Regex<AnyRegexOutput>?
        if regexSource != nil {
            guard let compiled = try? makeRegex() else { return result }
            regex = compiled
        } else {
            regex = nil
        }
        bytes.withUnsafeBufferPointer { buf in
            let count = buf.count
            guard count > 0, let base = buf.baseAddress else { return }
            var pos = 0
            var lineNo = 0
            while pos < count {
                if shouldStop() { return }
                lineNo += 1
                var end = count
                if let nl = memchr(base + pos, 0x0A, count - pos) {
                    end = base.distance(to: nl.assumingMemoryBound(to: UInt8.self))
                }
                let next = end < count ? end + 1 : count
                var contentEnd = end
                if contentEnd > pos, base[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                defer { pos = next }
                if regexSource == nil && contentEnd - pos < needle.count { continue }
                if contentEnd == pos { continue }

                if let regex {
                    if contentEnd - pos > Self.maxRegexLine {
                        result.skippedLongLines = true
                        continue
                    }
                    if let budget = regexBudget, ContinuousClock.now - started > budget {
                        result.overBudget = true
                        return
                    }
                    scanRegexLine(regex, base, pos, contentEnd, lineNo, &result)
                } else {
                    scanLiteralLine(base, pos, contentEnd, lineNo, &scratch, &result)
                }
            }
        }
        return result
    }

    private func scanLiteralLine(
        _ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ lineNo: Int,
        _ scratch: inout [UInt8], _ result: inout ScanResult
    ) {
        let length = end - start
        let n = needle.count
        var found: [Range<Int>] = []
        func search(_ hay: UnsafePointer<UInt8>) {
            var from = 0
            while from + n <= length {
                guard let p = memmem(hay + from, length - from, needle, n) else { return }
                let i = hay.distance(to: p.assumingMemoryBound(to: UInt8.self))
                if wholeWord {
                    let before = i > 0 ? base[start + i - 1] : 0
                    let after = i + n < length ? base[start + i + n] : 0
                    if Self.isWord(before) || Self.isWord(after) {
                        from = i + 1
                        continue
                    }
                }
                found.append(i..<(i + n))
                from = i + n
            }
        }
        if caseSensitive {
            search(base + start)
        } else {
            scratch.removeAll(keepingCapacity: true)
            for k in start..<end { scratch.append(Self.lower(base[k])) }
            scratch.withUnsafeBufferPointer { if let p = $0.baseAddress { search(p) } }
        }
        for r in found {
            result.matches.append(makeMatch(base, start, end, lineNo, r))
        }
    }

    private func scanRegexLine(
        _ regex: Regex<AnyRegexOutput>, _ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int,
        _ lineNo: Int, _ result: inout ScanResult
    ) {
        let slice = UnsafeBufferPointer(start: base + start, count: end - start)
        let line = String(decoding: slice, as: UTF8.self)
        // Invalid UTF-8 would shift offsets; skip such a line rather than mis-map it.
        guard line.utf8.count == slice.count else { return }
        var sawEmpty = false
        var sawReal = false
        for m in line.matches(of: regex) {
            if m.range.isEmpty {
                sawEmpty = true
                continue
            }
            sawReal = true
            let lo = line.utf8.distance(from: line.startIndex, to: m.range.lowerBound)
            let hi = line.utf8.distance(from: line.startIndex, to: m.range.upperBound)
            result.matches.append(makeMatch(base, start, end, lineNo, lo..<hi))
        }
        if sawEmpty && !sawReal { result.sawOnlyEmpty = true }
    }

    /// `local` is the match range as byte offsets within the line `[start, end)`.
    private func makeMatch(
        _ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ lineNo: Int, _ local: Range<Int>
    ) -> SearchMatch {
        func text(_ a: Int, _ b: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: base + start + a, count: b - a), as: UTF8.self)
        }
        // Bound the decode per match: a byte window of 4x the character cap (a scalar is at most
        // 4 bytes), snapped to scalar boundaries, so a huge single line costs O(1) per match.
        let lineLen = end - start
        func isCont(_ i: Int) -> Bool { i < lineLen && (base[start + i] & 0xC0) == 0x80 }
        var bLo = max(0, local.lowerBound - 4 * 30)
        while bLo < local.lowerBound, isCont(bLo) { bLo += 1 }
        var mHi = min(local.upperBound, local.lowerBound + 4 * Self.previewLimit)
        while mHi > local.lowerBound, isCont(mHi) { mHi -= 1 }
        var aHi = min(lineLen, local.upperBound + 4 * Self.previewLimit)
        while aHi > local.upperBound, isCont(aHi) { aHi -= 1 }
        var before = Substring(text(bLo, local.lowerBound))
        var middle = Substring(text(local.lowerBound, mHi))
        var after = Substring(text(local.upperBound, aHi))
        let afterComplete = aHi == lineLen
        // Trim whitespace only outside the match.
        while let f = before.first, f == " " || f == "\t" { before.removeFirst() }
        while afterComplete, let l = after.last, l == " " || l == "\t" { after.removeLast() }
        // Cap to previewLimit characters, keeping the match visible.
        if middle.count > Self.previewLimit { middle = middle.prefix(Self.previewLimit) }
        let budget = Self.previewLimit - middle.count
        let beforeKeep = min(before.count, min(30, budget))
        if before.count > beforeKeep { before = before.suffix(beforeKeep) }
        let afterKeep = max(0, min(after.count, budget - beforeKeep))
        if after.count > afterKeep { after = after.prefix(afterKeep) }
        let b = before.utf8.count
        return SearchMatch(
            line: lineNo, lineStart: start, range: (start + local.lowerBound)..<(start + local.upperBound),
            preview: String(before) + String(middle) + String(after), previewMatch: b..<(b + middle.utf8.count))
    }

    // MARK: Replacement

    /// The text that replaces `m`. In literal mode the template is used verbatim. In regex mode
    /// `$0`..`$9` and `${n}` expand to captures (`$$` is a literal dollar); an unknown group
    /// expands to nothing. `line` is the full text of the match's line (without `\r`).
    public func replacement(for m: SearchMatch, in line: Substring, template: String) -> String {
        guard let regex = try? makeRegex() else { return template }
        let offset = m.range.lowerBound - m.lineStart
        let text = String(line)
        var captures: [Substring?] = []
        var names: [String: Int] = [:]
        for found in text.matches(of: regex) {
            let lo = text.utf8.distance(from: text.startIndex, to: found.range.lowerBound)
            if lo == offset, !found.range.isEmpty {
                captures = found.output.map { $0.substring }
                for (i, c) in found.output.enumerated() { if let n = c.name { names[n] = i } }
                break
            }
            if lo > offset { break }
        }
        return Self.expand(template, captures, names: names)
    }

    static func expand(_ template: String, _ captures: [Substring?], names: [String: Int] = [:]) -> String {
        var out = ""
        var it = template.makeIterator()
        var pending: Character? = it.next()
        func advance() { pending = it.next() }
        while let c = pending {
            guard c == "$" else {
                out.append(c)
                advance()
                continue
            }
            advance()
            guard let n = pending else {
                out.append("$")
                break
            }
            if n == "$" {
                out.append("$")
                advance()
            } else if n == "{" {
                advance()
                var key = ""
                while let d = pending, d != "}", d != "$", d != "{" {
                    key.append(d)
                    advance()
                }
                if pending == "}", !key.isEmpty {
                    advance()
                    let index = key.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(key) : names[key]
                    if let i = index, i >= 0, i < captures.count, let s = captures[i] { out += s }
                } else {
                    out += "${" + key
                }
            } else if n.isASCII, n.isNumber, let i = Int(String(n)) {
                advance()
                if i < captures.count, let s = captures[i] { out += s }
            } else {
                out.append("$")
            }
        }
        return out
    }
}
