import Foundation

/// What the user has changed since the last save: the saved text against the buffer. Pure, so it runs off the main thread.
public enum OwnEdits {
    /// Buffers over this size get no own-edit tint and no diff (the same limit as the git gutter marks).
    public static let sizeLimit = 2 << 20

    /// 0-based line ranges in `current` that differ from `saved`. A deletion-only region is an empty range at the line
    /// where it happened.
    public static func changedLines(saved: String, current: String) -> [Range<Int>] {
        if TextDiff.same(saved, current) { return [] }
        return TextDiff.regions(old: TextDiff.lineUnits(saved), new: TextDiff.lineUnits(current)).map(\.new)
    }

    /// UTF-8 byte ranges in `current` that differ from `saved`: each changed line region narrowed to the bytes between
    /// its common prefix and suffix. A pure deletion gives an empty range at the deletion point.
    public static func changedBytes(saved: String, current: String) -> [Range<Int>] {
        if TextDiff.same(saved, current) { return [] }
        let oldUnits = TextDiff.lineUnits(saved), newUnits = TextDiff.lineUnits(current)
        var newOffsets = [0]
        newOffsets.reserveCapacity(newUnits.count + 1)
        for u in newUnits { newOffsets.append(newOffsets[newOffsets.count - 1] + u.utf8.count) }
        var oldOffsets = [0]
        oldOffsets.reserveCapacity(oldUnits.count + 1)
        for u in oldUnits { oldOffsets.append(oldOffsets[oldOffsets.count - 1] + u.utf8.count) }
        let old = Array(saved.utf8), new = Array(current.utf8)
        return TextDiff.regions(old: oldUnits, new: newUnits).map { region in
            let o = oldOffsets[region.old.lowerBound]..<oldOffsets[region.old.upperBound]
            let n = newOffsets[region.new.lowerBound]..<newOffsets[region.new.upperBound]
            var p = 0
            while p < o.count, p < n.count, old[o.lowerBound + p] == new[n.lowerBound + p] { p += 1 }
            var s = 0
            while s < o.count - p, s < n.count - p, old[o.upperBound - 1 - s] == new[n.upperBound - 1 - s] { s += 1 }
            return (n.lowerBound + p)..<(n.upperBound - s)
        }
    }
}
