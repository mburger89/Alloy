import AlloyCore
import Foundation
import Observation

/// What the Git tab shows. Only that tab reads it, and it changes only when a status update says something changed,
/// so a project with the tab closed re-renders nothing.
@MainActor @Observable
public final class GitPanelModel {
    public private(set) var state: GitRepoState = .unknown
    public private(set) var branch: String?
    public private(set) var ahead = 0
    public private(set) var behind = 0
    /// Whether the branch has an upstream ref (ahead and behind mean something only then).
    public private(set) var hasUpstream = false
    public private(set) var isUnborn = false
    public private(set) var operation: GitOperation?
    public private(set) var staged: [GitFileStatus] = []
    public private(set) var changes: [GitFileStatus] = []
    public private(set) var untracked: [GitFileStatus] = []
    public private(set) var conflicts: [GitFileStatus] = []
    public private(set) var statusTimedOut = false
    public var lastError: String?

    public init() {}

    func apply(_ update: GitUpdate) {
        let s = update.status
        func sorted(_ f: (GitFileStatus) -> Bool) -> [GitFileStatus] {
            s.entries.values.filter(f).sorted { $0.path < $1.path }
        }
        // Each assignment is guarded: an equal value must not invalidate the views that read it.
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<GitPanelModel, T>, _ value: T) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        set(\.state, update.state)
        set(\.branch, s.branch ?? (s.oid.map { String($0.prefix(7)) }))
        set(\.ahead, s.ahead ?? 0)
        set(\.behind, s.behind ?? 0)
        set(\.hasUpstream, s.ahead != nil)
        set(\.isUnborn, s.isUnborn)
        set(\.operation, s.operation)
        set(\.staged, sorted { $0.isStaged && $0.kind != .unmerged })
        set(\.changes, sorted { ($0.kind == .ordinary || $0.kind == .renamed) && $0.worktree != "." })
        set(\.untracked, sorted { $0.kind == .untracked })
        set(\.conflicts, sorted { $0.kind == .unmerged })
        set(\.statusTimedOut, update.timedOut)
    }
}
