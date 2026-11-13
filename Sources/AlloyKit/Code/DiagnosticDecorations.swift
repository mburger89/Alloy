import AlloyLSP
import Foundation
import MetalUI
import MetalUICodeBuffer

/// Paints language-server diagnostics into a `CodeDecorations`: a tint over each range (on MetalUI's `.diagnostics`
/// layer), a gutter bar on the first row of each problem, and one message row under each row that has an error or
/// warning. Hints are counted nowhere and painted nowhere.
enum DiagnosticDecorations {
    /// The most message rows a file gets.
    static let maxVirtualRows = 200

    /// The row decorations and message rows of the diagnostics, in the rows of one buffer version.
    struct Layout {
        var lines: [CodeLineDecoration] = []
        var rows: [CodeVirtualRow] = []
        var isEmpty: Bool { lines.isEmpty && rows.isEmpty }
    }

    static func color(_ severity: Severity) -> Color? {
        switch severity {
        case .error: .diagnosticError
        case .warning: .diagnosticWarning
        case .information: .diagnosticInfo
        case .hint: nil
        }
    }

    // MARK: Pure parts

    /// Disjoint ranges covering the text any diagnostic covers, each with the most severe diagnostic over it (an error
    /// beats a warning on the same byte). Hints and empty ranges are left out.
    static func segments(_ items: [LSPDiagnostic]) -> [(range: Range<Int>, severity: Severity)] {
        var deltas: [Int: [Int]] = [:]   // offset -> per-severity change of the number of diagnostics covering it
        for item in items where item.severity != .hint && !item.range.isEmpty {
            let s = item.severity.rawValue - 1
            deltas[item.range.lowerBound, default: [0, 0, 0]][s] += 1
            deltas[item.range.upperBound, default: [0, 0, 0]][s] -= 1
        }
        var result: [(range: Range<Int>, severity: Severity)] = []
        var active = [0, 0, 0]
        var start = 0
        var current: Severity?
        for offset in deltas.keys.sorted() {
            if let current, start < offset {
                if let last = result.last, last.severity == current, last.range.upperBound == start {
                    result[result.count - 1].range = last.range.lowerBound..<offset
                } else {
                    result.append((start..<offset, current))
                }
            }
            for i in 0..<3 { active[i] += deltas[offset]![i] }
            current = active.firstIndex { $0 > 0 }.flatMap { Severity(rawValue: $0 + 1) }
            start = offset
        }
        return result
    }

    /// The row decorations and message rows for `items` (ranges in the coordinates of `snapshot`).
    static func layout(_ items: [LSPDiagnostic], in snapshot: CodeSnapshot) -> Layout {
        var worst: [Int: Severity] = [:]
        var message: [Int: LSPDiagnostic] = [:]
        for item in items where item.severity != .hint {
            let row = snapshot.point(at: min(item.range.lowerBound, snapshot.utf8Count)).row
            if worst[row].map({ item.severity.rawValue < $0.rawValue }) ?? true { worst[row] = item.severity }
            guard item.severity == .error || item.severity == .warning else { continue }
            // The most severe message of the row, the first of equals.
            if message[row].map({ item.severity.rawValue < $0.severity.rawValue }) ?? true { message[row] = item }
        }
        var layout = Layout()
        // Neighbouring rows of one severity share a decoration.
        var run: (rows: Range<Int>, severity: Severity)?
        func flush() {
            guard let run, let bar = color(run.severity) else { return }
            layout.lines.append(CodeLineDecoration(lines: run.rows, gutterBar: bar))
        }
        for row in worst.keys.sorted() {
            let severity = worst[row]!
            if let open = run, open.rows.upperBound == row, open.severity == severity {
                run = (open.rows.lowerBound..<(row + 1), severity)
            } else {
                flush()
                run = (row..<(row + 1), severity)
            }
        }
        flush()
        for row in message.keys.sorted().prefix(maxVirtualRows) {
            let item = message[row]!
            guard let tint = color(item.severity) else { continue }
            layout.rows.append(CodeVirtualRow(anchor: .after(line: row), lines: [rowText(item)], gutterBar: tint,
                                              background: tint.opacity(diagnosticTintAlpha)))
        }
        return layout
    }

    /// `"⚠ message — source"`; the message up to its first line break.
    static func rowText(_ item: LSPDiagnostic) -> String {
        let first = item.message.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "\u{26A0} " + first + (item.source.map { " \u{2014} " + $0 } ?? "")
    }

    /// The problem after (`direction` 1) or before (`-1`) `selection`, wrapping. Problems are ordered by start, then
    /// severity, then position in `items`, so several that start at one offset are each reached. When the selection is
    /// exactly a problem's range (where the last step landed) the step goes from that problem; otherwise from the caret.
    static func nextProblem(_ items: [LSPDiagnostic], selection: Range<Int>, direction: Int) -> Range<Int>? {
        let ordered = items.enumerated().filter { $0.element.severity != .hint }
            .sorted { ($0.element.range.lowerBound, $0.element.severity.rawValue, $0.offset)
                < ($1.element.range.lowerBound, $1.element.severity.rawValue, $1.offset) }
            .map(\.element.range)
        guard !ordered.isEmpty else { return nil }
        let forward = direction >= 0
        if let last = ordered.lastIndex(of: selection), let first = ordered.firstIndex(of: selection) {
            // Equal ranges are one stop.
            return forward ? ordered[(last + 1) % ordered.count] : ordered[(first - 1 + ordered.count) % ordered.count]
        }
        if forward {
            let from = selection.lowerBound
            return ordered.first { selection.isEmpty ? $0.lowerBound >= from : $0.lowerBound > from } ?? ordered[0]
        }
        return ordered.last { $0.lowerBound < selection.lowerBound } ?? ordered[ordered.count - 1]
    }

    // MARK: Following the buffer

    /// `entry`'s diagnostics in the buffer's current coordinates: each range moves through the edits since the
    /// version it was published for. A range whose text was replaced collapses and goes; so does one the edit log
    /// no longer reaches.
    @MainActor
    static func current(_ entry: DiagnosticStore.Entry?, in buffer: CodeBuffer) -> [LSPDiagnostic] {
        guard let entry else { return [] }
        let now = buffer.version
        let version = entry.version.map { UInt64($0) } ?? now
        if version == now { return entry.items }
        let total = buffer.utf8Count
        return entry.items.compactMap { item in
            guard let lower = buffer.map(item.range.lowerBound, from: version, bias: .after),
                  let upper = buffer.map(item.range.upperBound, from: version, bias: .before) else { return nil }
            let range = min(lower, total)..<min(max(lower, upper), total)
            guard !range.isEmpty else { return nil }
            var moved = item
            moved.range = range
            return moved
        }
    }

    // MARK: Painting

    /// A range wide enough to cover any text; `setHighlights` clamps it.
    private static let wholeText = 0..<(1 << 40)

    /// Replaces the tint of `decorations` with the diagnostics of `entry`, at the version they were published for
    /// (MetalUI maps the runs forward through later edits).
    @MainActor
    static func applyTint(_ entry: DiagnosticStore.Entry?, to decorations: CodeDecorations) {
        var version = entry?.version.map { UInt64($0) } ?? decorations.buffer.version
        var entry = entry
        if decorations.buffer.map(0, from: version, bias: .after) == nil {
            // The edit log no longer reaches the version these were published for: show nothing rather than stale paint.
            entry = nil
            version = decorations.buffer.version
        }
        var styles: [Severity: CodeStyleID] = [:]
        var runs: [CodeStyleRun] = []
        for segment in segments(entry?.items ?? []) {
            guard let tint = color(segment.severity) else { continue }
            let id = styles[segment.severity] ?? decorations.register(CodeStyle(background: tint.opacity(diagnosticTintAlpha)))
            styles[segment.severity] = id
            runs.append(CodeStyleRun(range: segment.range, style: id))
        }
        decorations.setHighlights(runs, in: wholeText, layer: .diagnostics, asOf: version)
    }

    /// The row layout of `entry` for the buffer as it is now.
    @MainActor
    static func currentLayout(_ entry: DiagnosticStore.Entry?, in buffer: CodeBuffer) -> Layout {
        guard entry != nil else { return Layout() }
        return layout(current(entry, in: buffer), in: buffer.snapshot())
    }
}
