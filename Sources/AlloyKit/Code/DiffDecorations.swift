import AlloyCore
import Foundation
import MetalUI

/// Puts a ``DiffDecorationModel`` into a `CodeDecorations`: author bars and a tint on added rows, the removed
/// lines as virtual rows, and a background on the text of lines more than one author wrote.
enum DiffDecorations {
    /// Replaces the diff decorations of `decorations`. Rows and offsets are those of buffer `version`, whose text is
    /// `byteCount` bytes long; MetalUI maps them forward through later edits.
    @MainActor
    static func apply(_ model: DiffDecorationModel, to decorations: CodeDecorations, sessions: [Session],
                      version: UInt64, byteCount: Int, fillers: [SideBySideModel.Filler]? = nil) {
        func color(_ author: Author) -> Color { authorColor(author, sessions: sessions) }
        func tag(_ edit: UUID) -> UInt64? { model.tagOf[edit] }
        decorations.setLineDecorations(model.lineBars.map {
            CodeLineDecoration(lines: $0.rows, gutterBar: color($0.author), background: .addedRowTint, tag: tag($0.edit))
        }, asOf: version)
        if let fillers {
            // Side by side: the right pane shows no removed lines, only the blank rows that keep it level with the left.
            decorations.setVirtualRows(fillers.map { .filler($0.count, at: .before(line: $0.beforeRow)) }, asOf: version)
        } else {
            decorations.setVirtualRows(model.removedGroups.map {
                CodeVirtualRow(anchor: .before(line: $0.beforeRow), lines: $0.lines, gutterBar: color($0.author),
                               background: .removedRowTint, gutterMarker: CodeGutterMarker("-"), tag: tag($0.edit))
            }, asOf: version)
        }
        var styles: [Author: CodeStyleID] = [:]
        let runs = model.authorRuns.map { run -> CodeStyleRun in
            let id = styles[run.author] ?? decorations.register(CodeStyle(background: color(run.author).opacity(authorRunAlpha)))
            styles[run.author] = id
            return CodeStyleRun(range: run.byteRange, style: id)
        }
        decorations.setHighlights(runs, in: 0..<byteCount, layer: .annotations, asOf: version)
    }

    /// Decorates the left (old) pane of a side-by-side diff: the removed lines tinted with the author's bar, and the
    /// filler rows in front of the lines the right pane added. The left buffer is read-only and never edited, so
    /// `version` is its own.
    @MainActor
    static func applyLeft(_ model: SideBySideModel, to decorations: CodeDecorations, sessions: [Session], version: UInt64) {
        decorations.setLineDecorations(model.leftBars.map {
            CodeLineDecoration(lines: $0.rows, gutterBar: authorColor($0.author, sessions: sessions),
                               background: .removedRowTint, tag: $0.tag)
        }, asOf: version)
        decorations.setVirtualRows(model.leftFillers.map { .filler($0.count, at: .before(line: $0.beforeRow)) }, asOf: version)
    }
}
