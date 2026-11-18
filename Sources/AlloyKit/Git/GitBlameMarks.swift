import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer
import Observation

/// Puts blame runs into a view's `CodeDecorations` under the owner `git-blame` (priority -1, a name of its own so it
/// never replaces the git marks): a two-character initials marker at the first row of each run.
enum GitBlameMarks {
    static let owner = CodeDecorationOwner("git-blame", priority: -1)

    /// The width of the file-blame marker lane in characters: two initials, a space, up to three of age.
    static let laneWidth = 6

    /// The marker of each run (tag = its index in `runs` plus one), over the run's first row: initials and age
    /// (`AL 3d`), never wider than the lane.
    static func build(_ runs: [GitBlameRun], rowCount: Int, now: Date = Date()) -> [CodeLineDecoration] {
        var lines: [CodeLineDecoration] = []
        for (i, run) in runs.enumerated() where run.startLine < rowCount {
            let text = run.isUncommitted ? "\u{00B7}\u{00B7}"
                : String("\(run.initials.prefix(2)) \(GitGutterHelp.age(from: run.authorTime, now: now))".prefix(laneWidth))
            let color: Color = run.isUncommitted ? .mutedInk : .primary
            lines.append(CodeLineDecoration(lines: run.startLine..<(run.startLine + 1),
                                            gutterMarker: CodeGutterMarker(text, color: color), tag: UInt64(i + 1)))
        }
        return lines
    }

    /// Replaces the blame decorations; `version` is the buffer version `runs` describe (the saved one), which
    /// MetalUI maps forward through later edits.
    @MainActor
    static func apply(_ runs: [GitBlameRun], to decorations: CodeDecorations, asOf version: UInt64, rowCount: Int) {
        decorations.setLineDecorations(build(runs, rowCount: rowCount), asOf: version, owner: owner)
    }

    @MainActor
    static func clear(_ decorations: CodeDecorations) {
        decorations.removeDecorations(of: owner)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

/// One open blame popover. A new one per request, so nothing outlives it.
@MainActor @Observable
final class GitBlameSelection: Identifiable {
    @ObservationIgnored let id = UUID()
    /// The commit's run; nil for a row not in the saved file (typed since) or a file with no history.
    @ObservationIgnored let run: GitBlameRun?
    @ObservationIgnored let message: String?
    @ObservationIgnored let anchor: Range<Int>
    @ObservationIgnored let version: UInt64

    init(run: GitBlameRun?, message: String?, anchor: Range<Int>, version: UInt64) {
        self.run = run; self.message = message; self.anchor = anchor; self.version = version
    }
}

/// The per-view blame state. Only `fileOn` and `popover` are observed; the runs are read on demand.
@MainActor @Observable
final class GitBlameState {
    var fileOn = false
    var popover: GitBlameSelection?
    @ObservationIgnored var runs: [GitBlameRun] = []
    /// The buffer version and row count the runs are rows of (the saved text).
    @ObservationIgnored var version: UInt64 = 0
    @ObservationIgnored var rowCount = 0
    @ObservationIgnored var requested = false
    @ObservationIgnored var generation = 0
    /// Why there is nothing to show (an untracked file), for the popover.
    @ObservationIgnored var unavailable: String?

    func reset() {
        generation += 1
        fileOn = false; popover = nil; runs = []; requested = false; unavailable = nil
    }
}

struct GitBlamePopover: Component {
    let selection: GitBlameSelection

    var content: some ElementGroup {
        let selection = selection
        VStack(alignment: .leading, spacing: Pixels(4)) {
            if let run = selection.run, !run.isUncommitted {
                Text(verbatim: run.author).font(size: 12).accessibilityIdentifier("git-blame-author")
                Text(verbatim: "\(GitBlameMarks.dateText(run.authorTime))  \(run.shortHash)").font(family: "Menlo", size: 11)
                    .foregroundColor(.mutedInk).accessibilityIdentifier("git-blame-commit")
                Text(verbatim: run.summary).font(size: 12).lineLimit(3).accessibilityIdentifier("git-blame-summary")
            } else {
                Text(verbatim: selection.message ?? "Not committed yet").font(size: 12).accessibilityIdentifier("git-blame-summary")
            }
        }
        .padding(inset(10, 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-blame-popover")
    }
}

extension OpenDocumentView {
    /// A press on an initials marker: that run's popover.
    func openBlameRun(_ hit: CodeGutterHit) {
        guard let tag = hit.tag, tag >= 1, Int(tag) <= blame.runs.count else { return }
        let snapshot = document.buffer.snapshot()
        let row = max(0, min(hit.lines.lowerBound, snapshot.lineCount - 1))
        let run = blame.runs[Int(tag) - 1]
        blame.popover = GitBlameSelection(run: run, message: run.isUncommitted ? "Not committed yet" : nil,
                                          anchor: snapshot.lineRange(row), version: snapshot.version)
    }
}

extension GitCoordinator {
    /// Loads the blame of `view`'s file (cached by the service until a save or a HEAD change) and applies it if it is
    /// still wanted. Runs only on request.
    private func loadBlame(_ view: OpenDocumentView) async {
        let state = view.blame
        state.requested = true
        state.generation += 1
        let gen = state.generation
        let savedVersion = view.document.savedVersion
        let rowCount = view.document.savedSnapshot.lineCount
        let runs = await service.blame(path: view.document.path)
        guard gen == state.generation, !view.closed else { return }
        state.runs = runs
        state.version = savedVersion
        state.rowCount = rowCount
        state.unavailable = runs.isEmpty ? "No history for this file yet." : nil
        if state.fileOn {
            GitBlameMarks.apply(runs, to: view.decorations, asOf: savedVersion, rowCount: rowCount)
        }
    }

    /// Git > Toggle File Blame: initials at the first row of each run, with the marker lane reserved while on.
    func toggleFileBlame(in view: OpenDocumentView) {
        let state = view.blame
        if state.fileOn {
            state.generation += 1
            state.fileOn = false
            GitBlameMarks.clear(view.decorations)
            return
        }
        state.fileOn = true
        Task { await loadBlame(view) }
    }

    /// Git > Blame Line: a popover at the caret line.
    func blameLine(in view: OpenDocumentView) {
        let state = view.blame
        Task {
            if !state.requested { await loadBlame(view) }
            view.services.drainEdits()
            let snapshot = view.document.buffer.snapshot()
            let caret = snapshot.point(at: view.selection().primarySelection.head).row
            let anchor = snapshot.lineRange(min(caret, snapshot.lineCount - 1))
            let run = Self.run(at: caret, in: view)
            let message = run == nil ? (state.unavailable ?? "Not committed yet") : nil
            state.popover = GitBlameSelection(run: run, message: message, anchor: anchor, version: snapshot.version)
        }
    }

    /// The run that covers buffer row `row` as the buffer is now: the runs' rows (those of the saved text) carried
    /// through the edits since, so a row typed after the save belongs to no run.
    private static func run(at row: Int, in view: OpenDocumentView) -> GitBlameRun? {
        let state = view.blame
        guard !state.runs.isEmpty else { return nil }
        let probes = state.runs.enumerated().map {
            CodeLineDecoration(lines: $0.element.startLine..<($0.element.startLine + $0.element.count), tag: UInt64($0.offset))
        }
        guard let moved = view.services.rowLog.move(lines: probes, rows: [], from: state.version, rowCount: state.rowCount,
                                                    to: view.document.buffer.version) else { return nil }
        guard let hit = moved.lines.first(where: { $0.lines.contains(row) }), let tag = hit.tag else { return nil }
        return state.runs[Int(tag)]
    }

    /// A save or a HEAD change dropped the service's blame: views with file blame on ask again, the others forget.
    func blameInvalidated(path: String?) {
        for entry in liveMarks where path == nil || entry.path == path {
            guard let view = entry.view else { continue }
            if view.blame.fileOn {
                Task { await loadBlame(view) }
            } else {
                view.blame.runs = []; view.blame.requested = false
            }
        }
    }
}
