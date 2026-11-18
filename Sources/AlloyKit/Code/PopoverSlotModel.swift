import AlloyCore
import AlloyLSP
import Foundation
import Observation

/// What the hover popover shows: the server's Markdown, the diagnostics under the pointer, and the byte range the popover
/// points at (the server's range, else the hovered character).
struct HoverPresentation: Identifiable, Equatable {
    let id = UUID()
    var markdown: String
    var diagnostics: [LSPDiagnostic]
    var range: Range<Int>?

    static func == (a: HoverPresentation, b: HoverPresentation) -> Bool { a.id == b.id }
}

/// What the rename field edits: the new name, the selection in the field and the last failure. Read only by the field.
@MainActor @Observable
final class RenameFieldState: Identifiable {
    nonisolated let id = UUID()
    var name: String
    var busy = false
    var error: String?
    let target: RenameTarget
    /// The field's own selection (Character offsets); written by the field as the user moves it, so it is not observed.
    @ObservationIgnored var selection: Range<Int>?

    init(target: RenameTarget) {
        self.target = target
        name = target.oldName
        selection = 0..<target.oldName.count
    }
}

/// One file of a finished rename and what became of it.
struct RenameSummaryRow: Equatable {
    enum State: Equatable { case applied, kept, reverted, conflict(String) }
    var path: String
    var edits: Int
    var state: State = .applied
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
    var outcome: String {
        switch state {
        case .applied: edits == 1 ? "1 change" : "\(edits) changes"
        case .kept: "kept"
        case .reverted: "reverted"
        case .conflict(let reason): "kept: \(reason)"
        }
    }
}

/// What the rename summary shows: the files the rename changed, their outcomes and the one line over them. Read only by
/// the summary view.
@MainActor @Observable
final class RenameSummaryState: Identifiable {
    nonisolated let id = UUID()
    let group: UUID
    let anchor: Range<Int>
    var rows: [RenameSummaryRow]
    var summary: String
    var busy = false

    init(group: UUID, rows: [RenameRow], anchor: Range<Int>) {
        self.group = group
        self.anchor = anchor
        self.rows = rows.map { RenameSummaryRow(path: $0.path, edits: $0.edits) }
        let edits = rows.reduce(0) { $0 + $1.edits }
        summary = "Renamed \(edits) \(edits == 1 ? "occurrence" : "occurrences") in \(rows.count) \(rows.count == 1 ? "file" : "files")"
    }

    /// Keep All and Revert All apply only while some file is still applied and no choice is running.
    var isOpen: Bool { !busy && rows.contains { $0.state == .applied } }

    func keepAll(workspace: Workspace) {
        guard isOpen else { return }
        busy = true
        let group = group
        _ = workspace.track { [self] in
            await workspace.keepAll(group: group)
            var kept = 0
            for i in rows.indices where rows[i].state == .applied {
                if workspace.hasEdit(group: group, path: rows[i].path) { rows[i].state = .kept; kept += 1 } else { rows[i].state = .reverted }
            }
            summary = "Kept \(kept) \(kept == 1 ? "file" : "files")"
            busy = false
        }
    }

    func revertAll(workspace: Workspace) {
        guard isOpen else { return }
        busy = true
        let group = group
        _ = workspace.track { [self] in
            let results = await workspace.revertAll(group: group)
            var reverted = 0, kept = 0
            var reason: String?
            for i in rows.indices where rows[i].state == .applied {
                switch results.first(where: { $0.path == rows[i].path })?.outcome {
                case .conflict(let why)?:
                    rows[i].state = .conflict(why)
                    kept += 1
                    reason = reason ?? why
                default:
                    rows[i].state = .reverted   // reverted now, or already undone file by file
                    reverted += 1
                }
            }
            var line = "Reverted \(reverted) \(reverted == 1 ? "file" : "files")"
            if kept > 0 { line += "; \(kept) kept" + (reason.map { ": \($0)" } ?? "") }
            summary = line
            busy = false
        }
    }
}

/// What the view's one text-anchored popover (slot B) shows: the hover, the rename field, or the rename summary.
enum SlotPresentation: Identifiable, Equatable {
    case hover(HoverPresentation)
    case rename(RenameFieldState)
    case summary(RenameSummaryState)

    var id: UUID {
        switch self {
        case .hover(let p): p.id
        case .rename(let s): s.id
        case .summary(let s): s.id
        }
    }

    /// The byte range the popover points at.
    var range: Range<Int> {
        switch self {
        case .hover(let p): p.range ?? 0..<0
        case .rename(let s): s.target.range
        case .summary(let s): s.anchor
        }
    }

    nonisolated static func == (a: SlotPresentation, b: SlotPresentation) -> Bool { a.id == b.id }
}

/// The one text-anchored presentation of a code view (slot B): the hover popover or the rename field, one at a time.
@MainActor @Observable
final class PopoverSlotModel {
    var hover: HoverPresentation?
    var rename: RenameFieldState?
    var summary: RenameSummaryState?
    /// The parsed Markdown of the open hover, kept across the popover's rebuilds.
    @ObservationIgnored let markdownCache = MarkdownCache()

    /// The open presentation (summary, then rename, then hover); setting nil closes whatever is open.
    var item: SlotPresentation? {
        get { summary.map { .summary($0) } ?? rename.map { .rename($0) } ?? hover.map { .hover($0) } }
        set {
            if newValue == nil {
                if summary != nil { summary = nil }
                if hover != nil { hover = nil }
                if rename != nil { rename = nil }
            }
        }
    }
}
