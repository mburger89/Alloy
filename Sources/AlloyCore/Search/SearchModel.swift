import Foundation
import MetalUICodeBuffer
import Observation

/// One file's results in the list. Identified by the engine's index (stable while the list is edited).
public struct SearchGroup: Identifiable, Sendable, Equatable {
    public var index: Int
    public var path: String
    public var matches: [SearchMatch]
    public var isUTF8: Bool

    public var id: Int { index }

    public init(index: Int, path: String, matches: [SearchMatch], isUTF8: Bool) {
        self.index = index; self.path = path; self.matches = matches; self.isUTF8 = isUTF8
    }

    init(_ file: SearchFileResult) {
        self.init(index: file.index, path: file.path, matches: file.matches, isUTF8: file.isUTF8)
    }

    /// The file name and the folder it is in ("" at the project root).
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// A selected preview: positions in `SearchModel.groups` and in that group's `matches`.
public struct SearchSelection: Equatable, Sendable {
    public var file: Int
    public var line: Int
    public init(file: Int, line: Int) { self.file = file; self.line = line }
}

/// What a replaced file looks like in the review list.
public enum ReviewState: Equatable, Sendable {
    case applied
    case skipped(String)
    case kept
    case reverted
    /// Revert refused (the file was edited since); the replace stays.
    case conflict(String)
}

public struct ReviewRow: Identifiable, Equatable, Sendable {
    public var path: String
    public var diffCount: Int
    public var state: ReviewState
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// The review of one replace: its files and a one-line summary, with Keep All / Revert All acting on `group`.
public struct ReplaceReview: Equatable, Sendable {
    public var group: UUID
    public var rows: [ReviewRow]
    public var summary: String
    /// Keep All / Revert All apply only while some file is still applied.
    public var isOpen: Bool { rows.contains { $0.state == .applied } }
}

/// The project search's UI-facing state: the query being edited, the streamed results, the summary, the selection
/// and the stale marker. Only `SearchView` (AlloyKit) reads the observed properties. A run starts only from a user
/// action (typing after a debounce, Return, an option change, Re-run, showing the tab with stale results); file
/// events and saves only flip `isStale`, once.
@MainActor @Observable
public final class SearchModel {
    // MARK: Observed state

    /// The query the Search tab edits. Written by `setQuery(_:)`; the restore seeds it directly.
    public private(set) var query = SearchQuery()
    /// The replacement text.
    public var replacement = ""
    /// Whether the globs disclosure is open.
    public var globsOpen = false
    /// File groups in index order, appended batch by batch.
    public private(set) var groups: [SearchGroup] = []
    /// Matches in `groups` (kept in step with it).
    public private(set) var matchCount = 0
    /// The facts of the last finished run; nil while running or before any run.
    public private(set) var facts: SearchSummaryFacts?
    /// A message for a query that cannot run (an invalid regex); nil otherwise.
    public private(set) var error: String?
    public private(set) var isRunning = false
    /// The run was cancelled before it finished: `groups` holds only what was found so far.
    public private(set) var isStopped = false
    /// Finished results the files may have outgrown (a save or an outside change since).
    public private(set) var isStale = false
    public var selection: SearchSelection?
    /// The replace just made, shown in place of the results; nil when there is none.
    public private(set) var review: ReplaceReview?
    /// A replace is running (its buttons are disabled).
    public private(set) var isReplacing = false
    /// The match count of a Replace All waiting for confirmation; nil when none is.
    public private(set) var pendingConfirm: Int?
    /// Bumped to ask the query field for focus.
    public private(set) var focusToken = 0

    // MARK: Not observed

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// The query was edited after the last run started (a debounce is pending or typing does not run).
    @ObservationIgnored private var queryDirty = false
    /// True from the finished batch until the first `noteChanged`: the O(1) guard every save and file event hits.
    @ObservationIgnored private var staleArmed = false
    /// A change arrived while the run was still going; the finished batch then marks the results stale at once.
    @ObservationIgnored private var changedWhileRunning = false
    /// Whether the last scan of the file index hit its path limit; typing then runs nothing, only Return does.
    @ObservationIgnored var indexTruncated = false
    /// Test hooks: batches that landed, runs started, and the scan gate each worker awaits before reading a path.
    @ObservationIgnored public private(set) var landedCount = 0
    @ObservationIgnored public private(set) var runCount = 0
    @ObservationIgnored var scanGate: (@Sendable (String) async -> Void)?
    @ObservationIgnored var limits = SearchLimits()

    public static let debounce = 0.2
    /// Replace All above this many matches asks first.
    public static let confirmThreshold = 1_000

    public init() {}

    func attach(_ workspace: Workspace) { self.workspace = workspace }

    /// Seeds the query from the saved state; nil keeps the empty query.
    func restore(_ saved: SearchQuery?) {
        guard let saved else { return }
        query = saved
        globsOpen = !saved.include.isEmpty || !saved.exclude.isEmpty
    }

    // MARK: Query

    /// The field, a toggle or a glob field changed. Text and glob edits re-run after 200 ms (never when the index is
    /// truncated); an option toggle re-runs at once; an empty query clears.
    public func setQuery(_ new: SearchQuery) {
        guard new != query else { return }
        let old = query
        query = new
        debounceTask?.cancel(); debounceTask = nil
        if new.text.isEmpty { start(); return }
        if new.text == old.text, new.include == old.include, new.exclude == old.exclude { start(); return }
        queryDirty = true
        guard !isIndexTruncated, let workspace else { return }
        let clock = workspace.autosaveClock
        // The deadline is taken now, so a manual clock advanced before the timer task runs still fires it.
        let deadline = clock.now + Self.debounce
        debounceTask = workspace.track { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.debounceTask = nil
            self.start()
        }
    }

    private var isIndexTruncated: Bool { indexTruncated || (workspace?.fileTree.snapshot.truncated ?? false) }

    /// Return in a field: runs now.
    public func submit() {
        debounceTask?.cancel(); debounceTask = nil
        start()
    }

    /// Return in the query field: opens the selected preview when the results are for the query as typed, else runs.
    public func submitOrOpen() {
        if selection != nil, !queryDirty, !isRunning { openSelected() } else { submit() }
    }

    /// The Re-run link and showing the tab with stale results.
    public func rerun() { submit() }

    /// Called when the Search tab shows: stale results re-run.
    public func tabShown() { if isStale { rerun() } }

    /// Sets the query to `text` (the focused editor's selection) and runs it; the options stay.
    func seed(_ text: String) {
        var next = query
        next.text = text
        debounceTask?.cancel(); debounceTask = nil
        guard next != query else { focusToken += 1; return }
        query = next
        focusToken += 1
        start()
    }

    func requestFocus() { focusToken += 1 }

    /// Escape in the field and project close: stops the run and the pending debounce. Results found so far stay.
    public func cancel() {
        generation += 1
        debounceTask?.cancel(); debounceTask = nil
        runTask?.cancel(); runTask = nil
        if isRunning { isRunning = false; isStopped = true; facts = nil; staleArmed = false; changedWhileRunning = false }
    }

    public func shutdown() {
        cancel()
    }

    // MARK: Running

    private func clearResults() {
        groups = []; matchCount = 0; facts = nil; selection = nil
        isStale = false; staleArmed = false; isStopped = false; changedWhileRunning = false
    }

    private func start() {
        generation += 1
        let ticket = generation
        queryDirty = false
        runTask?.cancel(); runTask = nil
        guard let workspace, !workspace.isShuttingDown else { return }
        guard !query.text.isEmpty else {
            clearResults(); error = nil; isRunning = false; review = nil; pendingConfirm = nil
            return
        }
        do { _ = try query.compile() } catch {
            clearResults(); isRunning = false
            self.error = "Invalid regular expression"
            return
        }
        error = nil
        clearResults()
        review = nil; pendingConfirm = nil
        isRunning = true
        runCount += 1
        workspace.lastSearch = query
        workspace.scheduleUIStateWrite()
        runTask = workspace.track { [weak self] in await self?.execute(ticket) }
    }

    private func execute(_ ticket: Int) async {
        guard let workspace else { return }
        if workspace.fileIndexStale {
            workspace.fileIndexStale = false
            await workspace.fileIndex.refresh()
            guard ticket == generation else { return }
        }
        let paths = await workspace.fileIndex.paths()
        let truncated = await workspace.fileIndex.isTruncated
        guard ticket == generation else { return }
        indexTruncated = truncated
        var overlays: [String: CodeSnapshot] = [:]
        for doc in workspace.documents.values { overlays[doc.path] = doc.buffer.snapshot() }
        let engine = SearchEngine(root: workspace.projectRoot, limits: limits)
        await engine.setScanGate(scanGate)
        let stream = await engine.run(query, paths: paths, indexTruncated: truncated, overlays: overlays,
                                      extraExclude: workspace.settings.searchExcludes,
                                      maxResults: workspace.settings.searchMaxResults)
        for await batch in stream {
            guard ticket == generation, !Task.isCancelled else { return }
            if !batch.files.isEmpty {
                groups.append(contentsOf: batch.files.map(SearchGroup.init))
                matchCount += batch.files.reduce(0) { $0 + $1.matches.count }
            }
            if let finished = batch.finished {
                facts = finished
                isRunning = false
                if changedWhileRunning { changedWhileRunning = false; isStale = true } else { staleArmed = true }
            }
            landedCount += 1
        }
        // The stream ended without a finished batch while this run is current: show what landed as stopped.
        if ticket == generation, isRunning { isRunning = false; isStopped = true }
    }

    // MARK: Stale

    /// A file was saved or changed outside. Does nothing unless finished results are not yet marked stale; the first
    /// call after a run flips `isStale` once, every later call returns at the guard.
    public func noteChanged(_ path: String) {
        if isRunning { changedWhileRunning = true; return }
        guard staleArmed else { return }
        staleArmed = false
        isStale = true
    }

    // MARK: Results

    /// Removes one preview (or, with `line == nil`, a whole file) from the result set.
    public func dismiss(file: Int, line: Int? = nil) {
        guard groups.indices.contains(file) else { return }
        if let line {
            guard groups[file].matches.indices.contains(line) else { return }
            groups[file].matches.remove(at: line)
            matchCount -= 1
            if groups[file].matches.isEmpty { groups.remove(at: file) }
        } else {
            matchCount -= groups[file].matches.count
            groups.remove(at: file)
        }
        selection = nil
    }

    /// Flattened (file, line) positions in display order.
    private var flat: [SearchSelection] {
        var out: [SearchSelection] = []
        for (f, g) in groups.enumerated() { for l in g.matches.indices { out.append(SearchSelection(file: f, line: l)) } }
        return out
    }

    /// Moves the selection one preview, stopping at the ends (↑ / ↓ in the list).
    public func moveSelection(_ delta: Int) {
        let all = flat
        guard !all.isEmpty else { return }
        guard let current = selection, let i = all.firstIndex(of: current) else {
            selection = delta >= 0 ? all.first : all.last
            return
        }
        selection = all[min(max(i + delta, 0), all.count - 1)]
    }

    /// Go > Next / Previous Result: moves the selection, wrapping at the ends, and opens it.
    public func step(_ delta: Int) {
        let all = flat
        guard !all.isEmpty else { return }
        if let current = selection, let i = all.firstIndex(of: current) {
            selection = all[((i + delta) % all.count + all.count) % all.count]
        } else {
            selection = delta >= 0 ? all.first : all.last
        }
        openSelected()
    }

    public func openSelected(in pane: PaneID? = nil) {
        guard let selection else { return }
        open(file: selection.file, line: selection.line, in: pane)
    }

    /// Opens the file of a preview in the focused group (or `pane`) with the match selected.
    public func open(file: Int, line: Int, in pane: PaneID? = nil) {
        guard let workspace, groups.indices.contains(file), groups[file].matches.indices.contains(line) else { return }
        selection = SearchSelection(file: file, line: line)
        let path = groups[file].path, match = groups[file].matches[line]
        workspace.track { [weak workspace] in
            await workspace?.open(path, selecting: { Self.range(of: match, in: $0) }, in: pane)
        }
    }

    /// The range to select for `match` in the loaded text: the stored byte range when the text still holds the same
    /// bytes there (on scalar boundaries), else the start of the stored line.
    nonisolated static func range(of match: SearchMatch, in snap: CodeSnapshot) -> Range<Int> {
        let r = match.range
        if r.lowerBound >= 0, r.upperBound <= snap.utf8Count, !r.isEmpty {
            let preview = Array(match.preview.utf8)
            let expected = match.previewMatch.upperBound <= preview.count ? Array(preview[match.previewMatch]) : []
            let actual = snap.utf8(in: r)
            let sameBytes = !expected.isEmpty && actual.starts(with: expected)
            func continuation(_ offset: Int) -> Bool {
                guard offset < snap.utf8Count, let b = snap.utf8(in: offset..<(offset + 1)).first else { return false }
                return b & 0xC0 == 0x80
            }
            if sameBytes, !continuation(r.lowerBound), !continuation(r.upperBound) { return r }
        }
        let row = min(max(match.line - 1, 0), max(snap.lineCount - 1, 0))
        let start = snap.lineRange(row).lowerBound
        return start..<start
    }

    // MARK: Replace

    /// Replace needs a finished, current result set for the query as typed.
    public var canReplace: Bool {
        !isRunning && !isStale && !isStopped && !isReplacing && error == nil && facts != nil && !queryDirty
            && !groups.isEmpty && review == nil
    }

    private func plan(for files: [SearchGroup]) -> ReplacePlan {
        ReplacePlan(files: files.map { ReplaceFile(path: $0.path, matches: $0.matches) }, query: query, template: replacement)
    }

    /// Replace All: applies at once up to 1,000 matches, otherwise waits for `confirmReplaceAll()`.
    public func replaceAll() {
        guard canReplace, pendingConfirm == nil else { return }
        if matchCount > Self.confirmThreshold { pendingConfirm = matchCount; return }
        perform(plan(for: groups))
    }

    public func confirmReplaceAll() {
        guard pendingConfirm != nil else { return }
        pendingConfirm = nil
        guard canReplace else { return }
        perform(plan(for: groups))
    }

    public func cancelConfirm() { pendingConfirm = nil }

    /// The confirmation text for the pending Replace All.
    public var confirmMessage: String? {
        pendingConfirm.map { "Replace \(Self.grouped($0)) matches in \(Self.files(groups.count))?" }
    }

    /// Replaces every match of one file (a position in `groups`).
    public func replace(file: Int) {
        guard canReplace, groups.indices.contains(file) else { return }
        perform(plan(for: [groups[file]]))
    }

    /// Replaces one match.
    public func replace(file: Int, line: Int) {
        guard canReplace, groups.indices.contains(file), groups[file].matches.indices.contains(line) else { return }
        var one = groups[file]
        one.matches = [one.matches[line]]
        perform(plan(for: [one]))
    }

    private func perform(_ plan: ReplacePlan) {
        guard let workspace else { return }
        isReplacing = true
        workspace.track { [weak self, weak workspace] in
            guard let workspace else { return }
            let report = await workspace.replace(plan)
            self?.finishReplace(report, in: workspace)
        }
    }

    private func finishReplace(_ report: ReplaceReport, in workspace: Workspace) {
        isReplacing = false
        var rows: [ReviewRow] = []
        for (path, outcome) in report.perFile {
            switch outcome {
            case .applied(let n):
                // Listed once its tagged edit exists; a save still merging a disk change lists nothing yet.
                if workspace.hasEdit(group: report.group, path: path) { rows.append(ReviewRow(path: path, diffCount: n, state: .applied)) }
            case .skipped(let reason):
                rows.append(ReviewRow(path: path, diffCount: 0, state: .skipped(reason)))
            }
        }
        var review = ReplaceReview(group: report.group, rows: rows, summary: "")
        review.summary = Self.replaceSummary(review)
        self.review = review
    }

    static func replaceSummary(_ review: ReplaceReview) -> String {
        let applied = review.rows.filter { $0.state == .applied }
        let matches = applied.reduce(0) { $0 + $1.diffCount }
        var parts = applied.isEmpty ? [] : ["Replaced \(grouped(matches)) \(matches == 1 ? "match" : "matches") in \(files(applied.count))"]
        let stale = review.rows.filter {
            if case .skipped(let r) = $0.state { return r == "changed since search" || r == "changed during replace" }
            return false
        }.count
        let other = review.rows.filter { if case .skipped = $0.state { return true } else { return false } }.count - stale
        if stale > 0 { parts.append("\(files(stale)) changed since search; re-run") }
        if other > 0 { parts.append("\(files(other)) skipped (see each file)") }
        return parts.joined(separator: " · ")
    }

    /// Leaves the review and shows the (now stale) results again.
    public func dismissReview() { review = nil }

    public func keepAll() {
        guard let workspace, var review, review.isOpen, !isReplacing else { return }
        isReplacing = true
        workspace.track { [weak self, weak workspace] in
            await workspace?.keepAll(group: review.group)
            guard let self else { return }
            isReplacing = false
            for i in review.rows.indices where review.rows[i].state == .applied { review.rows[i].state = .kept }
            let kept = review.rows.filter { $0.state == .kept }.count
            review.summary = "Kept \(Self.files(kept))"
            self.review = review
        }
    }

    public func revertAll() {
        guard let workspace, var review, review.isOpen, !isReplacing else { return }
        isReplacing = true
        workspace.track { [weak self, weak workspace] in
            guard let workspace else { return }
            let results = await workspace.revertAll(group: review.group)
            guard let self else { return }
            isReplacing = false
            let total = review.rows.filter { $0.state == .applied }.count
            for (path, outcome) in results {
                guard let i = review.rows.firstIndex(where: { $0.path == path }) else { continue }
                switch outcome {
                case .reverted: review.rows[i].state = .reverted
                case .conflict(let reason): review.rows[i].state = .conflict(reason)
                }
            }
            let reverted = review.rows.filter { $0.state == .reverted }.count
            let kept = review.rows.filter { if case .conflict = $0.state { return true } else { return false } }.count
            review.summary = kept == 0 ? "Reverted \(Self.files(reverted))"
                : "Reverted \(reverted) of \(Self.files(total)); \(kept) kept because \(kept == 1 ? "it was" : "they were") edited since (see each file)"
            self.review = review
        }
    }

    // MARK: Summary

    /// "1,204 results in 87 files", with "searching…" while running and a note for each cap, skip and truncation.
    public var summary: String {
        if error != nil { return "" }
        var parts: [String] = []
        if isRunning {
            parts.append(matchCount > 0 ? "\(Self.grouped(matchCount)) \(matchCount == 1 ? "result" : "results") in \(Self.files(groups.count))" : "")
            parts.append("searching…")
        } else if isStopped {
            parts.append(matchCount > 0 ? "\(Self.grouped(matchCount)) \(matchCount == 1 ? "result" : "results") so far (stopped)" : "Stopped")
        } else if let facts {
            if facts.onlyEmptyMatches {
                parts.append("Regex matches only empty text")
            } else if facts.cappedMatches || facts.cappedFiles {
                parts.append("\(Self.grouped(max(matchCount, facts.totalMatches)))+ results, refine the query")
            } else if groups.isEmpty {
                parts.append("No results")
            } else {
                parts.append("\(Self.grouped(matchCount)) \(matchCount == 1 ? "result" : "results") in \(Self.files(groups.count))")
            }
            if facts.indexTruncated { parts.append("partial: index truncated") }
            if facts.skipped > 0 { parts.append("\(Self.files(facts.skipped)) skipped (binary, large or slow)") }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func files(_ n: Int) -> String { "\(grouped(n)) \(n == 1 ? "file" : "files")" }

    /// `1204` -> "1,204", independent of the locale.
    static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, c) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}
