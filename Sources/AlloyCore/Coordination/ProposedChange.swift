import Foundation

/// Lines (1-based, inclusive) of one file. `path` is project-relative, the key `ProjectLedger.files` uses.
public struct LineRange: Hashable, Sendable {
    public var path: String
    public var lines: ClosedRange<Int>
    public init(path: String, lines: ClosedRange<Int>) { self.path = path; self.lines = lines }
}

/// What a session is about to do to a file, seen at its PreToolUse hook, before the tool runs.
public struct ProposedChange: Sendable, Equatable {
    public var session: UUID
    public var toolUseID: String
    /// The smallest range covering every changed span.
    public var range: LineRange
    /// Every changed span (more than one for `replace_all`), ascending. The overlap check uses these, so a
    /// `replace_all` does not claim the lines between its matches.
    public var ranges: [ClosedRange<Int>]
    public var date: Date
    /// A compact unified-ish snippet (`-old` / `+new`), at most `maxDiffLines` lines.
    public var diff: String

    public static let maxDiffLines = 20
    static let maxDiffLineCharacters = 120

    public init(session: UUID, toolUseID: String, range: LineRange, ranges: [ClosedRange<Int>]? = nil,
                date: Date, diff: String) {
        self.session = session; self.toolUseID = toolUseID; self.range = range
        self.ranges = ranges ?? [range.lines]; self.date = date; self.diff = diff
    }

    /// Maps a tool input to the lines it would change in `currentText`, the in-memory text (the ledger's, or
    /// the open buffer's). Pure, with no file access. `path` is the project-relative path the caller
    /// resolved from the input. Nil when the change cannot be placed:
    /// - `currentText` is nil (Alloy does not hold the file, or the file is new);
    /// - Edit: `old_string` is empty, absent, or (without `replace_all`) matches more than once, which the CLI
    ///   rejects;
    /// - Write: the content equals the current text;
    /// - NotebookEdit: no `cell_id` that names one cell of the notebook JSON;
    /// - any other tool. (The CLI has no MultiEdit tool, so it is not mapped.)
    public static func from(session: UUID, toolUseID: String, path: String, toolName: String, input: JSONValue,
                            currentText: String?, date: Date = Date()) -> ProposedChange? {
        guard let currentText, case .object(let obj) = input else { return nil }
        func string(_ key: String) -> String? { if case .string(let s)? = obj[key] { return s } else { return nil } }
        var spans: [ClosedRange<Int>]
        let diff: String
        switch toolName {
        case "Edit":
            guard let old = string("old_string"), !old.isEmpty else { return nil }
            let replaceAll: Bool = { if case .bool(true)? = obj["replace_all"] { return true } else { return false } }()
            var text = currentText
            let needle = Array(old.utf8)
            let matches = text.withUTF8 { Bytes.matchLines($0, needle: needle, limit: replaceAll ? nil : 2) }
            guard !matches.isEmpty, replaceAll || matches.count == 1 else { return nil }
            spans = Self.merged(matches)
            diff = Self.compactDiff(old: lines(of: old), new: lines(of: string("new_string") ?? ""))
        case "Write":
            guard let content = string("content") else { return nil }
            var old = currentText, new = content
            guard let mapped = old.withUTF8({ o in new.withUTF8 { n in Bytes.writeSpan(old: o, new: n) } }) else { return nil }
            spans = [mapped.lines]
            diff = Self.compactDiff(old: lines(of: mapped.oldText), new: lines(of: mapped.newText))
        case "NotebookEdit":
            guard let cell = string("cell_id"), let span = notebookCellLines(in: currentText, cellID: cell) else { return nil }
            if string("edit_mode") == "insert" {
                // The new cell lands after `cell_id`: anchor on the boundary between its closing line and the next.
                spans = [span.upperBound...(span.upperBound + 1)]
                diff = Self.compactDiff(old: [], new: lines(of: string("new_source") ?? ""))
            } else {
                spans = [span]
                diff = Self.compactDiff(old: [], new: lines(of: string("new_source") ?? ""))
            }
        default:
            return nil
        }
        let hull = spans.first!.lowerBound...spans.last!.upperBound
        return ProposedChange(session: session, toolUseID: toolUseID, range: LineRange(path: path, lines: hull),
                              ranges: spans, date: date, diff: diff)
    }

    // MARK: Helpers

    static let maxSpans = 50

    /// Joins spans that share or touch lines; beyond `maxSpans` the tail becomes one covering span.
    static func merged(_ spans: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for s in spans {
            if let l = out.last, s.lowerBound <= l.upperBound + 1 {
                out[out.count - 1] = l.lowerBound...max(l.upperBound, s.upperBound)
            } else { out.append(s) }
        }
        if out.count > maxSpans {
            let tail = out[(maxSpans - 1)...]
            out = Array(out[..<(maxSpans - 1)]) + [tail.first!.lowerBound...tail.last!.upperBound]
        }
        return out
    }

    /// Lines without terminators ("\n" or "\r\n"); a final newline does not make an empty last line. Splits on
    /// bytes, because Swift treats "\r\n" as one Character.
    static func lines(of text: String) -> [String] {
        var parts = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// `-old` lines then `+new` lines, at most `maxDiffLines` in all (the last is "..." when cut).
    static func compactDiff(old: [String], new: [String]) -> String {
        var out = old.map { "-" + clip($0) } + new.map { "+" + clip($0) }
        if out.count > maxDiffLines { out = Array(out.prefix(maxDiffLines - 1)) + ["..."] }
        return out.joined(separator: "\n")
    }

    /// At most `maxDiffLineCharacters` UTF-8 bytes (cut on a scalar boundary), without a trailing CR.
    static func clip(_ line: String) -> String {
        var s = line
        if s.utf8.last == 0x0D { s = String(decoding: s.utf8.dropLast(), as: UTF8.self) }
        guard s.utf8.count > maxDiffLineCharacters else { return s }
        var out = String.UnicodeScalarView(), bytes = 0
        for u in s.unicodeScalars {
            let w = UTF8.width(u)
            if bytes + w > maxDiffLineCharacters { break }
            out.append(u); bytes += w
        }
        return String(out) + "\u{2026}"
    }

    /// The lines of the top-level notebook cell (`{ "cells": [ { ... } ] }`) whose `"id"` is `cellID`. A single
    /// forward scan that tracks JSON strings and the stack of open containers; it never builds a parse tree. Nil
    /// when no cell, or more than one, has that id.
    static func notebookCellLines(in text: String, cellID: String) -> ClosedRange<Int>? {
        let bytes = Array(text.utf8)
        let target = Array(("\"" + cellID + "\"").utf8)
        var stack: [(kind: UInt8, offset: Int)] = []
        var found: (open: Int, close: Int?)?
        var inString = false, escaped = false
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
            } else if b == 0x22 {
                if stack.count == 3, stack[0].kind == 0x7B, stack[1].kind == 0x5B, stack[2].kind == 0x7B,
                   bytes[i...].starts(with: target), idKeyPrecedes(bytes, i) {
                    // A second cell with the same id makes the target ambiguous.
                    if found != nil { return nil }
                    found = (stack[2].offset, nil)
                }
                inString = true
            } else if b == 0x7B || b == 0x5B {
                stack.append((b, i))
            } else if b == 0x7D || b == 0x5D, let top = stack.popLast(), let f = found, f.close == nil, f.open == top.offset {
                found = (top.offset, i)   // keep scanning only to rule out a duplicate id
            }
            i += 1
        }
        guard let f = found, let close = f.close else { return nil }
        func line(_ offset: Int) -> Int { 1 + bytes[..<offset].reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }
        return line(f.open)...line(close)
    }

    /// Whether the string starting at `i` is the value of an `"id"` key (`"id" :` before it).
    private static func idKeyPrecedes(_ bytes: [UInt8], _ i: Int) -> Bool {
        func space(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D }
        var j = i - 1
        while j >= 0, space(bytes[j]) { j -= 1 }
        guard j >= 0, bytes[j] == 0x3A else { return false }
        j -= 1
        while j >= 0, space(bytes[j]) { j -= 1 }
        let key = Array("\"id\"".utf8)
        return j >= key.count - 1 && Array(bytes[(j - key.count + 1)...j]) == key
    }
}

/// Byte-level scans over a text that is already in memory. They read the string's own UTF-8 storage (no copy)
/// and jump between newlines with `memchr`, so a 5,000-line file costs microseconds.
enum Bytes {
    private static func newlines(_ b: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> Int {
        guard let base = b.baseAddress, from < to else { return 0 }
        var n = 0, p = from
        while p < to, let hit = memchr(base + p, 0x0A, to - p) {
            n += 1; p = base.distance(to: hit.assumingMemoryBound(to: UInt8.self)) + 1
        }
        return n
    }

    /// The line span of each non-overlapping occurrence of `needle`, at most `limit` of them. A newline byte
    /// belongs to the line it ends.
    static func matchLines(_ b: UnsafeBufferPointer<UInt8>, needle: [UInt8], limit: Int?) -> [ClosedRange<Int>] {
        guard let base = b.baseAddress, !needle.isEmpty, needle.count <= b.count else { return [] }
        var out: [ClosedRange<Int>] = []
        var pos = 0, counted = 0, line = 1
        while pos <= b.count - needle.count,
              let hit = memmem(base + pos, b.count - pos, needle, needle.count) {
            let off = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
            line += newlines(b, counted, off)
            let end = line + newlines(b, off, off + needle.count - 1)
            out.append(line...end)
            line = end; counted = off + needle.count - 1
            if let limit, out.count >= limit { break }
            pos = off + needle.count
        }
        return out
    }

    /// The one prefix/suffix-trimmed hunk between two texts: its lines in `old`, and the text of the changed
    /// lines on each side. Nil when the texts are byte-identical (a final newline counts).
    static func writeSpan(old o: UnsafeBufferPointer<UInt8>, new n: UnsafeBufferPointer<UInt8>)
        -> (lines: ClosedRange<Int>, oldText: String, newText: String)? {
        let m = min(o.count, n.count)
        var p = 0
        if let ob = o.baseAddress, let nb = n.baseAddress {
            while p + 256 <= m, memcmp(ob + p, nb + p, 256) == 0 { p += 256 }
        }
        while p < m, o[p] == n[p] { p += 1 }
        var s = 0
        let limit = m - p
        if let ob = o.baseAddress, let nb = n.baseAddress {
            while s + 256 <= limit, memcmp(ob + o.count - s - 256, nb + n.count - s - 256, 256) == 0 { s += 256 }
        }
        while s < limit, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        let oldEnd = o.count - s, newEnd = n.count - s
        if p == oldEnd && p == newEnd { return nil }

        let total = newlines(o, 0, o.count)
        let top = max(1, total + (o.last == 0x0A || o.isEmpty ? 0 : 1))
        func lineOf(_ offset: Int) -> Int { min(top, 1 + newlines(o, 0, offset)) }
        let lines: ClosedRange<Int>
        if p < oldEnd {
            lines = lineOf(p)...lineOf(oldEnd - 1)
        } else {
            // A pure insertion: the lines either side of the insertion point.
            let l = lineOf(p)
            lines = (p == 0 || o[p - 1] == 0x0A ? max(1, l - 1) : l)...l
        }
        // Whole lines of the changed span on both sides (the prefix and suffix are equal, so they line up).
        var start = p
        while start > 0, o[start - 1] != 0x0A { start -= 1 }
        func lineEnd(_ b: UnsafeBufferPointer<UInt8>, from i: Int) -> Int {
            var e = i
            while e < b.count, b[e] != 0x0A { e += 1 }
            return min(b.count, e + 1)
        }
        func text(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: b[lo..<max(lo, hi)]), as: UTF8.self)
        }
        let oldText = oldEnd > p ? text(o, start, lineEnd(o, from: oldEnd - 1)) : ""
        let newText = newEnd > p ? text(n, start, lineEnd(n, from: newEnd - 1)) : ""
        return (lines, oldText, newText)
    }
}
