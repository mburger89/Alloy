import Foundation

/// Finds the git executable once per launch and checks it is usable.
public enum GitExecutable {
    public enum Resolution: Equatable, Sendable {
        case usable(path: String, version: [Int])
        case notFound
        /// The `/usr/bin/git` shim exists but no developer toolchain is selected (running it would show a dialog).
        case shimWithoutTools
        /// The version string git reported, below the supported minimum.
        case tooOld(String)
    }

    /// The oldest supported git.
    public static let minimumVersion = [2, 23]

    /// Pure resolution over injected probes. A configured path wins, else the first `git` on `PATH`, else `/usr/bin`.
    public static func resolve(gitPath: String?, environment: [String: String], isExecutable: (String) -> Bool,
                               xcodeSelectOK: () -> Bool, versionOf: (String) -> String?) -> Resolution {
        var candidate: String?
        if let gitPath, !gitPath.isEmpty, isExecutable(gitPath) { candidate = gitPath }
        if candidate == nil {
            #if os(Windows)
            let name = "git.exe", separator: Character = ";"
            #else
            let name = "git", separator: Character = ":"
            #endif
            var dirs = (environment["PATH"] ?? "").split(separator: separator).map(String.init).filter { !$0.isEmpty }
            #if !os(Windows)
            if !dirs.contains("/usr/bin") { dirs.append("/usr/bin") }
            #endif
            for dir in dirs {
                let path = dir.hasSuffix("/") ? dir + name : dir + "/" + name
                if isExecutable(path) { candidate = path; break }
            }
        }
        guard let path = candidate else { return .notFound }
        if path == "/usr/bin/git", environment["DEVELOPER_DIR"] == nil, !xcodeSelectOK() { return .shimWithoutTools }
        guard let output = versionOf(path), let version = parseVersion(output) else { return .notFound }
        let shown = version.map(String.init).joined(separator: ".")
        if !atLeastMinimum(version) { return .tooOld(shown) }
        return .usable(path: path, version: version)
    }

    /// "git version 2.39.3 (Apple Git-146)" gives [2, 39, 3].
    static func parseVersion(_ output: String) -> [Int]? {
        guard let range = output.range(of: "version ") else { return nil }
        let token = output[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        let parts = token.split(separator: ".").compactMap { Int($0) }
        return parts.count >= 2 ? parts : nil
    }

    private static func atLeastMinimum(_ v: [Int]) -> Bool {
        for (a, b) in zip(v, minimumVersion) where a != b { return a > b }
        return v.count >= minimumVersion.count
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var gitPath: String?
        var resolved: Resolution?
    }
    private static let state = State()

    /// Sets the configured path. Ignored once the probe has run.
    public static func configure(gitPath: String?) {
        state.lock.withLock { if state.resolved == nil { state.gitPath = gitPath } }
    }

    /// The live resolution, probed on first use and then kept for the launch.
    public static var current: Resolution {
        state.lock.withLock {
            if let r = state.resolved { return r }
            let r = resolve(gitPath: state.gitPath, environment: ProcessInfo.processInfo.environment,
                            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                            xcodeSelectOK: DeveloperDirectory.liveSelected, versionOf: liveVersion)
            state.resolved = r
            return r
        }
    }

    private static func liveVersion(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// Whether a developer toolchain is selected. Running a `/usr/bin` shim (git, xcrun) without one shows a system dialog.
public enum DeveloperDirectory {
    /// `DEVELOPER_DIR` set, or `xcode-select -p` succeeds (it never shows a dialog).
    public static func isSelected(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let d = environment["DEVELOPER_DIR"], !d.isEmpty { return true }
        return liveSelected()
    }

    static func liveSelected() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
