import AlloyCore
import Foundation
import MetalUI

/// The hover text of git's gutter marks. Nothing here runs unless the pointer rests on a mark: MetalUI asks the
/// `gutterHelp` closure only while handling pointer input.
enum GitGutterHelp {
    /// A hunk's summary: `+3 −1` (added and removed lines), `+3` for a pure addition, `−2` for a pure deletion.
    static func hunkText(_ hunk: GitHunk) -> String {
        let added = hunk.newCount, removed = hunk.oldCount
        if removed == 0 { return "+\(added)" }
        if added == 0 { return "\u{2212}\(removed)" }
        return "+\(added) \u{2212}\(removed)"
    }

    /// How long ago `date` was, as the largest whole unit (`now`, `5m`, `3h`, `3d`, `2w`, `2mo`, `11y`); years cap at
    /// `99y`, so the text is at most three characters.
    static func age(from date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        let minute = 60.0, hour = 3600.0, day = 86400.0
        switch s {
        case ..<minute: return "now"
        case ..<hour: return "\(Int(s / minute))m"
        case ..<day: return "\(Int(s / hour))h"
        case ..<(7 * day): return "\(Int(s / day))d"
        case ..<(30 * day): return "\(Int(s / (7 * day)))w"
        case ..<(365 * day): return "\(Int(s / (30 * day)))mo"
        default: return "\(min(99, Int(s / (365 * day))))y"
        }
    }

    /// A blame run's author, date, short hash and summary; an uncommitted run says so.
    static func blameText(_ run: GitBlameRun) -> String {
        if run.isUncommitted { return "Not committed yet" }
        return "\(run.author)\n\(GitBlameMarks.dateText(run.authorTime))  \(run.shortHash)\n\(run.summary)"
    }
}

extension OpenDocumentView {
    /// The tooltip for a gutter hit, or nil: change bars of git give the hunk summary, blame markers the commit.
    /// An unknown or stale tag (a recompute dropped it, a blame toggled off) gives nil.
    @MainActor
    func gutterHelpText(for hit: CodeGutterHit) -> String? {
        gutterHelpCalls += 1
        guard let tag = hit.tag else { return nil }
        switch hit.source {
        case .changeBar where hit.owner == GitGutterMarks.owner:
            return gitMarks?.tags[tag].map(GitGutterHelp.hunkText)
        case .gutterMarker where hit.owner == GitBlameMarks.owner:
            guard tag >= 1, Int(tag) <= blame.runs.count else { return nil }
            return GitGutterHelp.blameText(blame.runs[Int(tag) - 1])
        default:
            return nil
        }
    }
}
