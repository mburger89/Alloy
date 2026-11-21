import Foundation

/// A deletion the ledger recorded, shown by the Table in the row-number column.
/// `beforeFileRow` is the file row just after the gap (nil: after the last row).
public struct CSVDeletionMarker: Equatable, Sendable {
    public var beforeFileRow: Int?
    public var removedRows: [String]
    public var edit: UUID

    public init(beforeFileRow: Int?, removedRows: [String], edit: UUID) {
        self.beforeFileRow = beforeFileRow; self.removedRows = removedRows; self.edit = edit
    }

    /// The hover text: the first five removed rows, then "and N more".
    public var help: String {
        let shown = removedRows.prefix(5).joined(separator: "\n")
        let more = removedRows.count - 5
        return more > 0 ? shown + "\nand \(more) more" : shown
    }
}

/// What the ledger knows about one file, in the coordinates of the text the ledger holds (the saved text). It is cheap
/// to keep (spans and a few small arrays, no file text) and is rebuilt once per ledger version. `CSVOwnership` maps it
/// to the current buffer.
public struct CSVOwnershipSource: Sendable {
    public struct Span: Equatable, Sendable {
        public var range: Range<Int>
        public var edit: UUID
        public init(range: Range<Int>, edit: UUID) { self.range = range; self.edit = edit }
    }
    public struct Point: Equatable, Sendable {
        public var offset: Int
        public var edit: UUID
        public init(offset: Int, edit: UUID) { self.offset = offset; self.edit = edit }
    }
    /// Whole rows a session removed, at `offset` (where the first removed row stood).
    public struct Removal: Equatable, Sendable {
        public var offset: Int
        public var rows: [String]
        public var edit: UUID
        public init(offset: Int, rows: [String], edit: UUID) { self.offset = offset; self.rows = rows; self.edit = edit }
    }

    public var spans: [Span]
    public var points: [Point]
    public var removals: [Removal]
    /// Live edits that removed a column from the header row.
    public var headerRemovals: Set<UUID>
    /// Live edits by id: their author.
    public var authors: [UUID: Author]
    /// Live edits by id: record sequence, so "latest" is decided by order and never by date.
    public var order: [UUID: Int]
    public var byteCount: Int

    public init(spans: [Span] = [], points: [Point] = [], removals: [Removal] = [], headerRemovals: Set<UUID> = [],
                authors: [UUID: Author] = [:], order: [UUID: Int] = [:], byteCount: Int = 0) {
        self.spans = spans; self.points = points; self.removals = removals; self.headerRemovals = headerRemovals
        self.authors = authors; self.order = order; self.byteCount = byteCount
    }

    public static let empty = CSVOwnershipSource()

    /// Reads the ledger once: `runs()` for who wrote which bytes, `deletionPoints()` for where text was removed and
    /// `diffEntries()` for the removed rows.
    public init(ledger: FileLedger, dialect: CSVDialect) {
        var spans: [Span] = []
        var offset = 0
        for run in ledger.runs() {
            let n = run.text.utf8.count
            if let e = run.edit, n > 0 {
                if let last = spans.last, last.edit == e, last.range.upperBound == offset {
                    spans[spans.count - 1].range = last.range.lowerBound..<(offset + n)
                } else {
                    spans.append(Span(range: offset..<(offset + n), edit: e))
                }
            }
            offset += n
        }
        var authors: [UUID: Author] = [:], order: [UUID: Int] = [:]
        for rec in ledger.edits where rec.state == .live {
            authors[rec.id] = rec.author
            order[rec.id] = ledger.sequence(of: rec.id) ?? 0
        }
        var removals: [Removal] = []
        var headerRemovals: Set<UUID> = []
        let entries = ledger.diffEntries()
        var position = 0, lines = 0, i = 0
        func fieldCount(_ text: String) -> Int { CSVParser.parseRow(Array(text.utf8), dialect: dialect).fields.count }
        while i < entries.count {
            guard case .removed = entries[i].line else {
                position += Self.length(of: entries[i]); lines += 1; i += 1
                continue
            }
            var j = i
            var groups: [(edit: UUID, rows: [String])] = []
            while j < entries.count, case .removed(let text, let edit) = entries[j].line {
                if groups.last?.edit == edit { groups[groups.count - 1].rows.append(text) } else { groups.append((edit, [text])) }
                j += 1
            }
            if j < entries.count, case .added(let added, _, let edit, _) = entries[j].line {
                // Replaced, not removed: the changed cells carry the tint. A header that lost fields lost columns.
                if lines == 0, case .removed(let old, _) = entries[i].line, fieldCount(old) > fieldCount(added) {
                    headerRemovals.insert(edit)
                }
            } else {
                var at = position
                for g in groups { removals.append(Removal(offset: at, rows: g.rows, edit: g.edit)); at = position }
            }
            i = j
        }
        self.init(spans: spans, points: ledger.deletionPoints().map { Point(offset: $0.offset, edit: $0.edit) },
                  removals: removals, headerRemovals: headerRemovals, authors: authors, order: order, byteCount: offset)
    }

    private static func length(of entry: (line: DiffLine, terminator: Int)) -> Int {
        switch entry.line {
        case .context(let text, _), .added(let text, _, _, _): text.utf8.count + entry.terminator
        case .removed: 0
        }
    }
}

/// Who last changed a byte range of the current buffer. Built once per (ledger version, buffer version) pair from a
/// `CSVOwnershipSource`; each lookup is a binary search.
public struct CSVOwnership: Sendable {
    public private(set) var spans: [CSVOwnershipSource.Span]
    public private(set) var points: [CSVOwnershipSource.Point]
    public private(set) var removals: [CSVOwnershipSource.Removal]
    public let headerRemovals: Set<UUID>
    private let authors: [UUID: Author]
    private let order: [UUID: Int]

    public static let empty = CSVOwnership(source: .empty, map: { o, _ in o }, byteCount: 0)

    /// `map(offset, isEnd)` carries a saved-text offset to the current buffer (`isEnd` is true for a span's upper end,
    /// so an insertion at the end stays outside the span). When it returns nil (the buffer no longer remembers that
    /// version) the offset is clamped into the buffer, so a span survives roughly where it was. Mapped spans are kept
    /// ordered and disjoint.
    public init(source: CSVOwnershipSource, map: (Int, Bool) -> Int?, byteCount: Int) {
        func place(_ o: Int, _ isEnd: Bool) -> Int { max(0, min(byteCount, map(o, isEnd) ?? o)) }
        var spans: [CSVOwnershipSource.Span] = []
        spans.reserveCapacity(source.spans.count)
        var floor = 0
        for s in source.spans {
            let lo = max(floor, place(s.range.lowerBound, false)), hi = place(s.range.upperBound, true)
            guard hi > lo else { continue }
            if let last = spans.last, last.edit == s.edit, last.range.upperBound == lo {
                spans[spans.count - 1].range = last.range.lowerBound..<hi
            } else {
                spans.append(.init(range: lo..<hi, edit: s.edit))
            }
            floor = hi
        }
        self.spans = spans
        var points: [CSVOwnershipSource.Point] = []
        points.reserveCapacity(source.points.count)
        var pfloor = 0
        for p in source.points {
            let o = max(pfloor, place(p.offset, false))
            points.append(.init(offset: o, edit: p.edit))
            pfloor = o
        }
        self.points = points
        removals = source.removals.map { .init(offset: place($0.offset, false), rows: $0.rows, edit: $0.edit) }
        headerRemovals = source.headerRemovals
        authors = source.authors
        order = source.order
    }

    /// The latest live edit that wrote bytes in `range`, or removed text inside it. An empty range (an empty field)
    /// counts as changed when a deletion touches either end; a non-empty one when a deletion falls strictly inside.
    public func owner(of range: Range<Int>) -> UUID? {
        var best: UUID?
        var bestOrder = Int.min
        func consider(_ e: UUID) {
            let o = order[e] ?? 0
            if o > bestOrder { best = e; bestOrder = o }
        }
        if !range.isEmpty {
            var lo = 0, hi = spans.count   // first span ending after range.lowerBound
            while lo < hi {
                let mid = (lo + hi) / 2
                if spans[mid].range.upperBound > range.lowerBound { hi = mid } else { lo = mid + 1 }
            }
            var i = lo
            while i < spans.count, spans[i].range.lowerBound < range.upperBound { consider(spans[i].edit); i += 1 }
        }
        var lo = 0, hi = points.count   // first point at or after range.lowerBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].offset >= range.lowerBound { hi = mid } else { lo = mid + 1 }
        }
        var i = lo
        while i < points.count, points[i].offset <= range.upperBound {
            let p = points[i].offset
            if range.isEmpty || (p > range.lowerBound && p < range.upperBound) { consider(points[i].edit) }
            i += 1
        }
        return best
    }

    /// The author of the change in `range` when it is a session's or an outside one's; nil for your own edits, kept
    /// text and unchanged bytes.
    public func tint(of range: Range<Int>) -> Author? {
        guard let e = owner(of: range), let a = authors[e] else { return nil }
        switch a {
        case .session, .outside: return a
        case .user: return nil
        }
    }

    public func author(of edit: UUID) -> Author? { authors[edit] }
}
