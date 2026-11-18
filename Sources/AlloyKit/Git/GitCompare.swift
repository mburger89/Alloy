import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer

/// What the right pane of a side-by-side view is compared with: a session's edit (the ledger) or a git base.
enum CompareSource {
    case ledger(EditRecord)
    case git(GitCompare)
}

/// The buffer against HEAD or the index: the hunks with three lines of context (what the bar counts and steps), and
/// for each the zero-context changes inside it (what the bars, fillers and write commands use).
struct GitCompare {
    enum Base { case head, index }

    var base: Base
    var hunks: [GitHunk]
    /// `parts[i]` are the zero-context changes inside `hunks[i]`, numbered as in the whole file.
    var parts: [[GitHunk]]
    var baseText: String

    /// The compare of `snapshot` against `baseText`. Runs off the main actor.
    nonisolated static func build(base: Base, baseText: String, snapshot: CodeSnapshot) -> GitCompare {
        let hunks = GitHunks.compareHunks(base: baseText, buffer: snapshot.text)
        return GitCompare(base: base, hunks: hunks, parts: hunks.map(parts(of:)), baseText: baseText)
    }

    /// The zero-context changes inside a context hunk, in the file's numbering.
    nonisolated static func parts(of hunk: GitHunk) -> [GitHunk] {
        let old = hunk.oldLines.map { $0 + "\n" }.joined(), new = hunk.newLines.map { $0 + "\n" }.joined()
        let offsetOld = hunk.oldLines.isEmpty ? 0 : hunk.oldStart - 1
        let offsetNew = hunk.newLines.isEmpty ? 0 : hunk.newStart - 1
        return GitHunks.compute(base: old, buffer: new).map {
            var part = $0
            part.oldStart += offsetOld
            part.newStart += offsetNew
            return part
        }
    }

    /// The tag of every part, mapped to the index of the hunk it lies in (tags are `1...`).
    var tags: [UInt64: Int] {
        var out: [UInt64: Int] = [:]
        var tag: UInt64 = 1
        for (i, group) in parts.enumerated() { for _ in group { out[tag] = i; tag += 1 } }
        return out
    }
}

/// The decorations of the two panes of a git compare.
struct GitCompareDecorations {
    var rightLines: [CodeLineDecoration] = []
    var rightRows: [CodeVirtualRow] = []
    var leftLines: [CodeLineDecoration] = []
    var leftRows: [CodeVirtualRow] = []

    /// Change bars and tints on the changed rows of the right pane (a `deletedAbove` triangle where only the left has
    /// rows), gutter bars and tints on the base rows of the left, and filler rows that keep the two panes level.
    static func build(_ compare: GitCompare, leftRowCount: Int, rightRowCount: Int) -> GitCompareDecorations {
        var out = GitCompareDecorations()
        var tag: UInt64 = 1
        let rightLast = max(0, rightRowCount - 1)
        for group in compare.parts {
            for part in group {
                defer { tag += 1 }
                let oldRows = (part.oldStart - 1)..<(part.oldStart - 1 + part.oldCount)
                let oldEnd = part.oldCount == 0 ? part.oldStart : oldRows.upperBound
                let newEnd = part.newCount == 0 ? part.newStart : part.bufferRows.upperBound
                switch part.kind {
                case .added, .modified:
                    let rows = part.bufferRows
                    let clipped = min(rows.lowerBound, rightLast)..<min(rows.upperBound, rightRowCount)
                    if !clipped.isEmpty {
                        out.rightLines.append(CodeLineDecoration(lines: clipped, background: .addedRowTint, tag: tag,
                                                                 changeBar: part.kind == .added ? .added(.gitBarAdded) : .modified(.gitBarModified)))
                    }
                case .deleted:
                    let row = min(part.markRow, rightLast)
                    out.rightLines.append(CodeLineDecoration(lines: row..<(row + 1), tag: tag, changeBar: .deletedAbove(.gitBarDeleted)))
                }
                if part.oldCount > 0 {
                    let clipped = max(0, oldRows.lowerBound)..<min(oldRows.upperBound, max(leftRowCount, oldRows.upperBound))
                    out.leftLines.append(CodeLineDecoration(lines: clipped, gutterBar: part.kind == .deleted ? .gitBarDeleted : .gitBarModified,
                                                            background: .removedRowTint, tag: tag))
                }
                if part.newCount > part.oldCount {
                    out.leftRows.append(.filler(part.newCount - part.oldCount, at: .before(line: min(oldEnd, leftRowCount))))
                } else if part.oldCount > part.newCount {
                    out.rightRows.append(.filler(part.oldCount - part.newCount, at: .before(line: min(newEnd, rightRowCount))))
                }
            }
        }
        out.rightLines.sort { $0.lines.lowerBound < $1.lines.lowerBound }
        out.leftLines.sort { $0.lines.lowerBound < $1.lines.lowerBound }
        return out
    }
}

extension DiffDecorations {
    /// Decorates a git compare: the right pane (the live buffer; rows are those of `version`, which MetalUI maps
    /// forward through later edits) and the read-only left pane holding the base text.
    @MainActor
    static func applyGit(_ built: GitCompareDecorations, right: CodeDecorations, rightVersion: UInt64,
                         left: CodeDecorations?, leftVersion: UInt64) {
        right.setLineDecorations(built.rightLines, asOf: rightVersion)
        right.setVirtualRows(built.rightRows, asOf: rightVersion)
        left?.setLineDecorations(built.leftLines, asOf: leftVersion)
        left?.setVirtualRows(built.leftRows, asOf: leftVersion)
    }
}
