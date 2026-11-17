import Foundation

/// Commands that change the repository, plus branches and blame. Every write runs at the repository top with paths
/// given as `prefix + path` after `--`, never retries, and returns git's own stderr on failure. A write that worked
/// asks for a status refresh (the file events would, a little later).
extension GitService {
    private func writeFailure(_ message: String) -> GitCommandResult { GitCommandResult(ok: false, stderr: message) }

    private func write(_ args: [String], stdin: Data? = nil) async -> GitCommandResult {
        await discover()
        guard state == .ready, let top = repoTop else {
            return writeFailure(state == .notARepo ? "This folder is not a git repository." : "Git is not available.")
        }
        let r = await run(args, in: top, stdin: stdin, readOnly: false)
        let text = String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut { return writeFailure(text.isEmpty ? "git took too long and was stopped." : text) }
        if r.status != 0 { return writeFailure(text.isEmpty ? "git failed (exit \(r.status))." : text) }
        requestRefresh()
        return GitCommandResult(ok: true, stderr: text)
    }

    private func topPaths(_ paths: [String]) -> [String] { paths.map { prefix + $0 } }

    public func stage(_ paths: [String]) async -> GitCommandResult {
        guard !paths.isEmpty else { return GitCommandResult(ok: true) }
        await discover()
        return await write(["add", "--"] + topPaths(paths))
    }

    public func unstage(_ paths: [String]) async -> GitCommandResult {
        guard !paths.isEmpty else { return GitCommandResult(ok: true) }
        await discover()
        let unborn = status?.isUnborn ?? false
        // Without a commit there is no HEAD to restore from: drop the entries from the index instead.
        let head = unborn ? ["rm", "--cached", "-r", "-q", "--"] : ["restore", "--staged", "--"]
        return await write(head + topPaths(paths))
    }

    /// Puts the worktree copy back to what the index holds.
    public func discard(_ paths: [String]) async -> GitCommandResult {
        guard !paths.isEmpty else { return GitCommandResult(ok: true) }
        await discover()
        return await write(["restore", "--worktree", "--"] + topPaths(paths))
    }

    /// Stages one hunk (old side: the index text, new side: the buffer). `hunk` has no context.
    public func stageHunk(path: String, hunk: GitHunk, lineEnding: String = "\n",
                          noNewlineAtEnd: (old: Bool, new: Bool) = (false, false)) async -> GitCommandResult {
        await applyHunk(path: path, hunk: hunk, lineEnding: lineEnding, noNewlineAtEnd: noNewlineAtEnd, reverse: false)
    }

    /// Unstages one hunk (old side: HEAD, new side: the index).
    public func unstageHunk(path: String, hunk: GitHunk, lineEnding: String = "\n",
                            noNewlineAtEnd: (old: Bool, new: Bool) = (false, false)) async -> GitCommandResult {
        await applyHunk(path: path, hunk: hunk, lineEnding: lineEnding, noNewlineAtEnd: noNewlineAtEnd, reverse: true)
    }

    private func applyHunk(path: String, hunk: GitHunk, lineEnding: String, noNewlineAtEnd: (old: Bool, new: Bool), reverse: Bool) async -> GitCommandResult {
        await discover()
        let patch = GitPatch.make(path: prefix + path, hunk: hunk, lineEnding: lineEnding, noNewlineAtEnd: noNewlineAtEnd)
        var args = ["apply", "--cached", "--unidiff-zero"]
        if reverse { args.append("-R") }
        return await write(args + ["-"], stdin: patch)
    }

    /// Commits the index. The message goes in on stdin, so its first line may start with `#`.
    public func commit(message: String, amend: Bool = false) async -> GitCommandResult {
        await write(["commit", "-F", "-"] + (amend ? ["--amend"] : []), stdin: Data(message.utf8))
    }

    public func switchBranch(_ name: String) async -> GitCommandResult {
        guard !name.hasPrefix("-") else { return writeFailure("\"\(name)\" is not a valid branch name.") }
        return await write(["switch", name])
    }

    public func createBranch(_ name: String) async -> GitCommandResult {
        guard !name.hasPrefix("-") else { return writeFailure("\"\(name)\" is not a valid branch name.") }
        return await write(["switch", "-c", name])
    }

    /// Local branches, most recently committed first.
    public func branches() async -> [GitBranch] {
        await discover()
        guard state == .ready, let top = repoTop else { return [] }
        let r = await run(["for-each-ref", "--sort=-committerdate", "refs/heads",
                           "--format=%(HEAD)\t%(committerdate:unix)\t%(refname:short)"], in: top, readOnly: true)
        guard r.status == 0 else { return [] }
        return String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { return nil }
            return GitBranch(name: String(f[2]), isCurrent: f[0] == "*", lastCommit: Date(timeIntervalSince1970: Double(f[1]) ?? 0))
        }
    }

    /// Blame of `path` (project-relative) for the committed-plus-worktree file, cached per path until
    /// `invalidateBlame`. `lines` (1-based, inclusive) narrows the answer; the whole file is always what is cached.
    public func blame(path: String, lines: ClosedRange<Int>? = nil) async -> [GitBlameRun] {
        var runs = blameCache[path]
        if runs == nil {
            await discover()
            guard state == .ready, let top = repoTop else { return [] }
            blameSpawns += 1
            let r = await run(["blame", "--porcelain", "--", prefix + path], in: top, readOnly: true)
            guard r.status == 0 else { return [] }
            runs = GitBlameParser.parse(r.stdout)
            blameCache[path] = runs
        }
        guard let lines, let all = runs else { return runs ?? [] }
        return all.filter { $0.startLine + $0.count > lines.lowerBound - 1 && $0.startLine < lines.upperBound }
    }

    /// How many blame processes were started, and how many paths have a cached blame (tests pin both).
    public var blameCacheCount: Int { blameCache.count }

    public func invalidateBlame(path: String? = nil) {
        if let path { blameCache[path] = nil } else { blameCache = [:] }
    }

    /// Whether `index.lock` exists and is older than 60 s, so that the Git tab may offer to remove it.
    public func staleLockExists(now: Date = Date()) async -> Bool {
        await discover()
        guard let gitDir else { return false }
        let path = gitDir.appendingPathComponent("index.lock").path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) > 60
    }

    /// Removes `index.lock` when it is older than 60 s (a crashed git left it); a younger one may belong to a running git.
    @discardableResult
    public func removeStaleLock(now: Date = Date()) async -> Bool {
        await discover()
        guard let gitDir else { return false }
        let url = gitDir.appendingPathComponent("index.lock")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date, now.timeIntervalSince(modified) > 60 else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
