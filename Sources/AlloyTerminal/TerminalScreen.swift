#if !os(Windows)

import Foundation
import MetalUITerminal

/// What the terminal view does not do for itself: select all, clear scrollback, selected text, search and
/// reveal. Every call hops through the snapshot source's queue (`perform`), which publishes afterwards, so the
/// view redraws with the new selection or viewport.
public struct TerminalScreen: Sendable {
    private let source: TerminalSnapshotSource
    private let viewportRows: @Sendable () -> Int

    /// `viewportRows` is the pane's current row count, used to place a revealed match (the emulator exposes no
    /// public row count).
    public init(source: TerminalSnapshotSource, viewportRows: @escaping @Sendable () -> Int) {
        self.source = source
        self.viewportRows = viewportRows
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable (TerminalEmulator) -> T) async -> T {
        await withCheckedContinuation { continuation in
            source.perform { continuation.resume(returning: body($0)) }
        }
    }

    /// The absolute number of the last row that exists (scrollback and screen), by probing `rowText`.
    private static func lastRow(_ emulator: TerminalEmulator) -> Int {
        let first = emulator.firstRow
        var step = 1
        while emulator.rowText(first + step) != nil { step *= 2 }
        var low = step / 2, high = step   // row first+low exists (or low == 0), first+high does not
        while high - low > 1 {
            let mid = (low + high) / 2
            if emulator.rowText(first + mid) != nil { low = mid } else { high = mid }
        }
        return first + low
    }

    /// Selects every row from the oldest scrollback row to the last screen row.
    public func selectAll() async {
        await run { emulator in
            let first = emulator.firstRow
            let last = Self.lastRow(emulator)
            emulator.selection = .linear(TerminalRange(lowerBound: TerminalPosition(row: first, col: 0),
                                                       upperBound: TerminalPosition(row: last, col: Int.max)))
        }
    }

    /// The selected text (trailing blanks trimmed per row), nil without a selection.
    public func selectedText() async -> String? {
        await run { $0.selectedText() }
    }

    public func clearSelection() async {
        await run { $0.selection = nil }
    }

    /// Drops the scrollback (the emulator's ED 3) and keeps the screen.
    public func clearScrollback() async {
        await run { emulator in
            Array("\u{1B}[3J".utf8).withUnsafeBytes { emulator.feed($0) }
            emulator.scrollViewport(toOffset: 0)
        }
    }

    /// The first match of `needle` from `from` (nil: the selection start, else the viewport's first row is
    /// approximated by the oldest row for backwards and the first row for forwards). Never wraps.
    public func search(_ needle: String, from: TerminalPosition?, backwards: Bool) async -> TerminalRange? {
        guard !needle.isEmpty else { return nil }
        return await run { emulator in
            let start: TerminalPosition
            if let from {
                start = from
            } else if let selection = emulator.selection {
                switch selection {
                case .linear(let r), .block(let r): start = min(r.lowerBound, r.upperBound)
                }
            } else if backwards {
                start = TerminalPosition(row: Self.lastRow(emulator), col: Int.max)
            } else {
                start = TerminalPosition(row: emulator.firstRow, col: 0)
            }
            return emulator.search(needle, from: start, backwards: backwards)
        }
    }

    /// Selects `range` and scrolls the viewport so its first row shows, near the middle when it was off screen.
    public func reveal(_ range: TerminalRange) async {
        let rows = max(viewportRows(), 1)
        await run { emulator in
            emulator.selection = .linear(range)
            let last = Self.lastRow(emulator)
            let liveTop = last - rows + 1
            let row = min(range.lowerBound.row, range.upperBound.row)
            if row >= liveTop {
                emulator.scrollViewport(toOffset: 0)
            } else {
                emulator.scrollViewport(toOffset: liveTop - row + rows / 2)
            }
        }
    }


    /// The next (or previous) match of `needle` after the current selection, wrapping past either end, selected and
    /// scrolled into view. `inclusive` lets a match at the selection itself count (a query that just changed). Nil
    /// for an empty needle or no match anywhere; the selection and viewport then stay as they were.
    public func find(_ needle: String, backwards: Bool, inclusive: Bool = false) async -> TerminalRange? {
        guard !needle.isEmpty else { return nil }
        let match: TerminalRange? = await run { emulator in
            let selected: TerminalPosition? = emulator.selection.map {
                switch $0 { case .linear(let r), .block(let r): return min(r.lowerBound, r.upperBound) }
            }
            var from: TerminalPosition
            if let selected {
                from = backwards || inclusive ? selected : TerminalPosition(row: selected.row, col: selected.col + 1)
            } else {
                from = backwards ? TerminalPosition(row: Self.lastRow(emulator), col: Int.max)
                                 : TerminalPosition(row: emulator.firstRow, col: 0)
            }
            if let hit = emulator.search(needle, from: from, backwards: backwards) { return hit }
            from = backwards ? TerminalPosition(row: Self.lastRow(emulator), col: Int.max)
                             : TerminalPosition(row: emulator.firstRow, col: 0)
            return emulator.search(needle, from: from, backwards: backwards)
        }
        if let match { await reveal(match) }
        return match
    }

    public func modes() async -> TerminalModes {
        await run { $0.modes }
    }
}

#endif
