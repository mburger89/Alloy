import Foundation

/// Selects the part of a file diff a chat block shows.
public enum DiffSlice {
    /// Lines owned by `editIDs`, plus two lines of unchanged context either side of each run. Changed lines that
    /// belong to other edits are never shown, not even as context: a file diff merges neighbouring edits into one
    /// region, and another session's inserted lines would otherwise appear on this edit's card as its own.
    public static func visible(_ lines: [DiffLine], editIDs: Set<UUID>) -> [DiffLine] {
        var keep = Array(repeating: false, count: lines.count)
        for (i, line) in lines.enumerated() {
            if owns(line, editIDs) { for j in max(0, i - 2)...min(lines.count - 1, i + 2) { keep[j] = true } }
        }
        return lines.indices.filter { keep[$0] && (isContext(lines[$0]) || owns(lines[$0], editIDs)) }.map { lines[$0] }
    }

    private static func isContext(_ line: DiffLine) -> Bool {
        if case .context = line { true } else { false }
    }

    private static func owns(_ line: DiffLine, _ editIDs: Set<UUID>) -> Bool {
        switch line {
        case .context: false
        case .added(_, _, let e, _): editIDs.contains(e)
        case .removed(_, let e): editIDs.contains(e)
        }
    }
}
