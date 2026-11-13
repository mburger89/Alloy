/// One hunk of a unified diff as reported by the CLI's `structuredPatch`.
public struct PatchHunk: Codable, Sendable, Equatable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    /// Each line is prefixed with " ", "-" or "+".
    public var lines: [String]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}

/// Lossless line view of a text: lines carry no terminators.
///
/// `lineEnding` is "\r\n" when the first line break is CRLF, else "\n".
/// `text` round-trips input that uses a single line-ending style; with mixed
/// endings every break is normalised to `lineEnding` (documented limitation).
public struct TextLines: Sendable, Equatable, Codable {
    public var lines: [String]
    public var lineEnding: String
    public var hasTrailingNewline: Bool

    public init(_ text: String) { self.init(text, crlf: nil) }

    /// The CRLF flag `init(_:)` would pick for `text`: whether its first line break is "\r\n".
    static func detectsCRLF(_ bytes: [UInt8]) -> Bool {
        guard let firstLF = bytes.firstIndex(of: 0x0A) else { return false }
        return firstLF > 0 && bytes[firstLF - 1] == 0x0D
    }

    /// `crlf` overrides the detected line ending, so a slice cut from the middle of a text splits into the same lines
    /// as the whole text did (its own first line break may differ from the whole text's).
    init(_ text: String, crlf forced: Bool?) {
        let bytes = Array(text.utf8)
        let crlf = forced ?? Self.detectsCRLF(bytes)
        lineEnding = crlf ? "\r\n" : "\n"
        hasTrailingNewline = bytes.last == 0x0A
        guard !bytes.isEmpty else { lines = []; return }
        var segs = bytes.split(separator: 0x0A, omittingEmptySubsequences: false).map { Array($0) }
        if hasTrailingNewline { segs.removeLast() }
        let terminated = segs.count - (hasTrailingNewline ? 0 : 1)
        lines = segs.enumerated().map { i, seg in
            var s = seg
            if crlf, i < terminated, s.last == 0x0D { s.removeLast() }
            return String(decoding: s, as: UTF8.self)
        }
    }

    public var text: String {
        lines.joined(separator: lineEnding) + (hasTrailingNewline && !lines.isEmpty ? lineEnding : "")
    }
}

public struct PatchMismatch: Error, Equatable {
    public var hunkIndex: Int
    /// 1-based line number in the text being patched where the mismatch occurred.
    public var line: Int
    public init(hunkIndex: Int, line: Int) {
        self.hunkIndex = hunkIndex
        self.line = line
    }
}

public enum Patch {
    /// Applies hunks (1-based, ascending) to `lines`. A hunk with `oldLines == 0`
    /// follows the unified-diff convention: `oldStart` is the line after which to insert (0 = at the top).
    public static func apply(_ hunks: [PatchHunk], to lines: [String]) throws -> [String] {
        var out: [String] = []
        var cursor = 0   // next unconsumed index in `lines`
        for (h, hunk) in hunks.enumerated() {
            let start = hunk.oldLines == 0 ? hunk.oldStart : hunk.oldStart - 1
            guard start >= cursor, start <= lines.count else { throw PatchMismatch(hunkIndex: h, line: start + 1) }
            out.append(contentsOf: lines[cursor..<start])
            cursor = start
            for entry in hunk.lines {
                guard let tag = entry.first else { throw PatchMismatch(hunkIndex: h, line: cursor + 1) }
                let body = String(entry.dropFirst())
                switch tag {
                case " ", "-":
                    guard cursor < lines.count, lines[cursor] == body else {
                        throw PatchMismatch(hunkIndex: h, line: cursor + 1)
                    }
                    if tag == " " { out.append(body) }
                    cursor += 1
                case "+": out.append(body)
                case "\\": continue   // "\ No newline at end of file"
                default: throw PatchMismatch(hunkIndex: h, line: cursor + 1)
                }
            }
        }
        out.append(contentsOf: lines[cursor...])
        return out
    }

    /// Line diff shaped like the CLI's `structuredPatch`: `context` lines around changes,
    /// nearby hunks merged, 1-based starts. Pure insertions into an empty range use the
    /// unified-diff convention `oldStart`/`newStart` = line before the range (0 at the top).
    public static func diff(old: [String], new: [String], context: Int = 3) -> [PatchHunk] {
        let difference = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // Edit script: (prefix, text, old index before op, new index before op)
        var ops: [(tag: Character, text: String, o: Int, n: Int)] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                ops.append(("-", old[i], i, j)); i += 1
            } else if j < new.count, inserted.contains(j) {
                ops.append(("+", new[j], i, j)); j += 1
            } else {
                ops.append((" ", old[i], i, j)); i += 1; j += 1
            }
        }
        let changes = ops.indices.filter { ops[$0].tag != " " }
        guard !changes.isEmpty else { return [] }
        // Group changes whose separating equal-run is at most 2 * context.
        var groups: [(first: Int, last: Int)] = []
        for c in changes {
            if let g = groups.last, c - g.last - 1 <= 2 * context {
                groups[groups.count - 1].last = c
            } else {
                groups.append((c, c))
            }
        }
        return groups.map { g in
            let lo = max(0, g.first - context), hi = min(ops.count - 1, g.last + context)
            let slice = ops[lo...hi]
            let oldLines = slice.filter { $0.tag != "+" }.count
            let newLines = slice.filter { $0.tag != "-" }.count
            let o = ops[lo].o, n = ops[lo].n
            return PatchHunk(
                oldStart: oldLines == 0 ? o : o + 1, oldLines: oldLines,
                newStart: newLines == 0 ? n : n + 1, newLines: newLines,
                lines: slice.map { "\($0.tag)\($0.text)" })
        }
    }

    /// Swaps +/- and the old/new ranges; within each change run, removals precede insertions.
    public static func reversed(_ hunk: PatchHunk) -> PatchHunk {
        var lines: [String] = []
        var minus: [String] = [], plus: [String] = []
        func flush() { lines += minus + plus; minus = []; plus = [] }
        for entry in hunk.lines {
            switch entry.first {
            case "+": minus.append("-" + entry.dropFirst())
            case "-": plus.append("+" + entry.dropFirst())
            default: flush(); lines.append(entry)
            }
        }
        flush()
        return PatchHunk(oldStart: hunk.newStart, oldLines: hunk.newLines,
                         newStart: hunk.oldStart, newLines: hunk.oldLines, lines: lines)
    }
}
