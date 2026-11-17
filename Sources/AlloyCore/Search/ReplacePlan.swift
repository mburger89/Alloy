import Foundation

/// The matches of one file that a replace will rewrite, as found by a search.
public struct ReplaceFile: Sendable {
    public var path: String
    public var matches: [SearchMatch]

    public init(path: String, matches: [SearchMatch]) {
        self.path = path
        self.matches = matches
    }
}

/// What a replace does to one file: its new bytes, or why it was left alone.
public enum ReplaceRewrite: Sendable, Equatable {
    case rewritten([UInt8])
    case skipped(reason: String)
}

/// A replace across files: the searched matches plus the replacement template. Pure; it reads no files.
public struct ReplacePlan: Sendable {
    public static let maxFileBytes = 16 * 1024 * 1024

    public var files: [ReplaceFile]
    public var query: SearchQuery
    public var template: String

    public init(files: [ReplaceFile], query: SearchQuery, template: String) {
        self.files = files
        self.query = query
        self.template = template
    }

    public var totalMatches: Int { files.reduce(0) { $0 + $1.matches.count } }

    /// Why a file must not be rewritten, judged from its current bytes; nil when it can be.
    /// `size` is the file's size on disk (bytes may be a truncated read).
    public static func skipReason(bytes: [UInt8], size: Int? = nil, readOnly: Bool = false) -> String? {
        if readOnly { return "read-only" }
        if (size ?? bytes.count) > maxFileBytes { return "larger than 16 MB" }
        if String(bytes: bytes, encoding: .utf8) == nil { return "not valid UTF-8" }
        return nil
    }

    /// The replacements for `file`, sorted back to front so applying them in order never shifts a later range.
    /// Regex templates expand captures from each match's line, so `bytes` (the file as searched) is needed then;
    /// literal and whole-word templates are inserted verbatim. Always pass the searched bytes: a regex plan without
    /// them would expand captures to empty text.
    public func edits(for file: ReplaceFile, in bytes: [UInt8]) -> [(range: Range<Int>, text: String)] {
        let matcher = try? query.compile()
        let regex = matcher?.isRegex ?? false
        var lines: [Int: Substring] = [:]
        var out: [(range: Range<Int>, text: String)] = []
        out.reserveCapacity(file.matches.count)
        for m in file.matches {
            var text = template
            if regex, let matcher {
                let line: Substring
                if let cached = lines[m.lineStart] {
                    line = cached
                } else {
                    line = Self.line(at: m.lineStart, in: bytes)
                    lines[m.lineStart] = line
                }
                text = matcher.replacement(for: m, in: line, template: template)
            }
            out.append((m.range, text))
        }
        return out.sorted { $0.range.lowerBound > $1.range.lowerBound }
    }

    /// The line starting at `start`, without its terminator or a trailing `\r`.
    private static func line(at start: Int, in bytes: [UInt8]) -> Substring {
        guard start >= 0, start <= bytes.count else { return "" }
        var end = start
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
        return Substring(String(decoding: bytes[start..<end], as: UTF8.self))
    }

    /// Whether every planned match is still in `bytes` at the same range: the file is searched again, so a
    /// match whose text or position moved (or a file that became shorter) fails.
    public func verify(_ file: ReplaceFile, against bytes: [UInt8]) -> Bool {
        guard let matcher = try? query.compile() else { return false }
        if let last = file.matches.map(\.range.upperBound).max(), last > bytes.count { return false }
        let found = Set(matcher.scan(bytes).matches.map(\.range))
        return file.matches.allSatisfy { found.contains($0.range) }
    }

    /// The file's new bytes, or the reason it is left alone.
    public func rewrite(_ file: ReplaceFile, bytes: [UInt8], size: Int? = nil, readOnly: Bool = false) -> ReplaceRewrite {
        if let reason = Self.skipReason(bytes: bytes, size: size, readOnly: readOnly) { return .skipped(reason: reason) }
        guard verify(file, against: bytes) else { return .skipped(reason: "changed since search") }
        // One forward pass: `edits` is back to front, so walk it reversed to go ascending.
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 64)
        var prev = 0
        for edit in edits(for: file, in: bytes).reversed() {
            if edit.range.lowerBound > prev { out.append(contentsOf: bytes[prev..<edit.range.lowerBound]) }
            out.append(contentsOf: edit.text.utf8)
            prev = max(prev, edit.range.upperBound)
        }
        if prev < bytes.count { out.append(contentsOf: bytes[prev...]) }
        return .rewritten(out)
    }
}

public enum ReplaceOutcome: Sendable, Equatable {
    case applied(edits: Int)
    case skipped(reason: String)
}

public struct ReplaceReport {
    public var group: UUID
    public var perFile: [(path: String, outcome: ReplaceOutcome)]

    public init(group: UUID, perFile: [(path: String, outcome: ReplaceOutcome)] = []) {
        self.group = group
        self.perFile = perFile
    }
}
