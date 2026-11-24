import AlloyCore
import Foundation

/// Runs git for the plugin installer. A seam so tests can fake the size cap, credentials and timeout cases.
public protocol PluginGitRunner: Sendable {
    /// Runs git with `args` in `dir`. Past `timeout` seconds the run is killed (`timedOut`); while it runs, the total size
    /// of `watch` is polled and the run is killed past `sizeCap` bytes (`status == PluginGitRunnerStatus.sizeCapExceeded`).
    func run(_ args: [String], in dir: URL, timeout: Double, sizeCap: UInt64?, watch: URL?) async -> GitResult
}

public enum PluginGitRunnerStatus {
    /// The status a runner reports for a run it killed for growing past its size cap.
    public static let sizeCapExceeded: Int32 = -2
}

/// The real runner: the resolved git, no terminal prompts, no credential helpers that ask.
public struct LivePluginGitRunner: PluginGitRunner {
    /// Added to git's environment (a test points `GIT_CONFIG_GLOBAL` at a config of its own).
    public var extraEnvironment: [String: String]

    public init(extraEnvironment: [String: String] = [:]) { self.extraEnvironment = extraEnvironment }

    public func run(_ args: [String], in dir: URL, timeout: Double, sizeCap: UInt64?, watch: URL?) async -> GitResult {
        guard case .usable(let path, _) = GitExecutable.current else { return GitResult(status: -1) }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Self.runBlocking(path, args, dir, timeout, sizeCap, watch, extraEnvironment))
            }
        }
    }

    private static func runBlocking(_ path: String, _ args: [String], _ dir: URL, _ timeout: Double, _ sizeCap: UInt64?,
                                    _ watch: URL?, _ extraEnvironment: [String: String]) -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = ""
        env["SSH_ASKPASS"] = ""
        env["GCM_INTERACTIVE"] = "never"
        // A repository with Git LFS filters must not download its large files behind the size cap.
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        for (key, value) in extraEnvironment { env[key] = value }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return GitResult(status: -1) }
        let outBuffer = DrainBuffer(limit: 4 * 1024 * 1024), errBuffer = DrainBuffer(limit: 64 * 1024)
        let group = DispatchGroup()
        for (pipe, buffer) in [(out, outBuffer), (err, errBuffer)] {
            group.enter()
            DispatchQueue.global().async {
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                group.leave()
            }
        }
        let start = Date()
        var timedOut = false, tooLarge = false
        var lastSize = Date()
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
            if Date().timeIntervalSince(start) > timeout { timedOut = true; break }
            if let sizeCap, let watch, Date().timeIntervalSince(lastSize) >= 0.5 {
                lastSize = Date()
                if directorySize(watch) > sizeCap { tooLarge = true; break }
            }
        }
        if timedOut || tooLarge {
            process.terminate()
            let killAt = Date().addingTimeInterval(2)
            while process.isRunning, Date() < killAt { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        group.wait()
        // A clone can finish between two polls; the cap holds for what it left behind too.
        if !timedOut, !tooLarge, let sizeCap, let watch, directorySize(watch) > sizeCap { tooLarge = true }
        if tooLarge { return GitResult(status: PluginGitRunnerStatus.sizeCapExceeded, stdout: outBuffer.data, stderr: errBuffer.data) }
        return GitResult(status: process.terminationStatus, stdout: outBuffer.data, stderr: errBuffer.data, timedOut: timedOut)
    }

    /// The bytes of every file under `url`.
    static func directorySize(_ url: URL) -> UInt64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Collects a pipe's output up to a limit and keeps draining past it.
private final class DrainBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        if bytes.count < limit { bytes.append(chunk.prefix(limit - bytes.count)) }
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

/// What the update check found for an installed git plugin.
public enum PluginUpdate: Equatable, Sendable {
    case newer(tag: String, version: String, commit: String)
    /// The installed version's tag now points at another commit. Shown, never installed.
    case tagMoved(tag: String)
}

/// A `major.minor.patch` version with an optional `-pre.release` part, written with an optional leading `v`; build
/// metadata after `+` is ignored. Ordered by semver 2.0 precedence (`1.0.0-beta < 1.0.0`). Anything else (branch names) is
/// not a version here.
struct PluginSemver: Comparable {
    let parts: [Int]
    /// Dot-separated pre-release identifiers; empty for a release.
    let prerelease: [String]

    init?(_ text: String) {
        var s = Substring(text)
        if s.hasPrefix("v") { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let tail = s[s.index(after: dash)...]
            s = s[..<dash]
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            for id in pre {
                guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
                // A numeric identifier has no leading zero.
                if id.allSatisfy(\.isNumber), id.count > 1, id.hasPrefix("0") { return nil }
            }
        }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var numbers: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), piece.allSatisfy(\.isNumber), let n = Int(piece) else { return nil }
            numbers.append(n)
        }
        parts = numbers
        prerelease = pre
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// `1.2.3` or `1.2.3-rc.1`.
    var text: String { parts.map(String.init).joined(separator: ".") + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: ".")) }

    static func < (a: PluginSemver, b: PluginSemver) -> Bool {
        if a.parts != b.parts { return a.parts.lexicographicallyPrecedes(b.parts) }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (x.allSatisfy(\.isNumber) ? Int(x) : nil, y.allSatisfy(\.isNumber) ? Int(y) : nil) {
            case (let m?, let n?): return m < n
            case (nil, nil): return x < y
            case (_?, nil): return true   // numeric identifiers sort below alphanumeric ones
            case (nil, _?): return false
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// Installs and updates plugins from a git tag. Clones into staging with hooks and submodules off, validates there and
/// moves the folder into place; an update keeps the old folder as `.<id>.previous` until the new version has started.
public struct PluginGitInstaller: Sendable {
    public let paths: PluginPaths
    public let runner: any PluginGitRunner
    public let pathDirs: [String]

    /// The clone limits: 60 seconds and 200 MB.
    static let cloneTimeout = 60.0
    static let cloneSizeCap: UInt64 = 209_715_200

    public init(paths: PluginPaths, runner: any PluginGitRunner, pathDirs: [String]) {
        self.paths = paths
        self.runner = runner
        self.pathDirs = pathDirs
    }

    /// Leading git arguments for every run.
    static let safeConfig = ["-c", "protocol.ext.allow=never", "-c", "core.hooksPath=/dev/null", "-c", "submodule.recurse=false"]

    /// A URL or tag that git could read as an option is refused before anything is spawned.
    private static func checkOperands(_ operands: String...) throws(PluginInstallError) {
        for operand in operands where operand.hasPrefix("-") || operand.isEmpty { throw .git("that URL or tag is not allowed") }
    }

    private var installer: PluginInstaller { PluginInstaller(paths: paths, pathDirs: pathDirs) }

    func previousFolder(_ id: String) -> URL { paths.plugins.appendingPathComponent(".\(id).previous") }

    // MARK: Install

    /// Clones `tag` of `url`, validates it and moves it to `plugins/<id>`. The same id from another source is refused; the
    /// same git URL reinstalls over the old copy.
    public func install(url: String, tag: String, installed: [String: PluginSetting]) async throws(PluginInstallError)
        -> (manifest: PluginManifest, commit: String) {
        try Self.checkOperands(url, tag)
        let fm = FileManager.default
        let job = paths.staging.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: job) }
        let (cloned, commit) = try await clone(url: url, tag: tag, into: job)
        let copy = Self.namedAfterItsID(cloned)
        let manifest = try installer.validate(copy)
        if let existing = installed[manifest.id] {
            guard case .git(let oldURL, _, _) = existing.source, oldURL == url else { throw .alreadyInstalled(from: existing.source) }
        }
        try installer.place(copy, as: manifest)
        return (manifest, commit)
    }

    /// `git clone` of one tag into `<job>/plugin`; returns that folder and the tag's commit.
    private func clone(url: String, tag: String, into job: URL) async throws(PluginInstallError) -> (URL, String) {
        let fm = FileManager.default
        let copy = job.appendingPathComponent("plugin")
        do { try fm.createDirectory(at: job, withIntermediateDirectories: true) } catch { throw .io(error.localizedDescription) }
        // `--` ends the options, so a URL or path can never be read as one; the -c flags turn off hooks, submodules and the
        // `ext::` transport (which runs a command) whatever the user's own git configuration says.
        let result = await runner.run(Self.safeConfig + ["clone", "--depth", "1", "--branch", tag, "--no-recurse-submodules", "--", url, copy.path],
                                      in: job, timeout: Self.cloneTimeout, sizeCap: Self.cloneSizeCap, watch: copy)
        try Self.check(result)
        let head = await runner.run(["-C", copy.path, "rev-parse", "HEAD"], in: job, timeout: 10, sizeCap: nil, watch: nil)
        try Self.check(head)
        let commit = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commit.isEmpty else { throw .git("no commit") }
        return (copy, commit)
    }

    /// A manifest's id must equal its folder's name, so the checkout is renamed to the id its manifest declares (an unusable
    /// id leaves the name alone and fails validation).
    private static func namedAfterItsID(_ checkout: URL) -> URL {
        guard let data = try? Data(contentsOf: checkout.appendingPathComponent("alloy-plugin.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = object["id"] as? String,
              !id.isEmpty, !id.contains("/"), !id.hasPrefix("."), !id.contains("..") else { return checkout }
        let renamed = checkout.deletingLastPathComponent().appendingPathComponent(id)
        guard (try? FileManager.default.moveItem(at: checkout, to: renamed)) != nil else { return checkout }
        return renamed
    }

    private static func check(_ result: GitResult) throws(PluginInstallError) {
        if result.status == PluginGitRunnerStatus.sizeCapExceeded { throw .tooLarge }
        if result.timedOut { throw .git("git timed out") }
        guard result.status == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self)
            let lower = message.lowercased()
            if lower.contains("terminal prompts disabled") || lower.contains("could not read username")
                || lower.contains("could not read password") { throw .needsCredentials }
            if result.status == -1 && message.isEmpty { throw .git("git is not available") }
            let line = message.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "git failed"
            throw .git(String(line.prefix(300)))
        }
    }

    // MARK: Update

    /// The newest version above the installed one, or the installed tag having moved, or nil.
    public func availableUpdate(for setting: PluginSetting, url: String) async throws(PluginInstallError) -> PluginUpdate? {
        guard case .git(_, let installedTag, let installedCommit) = setting.source else { return nil }
        try Self.checkOperands(url)
        let result = await runner.run(Self.safeConfig + ["ls-remote", "--tags", "--", url], in: FileManager.default.temporaryDirectory, timeout: 30, sizeCap: nil, watch: nil)
        try Self.check(result)
        // Annotated tags list twice; the peeled line (`^{}`) holds the commit.
        var commits: [String: String] = [:]
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[1].hasPrefix("refs/tags/") else { continue }
            var name = String(fields[1].dropFirst("refs/tags/".count))
            if name.hasSuffix("^{}") { name.removeLast(3); commits[name] = fields[0] } else if commits[name] == nil { commits[name] = fields[0] }
        }
        let current = PluginSemver(setting.version)
        var best: (semver: PluginSemver, tag: String)?
        for tag in commits.keys.sorted() {
            // A pre-release tag is offered only to a plugin that is on a pre-release itself.
            guard let v = PluginSemver(tag), current.map({ v > $0 }) ?? true, !v.isPrerelease || current?.isPrerelease == true
            else { continue }
            if best == nil || v > best!.semver { best = (v, tag) }
        }
        if let best, let commit = commits[best.tag] {
            return .newer(tag: best.tag, version: best.semver.text, commit: commit)
        }
        if let now = commits[installedTag], !installedCommit.isEmpty, now != installedCommit { return .tagMoved(tag: installedTag) }
        return nil
    }

    /// Installs the update in staging, then swaps it in; the old folder waits as `.<id>.previous`.
    /// `url` is the one Alloy recorded when it installed the plugin, never one read back from the plugin's own `.git/config`.
    public func update(id: String, to update: PluginUpdate, url: String) async throws(PluginInstallError) -> PluginManifest {
        guard case .newer(let tag, _, let commit) = update else { throw .git("the tag moved; not installed") }
        try Self.checkOperands(url, tag)
        let fm = FileManager.default
        let target = paths.plugins.appendingPathComponent(id)
        let job = paths.staging.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: job) }
        let (checkout, cloned) = try await clone(url: url, tag: tag, into: job)
        let copy = Self.namedAfterItsID(checkout)
        guard cloned == commit else { throw .git("the tag moved since the check") }
        let manifest = try installer.validate(copy)
        guard manifest.id == id else { throw .io("the update is for \(manifest.id), not \(id)") }
        if case .success(let old) = PluginManifestLoader.load(folder: target, pathDirs: pathDirs),
           let a = PluginSemver(manifest.version), let b = PluginSemver(old.version), a <= b { throw .downgrade }
        let previous = previousFolder(id)
        do {
            try? fm.removeItem(at: previous)
            try fm.moveItem(at: target, to: previous)
            do { try fm.moveItem(at: copy, to: target) } catch {
                try? fm.moveItem(at: previous, to: target)
                throw error
            }
        } catch {
            throw .io(error.localizedDescription)
        }
        return manifest
    }

    /// Puts the previous version's folder back (the new one did not start).
    public func restorePrevious(id: String) throws {
        let fm = FileManager.default
        let previous = previousFolder(id)
        guard fm.fileExists(atPath: previous.path) else { return }
        let target = paths.plugins.appendingPathComponent(id)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: previous, to: target)
    }

    /// Deletes the previous version's folder (the new one started).
    public func dropPrevious(id: String) {
        try? FileManager.default.removeItem(at: previousFolder(id))
    }

    /// Deletes every `.<id>.previous` folder: at launch no update is pending, so none is needed.
    public static func dropStalePrevious(paths: PluginPaths) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: paths.plugins.path)) ?? [] where name.hasPrefix(".") && name.hasSuffix(".previous") {
            try? fm.removeItem(at: paths.plugins.appendingPathComponent(name))
        }
    }
}
