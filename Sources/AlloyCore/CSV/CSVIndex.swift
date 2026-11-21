import MetalUICodeBuffer

/// Row start offsets (UTF-8 bytes) of one CSV or TSV document, plus the rows a lenient fallback parsed.
/// Rows may span lines; a row's terminator belongs to the row. A leading UTF-8 BOM is skipped and kept.
/// A trailing terminator does not create an extra empty row; an empty or BOM-only file has no rows.
public struct CSVIndex: Equatable, Sendable {
    public private(set) var rowStarts: [UInt32]
    /// Sorted row numbers of rows parsed by a fallback.
    public private(set) var flaggedRows: [UInt32]
    public private(set) var bomLength: Int
    public private(set) var byteCount: Int
    public private(set) var dialect: CSVDialect

    /// How far an incremental update rescans before giving up and asking for a full rebuild.
    static let maxResyncRows = 4096
    static let maxResyncBytes = 4 << 20
    static let progressInterval = 4096
    static let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]
    /// The lookahead every scan uses. Build and incremental update must agree.
    static let lookahead = CSVLookahead()

    public var rowCount: Int { rowStarts.count }

    /// Bytes held by the index arrays.
    var retainedBytes: Int { (rowStarts.capacity + flaggedRows.capacity) * 4 }

    public init(dialect: CSVDialect = .comma) {
        rowStarts = []; flaggedRows = []; bomLength = 0; byteCount = 0
        self.dialect = dialect
    }

    /// Releases the doubling slack growth leaves in the arrays; the model calls it once after a full build.
    mutating func trimCapacity() {
        var starts: [UInt32] = []
        starts.reserveCapacity(rowStarts.count)
        starts.append(contentsOf: rowStarts)
        rowStarts = starts
    }

    /// The byte range of a row, terminator included.
    public func rowRange(_ row: Int) -> Range<Int> {
        let start = Int(rowStarts[row])
        let end = row + 1 < rowStarts.count ? Int(rowStarts[row + 1]) : byteCount
        return start..<end
    }

    /// The row holding `offset`; clamps to the first and last row. Returns 0 for an index with no rows.
    public func row(containing offset: Int) -> Int {
        guard !rowStarts.isEmpty else { return 0 }
        var lo = 0, hi = rowStarts.count   // first row whose start is greater than offset
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(rowStarts[mid]) > offset { hi = mid } else { lo = mid + 1 }
        }
        return max(0, lo - 1)
    }

    public func isFlagged(_ row: Int) -> Bool {
        var lo = 0, hi = flaggedRows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if Int(flaggedRows[mid]) < row { lo = mid + 1 } else { hi = mid }
        }
        return lo < flaggedRows.count && Int(flaggedRows[lo]) == row
    }

    static func bomLength(of source: some CSVBytes) -> Int {
        source.utf8Count >= 3 && source.utf8(in: 0..<3) == bomBytes ? 3 : 0
    }

    /// Builds the index synchronously (the model calls this off the main thread). `progress` receives a partial
    /// index (rows so far, `byteCount` already final) every 4096 rows.
    public static func build(_ source: some CSVBytes, dialect: CSVDialect,
                             progress: ((CSVIndex) -> Void)? = nil) -> CSVIndex {
        var index = CSVIndex(dialect: dialect)
        index.byteCount = source.utf8Count
        index.bomLength = bomLength(of: source)
        var reader = CSVChunkReader(source)
        var pos = index.bomLength
        while pos < index.byteCount {
            if index.rowStarts.count % progressInterval == 0, !index.rowStarts.isEmpty { progress?(index) }
            let r = CSVParser.scanRow(&reader, start: pos, dialect: dialect, lookahead: lookahead, collect: false)
            if r.parse.flagged { index.flaggedRows.append(UInt32(index.rowStarts.count)) }
            index.rowStarts.append(UInt32(pos))
            pos = r.end
        }
        return index
    }

    /// Applies one buffer edit (in pre-edit coordinates) given the text after it. False means nothing changed
    /// and the caller must rebuild from scratch.
    public mutating func apply(_ edit: CodeEdit, newSource: some CSVBytes) -> Bool {
        applyEdit(edit, newSource: newSource) != nil
    }

    /// Like `apply`, and reports which rows the edit replaced: rows `first..<first + removed` of the old index became
    /// `inserted` rows. Nil means the caller must rebuild.
    public mutating func applyEdit(_ edit: CodeEdit, newSource: some CSVBytes) -> CSVRowSplice? {
        let range = edit.range
        let newLen = edit.newText.utf8.count
        let delta = newLen - range.count
        let newCount = byteCount + delta
        guard range.upperBound <= byteCount, newSource.utf8Count == newCount else { return nil }
        // Edits near the start can create or destroy the BOM.
        guard range.lowerBound >= 3, range.lowerBound >= bomLength else { return nil }

        // First row to rescan: the row holding the byte before the edit (a terminator or a closing quote there
        // may change), or earlier when a fallback row's lookahead window reaches the edit.
        var first = 0
        var scanStart = bomLength
        if !rowStarts.isEmpty {
            first = row(containing: max(range.lowerBound - 1, bomLength))
            let reach = range.lowerBound - Self.lookahead.maxBytes
            var lo = 0, hi = flaggedRows.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if Int(rowStarts[Int(flaggedRows[mid])]) > reach { hi = mid } else { lo = mid + 1 }
            }
            if lo < flaggedRows.count, Int(flaggedRows[lo]) < first { first = Int(flaggedRows[lo]) }
            scanStart = Int(rowStarts[first])
        }

        var reader = CSVChunkReader(newSource)
        var newStarts: [UInt32] = []
        var newFlags: [UInt32] = []
        var pos = scanStart
        var oldIdx = first
        var tailStart = rowStarts.count
        while pos < newCount {
            if !newStarts.isEmpty {
                // Resync: a new row boundary past the edit that is also an old boundary.
                let oldPos = pos - delta
                if oldPos >= range.upperBound {
                    while oldIdx < rowStarts.count, Int(rowStarts[oldIdx]) < oldPos { oldIdx += 1 }
                    if oldIdx < rowStarts.count, Int(rowStarts[oldIdx]) == oldPos { tailStart = oldIdx; break }
                }
                if newStarts.count >= Self.maxResyncRows || pos - scanStart >= Self.maxResyncBytes { return nil }
            }
            let r = CSVParser.scanRow(&reader, start: pos, dialect: dialect, lookahead: Self.lookahead, collect: false)
            if r.parse.flagged { newFlags.append(UInt32(first + newStarts.count)) }
            newStarts.append(UInt32(pos))
            pos = r.end
        }

        let rowShift = first + newStarts.count - tailStart
        var starts = Array(rowStarts[0..<first])
        starts.reserveCapacity(first + newStarts.count + rowStarts.count - tailStart)
        starts += newStarts
        for i in tailStart..<rowStarts.count { starts.append(UInt32(Int(rowStarts[i]) + delta)) }
        var flags = flaggedRows.filter { Int($0) < first }
        flags += newFlags
        for f in flaggedRows where Int(f) >= tailStart { flags.append(UInt32(Int(f) + rowShift)) }
        rowStarts = starts
        flaggedRows = flags
        byteCount = newCount
        return CSVRowSplice(first: first, removed: tailStart - first, inserted: newStarts.count)
    }
}

/// Rows `first..<first + removed` of the old index became `inserted` rows.
public struct CSVRowSplice: Equatable, Sendable {
    public var first: Int
    public var removed: Int
    public var inserted: Int
}
