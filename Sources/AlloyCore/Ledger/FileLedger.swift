import Foundation

public enum Author: Hashable, Codable, Sendable { case session(UUID), user, outside }

public struct EditRecord: Identifiable, Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case live, kept, reverted }
    public var id: UUID
    public var author: Author
    public var path: String   // project-relative
    public var date: Date
    public var toolUseID: String?
    public var hunks: [PatchHunk]
    public var state: State

    public init(id: UUID, author: Author, path: String, date: Date, toolUseID: String?, hunks: [PatchHunk], state: State) {
        self.id = id; self.author = author; self.path = path; self.date = date
        self.toolUseID = toolUseID; self.hunks = hunks; self.state = state
    }
}

/// A run of visible text and the live edit that inserted it (`nil` = baseline or kept).
public struct AttributedRun: Equatable, Sendable {
    public var text: String
    public var edit: UUID?
    public init(text: String, edit: UUID?) { self.text = text; self.edit = edit }
}

/// Names one character by its permanent insertion identity, so it follows the character through later edits.
/// `insertion == nil` means the end of the text.
public struct Anchor: Codable, Hashable, Sendable {
    public enum Bias: String, Codable, Hashable, Sendable { case left, right }
    var insertion: InsertionID?
    public var bias: Bias
}

public enum DiffLine: Equatable, Sendable {
    case context(text: String, line: Int)
    case added(text: String, line: Int, edit: UUID, runs: [AttributedRun])
    case removed(text: String, edit: UUID)
}

public enum RevertOutcome: Equatable, Sendable { case reverted(newText: String), conflict(reason: String) }

/// The ledger of one file: its visible text, who wrote which characters, and the edits that did it.
public struct FileLedger: Codable, Sendable, Equatable {
    public let path: String
    public private(set) var edits: [EditRecord] = []
    private var history: EditHistory
    /// Bumped by every in-place relabel of a record (`adoptOutside`), which changes who wrote the text but not
    /// the number of edits or their states.
    private var revision = 0

    private enum CodingKeys: String, CodingKey { case path, edits, history, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        edits = try c.decode([EditRecord].self, forKey: .edits)
        history = try c.decode(EditHistory.self, forKey: .history)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0   // ledgers saved before the counter
    }

    public init(path: String, baseline: String) {
        self.path = path
        history = EditHistory(baseline: baseline)
    }

    /// Grows with every mutation (an edit recorded, kept, reverted or relabelled), so a cache keyed by it never
    /// goes stale. Edits only append and states only leave `.live`, so those two are derived; relabels are counted.
    public var version: Int { edits.count + edits.reduce(0) { $0 + ($1.state == .live ? 0 : 1) } + revision }

    /// The visible text.
    public var text: TextLines { TextLines(history.visibleText) }

    /// The visible text as one string, without the line split `text` does.
    var currentText: String { history.visibleText }

    var fragmentCount: Int { history.fragments.count }

    // MARK: Recording edits

    /// Applies a CLI patch. Returns `[]` and changes nothing if the hunks do not apply to `originalFile`
    /// (or the current text). A stale `originalFile` records an `.outside` edit first.
    @discardableResult
    public mutating func applyPatch(author: Author, originalFile: String?, hunks: [PatchHunk],
                                    toolUseID: String?, date: Date) -> [EditRecord] {
        applyPatchChecked(author: author, originalFile: originalFile, hunks: hunks, toolUseID: toolUseID, date: date) ?? []
    }

    /// Like `applyPatch` but `nil` when the hunks do not apply.
    mutating func applyPatchChecked(author: Author, originalFile: String?, hunks: [PatchHunk],
                                    toolUseID: String?, date: Date) -> [EditRecord]? {
        let current = history.visibleText
        let base = originalFile ?? current
        var tl = TextLines(base)
        guard let patched = try? Patch.apply(hunks, to: tl.lines) else { return nil }
        if tl.lines.isEmpty { tl.hasTrailingNewline = true }
        tl.lines = patched
        var out: [EditRecord] = []
        if !TextDiff.same(base, current), let outside = record(.outside, to: base, hunks: nil, toolUseID: nil, date: date) {
            out.append(outside)
        }
        if let mine = record(author, to: tl.text, hunks: hunks, toolUseID: toolUseID, date: date) { out.append(mine) }
        return out
    }

    @discardableResult
    public mutating func applyFullText(author: Author, newText: String, toolUseID: String?, date: Date) -> EditRecord? {
        record(author, to: newText, hunks: nil, toolUseID: toolUseID, date: date)
    }

    /// `.outside` records and the session records Bash attribution made (no tool call id) can be adopted.
    private static func adoptable(_ e: EditRecord) -> Bool {
        if e.author == .outside { return true }
        if case .session = e.author { return e.toolUseID == nil }
        return false
    }

    /// Whether `adoptOutside` could possibly relabel anything: a live adoptable record exists and the ledger has
    /// moved past `originalFile`. Cheap (a scan of the edits first, the text comparison only when one exists), so a
    /// tool result can skip building its patched text on the common path where nothing is adoptable.
    func canAdopt(originalFile: String) -> Bool {
        edits.contains { Self.adoptable($0) && $0.state == .live } && !TextDiff.same(history.visibleText, originalFile)
    }

    /// A tool result that arrives after its file change was already recorded as `.outside` (the file was seen on
    /// disk before the result reached Alloy). Relabels that record as `author`'s and returns it; nil when no such
    /// record exists. Applies only when the ledger has moved past `originalFile`: a result that applies to the
    /// current text is recorded normally.
    mutating func adoptOutside(as author: Author, originalFile: String, newText: String,
                               toolUseID: String?) -> EditRecord? {
        guard canAdopt(originalFile: originalFile) else { return nil }
        let hunks = TextDiff.hunks(old: originalFile, new: newText)
        guard let i = edits.lastIndex(where: { Self.adoptable($0) && $0.state == .live && $0.hunks == hunks })
        else { return nil }
        edits[i].author = author
        edits[i].toolUseID = toolUseID
        revision += 1
        return edits[i]
    }

    /// The one core path: line-diff the visible text against `newText`, character-diff each changed
    /// region and apply the resulting operations to the fragments.
    private mutating func record(_ author: Author, to newText: String, hunks: [PatchHunk]?,
                                 toolUseID: String?, date: Date) -> EditRecord? {
        let old = history.visibleText
        guard !TextDiff.same(old, newText) else { return nil }
        let id = UUID()
        history.register(id)
        history.apply(TextDiff.ops(old: old, new: newText), as: id)
        let rec = EditRecord(id: id, author: author, path: path, date: date, toolUseID: toolUseID,
                             hunks: hunks ?? TextDiff.hunks(old: old, new: newText), state: .live)
        edits.append(rec)
        return rec
    }

    // MARK: Attribution

    public func runs() -> [AttributedRun] { history.runs() }

    /// "Latest" is record sequence (the order edits were recorded), not date.
    public func lineOwners() -> [UUID?] { history.lineOwners() }

    /// Per live edit, the visible lines where its deleted text used to be (see `EditHistory.deletionAnchors`).
    public func deletionAnchors() -> [UUID: [Int]] { history.deletionAnchors() }

    /// Changed lines are attributed by identity, never by position, and lines are paired by identity too
    /// (an old and a new line are the same line only if they are each other's only survivors and byte-equal),
    /// so identical-looking lines such as blanks never swap roles.
    /// Removed line: the edit that deleted its characters; else all its characters survive, so the latest
    /// live edit that inserted characters on the new line holding them (an indent, a split terminator, a
    /// prefix); else the earliest live edit that deleted a "\n" between its first character and the
    /// preceding character of the same new line (a join removed the boundary in front of it).
    /// Added line: the owner of its characters; else the latest live edit whose deletion sits inside it (a
    /// joined-away terminator, a removed indent); else the earliest live edit that inserted a "\n" between
    /// its first character and the preceding character of the same old line (a split created the boundary in
    /// front of it; "earliest" because later "\n"s in that gap only split off further, empty or new, lines).
    /// If all of these find nothing (rare), the edit that deleted/inserted the previous line's terminator,
    /// then the latest owner in the same region, then the latest live edit. "Latest" is record sequence.
    public func diffLines() -> [DiffLine] { diffEntries().map(\.line) }

    /// `diffLines()` with each line's own terminator length in UTF-8 bytes (0 for a last line without one). A removed line reports the terminator it had in the old text, which
    /// a file with mixed line endings needs to place byte offsets.
    public func diffEntries() -> [(line: DiffLine, terminator: Int)] {
        let oldFragments = history.oldViewFragments()
        let oldUnits = TextDiff.lineUnits(oldFragments.map(\.text).joined())
        let newUnits = TextDiff.lineUnits(history.visibleText)
        let owners = history.lineOwners(), removers = history.removalOwners(in: oldFragments)
        let fallback = edits.last { $0.state == .live }?.id ?? UUID()
        func latest(_ ids: some Sequence<UUID?>) -> UUID? {
            ids.compactMap { $0 }.max { history.seq(of: $0) < history.seq(of: $1) }
        }
        func owner(_ k: Int) -> UUID? { k < owners.count ? owners[k] : nil }
        func remover(_ k: Int) -> UUID? { k < removers.count ? removers[k] : nil }
        let links = history.lineLinks()
        let oldTerms = history.lineTerminators(old: true), newTerms = history.lineTerminators(old: false)
        var runsByLine: [[AttributedRun]]?
        var out: [(line: DiffLine, terminator: Int)] = []
        var o = 0, n = 0
        func context(upTo end: Int) {
            while o < end { out.append((.context(text: TextDiff.stripTerminator(newUnits[n]), line: n + 1), TextDiff.terminatorLength(newUnits[n]))); o += 1; n += 1 }
        }
        // Lines are paired by identity, not by text: an old and a new line are the same line only if their
        // characters are exactly each other's survivors and the text is byte-equal. Identical-looking lines
        // (blank lines, repeated braces) therefore never swap roles, so the edit that created or removed the
        // one that is shown as changed is the one named.
        var oldKeys = (0..<oldUnits.count).map { "-\($0)" }, newKeys = (0..<newUnits.count).map { "+\($0)" }
        for k in 0..<min(oldUnits.count, links.oldToNew.count) {
            guard links.oldToNew[k].count == 1, let j = links.oldToNew[k].first, j < newUnits.count,
                  links.newToOld[j] == [k], TextDiff.same(oldUnits[k], newUnits[j]) else { continue }
            oldKeys[k] = "=\(k)"; newKeys[j] = "=\(k)"
        }
        for region in TextDiff.regions(oldKeys: oldKeys, newKeys: newKeys) {
            context(upTo: region.old.lowerBound)
            for k in region.old {
                out.append((.removed(text: TextDiff.stripTerminator(oldUnits[k]), edit: remover(k)
                    // All characters survive; an insertion landed inside the line.
                    ?? (k < links.oldToNew.count ? history.latestLive(links.oldToNew[k].flatMap { links.newInserters[$0] }) : nil)
                    // A join deleted the terminator in front of this line.
                    ?? (k < links.oldJoiners.count ? history.earliestLive(links.oldJoiners[k]) : nil)
                    ?? (k > 0 && k - 1 < oldTerms.count ? history.deleter(ofFragment: oldTerms[k - 1]) : nil)
                    ?? latest(region.new.map(owner)) ?? fallback), TextDiff.terminatorLength(oldUnits[k])))
            }
            for k in region.new {
                if runsByLine == nil { runsByLine = lineRuns() }
                out.append((.added(text: TextDiff.stripTerminator(newUnits[k]), line: k + 1,
                                  edit: owner(k)
                                    // No owned characters; a deletion landed inside the line.
                                    ?? (k < links.newDeleters.count ? history.latestLive(links.newDeleters[k]) : nil)
                                    // A split inserted the terminator in front of this line.
                                    ?? (k < links.newSplitters.count ? history.earliestLive(links.newSplitters[k]) : nil)
                                    ?? (k > 0 && k - 1 < newTerms.count ? history.inserter(ofFragment: newTerms[k - 1]) : nil)
                                    ?? latest(region.old.map(remover)) ?? fallback,
                                  runs: k < runsByLine!.count ? runsByLine![k] : []), TextDiff.terminatorLength(newUnits[k])))
            }
            o = region.old.upperBound; n = region.new.upperBound
        }
        context(upTo: oldUnits.count)
        return out
    }

    /// Attribution runs per visible line, without the line terminator.
    private func lineRuns() -> [[AttributedRun]] {
        var lines: [[AttributedRun]] = [], cur: [AttributedRun] = []
        func finish() {
            var line = cur
            var dropped = 0   // scalars to drop from the end: "\n", then an optional "\r"
            outer: while let last = line.last {
                var scalars = Array(last.text.unicodeScalars)
                while let s = scalars.last {
                    if (dropped == 0 && s == "\n") || (dropped == 1 && s == "\r") { scalars.removeLast(); dropped += 1 }
                    else { dropped = 2 }
                    if dropped == 2 { break }
                }
                if scalars.isEmpty { line.removeLast(); if dropped < 2 { continue outer } }
                else { line[line.count - 1].text = String(String.UnicodeScalarView(scalars)) }
                break
            }
            lines.append(line); cur = []
        }
        for run in runs() {
            var buf = String.UnicodeScalarView()
            for s in run.text.unicodeScalars {
                buf.append(s)
                if s == "\n" { cur.append(AttributedRun(text: String(buf), edit: run.edit)); buf = .init(); finish() }
            }
            if !buf.isEmpty { cur.append(AttributedRun(text: String(buf), edit: run.edit)) }
        }
        if !cur.isEmpty { finish() }
        return lines
    }

    // MARK: Anchors

    public func anchor(atOffset offset: Int, bias: Anchor.Bias) -> Anchor { history.anchor(atOffset: offset, bias: bias) }

    public func offset(of anchor: Anchor) -> Int { history.offset(of: anchor) }

    // MARK: Keep / Revert

    public mutating func keep(_ id: UUID) {
        guard let i = edits.firstIndex(where: { $0.id == id }), edits[i].state == .live else { return }
        edits[i].state = .kept
        history.keep(id)
    }

    public mutating func keepAll(where predicate: (EditRecord) -> Bool) {
        for rec in edits where rec.state == .live && predicate(rec) { keep(rec.id) }
    }

    /// Reverts by identity (no text search). Conflicts when a later live edit touched this edit's text.
    /// `authorName` words an author in a conflict reason (the default shows a session's id).
    public mutating func revert(_ id: UUID, date: Date, authorName: (Author) -> String? = { _ in nil }) -> RevertOutcome {
        guard let i = edits.firstIndex(where: { $0.id == id }) else { return .conflict(reason: "Unknown edit.") }
        switch history.conflict(reverting: id) {
        case .notLive?: return .conflict(reason: "This edit is no longer live.")
        case .other(let other)?:
            let who = edits.first { $0.id == other }.map { authorName($0.author) ?? describe($0.author) } ?? "another edit"
            return .conflict(reason: "A later edit by \(who) changed the text this edit wrote.")
        case nil: break
        }
        let old = history.visibleText
        history.setState(id, .reverted)
        edits[i].state = .reverted
        let new = history.visibleText
        let userEdit = UUID()
        history.register(userEdit)
        history.setState(userEdit, .kept)   // owns no fragments; nothing left to review
        edits.append(EditRecord(id: userEdit, author: .user, path: path, date: date, toolUseID: nil,
                                hunks: TextDiff.hunks(old: old, new: new), state: .kept))
        return .reverted(newText: new)
    }

    private func describe(_ author: Author) -> String {
        switch author {
        case .session(let id): "session \(id.uuidString)"
        case .user: "you"
        case .outside: "an outside change"
        }
    }
}

/// Line and character diffing shared by every way of changing a file.
enum TextDiff {
    /// Lines with their terminators ("\n" or "\r\n"); concatenating them restores the text exactly.
    static func lineUnits(_ text: String) -> [String] {
        let bytes = Array(text.utf8)
        var out: [String] = []
        var start = 0
        for (i, b) in bytes.enumerated() where b == 0x0A {
            out.append(String(decoding: bytes[start...i], as: UTF8.self)); start = i + 1
        }
        if start < bytes.count { out.append(String(decoding: bytes[start...], as: UTF8.self)) }
        return out
    }

    /// Byte-exact equality: Swift's `String ==` treats canonically equivalent text (NFC/NFD) as equal.
    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    /// Comparison keys that make `String ==` byte-exact: non-ASCII lines become hex of their UTF-8.
    static func keys(_ units: some Sequence<String>) -> [String] {
        units.map { u in
            u.utf8.allSatisfy { $0 < 0x80 } ? u : "\u{1}x:" + u.utf8.map { String($0, radix: 16) }.joined(separator: ",")
        }
    }

    /// The UTF-8 length of a line unit's terminator: 0, 1 (`\n`) or 2 (`\r\n`).
    static func terminatorLength(_ unit: String) -> Int { unit.utf8.count - stripTerminator(unit).utf8.count }

    static func stripTerminator(_ unit: String) -> String {
        var s = unit.unicodeScalars
        if s.last == "\n" { s.removeLast() }
        if s.last == "\r" { s.removeLast() }
        return String(s)
    }

    /// Changed line regions between two line arrays, trimming the common prefix and suffix first.
    static func regions(old: [String], new: [String]) -> [(old: Range<Int>, new: Range<Int>)] {
        regions(oldKeys: keys(old), newKeys: keys(new))
    }

    /// Like `regions(old:new:)` on caller-supplied comparison keys (equal key = same line).
    static func regions(oldKeys old: [String], newKeys new: [String]) -> [(old: Range<Int>, new: Range<Int>)] {
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let om = Array(old[p..<(old.count - s)]), nm = Array(new[p..<(new.count - s)])
        return Patch.diff(old: om, new: nm, context: 0).map { h in
            let o = (h.oldLines == 0 ? h.oldStart : h.oldStart - 1) + p
            let n = (h.newLines == 0 ? h.newStart : h.newStart - 1) + p
            return (o..<(o + h.oldLines), n..<(n + h.newLines))
        }
    }

    /// Byte-level common prefix / suffix trim shared by `ops` and `hunks`. Returns the middle slices of
    /// `old` and `new` plus the count of cut leading bytes and lines. Always applies: both algorithms split on "\n"
    /// alone and a cut never falls inside a line terminator. (`hunks` additionally pins the line-ending flag, see there.)
    /// The cuts fall right after a "\n" in the common prefix and common suffix, so both texts stay split on
    /// the same line boundaries; `keepAfter` is how many whole common lines to keep after the changed region.
    private static func trimmed(old: String, new: String, keepBefore: Int, keepAfter: Int)
        -> (old: String, new: String, bytes: Int, lines: Int, scalars: Int) {
        let a = Array(old.utf8), b = Array(new.utf8)
        var p = 0
        let minLen = min(a.count, b.count)
        while p < minLen, a[p] == b[p] { p += 1 }
        // Prefix: cut after the (newlines in prefix - keepBefore)-th newline.
        var newlines = 0
        for i in 0..<p where a[i] == 0x0A { newlines += 1 }
        let cutLines = max(0, newlines - keepBefore)
        var cut = 0, seen = 0
        if cutLines > 0 {
            for i in 0..<p where a[i] == 0x0A {
                seen += 1
                if seen == cutLines { cut = i + 1; break }
            }
        }
        // Suffix zone: bytes common at the end that do not overlap the common prefix.
        var s = 0
        while s < minLen - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        var drop = 0
        var count = 0
        for i in (a.count - s)..<a.count where a[i] == 0x0A {
            count += 1
            if count == keepAfter + 1 { drop = a.count - (i + 1); break }
        }
        var scalars = 0
        for i in 0..<cut where a[i] & 0xC0 != 0x80 { scalars += 1 }
        func slice(_ x: [UInt8]) -> String { String(decoding: x[cut..<(x.count - drop)], as: UTF8.self) }
        return (slice(a), slice(b), cut, cutLines, scalars)
    }

    /// Character-level operations turning `old` into `new`, at scalar offsets in `old`. Trims the common
    /// prefix and suffix (at line boundaries) before diffing; equal to `opsReference`.
    static func ops(old: String, new: String) -> [TextOp] {
        let t = trimmed(old: old, new: new, keepBefore: 0, keepAfter: 0)
        return opsReference(old: t.old, new: t.new).map { TextOp(start: $0.start + t.scalars, deleteCount: $0.deleteCount, insert: $0.insert) }
    }

    /// The untrimmed algorithm behind `ops`, kept callable so tests can check the trimmed path against it.
    static func opsReference(old: String, new: String) -> [TextOp] {
        let ou = lineUnits(old), nu = lineUnits(new)
        var ops: [TextOp] = []
        var line = 0, offset = 0   // offset = scalars before ou[line]
        for r in regions(old: ou, new: nu) {
            while line < r.old.lowerBound { offset += ou[line].unicodeScalars.count; line += 1 }
            let oldSlice = ou[r.old].joined().unicodeScalars.map { $0 }
            let newSlice = nu[r.new].joined().unicodeScalars.map { $0 }
            ops += charOps(old: oldSlice, new: newSlice, base: offset)
            offset += oldSlice.count; line = r.old.upperBound
        }
        return ops
    }

    /// Beyond this many comparisons a region is replaced wholesale instead of character-diffed.
    private static let maxCharDiffWork = 4_000_000

    static func charOps(old: [Unicode.Scalar], new: [Unicode.Scalar], base: Int) -> [TextOp] {
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let om = Array(old[p..<(old.count - s)]), nm = Array(new[p..<(new.count - s)])
        if om.isEmpty && nm.isEmpty { return [] }
        func text(_ x: [Unicode.Scalar]) -> String { String(String.UnicodeScalarView(x)) }
        if om.isEmpty || nm.isEmpty || om.count * nm.count > maxCharDiffWork {
            return [TextOp(start: base + p, deleteCount: om.count, insert: text(nm))]
        }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in nm.difference(from: om) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var ops: [TextOp] = []
        var cur: (start: Int, del: Int, ins: [Unicode.Scalar])?
        func flush() {
            if let c = cur { ops.append(TextOp(start: c.start, deleteCount: c.del, insert: text(c.ins))) }
            cur = nil
        }
        var i = 0, j = 0
        while i < om.count || j < nm.count {
            if i < om.count, removed.contains(i) {
                if cur == nil { cur = (base + p + i, 0, []) }
                cur!.del += 1; i += 1
            } else if j < nm.count, inserted.contains(j) {
                if cur == nil { cur = (base + p + i, 0, []) }
                cur!.ins.append(nm[j]); j += 1
            } else {
                flush(); i += 1; j += 1
            }
        }
        flush()
        return ops
    }

    /// Line hunks (context 3) as stored on records; trims common lines first so huge files stay cheap.
    static func hunks(old: String, new: String, context: Int = 3) -> [PatchHunk] {
        // `TextLines` strips the "\r" of a CRLF line only when the text's first line break is CRLF. Lines of the two
        // texts compare after that, so texts that disagree take the full path, and a trimmed slice (whose own first
        // break can differ from the whole text's) is split with the whole text's flag.
        let crlf = TextLines.detectsCRLF(Array(old.utf8))
        guard crlf == TextLines.detectsCRLF(Array(new.utf8)) else { return hunksReference(old: old, new: new, context: context) }
        if crlf { return crlfHunks(old: old, new: new, context: context) }
        let t = trimmed(old: old, new: new, keepBefore: context + 1, keepAfter: context + 1)
        return hunksReference(old: t.old, new: t.new, context: context, crlf: crlf).map {
            var h = $0
            h.oldStart += t.lines; h.newStart += t.lines
            return h
        }
    }

    /// `hunks` for two texts whose first line break is CRLF. `TextLines` drops the "\r" of every terminated line there,
    /// so "a\r\n" and "a\n" are the same line and the byte trim could stop short of where the reference does (which
    /// changes where an insertion among equal lines lands). This trims the common lines by those stripped contents,
    /// keeping `context` lines each side exactly as `hunksReference` does, then diffs the slices with the same flag.
    private static func crlfHunks(old: String, new: String, context: Int) -> [PatchHunk] {
        let a = Array(old.utf8), b = Array(new.utf8)
        // Content range of the line starting at `i` (terminator and a CRLF's "\r" excluded) and where the next starts.
        func forward(_ x: [UInt8], _ i: Int) -> (end: Int, next: Int) {
            var j = i
            while j < x.count, x[j] != 0x0A { j += 1 }
            if j == x.count { return (j, j) }
            return (j > i && x[j - 1] == 0x0D ? j - 1 : j, j + 1)
        }
        // The line that ends (terminator included) at `e`: its content range and start.
        func backward(_ x: [UInt8], _ e: Int) -> (start: Int, end: Int) {
            let terminated = x[e - 1] == 0x0A
            var end = terminated ? e - 1 : e
            var start = end
            while start > 0, x[start - 1] != 0x0A { start -= 1 }
            if terminated, end > start, x[end - 1] == 0x0D { end -= 1 }
            return (start, end)
        }
        func lineCount(_ x: [UInt8]) -> Int {
            var n = 0
            for byte in x where byte == 0x0A { n += 1 }
            return n + (x.isEmpty || x.last == 0x0A ? 0 : 1)
        }
        let na = lineCount(a), nb = lineCount(b)
        var ia = 0, ib = 0, p = 0
        while p < na, p < nb {
            let x = forward(a, ia), y = forward(b, ib)
            guard a[ia..<x.end].elementsEqual(b[ib..<y.end]) else { break }
            ia = x.next; ib = y.next; p += 1
        }
        var ea = a.count, eb = b.count, s = 0
        while s < na - p, s < nb - p {
            let x = backward(a, ea), y = backward(b, eb)
            guard a[x.start..<x.end].elementsEqual(b[y.start..<y.end]) else { break }
            ea = x.start; eb = y.start; s += 1
        }
        let lo = max(0, p - context), hi = max(0, s - context)
        var fa = 0, fb = 0
        for _ in 0..<lo { fa = forward(a, fa).next; fb = forward(b, fb).next }
        var ta = a.count, tb = b.count
        for _ in 0..<hi { ta = backward(a, ta).start; tb = backward(b, tb).start }
        let oldSlice = String(decoding: a[fa..<max(fa, ta)], as: UTF8.self), newSlice = String(decoding: b[fb..<max(fb, tb)], as: UTF8.self)
        return hunksReference(old: oldSlice, new: newSlice, context: context, crlf: true).map {
            var h = $0
            h.oldStart += lo; h.newStart += lo
            return h
        }
    }

    /// The untrimmed algorithm behind `hunks` (it only trims whole common lines), for equivalence tests.
    static func hunksReference(old: String, new: String, context: Int = 3, crlf: Bool? = nil) -> [PatchHunk] {
        let a = TextLines(old, crlf: crlf).lines, b = TextLines(new, crlf: crlf).lines
        var p = 0
        while p < a.count, p < b.count, same(a[p], b[p]) { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, same(a[a.count - 1 - s], b[b.count - 1 - s]) { s += 1 }
        let lo = max(0, p - context), hi = max(0, s - context)
        let am = Array(a[lo..<(a.count - hi)]), bm = Array(b[lo..<(b.count - hi)])
        var original: [String: String] = [:]
        for (k, v) in zip(keys(am), am) { original[k] = v }
        for (k, v) in zip(keys(bm), bm) { original[k] = v }
        return Patch.diff(old: keys(am), new: keys(bm), context: context).map {
            var h = $0
            h.oldStart += lo; h.newStart += lo
            h.lines = h.lines.map { line in String(line.first!) + (original[String(line.dropFirst())] ?? String(line.dropFirst())) }
            return h
        }
    }
}
