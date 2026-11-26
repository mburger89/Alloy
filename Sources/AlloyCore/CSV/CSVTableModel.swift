import Foundation
import MetalUICodeBuffer
import Observation

/// One row as the table shows it. `values` are display forms (first line, return glyph when multi-line).
public struct CSVRowCells: Equatable, Sendable {
    public var fileRow: Int
    public var values: [String]
    public var flagged: Bool
    public var byteRange: Range<Int>
    /// Each field's byte range in the buffer the index describes (quotes included).
    public var fieldRanges: [Range<Int>] = []
}

/// The tint of a changed cell, UI-free: a session's colour slot, or an outside change.
public enum CSVTint: Hashable, Sendable {
    case session(Int)
    case outside
    /// What the user typed since the last save (only with the "Tint my own edits" setting on).
    case own
}

/// Per-document CSV state: the row index, a bounded window cache of parsed rows, the header toggle and the
/// change feed. The file is never copied: rows are parsed on demand from the snapshot the index was built for.
@MainActor @Observable
public final class CSVTableModel {
    /// The only observed property: bumped when the index, the header flag or the window content changes.
    public private(set) var revision = 0
    /// Observed apart from `revision`: a selection change redraws the table without re-deriving titles and widths.
    public private(set) var selectionRevision = 0

    @ObservationIgnored public let document: EditorDocument
    @ObservationIgnored public var hasHeader: Bool = true {
        didSet {
            guard hasHeader != oldValue else { return }
            dropSort()
            derivedRevision = -1
            changedCache = nil; changedCellsCache = nil
            bump()
        }
    }
    @ObservationIgnored public private(set) var isBuilding = false
    @ObservationIgnored public private(set) var columnCount = 0

    @ObservationIgnored private var index: CSVIndex
    /// The text the index describes. A rope snapshot, so holding it is not a copy of the file.
    @ObservationIgnored private var indexSnapshot: CodeSnapshot
    @ObservationIgnored private var cursor: CodeEditCursor?
    @ObservationIgnored private var cache: [Int: CSVRowCells] = [:]
    @ObservationIgnored private var lastRequested = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var round = 0
    @ObservationIgnored private var installed = false
    @ObservationIgnored private var dirtyDuringBuild = false
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var titlesCache: [String] = []
    @ObservationIgnored private var widthsCache: [Double] = []
    @ObservationIgnored private var derivedRevision = -1

    // Ownership (who changed what): the ledger's view in saved-text offsets, and its mapping to the current buffer.
    /// Where the model finds the file's ledger and the sessions (for their colour slots). Set by the owner of the model.
    @ObservationIgnored public var ledgerProvider: () -> (FileLedger?, [Session]) = { (nil, []) }
    @ObservationIgnored private var ownership = CSVOwnership.empty
    @ObservationIgnored private var ownershipSource = CSVOwnershipSource.empty
    @ObservationIgnored private var sourceLedgerVersion = -2
    @ObservationIgnored private var sourceSavedVersion: UInt64 = 0
    @ObservationIgnored private var colorSlots: [UUID: Int] = [:]
    @ObservationIgnored private var ownershipKey: (ledger: Int, buffer: UInt64)?
    @ObservationIgnored private var ownershipTask: Task<Void, Never>?
    @ObservationIgnored private var markers: [Int: CSVDeletionMarker] = [:]
    @ObservationIgnored private var trailingMarker: CSVDeletionMarker?
    @ObservationIgnored private var headerRemovedColumns = false
    /// How many times the ownership was mapped to a buffer (tests read it): once per (ledger version, buffer version).
    @ObservationIgnored public private(set) var ownershipBuilds = 0

    // The user's own unsaved edits (the "Tint my own edits" setting): byte spans of the buffer that differ from the saved
    // text, found off the main actor once per (saved version, buffer version) while the setting is on.
    /// Set by the owner of the model from the setting. Off: no spans, no work.
    @ObservationIgnored public var ownTintEnabled = false {
        didSet {
            guard ownTintEnabled != oldValue else { return }
            ownKey = nil
            if ownTintEnabled {
                refreshOwnTint()
            } else {
                ownGeneration += 1; ownTask?.cancel()
                if !ownSpans.isEmpty { ownSpans = []; bump() }
            }
        }
    }
    @ObservationIgnored private var ownSpans: [Range<Int>] = []
    @ObservationIgnored private var ownKey: (saved: UInt64, buffer: UInt64)?
    @ObservationIgnored private var ownGeneration = 0
    @ObservationIgnored private var ownTask: Task<Void, Never>?
    /// How many own-edit diffs were started (tests read it).
    @ObservationIgnored public private(set) var ownDiffs = 0

    // Selection, change navigation and reveal. Rows are file ordinals; the header row is never selectable.
    @ObservationIgnored public private(set) var selectedRows: Set<Int> = []
    @ObservationIgnored private var changedCache: (key: ChangedKey, rows: [Int])?
    @ObservationIgnored private var changedCellsCache: (key: ChangedKey, cells: [ActiveCell])?
    @ObservationIgnored private var changeDescriptions: [UUID: String] = [:]
    @ObservationIgnored private var pendingReveal: (offset: Int, column: Int?)?
    @ObservationIgnored private var pendingScroll: ActiveCell?
    /// Set by the panel: scrolls the table so a file row is in view (`ScrollViewReader.scrollTo(rowID)`).
    @ObservationIgnored public var scroller: ((ActiveCell) -> Void)?

    private struct ChangedKey: Equatable { var ledger: Int; var saved: UInt64; var buffer: UInt64; var header: Bool; var rows: Int }

    // View-only sort: the display permutation, frozen until the next header click.
    @ObservationIgnored public private(set) var sort: CSVSortOrder?
    /// The last requested order; the sort lands (and `sort` changes) when its background pass finishes.
    @ObservationIgnored private var sortRequest: (column: Int, ascending: Bool)?
    @ObservationIgnored private var sortGeneration = 0
    @ObservationIgnored private var sortTask: Task<Void, Never>?
    @ObservationIgnored private var inverseCache: (revision: Int, inverse: [UInt32])?

    static let cacheLimit = 512
    static let cacheTrimTarget = 448
    nonisolated static let sampleRows = 200
    static let minWidth = 60.0, maxWidth = 320.0
    /// Points per character and the cell padding; text layout is not consulted.
    static let charWidth = 7.5, cellPadding = 16.0

    public init(document: EditorDocument) {
        self.document = document
        indexSnapshot = document.buffer.snapshot()
        index = CSVIndex(dialect: document.language == "tsv" ? .tab : .comma)
        startBuild()
    }

    /// The text and delimiter the index describes (the cell edit pipeline reads one field from them).
    var cellEditSnapshot: CodeSnapshot { indexSnapshot }
    var cellEditDelimiter: UInt8 { index.dialect.delimiter }

    // MARK: Rows

    private var headerOffset: Int { hasHeader ? 1 : 0 }

    /// Rows whose extent is known. During the first build the last scanned row has no known end yet.
    private var usableRows: Int { isBuilding && !installed ? max(0, index.rowCount - 1) : index.rowCount }

    public var rowCount: Int { max(0, usableRows - headerOffset) }

    public func fileRow(forDataRow i: Int) -> Int { i + headerOffset }

    public func dataRow(forFileRow r: Int) -> Int? {
        let d = r - headerOffset
        return d >= 0 && r < usableRows ? d : nil
    }

    public var readOnlyReason: String? {
        if case .readOnly(let reason) = document.state { return reason }
        return nil
    }

    // MARK: Cells

    public func cells(forDataRow i: Int) -> CSVRowCells {
        let fr = fileRow(forDataRow: i)
        guard i >= 0, fr < usableRows else {
            return CSVRowCells(fileRow: fr, values: padded([]), flagged: false, byteRange: 0..<0)
        }
        lastRequested = fr
        if let hit = cache[fr] { return padded(hit) }
        let row = parse(fileRow: fr)
        if cache.count >= Self.cacheLimit { trimCache() }
        cache[fr] = row
        columnCount = max(columnCount, row.values.count)
        return padded(row)
    }

    private func padded(_ row: CSVRowCells) -> CSVRowCells {
        guard row.values.count < columnCount else { return row }
        var r = row
        r.values = padded(row.values)
        return r
    }

    private func padded(_ values: [String]) -> [String] {
        values.count < columnCount ? values + Array(repeating: "", count: columnCount - values.count) : values
    }

    private func parse(fileRow fr: Int) -> CSVRowCells {
        let range = index.rowRange(fr)
        let bytes = indexSnapshot.utf8(in: range)
        let p = CSVParser.parseRow(bytes, dialect: index.dialect)
        let values = zip(p.fields, p.quoted).map { CSVParser.displayValue(of: bytes[$0], quoted: $1) }
        let fields = p.fields.map { (range.lowerBound + $0.lowerBound)..<(range.lowerBound + $0.upperBound) }
        return CSVRowCells(fileRow: fr, values: values, flagged: p.flagged || index.isFlagged(fr), byteRange: range,
                           fieldRanges: fields)
    }

    private func trimCache() {
        let keep = cache.keys.sorted { abs($0 - lastRequested) < abs($1 - lastRequested) }.prefix(Self.cacheTrimTarget)
        let kept = Set(keep)
        cache = cache.filter { kept.contains($0.key) }
    }

    // MARK: Header and widths

    public func headerTitles() -> [String] {
        refreshDerived()
        return titlesCache
    }

    public func columnWidths() -> [Double] {
        refreshDerived()
        return widthsCache
    }

    private func refreshDerived() {
        guard derivedRevision != revision else { return }
        derivedRevision = revision
        var header: [String]?
        if hasHeader, usableRows > 0 { header = parse(fileRow: 0).values }
        var sample: [[String]] = []
        let first = headerOffset
        let last = min(usableRows, first + Self.sampleRows)
        if first < last { for r in first..<last { sample.append(parse(fileRow: r).values) } }
        var widest = columnCount
        if let h = header { widest = max(widest, h.count) }
        for s in sample { widest = max(widest, s.count) }
        columnCount = widest
        titlesCache = header.map(padded) ?? (0..<columnCount).map(Self.letters)
        var chars = [Int](repeating: 0, count: columnCount)
        for (c, t) in titlesCache.enumerated() { chars[c] = t.count }
        for s in sample { for (c, v) in s.enumerated() { chars[c] = max(chars[c], v.count) } }
        widthsCache = chars.map { min(Self.maxWidth, max(Self.minWidth, Double($0) * Self.charWidth + Self.cellPadding)) }
    }

    /// A, B, ... Z, AA, AB, ...
    static func letters(_ n: Int) -> String {
        var n = n, s = ""
        repeat {
            s = String(UnicodeScalar(UInt8(65 + n % 26))) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    // MARK: Change feed

    /// Drains the edit cursor into the index. Called by whoever observes `buffer.version`.
    public func sync() {
        guard let cursor else { return }
        let batch = cursor.drain()
        if isBuilding {
            // The running build covers an older text; it restarts when it lands.
            switch batch {
            case .edits(let e) where e.isEmpty: break
            default: dirtyDuringBuild = true
            }
            return
        }
        switch batch {
        case .resync:
            startBuild()
        case .edits(let edits):
            guard !edits.isEmpty else { return }
            // Several edits cannot be applied one by one (only the final text is at hand): rebuild.
            guard edits.count == 1, let edit = edits.first else { startBuild(); return }
            let after = document.buffer.snapshot()
            let oldIndex = index
            var next = index
            guard let splice = next.applyEdit(edit, newSource: after) else { startBuild(); return }
            invalidate(for: edit, in: oldIndex)
            sort?.apply(first: splice.first, removed: splice.removed, inserted: splice.inserted)
            index = next
            indexSnapshot = after
            reconcileSort()
            if document.savedVersion != sourceSavedVersion, sourceLedgerVersion != -2 { ledgerChanged() }
            refreshOwnership()
            bump()
        }
    }

    /// Drops cached rows an edit can reach: the edit's row and everything after it, and fallback rows whose
    /// lookahead window covers the edit.
    private func invalidate(for edit: CodeEdit, in old: CSVIndex) {
        let editRow = old.rowCount == 0 ? 0 : old.row(containing: max(edit.range.lowerBound - 1, old.bomLength))
        let reach = edit.range.lowerBound - CSVIndex.lookahead.maxBytes
        cache = cache.filter { key, row in
            guard key < editRow else { return false }
            return !(row.flagged && row.byteRange.lowerBound >= reach)
        }
    }

    /// Redraws the cells (the own-edit colour changed).
    public func redraw() { bump() }

    private func bump() {
        revision &+= 1
        pruneSelection()
        pruneActiveCell()
    }

    // MARK: Build

    private struct BuildResult: Sendable {
        var index: CSVIndex
        var columns: Int
    }

    private func startBuild() {
        buildTask?.cancel()
        generation += 1
        let gen = generation
        isBuilding = true
        buildTask = Task { [weak self] in await self?.runBuild(gen) }
    }

    private func runBuild(_ gen: Int) async {
        while true {
            // Snapshot and cursor are taken in the same main-actor turn, so they describe the same version.
            let snap = document.buffer.snapshot()
            cursor = document.buffer.makeEditCursor()
            dirtyDuringBuild = false
            round += 1
            let thisRound = round
            let language = document.language
            let progress: @Sendable (CSVIndex) -> Void = { [weak self] partial in
                Task { @MainActor in self?.partial(partial, snap, gen, thisRound) }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Self.buildAll(snap, language: language, progress: progress)
            }.value
            guard gen == generation else { return }
            round += 1   // late partial results are ignored
            index = result.index
            indexSnapshot = snap
            columnCount = result.columns
            cache.removeAll(keepingCapacity: true)
            installed = true
            reconcileSort()
            ownershipKey = nil
            refreshOwnership()
            bump()
            if document.buffer.version == snap.version && !dirtyDuringBuild { break }
        }
        isBuilding = false
        bump()   // the "building" label is read through `revision`
        if let p = pendingReveal { pendingReveal = nil; applyReveal(p.offset, column: p.column) }
    }

    private func partial(_ partial: CSVIndex, _ snap: CodeSnapshot, _ gen: Int, _ thisRound: Int) {
        guard gen == generation, thisRound == round, !installed else { return }
        index = partial
        indexSnapshot = snap
        bump()
    }

    nonisolated private static func buildAll(_ snap: CodeSnapshot, language: String?,
                                             progress: @escaping @Sendable (CSVIndex) -> Void) -> BuildResult {
        let bom = CSVIndex.bomLength(of: snap)
        let firstEnd = snap.utf8Count > bom ? CSVRowScanner.nextRow(in: snap, from: bom, dialect: .comma).end : bom
        let firstRow = snap.utf8(in: 0..<min(firstEnd, snap.utf8Count))
        let dialect = CSVDialect.detect(language: language, firstRow: firstRow)
        var built = CSVIndex.build(snap, dialect: dialect, progress: progress)
        built.trimCapacity()
        var widest = 0
        for r in 0..<min(built.rowCount, sampleRows + 1) {
            let range = built.rowRange(r)
            widest = max(widest, CSVParser.parseRow(snap.utf8(in: range), dialect: dialect).fields.count)
        }
        return BuildResult(index: built, columns: widest)
    }

    /// Resolves when no build is running or queued. A test hook.
    public func buildFinished() async {
        while let task = buildTask, isBuilding {
            await task.value
            if buildTask == nil { return }
        }
    }

    public func close() {
        generation += 1
        buildTask?.cancel()
        buildTask = nil
        cursor = nil
        isBuilding = false
        cache.removeAll()
        ownershipTask?.cancel()
        ownershipTask = nil
        ownTask?.cancel()
        ownTask = nil
        sortTask?.cancel()
        sortTask = nil
    }

    // MARK: Sort

    /// The comparator list the table's `sortOrder` binding reads: the requested order, or none in file order.
    public var sortComparators: [CSVColumnComparator] {
        guard let r = sortRequest else { return [] }
        return [CSVColumnComparator(column: r.column, order: r.ascending ? .forward : .reverse)]
    }

    /// True once the text changed after the order was computed (the order is frozen, not re-sorted).
    public var sortIsStale: Bool { sort.map { $0.sortedAtVersion != indexSnapshot.version } ?? false }

    /// The file ordinal shown at a display position (identity plus the header offset when unsorted).
    public func displayRow(at position: Int) -> Int {
        if let p = sort?.permutation, position >= 0, position < p.count { return Int(p[position]) }
        return position + headerOffset
    }

    /// The display position of a file ordinal, or nil for the header row and rows that do not exist.
    public func displayPosition(ofFileRow row: Int) -> Int? {
        guard let sort else { return row >= headerOffset && row - headerOffset < rowCount ? row - headerOffset : nil }
        let i = row - sort.firstOrdinal
        guard i >= 0 else { return nil }
        if i >= sort.permutation.count { return i < rowCount + 1 ? i : nil }   // the end-of-file marker row
        if inverseCache?.revision != revision { inverseCache = (revision, sort.inverse()) }
        guard let position = inverseCache?.inverse[i] else { return nil }
        return Int(position)
    }

    /// Sorts the displayed rows by a column's values off the main actor and publishes the permutation once.
    /// The file is never touched.
    public func sort(column: Int, ascending: Bool) {
        guard installed else { return }
        sortRequest = (column, ascending)
        sortTask?.cancel()
        sortGeneration += 1
        let gen = sortGeneration
        sortTask = Task { [weak self] in await self?.runSort(gen) }
    }

    /// Back to file order.
    public func clearSort() {
        guard sortRequest != nil || sort != nil else { return }
        dropSort()
        bump()
    }

    private func dropSort() {
        sortTask?.cancel()
        sortTask = nil
        sortGeneration += 1
        sortRequest = nil
        sort = nil
        inverseCache = nil
    }

    private func runSort(_ gen: Int) async {
        while true {
            guard gen == sortGeneration, let request = sortRequest else { return }
            let snap = indexSnapshot, idx = index, first = headerOffset
            let permutation = await Task.detached(priority: .userInitiated) {
                Self.sortedOrdinals(snap, idx, column: request.column, ascending: request.ascending, first: first)
            }.value
            guard gen == sortGeneration, !Task.isCancelled else { return }
            if snap.version != indexSnapshot.version { continue }   // the text moved on while sorting
            sort = CSVSortOrder(column: request.column, ascending: request.ascending, permutation: permutation,
                                firstOrdinal: first, sortedAtVersion: snap.version)
            inverseCache = nil
            bump()
            return
        }
    }

    nonisolated private static func sortedOrdinals(_ snap: CodeSnapshot, _ index: CSVIndex, column: Int,
                                                   ascending: Bool, first: Int) -> [UInt32] {
        let count = max(0, index.rowCount - first)
        let order = CSVSorter.sort(column: column, ascending: ascending, rowCount: count) { i in
            let range = index.rowRange(first + i)
            let bytes = snap.utf8(in: range)
            let p = CSVParser.parseRow(bytes, dialect: index.dialect)
            guard column < p.fields.count else { return "" }
            return CSVParser.displayValue(of: bytes[p.fields[column]], quoted: p.quoted[column])
        }
        return order.map { $0 + UInt32(first) }
    }

    /// After a rebuild or when counts drift: the order must cover exactly the current data rows.
    private func reconcileSort() {
        guard sort != nil else { return }
        if sort?.permutation.count != rowCount || sort?.firstOrdinal != headerOffset { sort?.resize(toRowCount: rowCount) }
        inverseCache = nil
    }

    // MARK: Ownership

    /// The tint of the cell at (`fileRow`, `column`): a session's colour slot or an outside change; nil for your own
    /// edits, kept text and unchanged cells.
    public func tint(forFileRow row: Int, column: Int) -> CSVTint? {
        if ownTintEnabled, !ownSpans.isEmpty, ownEdited(fileRow: row, column: column) { return .own }
        return ledgerTint(forFileRow: row, column: column)
    }

    /// The tint the ledger gives a cell (a session or an outside change), without the user's own unsaved edits.
    private func ledgerTint(forFileRow row: Int, column: Int) -> CSVTint? {
        guard let author = author(forFileRow: row, column: column) else { return nil }
        switch author {
        case .session(let id): return .session(colorSlots[id] ?? 0)
        case .outside: return .outside
        case .user: return nil
        }
    }

    /// Whether the cell's field intersects text the user changed since the last save. A deletion (an empty span) tints the
    /// field it was cut from.
    private func ownEdited(fileRow row: Int, column: Int) -> Bool {
        guard row >= 0, row < usableRows else { return false }
        let cells = cache[row] ?? parse(fileRow: row)
        guard column >= 0, column < cells.fieldRanges.count else { return false }
        let field = cells.fieldRanges[column]
        // The spans are ordered and disjoint: find the first that ends at or after the field's start.
        var lo = 0, hi = ownSpans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ownSpans[mid].upperBound >= field.lowerBound { hi = mid } else { lo = mid + 1 }
        }
        while lo < ownSpans.count, ownSpans[lo].lowerBound <= field.upperBound {
            let span = ownSpans[lo]
            if span.isEmpty || (span.upperBound > field.lowerBound && span.lowerBound < field.upperBound) { return true }
            lo += 1
        }
        return false
    }

    /// Looks at the saved text again (a save or a refresh moved it). A clean buffer clears the tint at once.
    public func savedTextChanged() { refreshOwnTint() }

    /// Diffs the saved text against the buffer text the index describes, off the main actor, once per (saved version,
    /// buffer version). Does nothing with the setting off, before the index is installed or above the size limit.
    private func refreshOwnTint() {
        guard ownTintEnabled, installed else { return }
        let key = (saved: document.savedVersion, buffer: indexSnapshot.version)
        if let k = ownKey, k == key { return }
        ownKey = key
        ownGeneration += 1
        ownTask?.cancel()
        let gen = ownGeneration
        let saved = document.savedSnapshot, snap = indexSnapshot
        if saved.version == snap.version || saved.utf8Count > OwnEdits.sizeLimit || snap.utf8Count > OwnEdits.sizeLimit {
            if !ownSpans.isEmpty { ownSpans = []; bump() }
            return
        }
        ownDiffs += 1
        ownTask = Task { [weak self] in
            let spans = await Task.detached(priority: .userInitiated) {
                OwnEdits.changedBytes(saved: saved.text, current: snap.text)
            }.value
            guard let self, gen == ownGeneration, !Task.isCancelled else { return }
            ownSpans = spans
            bump()
        }
    }

    /// Resolves when the last own-edit diff has landed. A test hook.
    public func ownTintSettled() async { await ownTask?.value }

    /// The author of the change in a cell when it is tinted.
    public func author(forFileRow row: Int, column: Int) -> Author? {
        guard row >= 0, row < usableRows, hasOwnership else { return nil }
        let cells = cache[row] ?? parse(fileRow: row)
        guard column >= 0, column < cells.fieldRanges.count else { return nil }
        return ownership.tint(of: cells.fieldRanges[column])
    }

    /// Who changed a tinted cell, in the ledger's words ("session <id>", "an outside change"); nil when it is not tinted.
    public func changeDescription(forFileRow row: Int, column: Int) -> String? {
        guard row >= 0, row < usableRows, hasOwnership else { return nil }
        let cells = cache[row] ?? parse(fileRow: row)
        guard column >= 0, column < cells.fieldRanges.count, ownership.tint(of: cells.fieldRanges[column]) != nil,
              let edit = ownership.owner(of: cells.fieldRanges[column]) else { return nil }
        return changeDescriptions[edit]
    }

    public func deletionMarker(beforeFileRow row: Int) -> CSVDeletionMarker? { markers[row] }

    /// The marker for rows removed at the very end of the file.
    public var endDeletionMarker: CSVDeletionMarker? { trailingMarker }

    /// True when a session removed a column from the header row.
    public var headerHasRemovedColumn: Bool { headerRemovedColumns }

    private var hasOwnership: Bool { !ownership.spans.isEmpty || !ownership.points.isEmpty }

    /// Reads the ledger and rebuilds the saved-text view of it off the main actor. Call when the file's ledger changes.
    public func ledgerChanged() {
        let (ledger, sessions) = ledgerProvider()
        let version = ledger?.version ?? -1
        // Any file's ledger change wakes the observer; only this file's version or save matters.
        if version == sourceLedgerVersion, document.savedVersion == sourceSavedVersion { return }
        colorSlots = Dictionary(sessions.map { ($0.id, $0.colorIndex) }, uniquingKeysWith: { a, _ in a })
        changeDescriptions = [:]
        if let ledger { for e in ledger.edits where e.state == .live { changeDescriptions[e.id] = ledger.authorDescription(of: e.id) } }
        changedCache = nil; changedCellsCache = nil
        ownershipTask?.cancel()
        guard let ledger, ledger.edits.contains(where: { $0.state == .live }) else {
            sourceLedgerVersion = version
            sourceSavedVersion = document.savedVersion
            ownershipSource = .empty
            ownershipKey = nil
            refreshOwnership()
            bump()
            return
        }
        let saved = document.savedVersion
        let dialect = index.dialect
        ownershipTask = Task { [weak self] in
            let source = await Task.detached(priority: .userInitiated) { CSVOwnershipSource(ledger: ledger, dialect: dialect) }.value
            guard let self, !Task.isCancelled else { return }
            ownershipSource = source
            sourceLedgerVersion = version
            sourceSavedVersion = saved
            ownershipKey = nil
            refreshOwnership()
            bump()
        }
    }

    /// Resolves when the ownership reflects the last `ledgerChanged()`. A test hook.
    public func ownershipSettled() async { await ownershipTask?.value }

    /// Maps the saved-text ownership to the current buffer, once per (ledger version, buffer version) pair, and places the
    /// deletion markers on rows. Never called from a body.
    private func refreshOwnership() {
        refreshOwnTint()
        let key = (ledger: sourceLedgerVersion, buffer: document.buffer.version)
        if let k = ownershipKey, k.ledger == key.ledger, k.buffer == key.buffer { return }
        ownershipKey = key
        ownershipBuilds += 1
        let source = ownershipSource
        guard !source.spans.isEmpty || !source.points.isEmpty || !source.removals.isEmpty || !source.headerRemovals.isEmpty else {
            ownership = .empty; markers = [:]; trailingMarker = nil; headerRemovedColumns = false
            return
        }
        let buffer = document.buffer, from = sourceSavedVersion
        ownership = CSVOwnership(source: source,
                                 map: { buffer.map($0, from: from, bias: $1 ? .before : .after) },
                                 byteCount: indexSnapshot.utf8Count)
        placeMarkers()
    }

    var headerOffsetValue: Int { headerOffset }
    var usableRowCount: Int { usableRows }
    var sourceLedgerVersionValue: Int { sourceLedgerVersion }
    func ownershipAuthor(_ edit: UUID) -> Author? { ownership.author(of: edit) }

    private func placeMarkers() {
        markers = [:]
        trailingMarker = nil
        headerRemovedColumns = !ownership.headerRemovals.isEmpty
        for r in ownership.removals {
            var row: Int? = nil
            if usableRows > 0, r.offset < indexSnapshot.utf8Count {
                var k = index.row(containing: r.offset)
                if index.rowRange(k).lowerBound < r.offset { k += 1 }
                k = max(k, headerOffset)
                if k < usableRows { row = k }
            }
            if let row {
                if var m = markers[row] { m.removedRows += r.rows; markers[row] = m }
                else { markers[row] = CSVDeletionMarker(beforeFileRow: row, removedRows: r.rows, edit: r.edit) }
            } else if var m = trailingMarker {
                m.removedRows += r.rows; trailingMarker = m
            } else {
                trailingMarker = CSVDeletionMarker(beforeFileRow: nil, removedRows: r.rows, edit: r.edit)
            }
        }
    }


    // MARK: Selection, changes and reveal

    /// The active cell of cell mode: a file row and a DATA column (never the `#` column). UI-free; the panel converts it
    /// to and from MetalUI's `TableCell` through `dataColumn(forTableColumn:)` and `tableColumn(forDataColumn:)`.
    public struct ActiveCell: Hashable, Sendable {
        public var row: Int
        public var column: Int
        public init(row: Int, column: Int) { self.row = row; self.column = column }
    }

    /// Declared columns before the first data column: the frozen `#` column.
    public static let leadingColumns = 1

    /// The ONE place that maps MetalUI's declared column index (static and `TableColumnForEach` columns alike) to the
    /// data column. The `#` column is declared first, so data column `c` is declared index `c + 1`. Nil for `#`.
    public func dataColumn(forTableColumn column: Int) -> Int? {
        let c = column - Self.leadingColumns
        return c >= 0 && c < max(columnCount, 1) ? c : nil
    }

    public func tableColumn(forDataColumn column: Int) -> Int { column + Self.leadingColumns }

    @ObservationIgnored public private(set) var activeCell: ActiveCell?
    /// The cell whose inline editor is open (data column), and the snapshot its commit maps from.
    @ObservationIgnored public internal(set) var editingCell: ActiveCell?
    @ObservationIgnored var pendingEditToken: CSVCellEditToken?

    /// Sets (or clears) the active cell and selects its row when MetalUI did not. A cell on the `#` column or on a row
    /// that is not selectable is never stored: a `#` click selects the row only.
    public func setActiveCell(_ cell: ActiveCell?) {
        guard let cell else {
            if activeCell != nil { activeCell = nil; selectionRevision &+= 1 }
            return
        }
        guard cell.row >= headerOffset, cell.row < usableRows, cell.column >= 0, cell.column < max(columnCount, 1) else {
            if activeCell != nil { activeCell = nil; selectionRevision &+= 1 }
            return
        }
        if activeCell != cell { activeCell = cell; selectionRevision &+= 1 }
        if selectedRows != [cell.row] { setSelection([cell.row]) }
    }

    /// Replaces the selection (a click, a key, Previous/Next change). Rows that are not selectable are dropped.
    public func setSelection(_ rows: Set<Int>) {
        let valid = rows.filter { $0 >= headerOffset && $0 < usableRows + (trailingMarker == nil ? 0 : 1) }
        guard valid != selectedRows else { return }
        selectedRows = valid
        selectionRevision &+= 1
    }

    /// A selected row survives sorts (ids are file ordinals) and is dropped when its row no longer exists.
    private func pruneSelection() {
        guard !selectedRows.isEmpty else { return }
        let limit = usableRows + (trailingMarker == nil ? 0 : 1)
        let kept = selectedRows.filter { $0 >= headerOffset && $0 < limit }
        if kept.count != selectedRows.count { selectedRows = kept; selectionRevision &+= 1 }
    }

    private func pruneActiveCell() {
        if let a = activeCell, a.row < headerOffset || a.row >= usableRows { activeCell = nil; selectionRevision &+= 1 }
    }

    /// File rows, ascending, that contain a tinted cell or a deletion marker. A marker belongs to the row after the gap
    /// (the last row for the trailing one). Cached per (ledger version, buffer version).
    public func changedRows() -> [Int] {
        let key = ChangedKey(ledger: sourceLedgerVersion, saved: sourceSavedVersion, buffer: document.buffer.version,
                             header: hasHeader, rows: usableRows)
        if let c = changedCache, c.key == key { return c.rows }
        var rows = Set<Int>()
        let count = usableRows
        if count > headerOffset {
            var candidates = Set<Int>()
            func tinted(_ edit: UUID) -> Bool {
                guard let a = ownership.author(of: edit) else { return false }
                if case .user = a { return false }
                return true
            }
            for s in ownership.spans where tinted(s.edit) {
                let lo = index.row(containing: s.range.lowerBound)
                let hi = index.row(containing: max(s.range.lowerBound, s.range.upperBound - 1))
                if lo <= hi { for r in lo...hi { candidates.insert(r) } }
            }
            for p in ownership.points where tinted(p.edit) {
                candidates.insert(index.row(containing: p.offset))
                if p.offset > 0 { candidates.insert(index.row(containing: p.offset - 1)) }
            }
            for r in candidates where r >= headerOffset && r < count {
                let cells = cache[r] ?? parse(fileRow: r)
                if cells.fieldRanges.contains(where: { ownership.tint(of: $0) != nil }) { rows.insert(r) }
            }
            for r in markers.keys where r >= headerOffset && r < count { rows.insert(r) }
            if trailingMarker != nil { rows.insert(count - 1) }
        }
        let sorted = rows.sorted()
        changedCache = (key, sorted)
        return sorted
    }

    /// True when one of `rows` is tinted or stands after a deletion marker (the end marker is one past the last row).
    /// Cheap: a binary search per row in the cached changed list.
    public func rowsHaveChange(_ rows: Set<Int>) -> Bool {
        guard !rows.isEmpty else { return false }
        let changed = changedRows()
        let rowSet = markers
        for r in rows {
            if r >= usableRows { if trailingMarker != nil { return true }; continue }
            if rowSet[r] != nil { return true }
            var lo = 0, hi = changed.count
            while lo < hi { let mid = (lo + hi) / 2; if changed[mid] < r { lo = mid + 1 } else { hi = mid } }
            if lo < changed.count, changed[lo] == r { return true }
        }
        return false
    }

    private var changeKey: ChangedKey {
        ChangedKey(ledger: sourceLedgerVersion, saved: sourceSavedVersion, buffer: document.buffer.version,
                   header: hasHeader, rows: usableRows)
    }

    /// The changed cells in file order (row, then column): tinted cells, and the first column of the row after a
    /// deletion marker (the last row for the trailing one). Cached with `changedRows()`.
    public func changedCells() -> [ActiveCell] {
        let key = changeKey
        if let c = changedCellsCache, c.key == key { return c.cells }
        var out: [ActiveCell] = []
        let last = usableRows - 1
        for r in changedRows() {
            let cells = cache[r] ?? parse(fileRow: r)
            var columns = Set<Int>()
            for c in cells.fieldRanges.indices where ledgerTint(forFileRow: r, column: c) != nil { columns.insert(c) }
            if markers[r] != nil || (trailingMarker != nil && r == last) { columns.insert(0) }
            for c in columns.sorted() { out.append(ActiveCell(row: r, column: c)) }
        }
        changedCellsCache = (key, out)
        return out
    }

    /// Moves to the next (previous) changed cell after (before) the active cell, or after (before) the selected rows
    /// when no cell is active, in file order, wrapping: selects its row, makes it the active cell and scrolls to it.
    /// Does nothing when nothing changed. Returns the row.
    @discardableResult
    public func stepChange(forward: Bool) -> Int? {
        let cells = changedCells()
        guard !cells.isEmpty else { return nil }
        func before(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
        let anchor = activeCell.flatMap { selectedRows.contains($0.row) ? $0 : nil }
        let target: ActiveCell
        if forward {
            let from = anchor.map { ($0.row, $0.column) } ?? (selectedRows.max() ?? -1, Int.max)
            target = cells.first { before(from, ($0.row, $0.column)) } ?? cells[0]
        } else {
            let from = anchor.map { ($0.row, $0.column) } ?? (selectedRows.min() ?? Int.max, -1)
            target = cells.last { before(($0.row, $0.column), from) } ?? cells[cells.count - 1]
        }
        setActiveCell(target)
        if activeCell != target { setSelection([target.row]) }
        scrollTo(cell: target)
        return target.row
    }

    /// Asks the panel to bring a file row into view; held until the panel has registered its scroller.
    public func scrollTo(fileRow row: Int) { scrollTo(cell: ActiveCell(row: row, column: 0)) }

    /// Asks the panel to bring a cell (file row, data column) into view; held until the panel registered its scroller.
    public func scrollTo(cell: ActiveCell) {
        if let scroller { scroller(cell) } else { pendingScroll = cell }
    }

    /// Runs a scroll that was asked for before the panel existed. Called by the panel after it registered `scroller`.
    public func flushPendingScroll() {
        guard let cell = pendingScroll, let scroller else { return }
        pendingScroll = nil
        scroller(cell)
    }

    public var hasPendingScroll: Bool { pendingScroll != nil }

    /// Selects, activates and scrolls to the cell holding byte `offset` (an offset in a delimiter or terminator goes to
    /// the field on its left; `column` overrides). While the index is building the request waits for it; the newest
    /// request wins.
    public func reveal(byteOffset offset: Int, column: Int? = nil) {
        if isBuilding || !installed { pendingReveal = (offset, column) } else { applyReveal(offset, column: column) }
    }

    private func applyReveal(_ offset: Int, column: Int?) {
        guard usableRows > headerOffset else { return }
        let row = min(max(index.row(containing: offset), headerOffset), usableRows - 1)
        let fields = (cache[row] ?? parse(fileRow: row)).fieldRanges
        var c = column ?? fields.lastIndex { $0.lowerBound <= offset } ?? 0
        c = min(max(c, 0), max(columnCount, 1) - 1)
        let cell = ActiveCell(row: row, column: c)
        setActiveCell(cell)
        if activeCell != cell { setSelection([row]) }
        scrollTo(cell: cell)
    }

    // MARK: Test support

    var cachedRowCount: Int { cache.count }
    var indexDialect: CSVDialect { index.dialect }

    /// Bytes retained by the index arrays and the cached values.
    var retainedByteEstimate: Int {
        index.retainedBytes + cache.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.utf8.count } }
    }
}

// MARK: Range targets (row-level Keep and Revert)

/// A piece of ledger text to keep: bytes of the ledger's visible (saved) text owned by `edit`.
public struct CSVKeepPiece: Equatable, Sendable {
    public var range: Range<Int>
    public var edit: UUID
    public init(range: Range<Int>, edit: UUID) { self.range = range; self.edit = edit }
}

/// What a row, a cell or a deletion marker stands for, in both coordinate systems: `current` bytes of the buffer to
/// restore (or `removedRows` to re-insert at `insertAt`), and the pieces of the ledger's text that Keep clears. The
/// versions it was computed at let an action refuse when the file moved underneath it.
public struct CSVRangeTarget: Equatable, Sendable {
    /// The bytes of the current buffer to replace with `replacement` (a row's text without its terminator).
    public var current: Range<Int>
    /// The previous text for `current`: the old rows joined by the terminator. Nil restores nothing: `current`
    /// (terminator included) is removed, because the change added the rows.
    public var replacement: String?
    public var removedRows: [String]
    public var insertAt: Int?
    public var keeps: [CSVKeepPiece]
    public var bufferVersion: UInt64
    public var ledgerVersion: Int

    public init(current: Range<Int>, replacement: String? = nil, removedRows: [String] = [], insertAt: Int? = nil,
                keeps: [CSVKeepPiece], bufferVersion: UInt64, ledgerVersion: Int) {
        self.current = current; self.replacement = replacement; self.removedRows = removedRows; self.insertAt = insertAt
        self.keeps = keeps; self.bufferVersion = bufferVersion; self.ledgerVersion = ledgerVersion
    }
}

extension CSVTableModel {
    /// A run of changed lines in the ledger's text: the rows a session added (with their saved byte ranges, terminator
    /// excluded) and the rows it removed at the same place.
    private struct ChangeGroup {
        var added: [(range: Range<Int>, edit: UUID, text: String)] = []
        var removed: [(text: String, edit: UUID)] = []
        var position = 0
    }

    private func changeGroups(_ ledger: FileLedger) -> [ChangeGroup] {
        var groups: [ChangeGroup] = []
        var position = 0
        var current: ChangeGroup?
        for (line, terminator) in ledger.diffEntries() {
            switch line {
            case .context(let text, _):
                if let c = current { groups.append(c); current = nil }
                position += text.utf8.count + terminator
            case .removed(let text, let edit):
                if current == nil { current = ChangeGroup(position: position) }
                current?.removed.append((text, edit))
            case .added(let text, _, let edit, _):
                if current == nil { current = ChangeGroup(position: position) }
                let n = text.utf8.count
                current?.added.append((position..<(position + n), edit, text))
                position += n + terminator
            }
        }
        if let c = current { groups.append(c) }
        return groups
    }

    /// The row's bytes without its terminator.
    private func body(ofRow row: Int) -> Range<Int> {
        let r = index.rowRange(row)
        let bytes = indexSnapshot.utf8(in: r)
        var end = bytes.count
        if end > 0, bytes[end - 1] == 0x0A { end -= 1 }
        if end > 0, bytes[end - 1] == 0x0D, end < bytes.count { end -= 1 }
        return r.lowerBound..<(r.lowerBound + end)
    }

    private func lineEnding(ofRow row: Int) -> String {
        let r = index.rowRange(row)
        let bytes = indexSnapshot.utf8(in: r)
        return bytes.count >= 2 && bytes[bytes.count - 2] == 0x0D && bytes[bytes.count - 1] == 0x0A ? "\r\n" : "\n"
    }

    private func isTinted(_ edit: UUID) -> Bool {
        guard let a = ownershipAuthor(edit) else { return false }
        if case .user = a { return false }
        return true
    }

    /// The target of the changed file row `fileRow`; nil for a clean row, a flagged row, a read-only document, or while
    /// the ledger and the buffer are not in step. Runs on the action (one `diffEntries()` pass), never in a body.
    public func rowTarget(fileRow: Int) -> CSVRangeTarget? {
        guard readOnlyReason == nil, document.state == .editable, !isBuilding,
              fileRow >= headerOffsetValue, fileRow < usableRowCount, let ledger = ledgerProvider().0,
              ledger.version == sourceLedgerVersionValue else { return nil }
        let buffer = document.buffer, from = sourceSavedVersion
        for g in changeGroups(ledger) where !g.added.isEmpty {
            var rows: [Int] = []
            for a in g.added {
                guard let start = buffer.map(a.range.lowerBound, from: from, bias: .after) else { return nil }
                rows.append(min(max(index.row(containing: start), headerOffsetValue), usableRowCount - 1))
            }
            guard rows.contains(fileRow) else { continue }
            if rows.contains(where: { index.isFlagged($0) }) { return nil }
            let edits = Set(g.added.map(\.edit)).union(g.removed.map(\.edit)).filter { isTinted($0) }
            guard !edits.isEmpty else { return nil }
            var targetRows = rows, lines = g.added, old = g.removed.map(\.text)
            let unit = g.removed.count == g.added.count && !g.removed.isEmpty
            if unit, let k = rows.firstIndex(of: fileRow) {
                targetRows = [rows[k]]; lines = [g.added[k]]; old = [old[k]]
            }
            guard let firstRow = targetRows.first, let lastRow = targetRows.last else { continue }
            let first = body(ofRow: firstRow), last = body(ofRow: lastRow)
            var current = first.lowerBound..<last.upperBound
            var replacement: String? = old.joined(separator: lineEnding(ofRow: lastRow))
            if g.removed.isEmpty {
                // Rows the session added: removing them takes their terminator (or the one before the last row).
                replacement = nil
                let end = index.rowRange(lastRow).upperBound
                if end > last.upperBound { current = first.lowerBound..<end }
                else if first.lowerBound > 0 { current = (first.lowerBound - lineEnding(ofRow: firstRow - 1).utf8.count)..<last.upperBound }
            }
            // Each tinted edit keeps what it wrote or removed anywhere on these lines (tombstones touching the range included).
            guard let firstLine = lines.first, let lastLine = lines.last else { continue }
            let span = firstLine.range.lowerBound..<lastLine.range.upperBound
            let keeps = edits.sorted { $0.uuidString < $1.uuidString }.map { CSVKeepPiece(range: span, edit: $0) }
            return CSVRangeTarget(current: current, replacement: replacement, keeps: keeps,
                                  bufferVersion: buffer.version, ledgerVersion: ledger.version)
        }
        return nil
    }

    /// The target of one changed cell: its field in the buffer, the old field's bytes verbatim, and the saved-text range
    /// of the field for Keep. Nil for an untinted cell, a flagged row, a read-only document, a row the session added
    /// (no old value) or one whose old and new field counts differ; use the row target there.
    public func cellTarget(fileRow: Int, column: Int) -> CSVRangeTarget? {
        guard readOnlyReason == nil, document.state == .editable, !isBuilding,
              fileRow >= headerOffsetValue, fileRow < usableRowCount, let ledger = ledgerProvider().0,
              ledger.version == sourceLedgerVersionValue, !index.isFlagged(fileRow) else { return nil }
        let cells = cache[fileRow] ?? parse(fileRow: fileRow)
        guard !cells.flagged, column >= 0, column < cells.fieldRanges.count,
              tint(forFileRow: fileRow, column: column) != nil else { return nil }
        let buffer = document.buffer, from = sourceSavedVersion, dialect = index.dialect
        for g in changeGroups(ledger) where !g.added.isEmpty && g.removed.count == g.added.count {
            var rows: [Int] = []
            for a in g.added {
                guard let start = buffer.map(a.range.lowerBound, from: from, bias: .after) else { return nil }
                rows.append(min(max(index.row(containing: start), headerOffsetValue), usableRowCount - 1))
            }
            guard rows.contains(fileRow) else { continue }
            guard rows.filter({ $0 == fileRow }).count == 1, let k = rows.firstIndex(of: fileRow) else { return nil }
            let new = CSVParser.parseRow(Array(g.added[k].text.utf8), dialect: dialect)
            let oldBytes = Array(g.removed[k].text.utf8)
            let old = CSVParser.parseRow(oldBytes, dialect: dialect)
            guard !new.flagged, !old.flagged, new.fields.count == cells.fieldRanges.count,
                  old.fields.count == new.fields.count else { return nil }
            let base = g.added[k].range.lowerBound
            let saved = (base + new.fields[column].lowerBound)..<(base + new.fields[column].upperBound)
            let edits = Set([g.added[k].edit, g.removed[k].edit]).filter { isTinted($0) }
            guard !edits.isEmpty else { return nil }
            let keeps = edits.sorted { $0.uuidString < $1.uuidString }.map { CSVKeepPiece(range: saved, edit: $0) }
            return CSVRangeTarget(current: cells.fieldRanges[column],
                                  replacement: String(decoding: oldBytes[old.fields[column]], as: UTF8.self), keeps: keeps,
                                  bufferVersion: buffer.version, ledgerVersion: ledger.version)
        }
        return nil
    }

    /// What Keep and Revert act on: the active cell when it is tinted and has a cell target, otherwise the selected
    /// rows (their tinted cells and deletion markers).
    public func actionTargets() -> [CSVRangeTarget] {
        if let a = activeCell, selectedRows.contains(a.row), let t = cellTarget(fileRow: a.row, column: a.column) { return [t] }
        return targets(forSelection: selectedRows)
    }

    /// The target of the deletion marker standing before `row` (nil: the end of the file).
    public func markerTarget(beforeFileRow row: Int?) -> CSVRangeTarget? {
        guard readOnlyReason == nil, document.state == .editable, !isBuilding, let ledger = ledgerProvider().0,
              ledger.version == sourceLedgerVersionValue else { return nil }
        let buffer = document.buffer, from = sourceSavedVersion
        var rows: [String] = [], keeps: [CSVKeepPiece] = []
        for g in changeGroups(ledger) where g.added.isEmpty && !g.removed.isEmpty {
            guard let at = buffer.map(g.position, from: from, bias: .after), markerRow(forOffset: at) == row else { continue }
            for r in g.removed where isTinted(r.edit) {
                rows.append(r.text)
                keeps.append(CSVKeepPiece(range: g.position..<g.position, edit: r.edit))
            }
        }
        guard !rows.isEmpty else { return nil }
        let insertAt = row.map { index.rowRange($0).lowerBound } ?? indexSnapshot.utf8Count
        return CSVRangeTarget(current: insertAt..<insertAt, removedRows: rows, insertAt: insertAt, keeps: keeps,
                              bufferVersion: buffer.version, ledgerVersion: ledger.version)
    }

    /// The file row a deletion at byte `offset` stands before; nil for the end of the file.
    func markerRow(forOffset offset: Int) -> Int? {
        guard usableRowCount > 0, offset < indexSnapshot.utf8Count else { return nil }
        var k = index.row(containing: offset)
        if index.rowRange(k).lowerBound < offset { k += 1 }
        k = max(k, headerOffsetValue)
        return k < usableRowCount ? k : nil
    }

    /// The targets for a selection of file rows (a trailing id one past the last row stands for the end marker),
    /// without duplicates.
    public func targets(forSelection rows: Set<Int>) -> [CSVRangeTarget] {
        var out: [CSVRangeTarget] = []
        func add(_ t: CSVRangeTarget?) { if let t, !out.contains(t) { out.append(t) } }
        for r in rows.sorted() {
            if r >= usableRowCount { add(markerTarget(beforeFileRow: nil)) } else {
                add(rowTarget(fileRow: r)); add(markerTarget(beforeFileRow: r))
            }
        }
        return out
    }
}
