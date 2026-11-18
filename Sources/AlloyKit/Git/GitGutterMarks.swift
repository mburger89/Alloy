import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer

/// Puts HEAD-versus-buffer hunks into a view's `CodeDecorations` under the owner `git` (priority -1), as marks in
/// MetalUI's change lane, so they show on the same row as an author's gutter bar.
enum GitGutterMarks {
    static let owner = CodeDecorationOwner("git", priority: -1)
    /// Buffers over this size get no marks (the diff would cost more than the marks are worth).
    static let sizeLimit = 2 << 20

    /// The decorations of `hunks` for a buffer of `rowCount` rows, and the table from each tag to its hunk. Added and
    /// modified hunks get a change bar over their rows; a deletion gets a `deletedAbove` triangle on the row after it
    /// (the last row when the deletion is at the end).
    static func build(_ hunks: [GitHunk], rowCount: Int) -> (lines: [CodeLineDecoration], tags: [UInt64: GitHunk]) {
        var lines: [CodeLineDecoration] = []
        var tags: [UInt64: GitHunk] = [:]
        let last = max(0, rowCount - 1)
        for (i, hunk) in hunks.enumerated() {
            let tag = UInt64(i + 1)
            tags[tag] = hunk
            switch hunk.kind {
            case .added, .modified:
                let rows = hunk.bufferRows
                let clipped = min(rows.lowerBound, last)..<min(rows.upperBound, rowCount)
                guard !clipped.isEmpty else { continue }
                lines.append(CodeLineDecoration(lines: clipped, tag: tag, changeBar: hunk.kind == .added ? .added(.gitBarAdded) : .modified(.gitBarModified)))
            case .deleted:
                let row = min(hunk.markRow, last)
                lines.append(CodeLineDecoration(lines: row..<(row + 1), tag: tag, changeBar: .deletedAbove(.gitBarDeleted)))
            }
        }
        lines.sort { $0.lines.lowerBound < $1.lines.lowerBound }
        return (lines, tags)
    }

    /// Replaces the git decorations of `decorations`; `asOf` is the buffer version `hunks` were computed for and
    /// `rowCount` its row count.
    @MainActor
    static func apply(_ hunks: [GitHunk], tags: inout [UInt64: GitHunk], to decorations: CodeDecorations, asOf version: UInt64,
                      rowCount: Int) {
        let built = build(hunks, rowCount: rowCount)
        tags = built.tags
        decorations.setLineDecorations(built.lines, asOf: version, owner: owner)
    }

    @MainActor
    static func clear(_ decorations: CodeDecorations) {
        decorations.removeDecorations(of: owner)
    }
}
