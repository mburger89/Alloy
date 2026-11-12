import Foundation

/// Permanent identity of one inserted run: the inserting edit (`nil` = the baseline) and the offset of
/// the run's first scalar within that edit's insertions. Splitting a fragment keeps `edit` and advances `offset`.
struct InsertionID: Codable, Hashable, Sendable {
    var edit: UUID?
    var offset: Int
}

/// A run of text inserted by one edit. Tombstones (deleted fragments) stay in the array.
struct Fragment: Codable, Equatable, Sendable {
    var id: InsertionID
    var text: String
    /// `text` length in Unicode scalars.
    var length: Int
    var deletedBy: Set<UUID>
    /// Derived cache of "inserted by a non-reverted edit and not deleted by a non-reverted edit". Not persisted
    /// and not part of equality; `EditHistory` keeps it current (`refreshVisibility`) so scans do not look
    /// up `metas` for every fragment.
    fileprivate(set) var visible = true

    private enum CodingKeys: String, CodingKey { case id, text, length, deletedBy }

    init(id: InsertionID, text: String, deletedBy: Set<UUID> = []) {
        self.id = id
        self.text = text
        self.length = text.unicodeScalars.count
        self.deletedBy = deletedBy
    }

    static func == (a: Fragment, b: Fragment) -> Bool {
        a.id == b.id && a.text == b.text && a.length == b.length && a.deletedBy == b.deletedBy
    }

    /// Splits at `k` scalars (0 < k < length); the right half keeps the insertion with an advanced offset.
    func split(at k: Int) -> (Fragment, Fragment) {
        let scalars = text.unicodeScalars
        // ASCII (one byte per scalar) cuts in O(1); other text walks scalars.
        let mid = text.utf8.count == length
            ? text.utf8.index(text.utf8.startIndex, offsetBy: k)
            : scalars.index(scalars.startIndex, offsetBy: k)
        let ascii = text.utf8.count == length
        var l = Fragment(id: id, text: ascii ? String(Substring(text.utf8[..<mid])) : String(scalars[..<mid]), deletedBy: deletedBy)
        var r = Fragment(id: InsertionID(edit: id.edit, offset: id.offset + k),
                         text: ascii ? String(Substring(text.utf8[mid...])) : String(scalars[mid...]), deletedBy: deletedBy)
        l.visible = visible; r.visible = visible
        return (l, r)
    }
}

/// One replace operation at visible scalar offsets of the text *before* the edit.
struct TextOp: Equatable, Sendable {
    var start: Int
    var deleteCount: Int
    var insert: String
}

/// The sequence CRDT behind `FileLedger`, modelled on Zed's text buffer without networking: the document
/// is an ordered array of fragments, each inserted by one edit and deleted by a set of edits.
///
/// Edits arrive one at a time per tool call, so a plain array is enough for v1. If Plan 6 benchmarks show
/// ledger time, the upgrade is a B-tree (Zed's SumTree) keyed by visible length.
struct EditHistory: Codable, Equatable, Sendable {
    struct InsertRange: Codable, Equatable, Sendable { var start: Int; var length: Int }
    struct Meta: Codable, Equatable, Sendable {
        var state: EditRecord.State
        /// Creation order; later edits have larger values.
        var seq: Int
        var nextOffset: Int
        var ranges: [InsertRange]
    }

    /// Where a physically removed (kept-deleted) character used to be, so anchors on it still resolve.
    struct Removal: Codable, Equatable, Sendable {
        var id: InsertionID
        var length: Int
        /// First character of the next / last character of the previous visible fragment at removal time.
        var next: InsertionID?
        var previous: InsertionID?
    }

    var fragments: [Fragment]
    var metas: [UUID: Meta] = [:]
    var removals: [Removal] = []

    /// Creation sequence of an edit; "latest" always means record sequence, not date.
    func seq(of edit: UUID) -> Int { metas[edit]?.seq ?? -1 }

    /// Tolerates ledgers saved before `metas` / `removals` existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fragments = try c.decode([Fragment].self, forKey: .fragments)
        metas = try c.decodeIfPresent([UUID: Meta].self, forKey: .metas) ?? [:]
        removals = try c.decodeIfPresent([Removal].self, forKey: .removals) ?? []
        refreshVisibility()
    }

    private enum CodingKeys: String, CodingKey { case fragments, metas, removals }

    init(baseline: String) {
        fragments = baseline.isEmpty ? [] : [Fragment(id: InsertionID(edit: nil, offset: 0), text: baseline)]
    }

    // MARK: Visibility

    private func state(_ id: UUID?) -> EditRecord.State? { id.flatMap { metas[$0]?.state } }

    /// Inserted by the baseline, a live edit or a kept edit.
    private func isInserted(_ f: Fragment) -> Bool {
        guard let e = f.id.edit else { return true }
        return metas[e]?.state != .reverted
    }

    /// Deleted by a live or kept edit (a reverted edit's deletion no longer counts).
    private func isDeleted(_ f: Fragment) -> Bool {
        f.deletedBy.contains { metas[$0]?.state != .reverted }
    }

    private func isVisible(_ f: Fragment) -> Bool { f.visible }

    /// Recomputes every fragment's cached visibility from `metas`; call after any change to edit states.
    private mutating func refreshVisibility() {
        for i in fragments.indices {
            let v = isInserted(fragments[i]) && !isDeleted(fragments[i])
            if fragments[i].visible != v { fragments[i].visible = v }
        }
    }

    /// Kept edits count as baseline for attribution.
    private func owner(_ f: Fragment) -> UUID? {
        guard let e = f.id.edit, metas[e]?.state == .live else { return nil }
        return e
    }

    var visibleText: String {
        var out = ""
        for f in fragments where isVisible(f) { out += f.text }
        return out
    }

    var visibleLength: Int { fragments.reduce(0) { $0 + (isVisible($1) ? $1.length : 0) } }

    // MARK: Applying edits

    mutating func register(_ edit: UUID) {
        metas[edit] = Meta(state: .live, seq: metas.count, nextOffset: 0, ranges: [])
    }

    mutating func setState(_ edit: UUID, _ state: EditRecord.State) {
        metas[edit]?.state = state
        refreshVisibility()
    }

    /// Index of the visible fragment starting at visible offset `p` (splitting one if `p` falls inside it),
    /// or `fragments.count` when `p` is the end of the text.
    private mutating func split(atVisible p: Int) -> Int {
        var cum = 0
        for i in fragments.indices {
            guard fragments[i].visible else { continue }   // no Fragment copy: that retains its String and Set
            if cum == p { return i }
            let length = fragments[i].length
            if p < cum + length {
                let (l, r) = fragments[i].split(at: p - cum)
                fragments.replaceSubrange(i...i, with: [l, r])
                return i + 1
            }
            cum += length
        }
        return fragments.count
    }

    /// Applies `ops` (ascending, disjoint, offsets in the pre-edit text) as `edit`.
    mutating func apply(_ ops: [TextOp], as edit: UUID) {
        for op in ops.reversed() {   // right to left keeps earlier offsets valid
            if op.deleteCount > 0 {
                let i = split(atVisible: op.start)
                let j = split(atVisible: op.start + op.deleteCount)
                for k in i..<j where fragments[k].visible {
                    fragments[k].deletedBy.insert(edit)
                    fragments[k].visible = false   // `edit` is live
                }
            }
            if !op.insert.isEmpty {
                // Right after the previous visible fragment, i.e. before any tombstones at this point.
                var at = op.start == 0 ? 0 : split(atVisible: op.start)
                while at > 0, !isVisible(fragments[at - 1]) { at -= 1 }
                let nextOffset = metas[edit]!.nextOffset   // not a whole-Meta copy: that would copy `ranges` on append
                let frag = Fragment(id: InsertionID(edit: edit, offset: nextOffset), text: op.insert)
                fragments.insert(frag, at: at)
                metas[edit]!.ranges.append(InsertRange(start: nextOffset, length: frag.length))
                metas[edit]!.nextOffset += frag.length + 1   // gap keeps separate operations non-contiguous
            }
        }
    }

    /// Physically removes the tombstones deleted by `edit` and marks it kept. Identities are unchanged.
    mutating func keep(_ edit: UUID) {
        setState(edit, .kept)
        for i in fragments.indices where fragments[i].deletedBy.contains(edit) {
            let f = fragments[i]
            var next: InsertionID?, previous: InsertionID?
            if let n = fragments[(i + 1)...].first(where: { isVisible($0) }) { next = n.id }
            if let p = fragments[..<i].last(where: { isVisible($0) }) {
                previous = InsertionID(edit: p.id.edit, offset: p.id.offset + p.length - 1)
            }
            removals.append(Removal(id: f.id, length: f.length, next: next, previous: previous))
        }
        fragments.removeAll { $0.deletedBy.contains(edit) }
    }

    // MARK: Revert conflicts

    enum Conflict: Equatable { case other(UUID), notLive }

    /// A revert by identity is refused when another *live* edit deleted part of this edit's insertions or
    /// inserted inside one of its runs. Inserting right before or after the whole run is fine. Kept edits
    /// count as baseline: reverting leaves their text in place.
    func conflict(reverting edit: UUID) -> Conflict? {
        guard let meta = metas[edit], meta.state == .live else { return .notLive }
        var pieces: [(index: Int, rangeIndex: Int)] = []
        for (i, f) in fragments.enumerated() {
            if f.id.edit == edit, let r = meta.ranges.firstIndex(where: { f.id.offset >= $0.start && f.id.offset < $0.start + $0.length }) {
                pieces.append((i, r))
                if let d = f.deletedBy.filter({ metas[$0]?.state == .live }).max(by: { metas[$0]!.seq < metas[$1]!.seq }) {
                    return .other(d)
                }
            }
        }
        for (p, q) in zip(pieces, pieces.dropFirst()) where p.rangeIndex == q.rangeIndex {
            for k in (p.index + 1)..<q.index {
                if let e = fragments[k].id.edit, e != edit, metas[e]?.state == .live { return .other(e) }
            }
        }
        return nil
    }

    // MARK: Attribution

    /// Visible text as runs; baseline and kept edits are `nil`, adjacent same-owner runs are merged.
    func runs() -> [AttributedRun] {
        var out: [AttributedRun] = []
        for f in fragments where isVisible(f) {
            let o = owner(f)
            if let last = out.last, last.edit == o { out[out.count - 1].text += f.text }
            else { out.append(AttributedRun(text: f.text, edit: o)) }
        }
        return out
    }

    /// Per line (terminator included) the latest live edit with a visible character on it.
    func lineOwners() -> [UUID?] {
        lineAttribution(of: fragments.filter(isVisible)) { owner($0) }
    }

    /// Where each live edit's deletions sit in the visible text: the 1-based number of the visible line the
    /// tombstones fall in (a deletion of whole lines sits at the line that followed them), ascending and without
    /// repeats. Whole-line deletes count too. One pass over the fragments.
    func deletionAnchors() -> [UUID: [Int]] {
        var out: [UUID: [Int]] = [:]
        var visibleNewlines = 0
        for f in fragments {
            if isVisible(f) {
                visibleNewlines += f.text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            } else if isInserted(f) {
                let k = visibleNewlines + 1
                for d in f.deletedBy where metas[d]?.state == .live && out[d]?.last != k { out[d, default: []].append(k) }
            }
        }
        return out
    }

    /// The text before live edits: baseline and kept insertions, with live edits' tombstones shown.
    func oldViewFragments() -> [Fragment] { fragments.filter(inOldView) }

    private func inOldView(_ f: Fragment) -> Bool { f.id.edit.map { metas[$0]?.state == .kept } ?? true }

    /// Per line of the old view (`old == true`) or the visible text, the index in `fragments` of the
    /// fragment holding the line's terminating "\n" (nil for an unterminated final line).
    func lineTerminators(old: Bool) -> [Int?] {
        var out: [Int?] = []
        var atLineStart = true
        for (i, f) in fragments.enumerated() where old ? inOldView(f) : isVisible(f) {
            for s in f.text.unicodeScalars {
                if atLineStart { out.append(nil); atLineStart = false }
                if s == "\n" { out[out.count - 1] = i; atLineStart = true }
            }
        }
        return out
    }

    /// The live edit that inserted fragment `index` (nil for baseline, kept, or out of range).
    func inserter(ofFragment index: Int?) -> UUID? {
        guard let index, fragments.indices.contains(index) else { return nil }
        return latest(fragments[index].id.edit.map { [$0] } ?? [])
    }

    /// The latest live edit that deleted fragment `index`.
    func deleter(ofFragment index: Int?) -> UUID? {
        guard let index, fragments.indices.contains(index) else { return nil }
        return latest(Array(fragments[index].deletedBy))
    }

    /// How the lines of the old view (baseline + kept text, live deletions shown) relate to the lines of
    /// the visible text. Characters present in both views link their old line to their new line.
    /// `newInserters[j]` are the live edits that inserted visible characters (terminator included) on new
    /// line `j`. `newDeleters[j]` are the live edits whose tombstones sit inside new line `j`: between its
    /// characters, before its first character (after the previous terminator), or after the end of an
    /// unterminated final line. A tombstone that ends in "\n" at a line start is a deleted whole line, not
    /// part of the next line.
    struct LineLinks {
        var oldToNew: [Set<Int>] = [], newToOld: [Set<Int>] = []
        var newInserters: [[UUID]] = [], newDeleters: [[UUID]] = []
        /// Boundary creation. If a new line's first surviving character follows a surviving character of
        /// the same old line, the line was split off that old line: `newSplitters[j]` are the live edits
        /// that inserted a "\n" in the gap between the old line's previous character and this line's first survivor. Mirror image for an old line whose
        /// first survivor follows a survivor that sits on the same new line (the lines were joined):
        /// `oldJoiners[k]` are the live edits that deleted a "\n" in the gap.
        var newSplitters: [[UUID]] = [], oldJoiners: [[UUID]] = []
    }

    func lineLinks() -> LineLinks {
        var links = LineLinks()
        var oldLine = -1, newLine = -1
        var oldStart = true, newStart = true
        var gapInserted: [UUID] = [], gapDeleted: [UUID] = []   // "\n"s since the last old-view / new-view character
        var lastOldLine: Int?, lastNewLine: Int?
        var seenOld = Set<Int>(), seenNew = Set<Int>()
        var pending: [UUID] = []   // deletions at a line start, waiting for the line's first character
        for f in fragments {
            let inOld = inOldView(f), inNew = isVisible(f)
            let inserter = f.id.edit.flatMap { metas[$0]?.state == .live ? $0 : nil }
            let deleters = f.deletedBy.filter { metas[$0]?.state == .live }
            guard inOld || inNew else {
                // Inserted and deleted again: it left no text, but it did create a boundary for a while.
                if let inserter, f.text.unicodeScalars.contains("\n") {
                    for s in f.text.unicodeScalars where s == "\n" { gapInserted.append(inserter) }
                    pending = []   // a boundary separated the pending deletions from what follows
                }
                continue
            }
            if inOld, !inNew {
                // A tombstone of a live deletion: credit the new line it sits in. At a line start it waits for
                // the line's first character; a tombstone ending in "\n" there is a deleted whole line.
                if !deleters.isEmpty {
                    if !newStart { links.newDeleters[newLine].append(contentsOf: deleters) }
                    else if f.text.unicodeScalars.last == "\n" { pending = [] }
                    else { if f.text.unicodeScalars.contains("\n") { pending = [] }; pending.append(contentsOf: deleters) }
                }
            }
            for s in f.text.unicodeScalars {
                if inOld, oldStart {
                    oldLine += 1; oldStart = false
                    links.oldToNew.append([]); links.oldJoiners.append([])
                }
                if inNew, newStart {
                    newLine += 1; newStart = false
                    links.newToOld.append([]); links.newInserters.append([]); links.newSplitters.append([])
                    links.newDeleters.append(pending); pending = []
                }
                if inOld, inNew {
                    links.oldToNew[oldLine].insert(newLine); links.newToOld[newLine].insert(oldLine)
                    if seenNew.insert(newLine).inserted, lastOldLine == oldLine { links.newSplitters[newLine] = gapInserted }
                    if seenOld.insert(oldLine).inserted, lastNewLine == newLine { links.oldJoiners[oldLine] = gapDeleted }
                }
                if inNew, let inserter { links.newInserters[newLine].append(inserter) }
                if inOld { lastOldLine = oldLine; gapInserted = [] }
                if inNew { lastNewLine = newLine; gapDeleted = [] }
                if s == "\n" {
                    if !inOld, let inserter { gapInserted.append(inserter) }
                    if !inNew { gapDeleted.append(contentsOf: deleters) }
                }
                if inOld, s == "\n" { oldStart = true }
                if inNew, s == "\n" { newStart = true }
            }
        }
        return links
    }

    /// The earliest live edit (record sequence) among `ids`.
    func earliestLive(_ ids: [UUID]) -> UUID? {
        ids.filter { metas[$0]?.state == .live }.min { metas[$0]!.seq < metas[$1]!.seq }
    }

    /// The latest live edit (record sequence) among `ids`.
    func latestLive(_ ids: [UUID]) -> UUID? { latest(ids) }

    private func latest(_ ids: [UUID]) -> UUID? {
        ids.filter { metas[$0]?.state == .live }.max { metas[$0]!.seq < metas[$1]!.seq }
    }

    /// Per old-view line, the latest live edit that deleted a character on it.
    func removalOwners(in old: [Fragment]) -> [UUID?] {
        lineAttribution(of: old) { f in
            f.deletedBy.filter { metas[$0]?.state == .live }.max { metas[$0]!.seq < metas[$1]!.seq }
        }
    }

    private func lineAttribution(of frags: [Fragment], tag: (Fragment) -> UUID?) -> [UUID?] {
        var owners: [UUID?] = []
        var atLineStart = true
        for f in frags {
            let t = tag(f)
            let seq = t.flatMap { metas[$0]?.seq } ?? -1
            for s in f.text.unicodeScalars {
                if atLineStart { owners.append(nil); atLineStart = false }
                if t != nil {
                    let cur = owners[owners.count - 1].flatMap { metas[$0]?.seq } ?? -1
                    if seq > cur { owners[owners.count - 1] = t }
                }
                if s == "\n" { atLineStart = true }
            }
        }
        return owners
    }

    // MARK: Anchors

    /// The character at visible `offset` (nil at the end of the text) plus bias.
    func anchor(atOffset offset: Int, bias: Anchor.Bias) -> Anchor {
        var cum = 0
        for f in fragments where isVisible(f) {
            if offset < cum + f.length {
                return Anchor(insertion: InsertionID(edit: f.id.edit, offset: f.id.offset + (offset - cum)), bias: bias)
            }
            cum += f.length
        }
        return Anchor(insertion: nil, bias: bias)
    }

    /// The anchored character's visible offset (either bias). If it is deleted or removed by Keep, the
    /// nearest visible character on the bias side: `.right` gives the offset of the next visible
    /// character (the end of the text if none), `.left` the offset of the previous visible character
    /// (0 if none).
    func offset(of anchor: Anchor) -> Int {
        guard let id = anchor.insertion else { return visibleLength }
        var cum = 0
        for f in fragments {
            if f.id.edit == id.edit, id.offset >= f.id.offset, id.offset < f.id.offset + f.length {
                if isVisible(f) { return cum + (id.offset - f.id.offset) }
                return anchor.bias == .right ? cum : max(cum - 1, 0)
            }
            if isVisible(f) { cum += f.length }
        }
        if let r = removals.last(where: { $0.id.edit == id.edit && id.offset >= $0.id.offset && id.offset < $0.id.offset + $0.length }) {
            // The character was removed by Keep: resolve through the neighbour recorded at removal.
            if anchor.bias == .right {
                return r.next.map { offset(of: Anchor(insertion: $0, bias: .right)) } ?? visibleLength
            }
            return r.previous.map { offset(of: Anchor(insertion: $0, bias: .left)) } ?? 0
        }
        return anchor.bias == .right ? visibleLength : 0
    }
}
