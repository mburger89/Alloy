import Foundation
import MetalUICodeBuffer

public struct MergeOutcome: Equatable, Sendable {
    /// Session hunks applied to the buffer.
    public var applied: Int
    /// For each skipped session hunk, its line range in the new disk text (1-based).
    public var conflicts: [ClosedRange<Int>]
    public init(applied: Int, conflicts: [ClosedRange<Int>]) { self.applied = applied; self.conflicts = conflicts }
}

/// One line-level change a session made to a file: the bytes it replaced in the old text (UTF-8 offsets) and
/// what it put there, plus the lines it occupies in the new text.
public struct SessionHunk: Equatable, Sendable {
    public var oldBytes: Range<Int>
    public var newText: String
    public var newLines: ClosedRange<Int>
}

/// The dirty-buffer rule: a session wrote `newDisk` over a file whose buffer holds unsaved typing. The
/// session's hunks that do not touch the user's edits are applied to the buffer; the rest are skipped, so the
/// user's text always survives.
public enum DirtyMerge {
    /// The session's line hunks, `Patch.diff(oldDisk, newDisk, context: 0)` with byte ranges. Pure, so it can
    /// run off the main actor. Lines keep their terminators, so a change of line ending or of the final
    /// newline is a hunk too.
    public nonisolated static func hunks(oldDisk: String, newDisk: String) -> [SessionHunk] {
        let old = TextDiff.lineUnits(oldDisk), new = TextDiff.lineUnits(newDisk)
        func offsets(_ units: [String]) -> [Int] {
            var out = [0]; out.reserveCapacity(units.count + 1)
            for u in units { out.append(out[out.count - 1] + u.utf8.count) }
            return out
        }
        let oldOffsets = offsets(old), newUnits = new
        return Patch.diff(old: old, new: new, context: 0).map { h in
            let o = h.oldLines == 0 ? h.oldStart : h.oldStart - 1
            let n = h.newLines == 0 ? h.newStart : h.newStart - 1
            let text = newUnits[n..<(n + h.newLines)].joined()
            let first = h.newLines == 0 ? max(1, h.newStart) : h.newStart
            let last = max(first, h.newStart + h.newLines - 1)
            return SessionHunk(oldBytes: oldOffsets[o]..<oldOffsets[o + h.oldLines], newText: text, newLines: first...last)
        }
    }

    /// Computes the hunks and merges. `cursor` is a `CodeEditCursor` opened when the buffer last equalled
    /// `oldDisk`, at `savedVersion`.
    @MainActor
    public static func merge(buffer: CodeBuffer, savedVersion: UInt64, oldDisk: String, newDisk: String,
                             cursor: CodeEditCursor) -> MergeOutcome {
        let edits: [CodeEdit]?
        switch cursor.drain() {
        case .edits(let events): edits = events.filter { $0.version > savedVersion }
        case .resync: edits = nil
        }
        return merge(buffer: buffer, savedVersion: savedVersion, hunks: hunks(oldDisk: oldDisk, newDisk: newDisk),
                     oldDisk: Array(oldDisk.utf8), userEdits: edits)
    }

    /// The merge proper. `userEdits` are all buffer edits since `savedVersion`, oldest first (any origin: they
    /// all move the hunks); nil means they are unknown, which makes every hunk a conflict. `oldDisk` is used to check that a hunk's target still
    /// holds the text the session replaced.
    @MainActor
    public static func merge(buffer: CodeBuffer, savedVersion: UInt64, hunks: [SessionHunk], oldDisk: [UInt8],
                             userEdits: [CodeEdit]?) -> MergeOutcome {
        guard let userEdits else { return MergeOutcome(applied: 0, conflicts: hunks.map(\.newLines)) }
        // The ranges the user's edits occupy now. Each is its inserted text (or the point of a deletion),
        // carried forward through the later edits.
        var touched: [Range<Int>] = []
        for (i, e) in userEdits.enumerated() where e.origin != .external {
            var lo = e.range.lowerBound, hi = lo + e.newText.utf8.count
            for later in userEdits[(i + 1)...] {
                lo = advance(lo, through: later, bias: .before)
                hi = advance(hi, through: later, bias: .after)
            }
            touched.append(lo..<max(lo, hi))
        }
        let snap = buffer.snapshot()
        var edits: [CodeTextEdit] = [], conflicts: [ClosedRange<Int>] = []
        for h in hunks {
            // Carried through the collected edits, not `buffer.map`: draining a cursor lets the buffer trim its
            // own log, which `map` needs. A non-empty hunk ends in front of text typed at its end (column 0 of the
            // next line); an empty hunk (pure insertion) widens over text typed at its point.
            let lo = userEdits.reduce(h.oldBytes.lowerBound) { advance($0, through: $1, bias: .before) }
            let endBias: CodeBias = h.oldBytes.isEmpty ? .after : .before
            let hi = userEdits.reduce(h.oldBytes.upperBound) { advance($0, through: $1, bias: endBias) }
            guard lo <= hi, hi <= snap.utf8Count,
                  !touched.contains(where: { intersects($0, lo..<hi) }),
                  snap.utf8(in: lo..<hi) == Array(oldDisk[h.oldBytes]) else {
                conflicts.append(h.newLines); continue
            }
            edits.append(CodeTextEdit(range: lo..<hi, text: h.newText))
        }
        if !edits.isEmpty {
            do { _ = try buffer.applyExternalEdits(edits, expectingVersion: buffer.version) }
            catch { return MergeOutcome(applied: 0, conflicts: hunks.map(\.newLines)) }
        }
        return MergeOutcome(applied: edits.count, conflicts: conflicts)
    }

    /// Whether a user edit and a (mapped) session hunk share bytes. An empty range is a point: it conflicts
    /// when it lies within the other range, edges included for an empty hunk and the start edge only for a
    /// non-empty one (typing at the start of the next line is not an overlap).
    private static func intersects(_ user: Range<Int>, _ hunk: Range<Int>) -> Bool {
        switch (user.isEmpty, hunk.isEmpty) {
        case (false, false): return user.lowerBound < hunk.upperBound && hunk.lowerBound < user.upperBound
        case (true, false): return hunk.lowerBound <= user.lowerBound && user.lowerBound < hunk.upperBound
        case (false, true): return user.lowerBound <= hunk.lowerBound && hunk.lowerBound <= user.upperBound
        case (true, true): return user.lowerBound == hunk.lowerBound
        }
    }

    /// Where `o` goes when `e` is applied (the rule of `CodeBuffer.map`).
    private static func advance(_ o: Int, through e: CodeEdit, bias: CodeBias) -> Int {
        let start = e.range.lowerBound, end = e.range.upperBound, length = e.newText.utf8.count
        if o < start { return o }
        if o >= end && !(o == start && start == end) { return o + length - (end - start) }
        if start == end { return bias == .after ? start + length : start }
        if o == start { return start }
        return bias == .after ? start + length : start
    }
}
