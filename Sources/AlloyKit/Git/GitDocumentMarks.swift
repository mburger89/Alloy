import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer
import Observation

/// What one open view of a tracked file shows in its gutter: the hunks of its buffer against the HEAD blob, kept as
/// the `git` decoration owner. The coordinator owns one per `OpenDocumentView` (weakly bound to the view) and asks it
/// to recompute on a save, an outside change, a HEAD change, a presentation or settings change, and (with `liveMarks`
/// on) after a typing pause. Typing alone costs nothing here: MetalUI carries the marks through edits.
@MainActor
final class GitDocumentMarks {
    private(set) weak var view: OpenDocumentView?
    private(set) weak var coordinator: GitCoordinator?
    let path: String

    /// The hunks last applied, as of `appliedVersion`.
    private(set) var hunks: [GitHunk] = []
    private(set) var tags: [UInt64: GitHunk] = [:]
    private(set) var appliedVersion: UInt64 = 0
    private var appliedRowCount = 0
    /// The HEAD blob text the hunks are against; nil when the file has no marks.
    private(set) var baseText: String?
    private var baseOID: String?
    private var showing = false
    /// Whether git marks can show for this document: a HEAD blob was found while marks are on and the view is plain.
    /// The code view reserves its change lane for as long as this holds, so the first hunk never shifts the text.
    /// It changes only when a recompute finishes or the marks clear, never on typing.
    private(set) var laneReserved = false {
        didSet { if laneReserved != oldValue { view?.gitLaneReserved = laneReserved } }
    }
    /// Whether git decorations are in the view's gutter now.
    var isShowing: Bool { showing }
    private var generation = 0
    private var lastMode: Presentation?
    private var liveTask: Task<Void, Never>?

    /// Observability for tests.
    private(set) var recomputeCount = 0
    private(set) var applyCount = 0
    /// Whether the last diff ran off the main thread.
    private(set) var lastDiffOffMain: Bool?
    /// A test hook awaited inside the detached diff.
    var diffGate: (@Sendable () async -> Void)?

    static let liveIdle = 0.75

    init(view: OpenDocumentView, coordinator: GitCoordinator) {
        self.view = view
        self.coordinator = coordinator
        self.path = view.document.path
    }

    // MARK: Triggers

    /// The view's presentation was seen; a change recomputes (a plain view shows marks, the others clear them).
    func presentationSeen(_ mode: Presentation) {
        guard mode != lastMode else { return }
        lastMode = mode
        recompute()
    }

    /// The buffer was edited. Only an enabled `liveMarks` does anything: restart the idle timer.
    func typed() {
        guard let coordinator, coordinator.liveMarksEnabled, let clock = coordinator.clock else { return }
        liveTask?.cancel()
        let deadline = clock.now + Self.liveIdle
        liveTask = Task { @MainActor [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            // A cancelled timer (marks off, or a recompute that replaced it) must not fire even if the clock returned normally.
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    func teardown() {
        generation += 1
        liveTask?.cancel(); liveTask = nil
        if let view, showing { GitGutterMarks.clear(view.decorations) }
        showing = false
        laneReserved = false
        hunks = []; tags = [:]
    }

    /// Recomputes the marks from the buffer as it is now.
    func recompute() {
        guard let view, !view.closed, let coordinator else { return }
        generation += 1
        let gen = generation
        liveTask?.cancel(); liveTask = nil
        guard coordinator.marksEnabled, view.currentPresentation == .plain else { clearMarks(); return }
        let snapshot = view.document.buffer.snapshot()
        guard snapshot.utf8Count <= GitGutterMarks.sizeLimit else { clearMarks(); return }
        recomputeCount += 1
        let service = coordinator.service, path = path, gate = diffGate
        Task { [weak self] in
            guard let oid = await service.headBlobOID(path: path), let base = await service.headText(oid: oid) else {
                self?.finish(gen, nil); return
            }
            let (found, offMain) = await Task.detached { () -> ([GitHunk], Bool) in
                await gate?()
                return Self.diff(base: base, snapshot: snapshot)
            }.value
            self?.finish(gen, (oid, base, found, snapshot, offMain))
        }
    }

    /// The diff, and whether it ran off the main thread. Never called on the main actor.
    nonisolated static func diff(base: String, snapshot: CodeSnapshot) -> ([GitHunk], Bool) {
        let offMain = !Thread.isMainThread
        return (GitHunks.compute(base: base, buffer: snapshot.text), offMain)
    }

    private func finish(_ gen: Int, _ result: (oid: String, base: String, hunks: [GitHunk], snapshot: CodeSnapshot, offMain: Bool)?) {
        guard gen == generation, let view, !view.closed else { return }
        guard let result else { clearMarks(); return }
        lastDiffOffMain = result.offMain
        baseText = result.base
        laneReserved = true
        if showing, result.oid == baseOID, result.hunks == hunks { return }
        baseOID = result.oid
        hunks = result.hunks
        if hunks.isEmpty {
            if showing { GitGutterMarks.clear(view.decorations) }
            tags = [:]; showing = false; appliedVersion = result.snapshot.version; appliedRowCount = result.snapshot.lineCount
            return
        }
        GitGutterMarks.apply(hunks, tags: &tags, to: view.decorations, asOf: result.snapshot.version, rowCount: result.snapshot.lineCount)
        appliedVersion = result.snapshot.version
        appliedRowCount = result.snapshot.lineCount
        showing = true
        applyCount += 1
    }

    private func clearMarks() {
        if let view, showing { GitGutterMarks.clear(view.decorations) }
        showing = false
        laneReserved = false
        hunks = []; tags = [:]; baseText = nil; baseOID = nil
    }

    // MARK: Hunk rows now

    /// The first row of every hunk in the buffer as it is now, ascending: the applied rows carried through the edits
    /// made since (MetalUI's rule, from the view's row log).
    func currentMarkRows() -> [Int] {
        guard let view, !hunks.isEmpty else { return [] }
        view.services.drainEdits()
        let current = view.document.buffer.version
        var rows = hunks.map { min($0.markRow, max(0, appliedRowCount - 1)) }
        if appliedVersion != current {
            let probes = rows.map { CodeLineDecoration(lines: $0..<($0 + 1)) }
            if let moved = view.services.rowLog.move(lines: probes, rows: [], from: appliedVersion, rowCount: appliedRowCount, to: current) {
                rows = moved.lines.map(\.lines.lowerBound)
            }
        }
        return rows.sorted()
    }

    /// Moves the caret to the start of the next (`direction` > 0) or previous change, wrapping.
    @discardableResult
    func step(_ direction: Int) -> Bool {
        guard let view else { return false }
        let rows = currentMarkRows()
        guard !rows.isEmpty else { return false }
        let snapshot = view.document.buffer.snapshot()
        let selection = view.selection()
        let caretRow = snapshot.point(at: selection.primarySelection.head).row
        let target: Int
        if direction >= 0 {
            target = rows.first { $0 > caretRow } ?? rows[0]
        } else {
            target = rows.last { $0 < caretRow } ?? rows[rows.count - 1]
        }
        let at = snapshot.lineRange(min(target, snapshot.lineCount - 1)).lowerBound
        selection.select(at..<at, reveal: true)
        return true
    }
}
