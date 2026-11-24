import AlloyCore
import Foundation

public enum PluginSandboxError: Error, Equatable {
    /// A path in the profile holds a quote, a backslash or a control character, so it cannot be written as a literal.
    case unquotablePath(String)
    /// A folder the profile would have to open for reading is the disk root, a top-level folder, the home folder or one of
    /// its ancestors, so the plugin is refused instead of getting that much of the disk.
    case grantTooBroad(String)
    case backendMissing
}

/// Everything the profile is built from.
public struct SandboxProfileInput: Sendable {
    public var pluginFolder: URL
    public var scratch: URL
    /// The resolved main executable (what `sandbox-exec` starts), or the script it names.
    public var executable: URL
    /// The programs a `#!` script goes on to start: its interpreter, or for `/usr/bin/env X` the `X` found on the PATH.
    public var interpreters: [URL]
    public var projectRoot: URL?
    public var home: URL
    public var grants: Set<PluginPermission>

    public init(pluginFolder: URL, scratch: URL, executable: URL, interpreters: [URL] = [], projectRoot: URL?, home: URL,
                grants: Set<PluginPermission>) {
        self.pluginFolder = pluginFolder
        self.scratch = scratch
        self.executable = executable
        self.interpreters = interpreters
        self.projectRoot = projectRoot
        self.home = home
        self.grants = grants
    }
}

/// Turns a plugin's command line into one that runs confined.
public protocol PluginSandboxBackend: Sendable {
    func wrap(executable: String, arguments: [String], profile: SandboxProfileInput) throws(PluginSandboxError)
        -> (executable: String, arguments: [String])
}

/// `/usr/bin/sandbox-exec -p <profile> <executable> <args…>`.
public struct SandboxExecBackend: PluginSandboxBackend {
    public static let path = "/usr/bin/sandbox-exec"

    public init() {}

    public func wrap(executable: String, arguments: [String], profile: SandboxProfileInput) throws(PluginSandboxError)
        -> (executable: String, arguments: [String]) {
        let text = try PluginSandbox.profile(profile)
        return (Self.path, ["-p", text, executable] + arguments)
    }
}

/// What a test puts in place of the platform's backend.
public enum PluginSandboxOverride: Sendable {
    /// The platform's own backend.
    case none
    /// No backend at all (as on Linux and Windows).
    case missing
    case backend(any PluginSandboxBackend)
}

/// Confines scripted plugins: a macOS `sandbox-exec` profile built from the plugin's grants.
public enum PluginSandbox {
    /// The backend for `override`: `SandboxExecBackend` on macOS when `/usr/bin/sandbox-exec` is executable; nil elsewhere.
    /// A test passes its override to the host and coordinator it builds, so nothing global is ever replaced.
    public static func backend(_ override: PluginSandboxOverride = .none) -> (any PluginSandboxBackend)? {
        switch override {
        case .missing: return nil
        case .backend(let b): return b
        case .none:
            #if os(macOS)
            return FileManager.default.isExecutableFile(atPath: SandboxExecBackend.path) ? SandboxExecBackend() : nil
            #else
            return nil
            #endif
        }
    }

    public static func backendAvailable(_ override: PluginSandboxOverride = .none) -> Bool { backend(override) != nil }

    public static var backendAvailable: Bool { backendAvailable(.none) }

    /// Scripted plugins must run through a backend on macOS; elsewhere they run unconfined (the manifest rules keep
    /// `network` and `process.spawn` plugins off those platforms).
    public static var isRequired: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The path with every symlink resolved, as the sandbox matches it (`/var` is `/private/var`; Foundation's own
    /// `resolvingSymlinksInPath` folds that back). A path that does not exist yet keeps its unresolved tail.
    public static func canonical(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        var tail: [String] = []
        while true {
            if let real = realpath(path, nil) {
                defer { free(real) }
                return URL(fileURLWithPath: ([String(cString: real)] + tail.reversed()).joined(separator: "/")
                    .replacingOccurrences(of: "//", with: "/"))
            }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path, !parent.isEmpty else { return url }
            tail.append((path as NSString).lastPathComponent)
            path = parent
        }
    }

    private static func quoted(_ path: String) throws(PluginSandboxError) -> String {
        for scalar in path.unicodeScalars where scalar == "\"" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F {
            throw PluginSandboxError.unquotablePath(path)
        }
        return "\"\(path)\""
    }

    /// Read-only system and runtime folders every plugin may read and run programs from. Children inherit the sandbox,
    /// so the `xcrun` stubs behind `/usr/bin/python3` and the like work without the `process.spawn` grant.
    public static let systemPrefixes = [
        "/usr/lib", "/usr/share", "/System", "/Library/Developer/CommandLineTools", "/Applications/Xcode.app",
        "/opt/homebrew", "/usr/local", "/bin", "/usr/bin", "/sbin", "/usr/libexec",
    ]

    private static func covered(_ path: String) -> Bool {
        systemPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// The folder as a profile literal, or nil when a system prefix already covers it. Refuses the disk root, a top-level
    /// folder, the home folder and any ancestor of it.
    private static func grant(_ folder: URL, home: URL) throws(PluginSandboxError) -> String? {
        // The caller passes canonical paths; `standardizedFileURL` would fold `/private/var` back to `/var`, which the
        // sandbox does not match.
        let path = folder.path
        if covered(path) { return nil }
        let depth = path.split(separator: "/").count
        let homePath = home.path
        if depth < 2 || path == homePath || homePath.hasPrefix(path + "/") { throw PluginSandboxError.grantTooBroad(path) }
        return try quoted(path)
    }

    public static func profile(_ input: SandboxProfileInput) throws(PluginSandboxError) -> String {
        let programs = [input.executable] + input.interpreters
        var exec: [String] = []
        for program in programs { exec.append("(literal \(try quoted(program.path)))") }
        var readable: [String] = []
        for prefix in systemPrefixes {
            exec.append("(subpath \(try quoted(prefix)))")
            readable.append("(subpath \(try quoted(prefix)))")
        }
        var computed = [input.pluginFolder, input.scratch] + programs.map { $0.deletingLastPathComponent() }
        if input.grants.contains(.projectRead), let root = input.projectRoot { computed.append(root) }
        var seen = Set<String>()
        for folder in computed {
            guard let literal = try grant(folder, home: input.home), seen.insert(literal).inserted else { continue }
            readable.append("(subpath \(literal))")
        }
        let scratch = try quoted(input.scratch.path)
        let dotClaude = try quoted(input.home.appendingPathComponent(".claude").path)
        var lines = [
            "(version 1)",
            "(deny default)",
            "(allow process-exec \(exec.joined(separator: " ")))",
            "(allow file-read* \(readable.joined(separator: " ")) (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\"))",
            // dyld and the Swift runtime list the root directory at start; without this a sandboxed process aborts.
            "(allow file-read* (literal \"/\"))",
            // The local time zone, so a plugin does not see UTC.
            "(allow file-read* (literal \"/private/etc/localtime\") (subpath \"/private/var/db/timezone\"))",
            "(allow file-read-metadata)",
            "(allow file-write* (subpath \(scratch)) (literal \"/dev/null\"))",
            "(allow sysctl-read)",
            // No mach-lookup: a plugin reaches no system service (pasteboard, LaunchServices, ...). The Swift runtime, sh,
            // bash and python3 run without any, and DNS goes through the resolver socket below.
            "(allow signal (target self))",
        ]
        if input.grants.contains(.network) {
            lines += [
                // Internet and loopback only: no Unix-domain sockets (docker.sock), except the resolver's own.
                "(allow network-outbound (remote ip))",
                "(allow network-inbound (local ip \"localhost:*\"))",
                "(allow network-bind (local ip \"localhost:*\"))",
                "(allow system-socket)",
                "(allow file-read* (literal \"/private/etc/resolv.conf\") (literal \"/private/etc/hosts\") (subpath \"/private/etc/ssl\"))",
                "(allow network-outbound (literal \"/private/var/run/mDNSResponder\"))",
                // The system trust store (curl, URLSession) asks these two services to evaluate a server certificate.
                // Found by bisecting every launchd service name; nothing else is needed, and the pasteboard stays out.
                "(allow mach-lookup (global-name \"com.apple.trustd.agent\") (global-name \"com.apple.TrustEvaluationAgent\"))",
            ]
        }
        if input.grants.contains(.processSpawn) { lines.append("(allow process-fork) (allow process-exec)") }
        lines.append("(deny file-write* (subpath \(dotClaude)) (regex #\"/\\.claude(/|$)\") (regex #\"/\\.git(/|$)\"))")
        return lines.joined(separator: "\n")
    }
}
