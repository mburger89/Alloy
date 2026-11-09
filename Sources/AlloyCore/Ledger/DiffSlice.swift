import Foundation

/// Selects the part of a file diff a chat block shows.
public enum DiffSlice {
    /// Lines owned by `editIDs`, plus two lines of context either side of each run.
    public static func visible(_ lines: [DiffLine], editIDs: Set<UUID>) -> [DiffLine] {
        var keep = Array(repeating: false, count: lines.count)
        for (i, line) in lines.enumerated() {
            let mine: Bool
            switch line {
            case .context: mine = false
            case .added(_, _, let e, _): mine = editIDs.contains(e)
            case .removed(_, let e): mine = editIDs.contains(e)
            }
            if mine { for j in max(0, i - 2)...min(lines.count - 1, i + 2) { keep[j] = true } }
        }
        return lines.indices.filter { keep[$0] }.map { lines[$0] }
    }
}
