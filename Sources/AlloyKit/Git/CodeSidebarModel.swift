import AlloyCore
import Foundation
import Observation

/// What a click on Discard asked for and is waiting on the user to confirm.
struct GitPendingDiscard: Equatable {
    var path: String
    var untracked: Bool
}

/// The Code sidebar's own state: which tab shows, and everything the Git tab keeps between frames (the commit
/// message, an error, a pending confirmation). The tab and the draft live in the workspace's persisted fields, so
/// they come back after a relaunch; the rest is memory only. Each property is observed on its own, so a keystroke in
/// the commit box wakes the commit box and nothing else.
@MainActor @Observable
public final class CodeSidebarModel {
    @ObservationIgnored weak var workspace: Workspace?

    init(workspace: Workspace?) { self.workspace = workspace }

    /// The shown tab: the workspace's one `codeLayout.sidebarTab` (Files, Search or Git), persisted with the UI state.
    public var tab: SidebarTab {
        get { workspace?.codeLayout.sidebarTab ?? .files }
        set { workspace?.codeLayout.sidebarTab = newValue }
    }

    /// The commit message being written.
    public var message: String {
        get {
            access(keyPath: \.message)
            return workspace?.persistedCommitDraft ?? ""
        }
        set {
            let stored = newValue.isEmpty ? nil : newValue
            guard workspace?.persistedCommitDraft != stored else { return }
            withMutation(keyPath: \.message) { workspace?.persistedCommitDraft = stored }
        }
    }

    /// A stage, unstage, discard or commit is running.
    public internal(set) var busy = false
    /// Bumped by Git > Commit… so the message editor takes focus.
    public internal(set) var focusRequest = 0
    /// The stale `index.lock` the error may be about is old enough to remove.
    public internal(set) var staleLock = false
    public internal(set) var confirmingLock = false
    var pendingDiscard: GitPendingDiscard?
}

/// Why Commit or Amend is unavailable; nil when it may run.
@MainActor enum GitCommitRules {
    static func blocker(panel: GitPanelModel, message: String, amend: Bool) -> String? {
        if panel.operation == .rebase { return "Rebase in progress: continue it in a terminal" }
        if !panel.conflicts.isEmpty { return "Resolve the conflicts first" }
        if amend && panel.isUnborn { return "There is nothing to amend yet" }
        if !amend && panel.staged.isEmpty { return "Stage changes to commit" }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write a commit message" }
        return nil
    }
}
