import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer

/// Puts a ``DiffDecorationModel`` into a `CodeDecorations`: author bars and a tint on added rows, the removed
/// lines as virtual rows, and a background on the text of lines more than one author wrote.
enum DiffDecorations {
    /// Replaces the diff decorations of `decorations`. Rows and offsets are those of buffer `version`, whose text is
    /// `byteCount` bytes long; MetalUI maps them forward through later edits.
    ///
    /// `diagnostics` (laid out for the buffer as it is now) go into the same two calls, because each replaces every
    /// line decoration and virtual row. Then the diff's rows, which are those of `saved`, are first moved to the
    /// buffer's current version and everything is set as of that. An author bar keeps its row; a diagnostic's bar
    /// shows only on rows with none. The author-run layer (`.annotations`) does not depend on the diagnostics, so a
    /// repaint for new diagnostics passes `includeAnnotations: false` and leaves it as it is.
    @MainActor @discardableResult
    static func apply(_ model: DiffDecorationModel, to decorations: CodeDecorations, sessions: [Session],
                      version: UInt64, byteCount: Int, fillers: [SideBySideModel.Filler]? = nil,
                      diagnostics: DiagnosticDecorations.Layout? = nil, rowLog: RowDeltaLog? = nil,
                      savedRowCount: Int = 0, includeAnnotations: Bool = true) -> Bool {
        func color(_ author: Author) -> Color { authorColor(author, sessions: sessions) }
        func tag(_ edit: UUID) -> UInt64? { model.tagOf[edit] }
        var lines = model.lineBars.map {
            CodeLineDecoration(lines: $0.rows, gutterBar: color($0.author), background: .addedRowTint, tag: tag($0.edit))
        }
        var rows: [CodeVirtualRow]
        if let fillers {
            // Side by side: the right pane shows no removed lines, only the blank rows that keep it level with the left.
            rows = fillers.map { .filler($0.count, at: .before(line: $0.beforeRow)) }
        } else {
            rows = model.removedGroups.map {
                CodeVirtualRow(anchor: .before(line: $0.beforeRow), lines: $0.lines, gutterBar: color($0.author),
                               background: .removedRowTint, gutterMarker: CodeGutterMarker("-"), tag: tag($0.edit))
            }
        }
        var asOf = version
        var ok = true
        if let diagnostics, !diagnostics.isEmpty {
            // Side by side keeps its panes level: only the right pane has message rows, so it gets none.
            let extra = fillers == nil ? diagnostics.rows : []
            if let rowLog, let moved = rowLog.move(lines: lines, rows: rows, from: version, rowCount: savedRowCount,
                                                   to: decorations.buffer.version) {
                // MetalUI's own rule, applied here so the diff looks the same with and without diagnostics. The message
                // rows go first: at one gap they must sit directly under their line, above removed lines.
                lines = diagnostics.lines + moved.lines
                rows = extra + moved.rows
                asOf = decorations.buffer.version
            } else {
                ok = false   // the edit log no longer reaches the saved version: the diff is gone, the diagnostics are not
                lines = diagnostics.lines
                rows = extra
                asOf = decorations.buffer.version
            }
        }
        decorations.setLineDecorations(lines, asOf: asOf)
        decorations.setVirtualRows(rows, asOf: asOf)
        guard includeAnnotations else { return ok }
        var styles: [Author: CodeStyleID] = [:]
        let runs = model.authorRuns.map { run -> CodeStyleRun in
            let id = styles[run.author] ?? decorations.register(CodeStyle(background: color(run.author).opacity(authorRunAlpha)))
            styles[run.author] = id
            return CodeStyleRun(range: run.byteRange, style: id)
        }
        decorations.setHighlights(runs, in: 0..<byteCount, layer: .annotations, asOf: version)
        return ok
    }

    /// The line decorations and message rows of a file with no diff, for the buffer as it is now.
    @MainActor
    static func applyDiagnostics(_ layout: DiagnosticDecorations.Layout, to decorations: CodeDecorations, showRows: Bool = true) {
        let version = decorations.buffer.version
        decorations.setLineDecorations(layout.lines, asOf: version)
        decorations.setVirtualRows(showRows ? layout.rows : [], asOf: version)
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

/// One edit's effect on rows, as MetalUI keeps it: rows `afterRow..<afterRow + removed` went and `inserted` new ones
/// took their place.
struct RowDelta: Equatable {
    var version: UInt64
    var afterRow: Int
    var removed: Int
    var inserted: Int
}

/// The row changes of a buffer since `base`, recorded from the edits the view drains. It repeats MetalUI's rule for
/// carrying line decorations and virtual rows forward (`CodeDecorations` splices at `startRow + 1`), so decorations
/// can be moved to the current version by hand, together with others that are already current.
struct RowDeltaLog {
    private(set) var base: UInt64
    private(set) var deltas: [RowDelta] = []
    static let limit = 4096

    init(base: UInt64) { self.base = base }

    mutating func record(_ edit: CodeEdit) {
        let startRow = edit.startPoint.row
        let removed = edit.oldEndPoint.row - startRow, inserted = edit.newEndPoint.row - startRow
        guard removed > 0 || inserted > 0 else { return }
        deltas.append(RowDelta(version: edit.version, afterRow: startRow + 1, removed: removed, inserted: inserted))
        if deltas.count > Self.limit {
            let drop = deltas.count - Self.limit
            base = deltas[drop - 1].version
            deltas.removeFirst(drop)
        }
    }

    /// The log no longer reaches back: start over from `version`.
    mutating func reset(at version: UInt64) {
        base = version
        deltas = []
    }

    /// `lines` and `rows`, which are rows of `version` (a buffer of `rowCount` rows then), as of `current`. Nil when
    /// the log does not reach `version`.
    func move(lines: [CodeLineDecoration], rows: [CodeVirtualRow], from version: UInt64, rowCount: Int,
              to current: UInt64) -> (lines: [CodeLineDecoration], rows: [CodeVirtualRow])? {
        guard version >= base || version == current else { return nil }
        let steps = deltas.filter { $0.version > version }
        var total = rowCount
        // Each decoration is a list of row ranges: an edit in its middle cuts a hole.
        var pieces: [[Range<Int>]] = lines.map { line in
            let r = max(0, line.lines.lowerBound)..<min(total, line.lines.upperBound)
            return r.isEmpty ? [] : [r]
        }
        // A gap (rows above a virtual row), or nil once an edit removed it.
        func gapOf(_ anchor: CodeVirtualRow.Anchor) -> Int {
            switch anchor {
            case .before(let line): max(0, line)
            case .after(let line): max(0, line) + 1
            }
        }
        var gaps: [Int?] = rows.map { min(gapOf($0.anchor), total) }
        for step in steps {
            let at = min(step.afterRow, total)
            let removed = min(step.removed, max(0, total - step.afterRow))
            let delta = step.inserted - removed
            for i in pieces.indices {
                pieces[i] = pieces[i].flatMap { piece -> [Range<Int>] in
                    var out: [Range<Int>] = []
                    let below = piece.lowerBound..<min(piece.upperBound, at)
                    if !below.isEmpty { out.append(below) }
                    let lo = max(piece.lowerBound, at + removed)
                    if piece.upperBound > lo { out.append((lo + delta)..<(piece.upperBound + delta)) }
                    return out
                }
            }
            for i in gaps.indices {
                guard let gap = gaps[i], gap > at else { continue }
                if removed > 0, gap <= at + removed - 1 { gaps[i] = nil } else { gaps[i] = gap + delta }
            }
            total += delta
        }
        var newLines: [CodeLineDecoration] = []
        for (line, parts) in zip(lines, pieces) {
            for part in parts {
                var copy = line
                copy.lines = part
                newLines.append(copy)
            }
        }
        var newRows: [CodeVirtualRow] = []
        for (row, gap) in zip(rows, gaps) {
            guard let gap else { continue }
            var copy = row
            if case .after = row.anchor { copy.anchor = .after(line: gap - 1) } else { copy.anchor = .before(line: gap) }
            newRows.append(copy)
        }
        return (newLines, newRows)
    }
}
