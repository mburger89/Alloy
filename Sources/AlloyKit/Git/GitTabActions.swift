import AlloyCore
import Foundation

/// What the Git tab's buttons do. Each command goes through `GitService`, never retries, shows git's own message when
/// it fails, and leaves the refresh to the service (a write asks for one) and to the file events that follow.
extension GitCoordinator {
    func stage(_ entry: GitFileStatus) {
        run { await $0.stage([entry.path]) }
    }

    func unstage(_ entry: GitFileStatus) {
        // A staged rename is two index entries; both go back.
        run { await $0.unstage([entry.path] + (entry.origPath.map { [$0] } ?? [])) }
    }

    /// Asks to discard `entry`; nothing happens until `confirmDiscard`.
    func requestDiscard(_ entry: GitFileStatus) {
        guard !entry.isSubmodule else { return }
        sidebar.pendingDiscard = GitPendingDiscard(path: entry.path, untracked: entry.kind == .untracked)
    }

    func cancelDiscard() { sidebar.pendingDiscard = nil }

    func confirmDiscard() {
        guard let pending = sidebar.pendingDiscard else { return }
        sidebar.pendingDiscard = nil
        if pending.untracked {
            guard let url = untrackedURL(pending.path) else { return }
            do {
                try FileManager.default.removeItem(at: url)
                panel.lastError = nil
            } catch {
                panel.lastError = "Could not delete \(pending.path): \(error.localizedDescription)"
            }
            let service = service
            Task { await service.requestRefresh() }
        } else {
            run { await $0.discard([pending.path]) }
        }
    }

    /// The file an untracked entry names, only when it lies inside the project and outside `.git`.
    private func untrackedURL(_ path: String) -> URL? {
        guard let root = host?.projectRoot else { return nil }
        let url = root.appendingPathComponent(path).standardizedFileURL
        let base = root.standardizedFileURL.path + "/"
        guard url.path.hasPrefix(base), !url.path.dropFirst(base.count).hasPrefix(".git/") else { return nil }
        return url
    }

    func commit(amend: Bool) {
        guard GitCommitRules.blocker(panel: panel, message: sidebar.message, amend: amend) == nil else { return }
        let message = sidebar.message
        run(onSuccess: { $0.sidebar.message = "" }) { await $0.commit(message: message, amend: amend) }
    }

    func refresh() {
        panel.lastError = nil; sidebar.staleLock = false; sidebar.confirmingLock = false
        let service = service
        Task { await service.refreshNow() }
    }

    func requestLockRemoval() { sidebar.confirmingLock = true }
    func cancelLockRemoval() { sidebar.confirmingLock = false }

    func confirmLockRemoval() {
        sidebar.confirmingLock = false
        let service = service
        Task { @MainActor in
            if await service.removeStaleLock() {
                self.panel.lastError = nil; self.sidebar.staleLock = false
                await service.requestRefresh()
            }
        }
    }

    /// A click on a row: Compare with HEAD for a tracked file, the file itself for an untracked one.
    func openRow(_ entry: GitFileStatus) {
        guard let host, !entry.path.hasSuffix("/"), entry.kind != .ignored else { return }
        let path = entry.path
        let pane = host.defaultPane
        if entry.kind == .untracked {
            host.requestOpen(path, in: pane)
            return
        }
        // A deleted file has nothing to open.
        guard entry.worktree != "D", entry.index != "D" else { return }
        Task { @MainActor in
            await host.open(path, in: pane)
            self.openCompare(path: path, against: .head, in: pane)
        }
    }

    private func run(onSuccess: (@MainActor (GitCoordinator) -> Void)? = nil,
                     _ command: @escaping @Sendable (GitService) async -> GitCommandResult) {
        guard !sidebar.busy else { return }
        sidebar.busy = true
        let service = service
        Task { @MainActor in
            let result = await command(service)
            self.sidebar.busy = false
            if result.ok {
                self.panel.lastError = nil; self.sidebar.staleLock = false
                onSuccess?(self)
            } else {
                self.panel.lastError = result.stderr.isEmpty ? "git failed" : result.stderr
                self.sidebar.staleLock = result.stderr.contains("index.lock") ? await service.staleLockExists() : false
            }
        }
    }
}
