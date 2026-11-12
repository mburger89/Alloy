import AppKit
import Darwin
import Foundation
import BenchCore

public struct LaunchedApp: Sendable {
    public let pid: pid_t
    public let launchedAt: UInt64  // mach_absolute_time
    /// Process start time (microseconds since epoch) at launch; guards against PID reuse.
    public let startTime: UInt64
    /// Per-run temporary user-data directory passed to the app (removed by `Launcher.terminate`), if any.
    public let userDataDir: String?
    public init(pid: pid_t, launchedAt: UInt64, startTime: UInt64, userDataDir: String? = nil) {
        self.pid = pid; self.launchedAt = launchedAt; self.startTime = startTime; self.userDataDir = userDataDir
    }
}

public enum LauncherError: Error, CustomStringConvertible {
    case missingExecutable(String)
    case untracked(pid_t)
    case seedFailed(String, String)
    public var description: String {
        switch self {
        case .missingExecutable(let p): return "executable not found: \(p)"
        case .seedFailed(let rel, let why): return "could not seed \(rel) into the per-run user-data directory: \(why)"
        case .untracked(let pid): return "could not read the start time of launched pid \(pid); it was killed so no app is left untracked"
        }
    }
}

public enum Launcher {
    /// All pids whose executable path equals the app's.
    public static func pidsRunning(path: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: 4096)
        var out: [pid_t] = []
        // proc_pidpath reports the symlink-resolved path (/var -> /private/var), so compare against both spellings.
        let wanted: Set<String> = [path, realpath(path, nil).map { defer { free($0) }; return String(cString: $0) } ?? path]
        for pid in pids.prefix(Int(n)) where pid > 0 {
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            if len > 0, wanted.contains(String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)) { out.append(pid) }
        }
        return out
    }

    /// The pid among `pids` whose parent is not itself in `pids`: the main app, not a same-binary helper such as
    /// Zed's crash handler (a child running the same executable).
    public static func rootMost(_ pids: [pid_t], parentOf: (pid_t) -> pid_t?) -> pid_t? {
        let set = Set(pids)
        return pids.sorted().first { pid in parentOf(pid).map { !set.contains($0) } ?? true }
    }

    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return r == Int32(MemoryLayout<proc_bsdinfo>.size) ? pid_t(info.pbi_ppid) : nil
    }

    /// pid of the main process of an already-running instance of the app, or nil. Matched by bundle identifier
    /// (NSRunningApplication) and by executable path (root-most match, so never a crash-handler helper).
    public static func runningInstance(of app: TargetApp) -> pid_t? {
        if let id = app.bundleID,
           let r = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
            return r.processIdentifier
        }
        return rootMost(pidsRunning(path: app.executablePath), parentOf: parentPid(of:))
    }

    /// Microseconds since the epoch, the unit of `startTime(of:)`.
    public static func nowMicroseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000) }

    /// Executes the app binary directly so the PID is the app and a new instance starts.
    /// Alloy gets its project dir as the working directory.
    public static func launch(_ app: TargetApp, file: String?, extraEnvironment: [String: String] = [:]) throws -> LaunchedApp {
        guard FileManager.default.isExecutableFile(atPath: app.executablePath) else {
            throw LauncherError.missingExecutable(app.executablePath)
        }
        var userDataDir: String?
        if app.userDataDirFlag != nil || app.dataDirEnvironmentKey != nil {
            let d = NSTemporaryDirectory() + "bench-userdata-\(getpid())-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            userDataDir = d
            do { try seed(app.seededFiles, into: d) } catch {
                try? FileManager.default.removeItem(atPath: d)
                throw error
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: app.executablePath)
        p.arguments = arguments(for: app, file: file, userDataDir: userDataDir)
        if let env = environment(for: app, userDataDir: userDataDir, extra: extraEnvironment) { p.environment = env }
        if app.id == "alloy" {
            let dir = file.map { ($0 as NSString).deletingLastPathComponent } ?? FileManager.default.currentDirectoryPath
            p.currentDirectoryURL = URL(fileURLWithPath: dir.isEmpty ? "." : dir)
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let t = mach_absolute_time()
        do { try p.run() } catch {
            if let d = userDataDir { try? FileManager.default.removeItem(atPath: d) }
            throw error
        }
        let pid = p.processIdentifier
        guard let st = acquireStartTime(of: pid) else {
            // Without a start time the PID-reuse guard cannot work, so never leave the app untracked. We own the
            // Process object (a child of ours), so this kill cannot hit a reused pid.
            kill(pid, SIGKILL)
            p.waitUntilExit()
            if let d = userDataDir { try? FileManager.default.removeItem(atPath: d) }
            throw LauncherError.untracked(pid)
        }
        return LaunchedApp(pid: pid, launchedAt: t, startTime: st, userDataDir: userDataDir)
    }

    /// Writes each seeded file (relative path -> contents) under `dir`, creating intermediate directories.
    public static func seed(_ files: [String: String], into dir: String) throws {
        for (rel, contents) in files.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(rel)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url)
            } catch { throw LauncherError.seedFailed(rel, error.localizedDescription) }
        }
    }

    /// The launch environment when the app takes its data directory from a variable (Alloy's `ALLOY_DATA_DIR`);
    /// nil when the app inherits ours unchanged. `extra` is added only in that same case, so apps without the key
    /// (Zed, Delta) never see it.
    public static func environment(for app: TargetApp, userDataDir: String?, extra: [String: String] = [:],
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String]? {
        guard let key = app.dataDirEnvironmentKey, let dir = userDataDir else { return nil }
        var env = base
        for (k, v) in extra { env[k] = v }
        env[key] = dir
        return env
    }

    /// Full argument vector: the isolation flag (when the app has one) followed by the app's own arguments.
    public static func arguments(for app: TargetApp, file: String?, userDataDir: String?) -> [String] {
        var args: [String] = []
        if let flag = app.userDataDirFlag, let dir = userDataDir { args += [flag, dir] }
        return args + app.launchArguments(file)
    }

    /// The start time of a just-spawned pid; retried for up to `timeoutMs` because the kernel may not list it yet.
    public static func acquireStartTime(of pid: pid_t, timeoutMs: Int = 50,
                                        lookup: (pid_t) -> UInt64? = { startTime(of: $0) }) -> UInt64? {
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while true {
            if let t = lookup(pid) { return t }
            if ContinuousClock.now >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    /// Process start time in microseconds since epoch, or nil if the pid does not exist.
    public static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard r == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// True when `pid` is still the process that was launched (same start time), not a reused pid.
    public static func isStillLaunched(_ l: LaunchedApp) -> Bool {
        l.startTime != 0 && startTime(of: l.pid) == l.startTime
    }

    /// SIGTERM the launched pid and its descendants, SIGKILL survivors after 5 s. Never by name,
    /// and never a pid whose start time no longer matches what we recorded (PID reuse).
    /// With `collecting`, returns the contents of `<userDataDir>/<fileName>` read after the process tree has exited
    /// and before the directory is removed (nil when absent).
    @discardableResult
    public static func terminate(_ launched: LaunchedApp, collecting fileName: String? = nil) async -> Data? {
        func collect() -> Data? {
            defer { if let d = launched.userDataDir { try? FileManager.default.removeItem(atPath: d) } }
            guard let fileName, let d = launched.userDataDir else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: d + "/" + fileName))
        }
        guard isStillLaunched(launched) else { return collect() }
        // pid -> start time, captured together so each later signal is checked against it.
        var tree: [(pid: pid_t, start: UInt64)] = []
        for p in ProcessTree.descendants(of: launched.pid) {
            if let st = startTime(of: p) { tree.append((p, st)) }
        }
        func signalAll(_ sig: Int32) {
            for t in tree.reversed() where startTime(of: t.pid) == t.start { kill(t.pid, sig) }
        }
        func anyAlive() -> Bool { tree.contains { startTime(of: $0.pid) == $0.start && isAlive($0.pid) } }
        signalAll(SIGTERM)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, anyAlive() {
            try? await Task.sleep(for: .milliseconds(50))
        }
        for t in tree.reversed() where startTime(of: t.pid) == t.start && isAlive(t.pid) { kill(t.pid, SIGKILL) }
        // Reap if it is our child so it does not linger as a zombie.
        var status: Int32 = 0
        for _ in 0..<40 {
            if waitpid(launched.pid, &status, WNOHANG) != 0 { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return collect()
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 { return false }
        var info = proc_bsdshortinfo()
        let r = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size))
        return !(r > 0 && info.pbsi_status == UInt32(SZOMB))
    }
}
