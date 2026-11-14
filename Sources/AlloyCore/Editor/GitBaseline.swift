import Foundation

/// Reads from the project's git repository, off the main actor, each git run limited to five seconds (SIGTERM at
/// five, SIGKILL at six and a half). No repository, an untracked path and a hung git all read as nil or false.
enum GitBaseline {
    static let terminateAfter = 5.0
    static let killAfter = 6.5

    /// HEAD's text of `path` (relative to `root`; `HEAD:./path`, so a project below the repository's top works).
    /// The blob's raw bytes: a file with eol conversion or an LFS pointer differs from its working text, so nothing is
    /// kept, which is the safe direction. Decoded as the ledger decodes files, invalid bytes becoming U+FFFD. Detached HEAD works.
    static func headText(root: URL, path: String) async -> String? {
        guard let data = await run(["cat-file", "blob", "HEAD:./" + path], root) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func isRepo(_ root: URL) async -> Bool {
        guard let data = await run(["rev-parse", "--is-inside-work-tree"], root) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The repository's own git directory for `root` (a worktree's private one, not the common directory).
    static func gitDirectory(root: URL) async -> String? {
        guard let data = await run(["rev-parse", "--absolute-git-dir"], root) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return path.isEmpty ? nil : path
    }

    private static func run(_ args: [String], _ root: URL) async -> Data? {
        await Workspace.gitRun(["-C", root.path] + args, in: root, terminateAfter: terminateAfter, killAfter: killAfter)
    }
}

extension Workspace {
    /// Git changes are coalesced over this long before ledger files are compared with HEAD.
    static let gitCoalesce = 0.5
    /// An outside record this soon after a git event triggers one more check.
    static let rearmWindow = 2.0

    /// Whether a `.git`-relative event path can mean a commit or checkout: HEAD, a branch ref, the reflog or the index.
    static func isBaselineEvent(_ rel: String) -> Bool {
        rel == ".git" || rel == ".git/HEAD" || rel == ".git/logs/HEAD" || rel == ".git/index" || rel.hasPrefix(".git/refs/heads/")
    }

    /// The `.git/...` form of an event path inside the external git directory, or nil for any other path.
    func externalGitEventPath(_ path: String) -> String? {
        guard let dir = externalGitDir else { return nil }
        if path == dir || path == dir + "/" { return ".git" }
        guard path.hasPrefix(dir + "/") else { return nil }
        var rest = String(path.dropFirst(dir.count + 1))
        if rest.hasSuffix("/") { rest.removeLast() }
        return ".git/" + rest
    }

    /// Finds the git directory once, off the main actor. When it lies outside the project root (a worktree, or a
    /// project below the repository's top) the root watcher never sees it, so a second source watches it.
    func watchExternalGitDirectory() async {
        guard let dir = await GitBaseline.gitDirectory(root: projectRoot), !isShuttingDown, watchTask != nil,
              externalGitDir == nil else { return }
        let real = FSEventsSource.realPath(URL(fileURLWithPath: dir))
        guard !eventRoots.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) else { return }
        externalGitDir = real
        let stream = changeFactory(URL(fileURLWithPath: real, isDirectory: true)).changes()
        gitWatchTask = Task { @MainActor [weak self] in
            for await paths in stream {
                guard let self else { return }
                self.enqueueOutside(paths)
            }
        }
    }

    /// A HEAD, branch or index change: remembers when, and compares ledger files with HEAD after the window. Whether
    /// any file has live edits is decided when the window ends, because the edit that was committed may be recorded
    /// only after the git event arrived (a later batch, or a watcher waiting on an Edit result).
    func baselineEventSeen() {
        let name = Self.readBranchName(projectRoot: projectRoot)
        if name != branchName { branchName = name }
        lastBaselineEvent = autosaveClock.now
        scheduleBaselineCheck()
    }

    /// An `.outside` record made within `rearmWindow` of the last git event may be the checkout's own write, which
    /// the earlier check could not see: look once more.
    func rearmBaselineCheckIfRecent() {
        guard let last = lastBaselineEvent, autosaveClock.now - last <= Self.rearmWindow else { return }
        scheduleBaselineCheck()
    }

    /// Compares ledger files with HEAD after the coalescing window.
    func scheduleBaselineCheck() {
        guard gitDebounce == nil, !isShuttingDown else { return }
        let deadline = autosaveClock.now + Self.gitCoalesce, clock = autosaveClock
        gitDebounce = track { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { self?.gitDebounce = nil; return }
            self?.gitDebounce = nil
            await self?.checkGitBaselines()
        }
    }

    /// For every ledger file with live edits whose text equals HEAD's byte for byte, keeps all its edits: the work
    /// is committed, so nothing is left to review. A file not in HEAD, or differing from it, keeps nothing.
    func checkGitBaselines() async {
        let candidates = ledger.changedFiles().map(\.path)
        guard !candidates.isEmpty else { return }
        // One probe first: without a repository, or with a hung git, the per-file reads would each wait out the timeout.
        gitSpawnCount += 1
        guard await GitBaseline.isRepo(projectRoot), !isShuttingDown else { return }
        for path in candidates {
            guard !isShuttingDown, let file = ledger.files[path] else { continue }
            let version = file.version
            gitSpawnCount += 1
            guard let head = await GitBaseline.headText(root: projectRoot, path: path) else { continue }
            let same = await Task.detached { head.utf8.elementsEqual(file.text.text.utf8) }.value
            guard same, !isShuttingDown, ledger.files[path]?.version == version else { continue }
            keepAllEdits(path: path)
        }
    }
}

extension Workspace {
    /// The branch in `HEAD` (`ref: refs/heads/<name>`), or the first 7 characters of a detached HEAD's hash. A `.git`
    /// file (a worktree) points at the real git directory. Nil without a readable `.git/HEAD`. Reads one small file.
    static func readBranchName(projectRoot: URL) -> String? {
        let fm = FileManager.default
        var gitDir = projectRoot.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue {
            guard let pointer = try? String(contentsOf: gitDir, encoding: .utf8),
                  let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : projectRoot.appendingPathComponent(path).standardizedFileURL
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if text.hasPrefix(prefix) {
            let name = String(text.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        return text.isEmpty ? nil : String(text.prefix(7))
    }
}
