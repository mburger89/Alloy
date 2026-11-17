import AlloyCore
import Foundation
import MetalUICodeBuffer

/// Connects one workspace to its `GitService`: the workspace's change hooks feed the service, and the service's
/// updates reach the Git tab through `panel`. It chains the hooks other features set (it calls the previous closure
/// first) and does nothing of its own on a frame or a keystroke.
@MainActor
public final class GitCoordinator {
    public let panel = GitPanelModel()
    /// The file tree's per-row status cells.
    public let tree = GitTreeStatus()
    /// The Code sidebar's tab and the Git tab's own state.
    public let sidebar: CodeSidebarModel
    /// The branch menu's list and the picker and new-branch field.
    let branchPicker = BranchPickerModel()
    let service: GitService
    private weak var workspace: Workspace?
    private var consumer: Task<Void, Never>?
    /// The gutter marks of every open view that has some, by view; the marks hold their view weakly.
    private var marks: [ObjectIdentifier: GitDocumentMarks] = [:]

    var host: Workspace? { workspace }
    var clock: (any AutosaveClock)? { workspace?.scheduleClock }
    var marksEnabled: Bool { workspace?.settings.git.gutterMarks ?? false }
    var liveMarksEnabled: Bool { workspace.map { $0.settings.git.gutterMarks && $0.settings.git.liveMarks } ?? false }

    /// The number of git processes the service started (tests pin it).
    public var spawnCount: Int { service.spawnCount }

    init(workspace: Workspace, service: GitService) {
        self.workspace = workspace
        self.service = service
        self.sidebar = CodeSidebarModel(workspace: workspace)
        wireBranchPicker()
    }

    /// Creates the coordinator for `workspace`, wires its hooks, and asks for the first status.
    @discardableResult
    public static func install(on workspace: Workspace, service: GitService? = nil) -> GitCoordinator {
        GitExecutable.configure(gitPath: workspace.settings.git.gitPath)
        let service = service ?? GitService(root: workspace.projectRoot, clock: workspace.scheduleClock)
        let coordinator = GitCoordinator(workspace: workspace, service: service)
        workspace.gitServices = coordinator
        coordinator.listen()

        let previousGit = workspace.gitChanged
        workspace.gitChanged = { [weak coordinator] paths in
            previousGit?(paths)
            coordinator?.gitEvent(paths)
        }
        let previousWorktree = workspace.worktreeChanged
        workspace.worktreeChanged = { [weak coordinator] paths in
            previousWorktree?(paths)
            coordinator?.worktreeEvent(paths)
        }
        let previousSaved = workspace.onSaved
        workspace.onSaved = { [weak coordinator] path in
            previousSaved?(path)
            coordinator?.saved(path)
        }
        let previousSettings = workspace.onGitSettingsChanged
        workspace.onGitSettingsChanged = { [weak coordinator] settings in
            previousSettings?(settings)
            coordinator?.applySettings(settings)
        }
        workspace.addStopHook { [weak coordinator] in
            await coordinator?.shutdown()
        }
        return coordinator
    }

    /// The production wiring: real git processes on the workspace's clock.
    @discardableResult
    public static func installLive(on workspace: Workspace) -> GitCoordinator { install(on: workspace) }

    /// Updates arrive in order through a stream, and the model changes only here, on the main actor.
    private func listen() {
        let (stream, continuation) = AsyncStream<GitUpdate>.makeStream()
        let service = service
        // One task, so the handler is in place before the first status can finish.
        Task {
            await service.setUpdateHandler { continuation.yield($0) }
            await service.requestRefresh()
        }
        consumer = Task { @MainActor [weak self] in
            for await update in stream {
                guard let self else { return }
                self.panel.apply(update)
                if let workspace = self.workspace { self.tree.enabled = workspace.settings.git.statusColours }
                self.tree.apply(update.changedDisplay)
                self.tree.apply(update.changedFolders)
                self.marksUpdated(update)
            }
        }
    }

    // MARK: - Workspace events

    private func gitEvent(_ paths: [String]) {
        // Lock files and object writes come with every git command and change nothing a status shows.
        guard paths.contains(where: { !$0.hasSuffix(".lock") && !$0.contains("/objects/") }) else { return }
        let service = service
        Task { await service.gitEvent() }
    }

    private func worktreeEvent(_ paths: [String]) {
        let service = service
        Task {
            if await service.shouldRefresh(forWorktreePaths: paths) { await service.requestRefresh() }
        }
        // An outside change to an open file (already merged into its buffer) moves its marks.
        let changed = Set(paths)
        for entry in liveMarks where changed.contains(entry.path) { entry.recompute() }
    }

    private func saved(_ path: String) {
        for entry in liveMarks where entry.path == path { entry.recompute() }
        let service = service
        Task {
            await service.invalidateBlame(path: path)
            await service.requestRefresh()
            self.blameInvalidated(path: path)
        }
    }

    private func shutdown() async {
        consumer?.cancel(); consumer = nil
        for entry in liveMarks { entry.teardown() }
        marks = [:]
        await service.stop()
    }

    // MARK: - Gutter marks

    var liveMarks: [GitDocumentMarks] {
        marks = marks.filter { $0.value.view != nil }
        return Array(marks.values)
    }

    /// Starts marks for `view` (one `OpenDocumentView` of a file) and computes them once.
    func attach(_ view: OpenDocumentView) {
        guard marks[ObjectIdentifier(view)] == nil else { return }
        let entry = GitDocumentMarks(view: view, coordinator: self)
        marks[ObjectIdentifier(view)] = entry
        view.gitMarks = entry
        entry.recompute()
    }

    /// Stops the marks of `view` and removes them from its gutter.
    func detach(_ view: OpenDocumentView) {
        marks.removeValue(forKey: ObjectIdentifier(view))?.teardown()
        if view.blame.requested {
            view.blame.reset()
            let service = service, path = view.document.path
            Task { await service.invalidateBlame(path: path) }
        }
    }

    /// The marks of `view`, if it has any.
    func marks(of view: OpenDocumentView) -> GitDocumentMarks? { marks[ObjectIdentifier(view)] }

    /// Selects the next (`direction` > 0) or previous change from the caret in `view`, wrapping.
    @discardableResult
    func nextChange(in view: OpenDocumentView, direction: Int) -> Bool {
        marks[ObjectIdentifier(view)]?.step(direction) ?? false
    }

    // MARK: - Compare

    /// The text of `path` in HEAD or the index; nil when the file has no such copy (untracked, new, unborn, binary).
    func compareBase(path: String, against base: GitCompare.Base) async -> String? {
        switch base {
        case .head:
            guard let oid = await service.headBlobOID(path: path) else { return nil }
            return await service.headText(oid: oid)
        case .index:
            guard let oid = await service.indexBlobOID(path: path) else { return nil }
            return await service.indexText(oid: oid)
        }
    }

    /// Shows `path` in `pane` side by side with its HEAD or index copy.
    func openCompare(path: String, against base: GitCompare.Base, in pane: PaneID) {
        host?.setPresentation(base == .head ? .compareHead : .compareIndex, of: path, in: pane)
    }

    /// The open compare views of `path` (or of every file, with nil) read their base again.
    private func compareBaseChanged(paths: Set<String>?) {
        for entry in liveMarks where paths?.contains(entry.path) ?? true { entry.view?.compareBaseChanged() }
    }

    /// A status update: HEAD moved, or a file that an open view shows changed its status.
    private func marksUpdated(_ update: GitUpdate) {
        guard !marks.isEmpty else { return }
        if update.headChanged { blameInvalidated(path: nil) }
        compareBaseChanged(paths: update.headChanged ? nil : Set(update.changedDisplay.keys))
        for entry in liveMarks where update.headChanged || update.changedDisplay.keys.contains(entry.path) { entry.recompute() }
    }

    /// A git setting changed. Marks come or go (a recompute reads `gutterMarks`; it also drops a pending `liveMarks`
    /// timer, and the next edit starts one only while `liveMarks` is on), the tree's cells clear or refill from the
    /// statuses already known, and a new `gitPath` waits for the next launch (the executable is probed once).
    func applySettings(_ settings: GitSettings) {
        tree.enabled = settings.statusColours
        for entry in liveMarks { entry.recompute() }
    }
}
