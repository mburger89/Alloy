#if !os(Windows)

import AlloyCore
import Foundation
import MetalUITerminal

/// Owns the sessions of one window: lazy spawn, restart, retire, busy detection and shutdown.
/// Callbacks from a session that was replaced, closed or retired are dropped by a generation check.
@MainActor public final class TerminalManager {
    public struct Delegate {
        public var title: @MainActor @Sendable (UUID, String) -> Void
        public var workingDirectory: @MainActor @Sendable (UUID, String) -> Void
        /// Also used for a spawn failure, with status 127.
        public var exited: @MainActor @Sendable (UUID, Int32) -> Void
        public var notice: @MainActor @Sendable (UUID, String) -> Void

        public init(title: @escaping @MainActor @Sendable (UUID, String) -> Void = { _, _ in },
                    workingDirectory: @escaping @MainActor @Sendable (UUID, String) -> Void = { _, _ in },
                    exited: @escaping @MainActor @Sendable (UUID, Int32) -> Void = { _, _ in },
                    notice: @escaping @MainActor @Sendable (UUID, String) -> Void = { _, _ in }) {
            self.title = title
            self.workingDirectory = workingDirectory
            self.exited = exited
            self.notice = notice
        }
    }

    /// Spawn size until the view reports its real one through `resize`.
    public static let defaultSize = TerminalSize(cols: 80, rows: 24)

    private struct Entry {
        let session: TerminalSession
        let generation: Int
    }

    private let spawner: any PtySpawner
    private let settings: @MainActor () -> TerminalSettings
    private let projectRoot: String
    private let environment: [String: String]
    private let home: String
    private let now: @Sendable () -> Date
    private let graceBeforeKill: Duration
    // swiftlint:disable:next weak_delegate - `Delegate` is a struct of closures (a value type), so it cannot be weak
    private let delegate: Delegate

    private var entries: [UUID: Entry] = [:]
    /// Panes whose spawn failed; only `restart` retries them.
    private var failed: Set<UUID> = []
    private var generation = 0
    private var shutdownTask: Task<Void, Never>?

    public init(spawner: any PtySpawner = LivePtySpawner(), settings: @escaping @MainActor () -> TerminalSettings,
                projectRoot: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory(), now: @escaping @Sendable () -> Date = Date.init,
                graceBeforeKill: Duration = .seconds(1), delegate: Delegate) {
        self.spawner = spawner
        self.settings = settings
        self.projectRoot = projectRoot
        self.environment = environment
        self.home = home
        self.now = now
        self.graceBeforeKill = graceBeforeKill
        self.delegate = delegate
    }

    /// Spawns the panes that have no session yet. Skips live, exited and failed panes and a shut-down manager.
    public func spawnIfNeeded(_ panes: [(id: UUID, cwd: String?)]) {
        guard shutdownTask == nil else { return }
        for pane in panes where entries[pane.id] == nil && !failed.contains(pane.id) {
            spawn(pane.id, cwd: pane.cwd)
        }
    }

    /// Closes the old session (if any) and spawns a fresh one.
    public func restart(_ pane: UUID, cwd: String?) {
        guard shutdownTask == nil else { return }
        retire(pane)
        failed.remove(pane)
        spawn(pane, cwd: cwd)
    }

    public func session(for pane: UUID) -> TerminalSession? { entries[pane]?.session }

    /// The live session's snapshot source, nil before spawn, after spawn failure and after retirement.
    public func snapshotSource(for pane: UUID) -> TerminalSnapshotSource? { entries[pane]?.session.snapshotSource }

    /// Screen actions over the live session; nil before spawn, after failure and after retirement.
    public func screen(for pane: UUID) -> TerminalScreen? {
        guard let session = entries[pane]?.session else { return nil }
        return TerminalScreen(source: session.snapshotSource, viewportRows: { [session] in session.size.rows })
    }

    public func write(_ pane: UUID, _ bytes: [UInt8]) { entries[pane]?.session.write(bytes) }

    public func resize(_ pane: UUID, cols: Int, rows: Int) { entries[pane]?.session.resize(cols: cols, rows: rows) }

    /// Terminates the sessions of panes no longer in the layout.
    public func retain(only live: Set<UUID>) {
        failed.formIntersection(live)
        for pane in entries.keys where !live.contains(pane) { retire(pane) }
    }

    /// On demand only, never polled.
    public func busyPanes() -> Set<UUID> {
        Set(entries.filter { $0.value.session.isBusy() }.keys)
    }

    /// Idempotent: terminates every session concurrently; later spawns are no-ops.
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let sessions = entries.values.map(\.session)
        entries = [:]
        let grace = graceBeforeKill
        let task = Task.detached {
            await withTaskGroup(of: Void.self) { group in
                for session in sessions { group.addTask { await session.terminate(grace: grace) } }
            }
        }
        shutdownTask = task
        await task.value
    }

    // MARK: Private

    private func retire(_ pane: UUID) {
        guard let entry = entries.removeValue(forKey: pane) else { return }
        let grace = graceBeforeKill
        Task.detached { await entry.session.terminate(grace: grace) }
    }

    private func spawn(_ pane: UUID, cwd: String?) {
        let fileManager = FileManager.default
        let launch = TerminalLaunchPlanner.plan(
            settings: settings(), environment: environment, paneCwd: cwd, projectRoot: projectRoot, home: home,
            isExecutable: { fileManager.isExecutableFile(atPath: $0) },
            isDirectory: { path in
                var isDir: ObjCBool = false
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            })
        let request = PtySpawnRequest(executable: launch.executable, argv: launch.argv, env: launch.env,
                                      cwd: launch.cwd, size: Self.defaultSize)
        let pty: any PtyHandle
        do {
            pty = try spawner.spawn(request)
        } catch {
            failed.insert(pane)
            delegate.notice(pane, "Could not start \(launch.executable): \(error)")
            delegate.exited(pane, 127)
            return
        }
        generation += 1
        let token = generation
        let session = TerminalSession(paneID: pane, pty: pty, size: Self.defaultSize,
                                      scrollback: settings().scrollbackLines, now: now)
        entries[pane] = Entry(session: session, generation: token)
        let delegate = self.delegate
        func current(_ manager: TerminalManager?) -> Bool { manager?.entries[pane]?.generation == token }
        session.start(.init(
            onTitle: { [weak self] title in if current(self) { delegate.title(pane, title) } },
            onWorkingDirectory: { [weak self] path in if current(self) { delegate.workingDirectory(pane, path) } },
            onExit: { [weak self] status in if current(self) { delegate.exited(pane, status) } }))
        for notice in launch.notices { delegate.notice(pane, notice) }
    }
}

#endif
