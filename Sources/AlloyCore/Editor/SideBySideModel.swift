import Foundation

/// The side-by-side diff of one file as plain values: the old text for the left pane, and the filler rows that keep
/// the two panes' lines level. Rows are 0-based rows of each pane's own text (the left pane shows `oldText`, the
/// right pane the current text). Nothing here touches a view.
public struct SideBySideModel: Equatable, Sendable {
    /// `count` blank display rows in front of buffer row `beforeRow` (equal to the line count: after the last line).
    public struct Filler: Equatable, Sendable {
        public var beforeRow: Int
        public var count: Int
        public init(beforeRow: Int, count: Int) { self.beforeRow = beforeRow; self.count = count }
    }

    /// Consecutive rows of one edit on one side, with the author's colour key and the click tag.
    public struct Bar: Equatable, Sendable {
        public var rows: Range<Int>
        public var author: Author
        public var edit: UUID
        public var tag: UInt64
    }

    /// The context and removed lines in order: the ledger's old view (baseline plus kept edits), with each line's
    /// own terminator.
    public var oldText = ""
    /// Blank rows on the left, where the right side has added lines the left lacks.
    public var leftFillers: [Filler] = []
    /// Blank rows on the right, where the left side has removed lines the right lacks.
    public var rightFillers: [Filler] = []
    /// Removed lines (left rows).
    public var leftBars: [Bar] = []
    /// Added lines (right rows).
    public var rightBars: [Bar] = []
    public var leftRowCount = 0
    public var rightRowCount = 0
    /// A bar tag to the edit it stands for; tags number the edits from 1 in order of appearance.
    public var tags: [UInt64: UUID] = [:]
    public var tagOf: [UUID: UInt64] = [:]

    public init() {}

    /// `terminators` gives each line's own terminator length in bytes (`FileLedger.diffEntries()`); without it every
    /// line ends in `lineEnding`.
    public static func build(_ lines: [DiffLine], terminators: [Int]? = nil,
                             authorOf: (UUID) -> Author = { _ in .outside }, lineEnding: String = "\n") -> SideBySideModel {
        var model = SideBySideModel()
        var old = ""
        var left = 0, right = 0
        var pendingRemoved = 0, pendingAdded = 0
        var authors: [UUID: Author] = [:]
        var leftBars: [Bar] = [], rightBars: [Bar] = []
        var tags: [UInt64: UUID] = [:], tagOf: [UUID: UInt64] = [:]
        func bar(_ edit: UUID, row: Int, into bars: inout [Bar]) {
            if authors[edit] == nil {
                authors[edit] = authorOf(edit)
                let tag = UInt64(tagOf.count + 1)
                tagOf[edit] = tag
                tags[tag] = edit
            }
            if let last = bars.last, last.edit == edit, last.rows.upperBound == row {
                bars[bars.count - 1].rows = last.rows.lowerBound..<(row + 1)
            } else {
                bars.append(Bar(rows: row..<(row + 1), author: authors[edit]!, edit: edit, tag: tagOf[edit]!))
            }
        }
        /// The shorter side of a replaced block is padded after its last row so the block's top edges line up.
        func flush() {
            if pendingRemoved > pendingAdded {
                model.rightFillers.append(Filler(beforeRow: right, count: pendingRemoved - pendingAdded))
            } else if pendingAdded > pendingRemoved {
                model.leftFillers.append(Filler(beforeRow: left, count: pendingAdded - pendingRemoved))
            }
            pendingRemoved = 0; pendingAdded = 0
        }
        func terminator(_ index: Int) -> String {
            guard let terminators else { return lineEnding }
            switch index < terminators.count ? terminators[index] : lineEnding.utf8.count {
            case 0: return ""
            case 2: return "\r\n"
            default: return "\n"
            }
        }
        for (index, line) in lines.enumerated() {
            switch line {
            case .context(let text, _):
                flush()
                old += text + terminator(index)
                left += 1; right += 1
            case .removed(let text, let edit):
                old += text + terminator(index)
                bar(edit, row: left, into: &leftBars)
                left += 1; pendingRemoved += 1
            case .added(_, _, let edit, _):
                bar(edit, row: right, into: &rightBars)
                right += 1; pendingAdded += 1
            }
        }
        // The count of an unflushed block is measured against the rows after it.
        flush()
        model.oldText = old
        model.leftBars = leftBars; model.rightBars = rightBars
        model.tags = tags; model.tagOf = tagOf
        model.leftRowCount = left
        model.rightRowCount = right
        return model
    }
}

extension FileLedger {
    /// The 1-based line of the current text where `edit` first shows: its first added line, or for a pure deletion
    /// the line the removed text stood in front of. Nil when the edit changed nothing visible.
    public func firstLine(of edit: UUID) -> Int? {
        var row = 0
        for (line, _) in diffEntries() {
            switch line {
            case .context: row += 1
            case .added(_, _, let e, _):
                if e == edit { return row + 1 }
                row += 1
            case .removed(_, let e):
                if e == edit { return row + 1 }
            }
        }
        return nil
    }

    /// The 1-based line the edit's first hunk changed, as recorded when the edit was made. Later edits may have
    /// shifted it; it is only a place to scroll to, used for edits that are no longer live (the diff no longer
    /// shows them).
    public func recordedLine(of edit: UUID) -> Int? {
        guard let hunk = edits.first(where: { $0.id == edit })?.hunks.first else { return nil }
        var line = hunk.newStart
        for text in hunk.lines {
            if text.hasPrefix("+") || text.hasPrefix("-") { return max(1, line) }
            line += 1
        }
        return nil
    }
}
