import Foundation

/// One changed region between a base text and a buffer, in git's numbering.
public struct GitHunk: Equatable, Sendable {
    public enum Kind: Sendable { case added, modified, deleted }

    /// Context lines kept around the change: 0 for gutter marks and patches, 3 for the compare view.
    public var context: Int = 0
    /// 1-based starts. When a count is 0 the start is the line before the (empty) range, as in a unified diff.
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var kind: Kind
    /// Lines without terminators. With context > 0 they include the context lines.
    public var oldLines: [String]
    public var newLines: [String]
    /// Context lines before the first changed line (0 when `context` is 0).
    public var leadingContext: Int = 0

    public init(context: Int = 0, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, kind: Kind,
                oldLines: [String], newLines: [String], leadingContext: Int = 0) {
        self.context = context; self.oldStart = oldStart; self.oldCount = oldCount; self.newStart = newStart
        self.newCount = newCount; self.kind = kind; self.oldLines = oldLines; self.newLines = newLines
        self.leadingContext = leadingContext
    }

    /// The buffer rows (0-based) the hunk covers; for a deletion the empty range at the row after the deletion.
    public var bufferRows: Range<Int> {
        if newCount == 0 { return newStart..<newStart }
        return (newStart - 1)..<(newStart - 1 + newCount)
    }

    /// The row a gutter mark or "go to change" lands on: the first changed row, or for a deletion the row below the deletion.
    public var markRow: Int {
        newCount == 0 ? newStart : newStart - 1 + leadingContext
    }
}

public enum GitBlobKind: Equatable, Sendable {
    case text, lfsPointer, binary

    public static func classify(_ data: Data) -> GitBlobKind {
        if data.starts(with: Data("version https://git-lfs.github.com/spec/v1".utf8)) { return .lfsPointer }
        if data.prefix(8192).contains(0) { return .binary }
        return .text
    }
}

public enum GitHunks {
    /// Hunks of `buffer` against `base` with no context. A CRLF buffer against a base without CR is compared as LF,
    /// so `core.autocrlf` does not mark every line.
    public static func compute(base: String, buffer: String) -> [GitHunk] { hunks(base: base, buffer: buffer, context: 0) }

    /// Hunks with 3 lines of context for the compare view.
    public static func compareHunks(base: String, buffer: String) -> [GitHunk] { hunks(base: base, buffer: buffer, context: 3) }

    private static func hunks(base: String, buffer: String, context: Int) -> [GitHunk] {
        var buffer = buffer
        if !base.utf8.contains(0x0D), buffer.utf8.contains(0x0D) {
            buffer = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        }
        var out = TextDiff.hunks(old: base, new: buffer, context: context).map { convert($0, context: context) }
        // A change that is only the final newline leaves every line equal; mark the last line.
        let a = TextLines(base), b = TextLines(buffer)
        if a.hasTrailingNewline != b.hasTrailingNewline, !a.lines.isEmpty, !b.lines.isEmpty {
            let touchesEnd = out.last.map { $0.oldStart + $0.oldCount - 1 >= a.lines.count && $0.newStart + $0.newCount - 1 >= b.lines.count } ?? false
            if !touchesEnd {
                let h = PatchHunk(oldStart: a.lines.count, oldLines: 1, newStart: b.lines.count, newLines: 1,
                                  lines: ["-" + a.lines[a.lines.count - 1], "+" + b.lines[b.lines.count - 1]])
                out.append(convert(h, context: 0))
            }
        }
        return out
    }

    private static func convert(_ p: PatchHunk, context: Int) -> GitHunk {
        var old: [String] = [], new: [String] = []
        var removed = 0, added = 0, leading = 0, seenChange = false
        for line in p.lines {
            let body = String(line.dropFirst())
            switch line.first {
            case "-": old.append(body); removed += 1; seenChange = true
            case "+": new.append(body); added += 1; seenChange = true
            default:
                old.append(body); new.append(body)
                if !seenChange { leading += 1 }
            }
        }
        let kind: GitHunk.Kind = removed == 0 ? .added : (added == 0 ? .deleted : .modified)
        return GitHunk(context: context, oldStart: p.oldStart, oldCount: p.oldLines, newStart: p.newStart, newCount: p.newLines,
                       kind: kind, oldLines: old, newLines: new, leadingContext: leading)
    }
}
