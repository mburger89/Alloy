import Foundation
import MetalUICodeBuffer

/// Another party's change near some lines.
public struct Overlap: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A live ledger edit (applied to the file).
        case active(UUID)
        /// A change another session announced at its PreToolUse and has not finished.
        case proposed(toolUseID: String)
        /// The user's unsaved typing in an open editor.
        case userTyping
    }
    public static let margin = 3

    public var other: Author
    public var kind: Kind
    /// The other party's lines (not the query's).
    /// Nil for the coarse "unsaved changes in this file" report (the edit log was lost).
    public var lines: ClosedRange<Int>?
    public var date: Date
    /// A compact `-old` / `+new` snippet (at most 20 lines), empty for unsaved typing.
    public var diff: String
}

/// Answers: before session X edits lines L of file F, who else changed those lines, or is about to?
///
/// This is a `@MainActor` class, not an actor. The ledger and the open documents live on the main actor, and a
/// query only reads them: it costs O(live edits in the file) once the file's line owners are cached (the cache
/// is keyed by the file ledger's version, so it is rebuilt only after the ledger changes; a rebuild is one
/// pass over the ledger's fragments). It never touches the disk, never diffs, and never reads the whole text.
/// A file Alloy holds neither in the ledger nor as an open buffer has nothing to report.
///
/// `path` everywhere is project-relative, the key `ProjectLedger.files` and `Workspace.documents` use. The
/// caller resolves hook paths with `ProjectLedger.relativePath(_:root:)`, which does file system lookups, so
/// it belongs off the hook's critical path or behind a cache.
@MainActor
public final class OverlapIndex {
    public typealias LedgerSource = @MainActor (String) -> FileLedger?
    public typealias DocumentSource = @MainActor (String) -> EditorDocument?

    private let ledgerFor: LedgerSource
    private let documentFor: DocumentSource
    private var proposals: [String: ProposedChange] = [:]
    private var owned: [String: (version: Int, runs: [UUID: [ClosedRange<Int>]])] = [:]

    private let now: @MainActor () -> Date
    /// How many times a file's line runs were rebuilt (a test reads it to see that a query skipped a file).
    private(set) var runBuilds = 0

    public init(ledger: @escaping LedgerSource, document: @escaping DocumentSource,
                now: @escaping @MainActor () -> Date = { Date() }) {
        ledgerFor = ledger; documentFor = document; self.now = now
    }

    /// Forget what is cached for `path`. Call it when a path's ledger is replaced rather than appended to.
    public func invalidate(path: String) { owned[path] = nil; typing[path] = nil }

    // MARK: Proposals

    /// Registers (or replaces) a session's pending change, keyed by its tool call id.
    public func propose(_ change: ProposedChange) { proposals[change.toolUseID] = change }

    /// Drops a proposal: the tool finished (PostToolUse or tool_result) or failed.
    public func resolve(toolUseID: String) { proposals[toolUseID] = nil }

    /// Drops every proposal of a session that ended.
    public func dropProposals(session: UUID) { proposals = proposals.filter { $0.value.session != session } }

    // MARK: Query

    /// Backstop only: a proposal normally ends with `resolve` or `dropProposals(session:)`. A long permission
    /// prompt or a slow Write must not lose its proposal, so this is an hour, just so a leak cannot live forever.
    public static let proposalLifetime: TimeInterval = 3_600

    /// Everything other than `session` that touches `range` or lies within `Overlap.margin` lines of it.
    public func overlaps(for session: UUID, range: LineRange) -> [Overlap] {
        var out: [Overlap] = []
        func near(_ other: ClosedRange<Int>) -> Bool {
            other.lowerBound <= range.lines.upperBound + Overlap.margin
                && range.lines.lowerBound <= other.upperBound + Overlap.margin
        }

        var applied = Set<String>()
        if let file = ledgerFor(range.path) {
            let runs = lineRuns(path: range.path, file: file)
            for e in file.edits where e.state == .live {
                if let id = e.toolUseID { applied.insert(id) }
                if case .session(let s) = e.author, s == session { continue }
                if e.author == .outside { continue }
                for r in runs[e.id] ?? [] where near(r) {
                    out.append(Overlap(other: e.author, kind: .active(e.id), lines: r, date: e.date,
                                       diff: Self.diff(of: e)))
                }
            }
        }

        let cutoff = now().addingTimeInterval(-Self.proposalLifetime)
        for (id, p) in proposals where p.date < cutoff { proposals[id] = nil }
        for p in proposals.values where p.range.path == range.path && p.session != session && !applied.contains(p.toolUseID) {
            for r in p.ranges where near(r) {
                out.append(Overlap(other: .session(p.session), kind: .proposed(toolUseID: p.toolUseID), lines: r,
                                   date: p.date, diff: p.diff))
            }
        }

        switch userTyping(path: range.path) {
        case .none: break
        case .lost: out.append(Overlap(other: .user, kind: .userTyping, lines: nil, date: now(), diff: ""))
        case .lines(let runs):
            for r in runs where near(r) { out.append(Overlap(other: .user, kind: .userTyping, lines: r, date: now(), diff: "")) }
        }
        return out.sorted { ($0.date, $0.lines?.lowerBound ?? 0) < ($1.date, $1.lines?.lowerBound ?? 0) }
    }

    // MARK: Active edits

    /// Where the live edit `edit` of `path` sits in the current text (empty when it is not live or not found).
    func runs(path: String, edit: UUID) -> [ClosedRange<Int>] {
        guard let file = ledgerFor(path) else { return [] }
        return lineRuns(path: path, file: file)[edit] ?? []
    }

    /// Whether two line runs touch or lie within `Overlap.margin` lines of each other.
    static func near(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> Bool {
        a.lowerBound <= b.upperBound + Overlap.margin && b.lowerBound <= a.upperBound + Overlap.margin
    }

    /// Where `session`'s live edits sit in `path` now, as sorted, non-touching line runs. Empty when it has none.
    public func liveRuns(path: String, session: UUID) -> [ClosedRange<Int>] {
        guard let file = ledgerFor(path) else { return [] }
        let runs = lineRuns(path: path, file: file)
        var all: [ClosedRange<Int>] = []
        for e in file.edits where e.state == .live && e.author == .session(session) { all += runs[e.id] ?? [] }
        all.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Int>] = []
        for r in all {
            if let l = merged.last, r.lowerBound <= l.upperBound + 1 {
                merged[merged.count - 1] = l.lowerBound...max(l.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    /// Each live edit's current line runs, from the ledger's own attribution (identity-based, so lines that
    /// moved because earlier lines changed are found where they are now), plus a two-line anchor
    /// (`k...k+1`) at every place its deletions sit that its inserted lines do not already cover.
    private func lineRuns(path: String, file: FileLedger) -> [UUID: [ClosedRange<Int>]] {
        let version = file.version
        if let hit = owned[path], hit.version == version { return hit.runs }
        runBuilds += 1
        var runs: [UUID: [ClosedRange<Int>]] = [:]
        for (i, owner) in file.lineOwners().enumerated() {
            guard let owner else { continue }
            let line = i + 1
            if let last = runs[owner]?.last, last.upperBound == line - 1 {
                runs[owner]![runs[owner]!.count - 1] = last.lowerBound...line
            } else {
                runs[owner, default: []].append(line...line)
            }
        }
        for (edit, anchors) in file.deletionAnchors() {
            var mine = runs[edit] ?? []
            for k in anchors where !mine.contains(where: { $0.contains(k) }) { mine.append(k...(k + 1)) }
            mine.sort { $0.lowerBound < $1.lowerBound }
            var merged: [ClosedRange<Int>] = []
            for r in mine {
                if let l = merged.last, r.lowerBound <= l.upperBound + 1 {
                    merged[merged.count - 1] = l.lowerBound...max(l.upperBound, r.upperBound)
                } else { merged.append(r) }
            }
            runs[edit] = merged
        }
        owned[path] = (version, runs)
        return runs
    }

    private static func diff(of e: EditRecord) -> String {
        var old: [String] = [], new: [String] = []
        for h in e.hunks { for l in h.lines {
            if l.hasPrefix("-") { old.append(String(l.dropFirst())) } else if l.hasPrefix("+") { new.append(String(l.dropFirst())) }
        } }
        return ProposedChange.compactDiff(old: old, new: new)
    }

    // MARK: Unsaved typing

    private enum UserTyping { case none, lost, lines([ClosedRange<Int>]) }

    private struct Typing {
        var document: UUID
        var savedVersion: UInt64
        var processed = 0
        var regions = TypingRegions()
        var lines: [ClosedRange<Int>] = []
    }

    private var typing: [String: Typing] = [:]

    /// The saved-text line runs the user's unsaved edits occupy. The edit log feeds a running list of touched
    /// ranges, so only events drained since the last query are applied; with no new events the answer is cached.
    /// `.lost` when the log no longer reaches back to the save: the file is dirty, but where is unknown.
    private func userTyping(path: String) -> UserTyping {
        guard let doc = documentFor(path), doc.isDirty else { typing[path] = nil; return .none }
        guard let log = doc.editsSinceSave() else { typing[path] = nil; return .lost }
        var t = typing[path]
        if t == nil || t!.document != doc.id || t!.savedVersion != doc.savedVersion || t!.processed > log.count {
            t = Typing(document: doc.id, savedVersion: doc.savedVersion)
        }
        if t!.processed < log.count {
            for e in log[t!.processed...] { t!.regions.apply(range: e.range, newLength: e.newText.utf8.count) }
            t!.processed = log.count
            t!.lines = Self.lines(of: t!.regions, in: doc.savedSnapshot)
        }
        typing[path] = t
        return .lines(t!.lines)
    }

    private static func lines(of regions: TypingRegions, in saved: CodeSnapshot) -> [ClosedRange<Int>] {
        let count = saved.utf8Count
        var out: [ClosedRange<Int>] = []
        for r in regions.regions {
            let lo = min(r.s.lowerBound, count), hi = min(r.s.upperBound, count)
            let first = saved.point(at: lo).row + 1
            let last = hi > lo ? saved.point(at: hi - 1).row + 1 : first
            let span = first...max(first, last)
            if let l = out.last, span.lowerBound <= l.upperBound + 1 {
                out[out.count - 1] = l.lowerBound...max(l.upperBound, span.upperBound)
            } else { out.append(span) }
        }
        return out
    }
}

/// The ranges the user's unsaved edits touch, as pairs: where each sits in the buffer now and where the text it
/// replaced sat in the saved text. Kept sorted and disjoint (edits that touch merge), so applying an event is a
/// binary search plus a shift of the regions after it, with no replay of earlier events.
struct TypingRegions {
    struct Region: Equatable { var b: Range<Int>; var s: Range<Int> }
    private(set) var regions: [Region] = []

    /// One buffer event: `range` (UTF-8 offsets in the buffer before the event) became `newLength` bytes.
    mutating func apply(range r: Range<Int>, newLength: Int) {
        let delta = newLength - r.count
        var lo = 0, hi = regions.count
        while lo < hi {   // first region whose end reaches the edit
            let mid = (lo + hi) / 2
            if regions[mid].b.upperBound < r.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        let i = lo
        var j = i
        while j < regions.count, regions[j].b.lowerBound <= r.upperBound { j += 1 }
        let before = i > 0 ? regions[i - 1].b.upperBound - regions[i - 1].s.upperBound : 0
        let merged: Region
        if i == j {
            merged = Region(b: r.lowerBound..<(r.lowerBound + newLength), s: (r.lowerBound - before)..<(r.upperBound - before))
        } else {
            let first = regions[i], last = regions[j - 1]
            let sLo = r.lowerBound < first.b.lowerBound ? r.lowerBound - before : first.s.lowerBound
            let sHi = r.upperBound > last.b.upperBound ? r.upperBound - (last.b.upperBound - last.s.upperBound) : last.s.upperBound
            let bLo = min(r.lowerBound, first.b.lowerBound), bHi = max(r.upperBound, last.b.upperBound)
            merged = Region(b: bLo..<(bHi + delta), s: sLo..<sHi)
        }
        regions.replaceSubrange(i..<j, with: [merged])
        if delta != 0 {
            for k in (i + 1)..<regions.count {
                regions[k].b = (regions[k].b.lowerBound + delta)..<(regions[k].b.upperBound + delta)
            }
        }
    }
}
