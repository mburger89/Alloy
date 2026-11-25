import AlloyCore
import AlloyRPC
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyPlugins

private func waitFor(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private let fakeHome = "/Volumes/Fake/home/someone"

private func input(grants: Set<PluginPermission> = [], root: String? = "/work/project", exe: String = "/opt/p/bin/run",
                   home: String = fakeHome) -> SandboxProfileInput {
    SandboxProfileInput(pluginFolder: URL(fileURLWithPath: "/plugins/a"), scratch: URL(fileURLWithPath: "/data/a/tmp"),
                        executable: URL(fileURLWithPath: exe), projectRoot: root.map { URL(fileURLWithPath: $0) },
                        home: URL(fileURLWithPath: home), grants: grants)
}

/// A TCP listener on a free local port, so a plugin's `connect` has something to reach.
private final class Listener {
    let fd: Int32
    let port: UInt16
    init() {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(sock, 8)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) } }
        fd = sock
        port = UInt16(bigEndian: bound.sin_port)
    }
    deinit { close(fd) }
}

@Suite("PluginSandbox", .serialized)
struct PluginSandboxTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-sandbox-tests-\(UUID().uuidString)")
    let paths: PluginPaths
    let project: URL
    let outside: URL

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = PluginPaths(appSupport: root)
        project = root.appendingPathComponent("project")
        outside = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try "hello".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Profile text (any platform)

    private static let prefixes = PluginSandbox.systemPrefixes
    private static let execPrefixes = prefixes.map { "(subpath \"\($0)\")" }.joined(separator: " ")

    @Test func profileHasExactBaseRules() throws {
        let text = try PluginSandbox.profile(input())
        let lines = [
            "(version 1)",
            "(deny default)",
            "(allow process-exec (literal \"/opt/p/bin/run\") \(Self.execPrefixes))",
            "(allow file-read* \(Self.execPrefixes) (subpath \"/plugins/a\") (subpath \"/data/a/tmp\") (subpath \"/opt/p/bin\") (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\"))",
            "(allow file-read* (literal \"/\"))",
            "(allow file-read* (literal \"/private/etc/localtime\") (subpath \"/private/var/db/timezone\"))",
            "(allow file-read-metadata)",
            "(allow file-write* (subpath \"/data/a/tmp\") (literal \"/dev/null\"))",
            "(allow sysctl-read)",
            "(allow signal (target self))",
            "(deny file-write* (subpath \"\(fakeHome)/.claude\") (regex #\"/\\.claude(/|$)\") (regex #\"/\\.git(/|$)\"))",
        ]
        #expect(text.components(separatedBy: "\n") == lines)
        #expect(!text.contains("mach-lookup"), "no Mach service is reachable")
        #expect(!text.contains("(subpath \"/\")"), "the whole disk is never readable")
        #expect(!text.contains("network"), "no network rule without the grant")
    }

    @Test func grantsAddTheirRules() throws {
        let base = try PluginSandbox.profile(input()).components(separatedBy: "\n")
        let read = try PluginSandbox.profile(input(grants: [.projectRead])).components(separatedBy: "\n")
        let net = try PluginSandbox.profile(input(grants: [.network])).components(separatedBy: "\n")
        let spawn = try PluginSandbox.profile(input(grants: [.processSpawn])).components(separatedBy: "\n")
        let ungranted = try PluginSandbox.profile(input(grants: [.projectWrite, .sessionsRead, .mcpTools])).components(separatedBy: "\n")
        func added(_ lines: [String]) -> [String] { lines.filter { !base.contains($0) } }
        #expect(read.contains { $0.contains("/work/project") })
        #expect(read.filter { $0.contains("/work/project") }.count == 1)
        #expect(added(net) == [
            "(allow network-outbound (remote ip))",
            "(allow network-inbound (local ip \"localhost:*\"))",
            "(allow network-bind (local ip \"localhost:*\"))",
            "(allow system-socket)",
            "(allow file-read* (literal \"/private/etc/resolv.conf\") (literal \"/private/etc/hosts\") (subpath \"/private/etc/ssl\"))",
            "(allow network-outbound (literal \"/private/var/run/mDNSResponder\"))",
            "(allow mach-lookup (global-name \"com.apple.trustd.agent\") (global-name \"com.apple.TrustEvaluationAgent\"))",
        ])
        // Only these two Mach services, and only with the network grant: no pasteboard, no LaunchServices.
        #expect(net.filter { $0.contains("mach-lookup") }.count == 1)
        #expect(!base.joined().contains("mach-lookup") && !spawn.joined().contains("mach-lookup"))
        #expect(!net.joined().contains("(allow network*)") && !net.joined().contains("network-outbound)"),
                "a bare network rule would allow Unix-domain sockets")
        #expect(added(spawn) == ["(allow process-fork) (allow process-exec)"])
        #expect(added(ungranted).isEmpty)
        #expect(base.last?.hasPrefix("(deny file-write*") == true)
        #expect(read.last == base.last && net.last == base.last && spawn.last == base.last)
    }

    @Test func systemExecutableAddsNoComputedFolder() throws {
        // /bin/bash: its folder is a top-level folder, but a system prefix already covers it, so nothing is granted and
        // nothing refused. The profile never opens the parent of the parent.
        for exe in ["/bin/bash", "/bin/sh", "/usr/bin/env", "/opt/homebrew/bin/python3"] {
            let text = try PluginSandbox.profile(input(exe: exe))
            #expect(!text.contains("(subpath \"/\")"), "\(exe)")
            #expect(!text.contains("(subpath \"/opt\")") && !text.contains("(subpath \"/usr\")"), "\(exe)")
        }
    }

    @Test func foldersThatAreTooBroadFailClosed() throws {
        func refused(_ i: SandboxProfileInput, _ folder: String) {
            #expect(throws: PluginSandboxError.grantTooBroad(folder)) { try PluginSandbox.profile(i) }
        }
        refused(input(exe: "/tool"), "/")
        refused(input(exe: "/opt/tool"), "/opt")
        refused(input(exe: "\(fakeHome)/tool"), fakeHome)
        refused(input(exe: "/Volumes/tool"), "/Volumes")
        refused(input(exe: "/Volumes/Fake/home/tool"), "/Volumes/Fake/home")
        refused(input(exe: "/Users" + "/tool"), "/Users")
        refused(input(grants: [.projectRead], root: fakeHome), fakeHome)
        refused(input(grants: [.projectRead], root: "/Users"), "/Users")
        refused(input(grants: [.projectRead], root: "/"), "/")
        // A tool in a folder of its own under home reads that folder and nothing more.
        let text = try PluginSandbox.profile(input(exe: "\(fakeHome)/bin/tool"))
        #expect(text.contains("(subpath \"\(fakeHome)/bin\")") && !text.contains("(subpath \"\(fakeHome)\")"))
    }

    @Test func shebangInterpretersAreExecutableAndTheirFoldersReadable() throws {
        var i = input(exe: "/plugins/a/run.sh")
        i.interpreters = [URL(fileURLWithPath: "/bin/sh"), URL(fileURLWithPath: "/usr/bin/env")]
        let text = try PluginSandbox.profile(i)
        #expect(text.contains("(allow process-exec (literal \"/plugins/a/run.sh\") (literal \"/bin/sh\") (literal \"/usr/bin/env\")"))
    }

    @Test func unquotablePathFails() throws {
        #expect(throws: PluginSandboxError.unquotablePath("/tmp/a\"b")) {
            try PluginSandbox.profile(input(grants: [.projectRead], root: "/tmp/a\"b"))
        }
        #expect(throws: PluginSandboxError.self) { try PluginSandbox.profile(input(exe: "/opt/a\\b/run")) }
        #expect(throws: PluginSandboxError.self) { try PluginSandbox.profile(input(exe: "/opt/a\nb/run")) }
    }

    // MARK: Real confinement (macOS)

    private func environment() -> [String: String] {
        ["PATH": "\(fakePluginDirectory):/usr/bin:/bin", "HOME": outside.path, "LANG": "en_US.UTF-8"]
    }

    private func start(_ id: String, grants: Set<PluginPermission> = [], script: JSONValue, withRoot: Bool = true,
                       sandbox: PluginSandboxOverride = .none) async throws
        -> (host: PluginHost, log: URL, started: Bool) {
        let scratch = paths.scratch(id)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let folder = try writeFakePlugin(id: id, in: paths.plugins, permissions: grants.map(\.rawValue), script: script,
                                         logDirectory: scratch)
        let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: [fakePluginDirectory]).get()
        let host = PluginHost(paths: paths, baseEnvironment: environment(), sandbox: sandbox)
        await host.configure([PluginRuntimeConfig(manifest: manifest, folder: folder, grants: grants)])
        if withRoot { await host.setWorkspace(root: project) }
        let started = await host.activate(id, .command)
        return (host, scratch.appendingPathComponent("log.jsonl"), started)
    }

    private func result(_ log: URL, _ suffix: String) async -> String? {
        let file = URL(fileURLWithPath: log.path + suffix)
        _ = await waitFor { FileManager.default.fileExists(atPath: file.path) }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func sandboxedPluginRunsAndAnswers() async throws {
        let (host, log, started) = try await start("dev.test.runs", script: .object([:]))
        #expect(started)
        #expect(await waitFor { (try? String(contentsOf: log, encoding: .utf8))?.contains("initialize") == true })
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func sandboxedPluginCannotReadHome() async throws {
        let secret = outside.appendingPathComponent("secret.txt").path
        let (host, log, started) = try await start("dev.test.home", script: .object(["readFile": .string(secret)]))
        #expect(started)
        #expect(await result(log, ".read") == "denied")
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func projectReadGrantAllowsRoot() async throws {
        let file = project.appendingPathComponent("a.txt").path
        let (h1, log1, _) = try await start("dev.test.noread", script: .object(["readFile": .string(file)]))
        #expect(await result(log1, ".read") == "denied")
        await h1.shutdown()
        let (h2, log2, _) = try await start("dev.test.read", grants: [.projectRead], script: .object(["readFile": .string(file)]))
        #expect(await result(log2, ".read") == "ok")
        await h2.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func cannotWriteProject() async throws {
        let target = project.appendingPathComponent("x")
        let (host, log, _) = try await start("dev.test.write", grants: [.projectRead, .projectWrite],
                                             script: .object(["writeFile": .string(target.path)]))
        #expect(await result(log, ".write") == "denied")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func networkDeniedWithoutGrant() async throws {
        let listener = Listener()
        let target = "127.0.0.1:\(listener.port)"
        let (h1, log1, _) = try await start("dev.test.nonet", script: .object(["connect": .string(target)]))
        #expect(await result(log1, ".connect") == "denied")
        await h1.shutdown()
        let (h2, log2, _) = try await start("dev.test.net", grants: [.network], script: .object(["connect": .string(target)]))
        #expect(await result(log2, ".connect") == "ok")
        await h2.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func spawnDeniedWithoutGrant() async throws {
        let (host, log, _) = try await start("dev.test.nospawn", script: .object(["spawnChild": .bool(true)]))
        #expect(await result(log, ".child") == "denied")
        await host.shutdown()
    }

    @Test func backendMissingFailsClosed() async throws {
        #if os(macOS)
        let (host, _, started) = try await start("dev.test.missing", script: .object([:]), sandbox: .missing)
        #expect(!started)
        if case .sandboxUnavailable = await host.state(of: "dev.test.missing") {} else {
            Issue.record("expected sandboxUnavailable, got \(await host.state(of: "dev.test.missing"))")
        }
        await host.shutdown()
        #endif
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func unquotablePluginPathDoesNotStart() async throws {
        let id = "dev.test.quote"
        let scratch = paths.scratch(id)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let folder = try writeFakePlugin(id: id, in: paths.plugins, script: .object([:]), logDirectory: scratch)
        let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: [fakePluginDirectory]).get()
        let host = PluginHost(paths: paths, baseEnvironment: environment(), sandbox: .none)
        var bad = PluginRuntimeConfig(manifest: manifest, folder: folder.appendingPathComponent("a\"b"), grants: [])
        bad.folder = URL(fileURLWithPath: folder.path + "/a\"b")
        await host.configure([bad])
        #expect(await host.activate(id, .command) == false)
        if case .sandboxUnavailable = await host.state(of: id) {} else { Issue.record("expected sandboxUnavailable") }
        await host.shutdown()
    }

    // MARK: Shell and script plugins, system services, sockets

    private static let initializeReply = #"printf 'Content-Length: 50\r\n\r\n{"id":1,"jsonrpc":"2.0","result":{"apiVersion":1}}'"#

    /// Writes a plugin whose main is `command` (a program on the PATH, or a script file in the folder).
    private func shellPlugin(_ id: String, command: String, args: [String] = [], file: (name: String, body: String)? = nil,
                             permissions: [String] = []) throws -> URL {
        let folder = paths.plugins.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.scratch(id), withIntermediateDirectories: true)
        if let file {
            let url = folder.appendingPathComponent(file.name)
            try file.body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let manifest: JSONValue = .object([
            "id": .string(id), "name": .string(id), "version": .string("1.0.0"), "apiVersion": .number(1),
            "main": .object(["command": .string(command), "args": .array(args.map { .string($0) })]),
            "permissions": .array(permissions.map { .string($0) }),
        ])
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("alloy-plugin.json"))
        return folder
    }

    private func run(_ id: String, folder: URL, grants: Set<PluginPermission> = []) async throws -> (host: PluginHost, started: Bool) {
        let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: ["/bin", "/usr/bin"]).get()
        let host = PluginHost(paths: paths, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": outside.path, "LANG": "en_US.UTF-8"],
                              sandbox: .none)
        await host.configure([PluginRuntimeConfig(manifest: manifest, folder: folder, grants: grants)])
        return (host, await host.activate(id, .command))
    }

    /// What a hostile shell plugin does: read a file in the fake home, list that folder, then answer `initialize`.
    private var probeBody: String {
        let secret = outside.appendingPathComponent("secret.txt").path
        return """
        exec 2>/dev/null
        if read x < "\(secret)"; then echo leak > "$TMPDIR/read"; else echo denied > "$TMPDIR/read"; fi
        set -- "\(outside.path)"/*
        echo "$1" > "$TMPDIR/list"
        \(Self.initializeReply)
        while read line; do :; done

        """
    }

    private func scratchFile(_ id: String, _ name: String) async -> String? {
        let url = paths.scratch(id).appendingPathComponent(name)
        _ = await waitFor { FileManager.default.fileExists(atPath: url.path) }
        return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func bashMainCannotReadOrListHome() async throws {
        let id = "dev.test.bash"
        let folder = try shellPlugin(id, command: "bash", args: ["-c", probeBody])
        let (host, started) = try await run(id, folder: folder)
        #expect(started)
        #expect(await scratchFile(id, "read") == "denied")
        #expect(await scratchFile(id, "list") == "\(outside.path)/*", "the folder cannot be listed")
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func bashScriptCannotReadOrListHome() async throws {
        let id = "dev.test.bashscript"
        let folder = try shellPlugin(id, command: "run.sh", file: ("run.sh", "#!/bin/bash\n" + probeBody))
        let (host, started) = try await run(id, folder: folder)
        #expect(started)
        #expect(await scratchFile(id, "read") == "denied")
        #expect(await scratchFile(id, "list") == "\(outside.path)/*")
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func shScriptStartsAndAnswersInitialize() async throws {
        let id = "dev.test.shscript"
        let folder = try shellPlugin(id, command: "run.sh", file: ("run.sh", "#!/bin/sh\n" + probeBody))
        let (host, started) = try await run(id, folder: folder)
        #expect(started)
        #expect(await host.state(of: id) == .running)
        #expect(await scratchFile(id, "read") == "denied")
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func envShebangScriptStartsAndAnswersInitialize() async throws {
        let id = "dev.test.envscript"
        let folder = try shellPlugin(id, command: "run.sh", file: ("run.sh", "#!/usr/bin/env sh\n" + probeBody))
        let (host, started) = try await run(id, folder: folder)
        #expect(started)
        #expect(await host.state(of: id) == .running)
        #expect(await scratchFile(id, "read") == "denied")
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func pluginInsideTheDiskRootFolderIsRefused() async throws {
        // A main whose folder is the home folder would expose all of home: refused with a log line, never started.
        let id = "dev.test.broad"
        let folder = try shellPlugin(id, command: "run.sh", file: ("run.sh", "#!/bin/sh\n" + probeBody))
        let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: ["/bin", "/usr/bin"]).get()
        // HOME is the plugin's own folder, so its folder is the home folder.
        let host = PluginHost(paths: paths, baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": folder.path], sandbox: .none)
        await host.configure([PluginRuntimeConfig(manifest: manifest, folder: folder, grants: [])])
        #expect(await host.activate(id, .command) == false)
        if case .sandboxUnavailable(let why) = await host.state(of: id) { #expect(why.contains("too much")) } else {
            Issue.record("expected sandboxUnavailable")
        }
        #expect(await host.stderrTail(of: id).contains("did not start"))
        await host.shutdown()
    }

    /// A shell plugin that answers `initialize`, then replaces itself with a small script kept in its scratch folder (a
    /// program outside the system folders). Returns what the script printed.
    private func execOfScratchCopy(_ id: String, grants: Set<PluginPermission>) async throws -> String {
        let copy = paths.scratch(id).appendingPathComponent("mytool")
        try FileManager.default.createDirectory(at: paths.scratch(id), withIntermediateDirectories: true)
        try "#!/bin/sh\necho ran\n".write(to: copy, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
        let body = """
        exec 2>/dev/null
        \(Self.initializeReply)
        exec "\(copy.path)" > "$TMPDIR/ran"

        """
        let folder = try shellPlugin(id, command: "bash", args: ["-c", body], permissions: grants.map(\.rawValue))
        let (host, _) = try await run(id, folder: folder, grants: grants)
        try? await Task.sleep(for: .milliseconds(700))
        await host.shutdown()
        return (try? String(contentsOf: paths.scratch(id).appendingPathComponent("ran"), encoding: .utf8)) ?? ""
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func execOfProgramOutsideTheSystemFoldersNeedsTheSpawnGrant() async throws {
        // The system folders can be executed (the xcrun stubs need it), anything else needs process.spawn.
        #expect(try await execOfScratchCopy("dev.test.execdeny", grants: []).isEmpty, "denied without the grant")
        #expect(try await execOfScratchCopy("dev.test.execok", grants: [.processSpawn]) == "ran\n", "the control runs with it")
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func clipboardIsUnreachableEvenWithSpawn() async throws {
        let id = "dev.test.clip"
        let body = """
        exec 2>/dev/null
        /usr/bin/pbpaste > "$TMPDIR/clip"; echo $? > "$TMPDIR/rc"
        \(Self.initializeReply)
        while read line; do :; done

        """
        let folder = try shellPlugin(id, command: "bash", args: ["-c", body], permissions: ["process.spawn"])
        let (host, started) = try await run(id, folder: folder, grants: [.processSpawn])
        #expect(started)
        let rc = await scratchFile(id, "rc")
        #expect(rc != nil && rc != "0", "pbpaste cannot reach the pasteboard service")
        #expect(await scratchFile(id, "clip") == "")
        await host.shutdown()
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func networkGrantStopsAtUnixSockets() async throws {
        // A short path: Unix socket paths are limited to 104 bytes.
        let dir = URL(fileURLWithPath: "/private/tmp/asb-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let socketPath = dir.appendingPathComponent("u.sock").path
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) } }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0 && listen(server, 4) == 0)
        let listener = Listener()
        let script: JSONValue = .object(["connectUnix": .string(socketPath), "connect": .string("127.0.0.1:\(listener.port)")])
        let (host, log, _) = try await start("dev.test.unix", grants: [.network], script: script)
        #expect(await result(log, ".unix") == "denied", "a docker.sock-style socket stays out of reach")
        #expect(await result(log, ".connect") == "ok", "loopback TCP still connects")
        await host.shutdown()
    }

    /// A shell plugin running `curl -sI https://example.com` and `pbpaste` (read only), then answering `initialize`.
    private func httpsProbe(_ id: String, grants: Set<PluginPermission>) async throws -> (curl: String?, pbpaste: String?) {
        let body = """
        exec 2>/dev/null
        /usr/bin/curl -sI -m 10 https://example.com > /dev/null; echo $? > "$TMPDIR/curl"
        /usr/bin/pbpaste > /dev/null; echo $? > "$TMPDIR/pbpaste"
        \(Self.initializeReply)
        while read line; do :; done

        """
        let folder = try shellPlugin(id, command: "bash", args: ["-c", body], permissions: grants.map(\.rawValue))
        let (host, _) = try await run(id, folder: folder, grants: grants)
        let curl = await scratchFile(id, "curl"), pbpaste = await scratchFile(id, "pbpaste")
        await host.shutdown()
        return (curl, pbpaste)
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func httpsWorksOnlyWithTheNetworkGrantAndThePasteboardStaysClosed() async throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var found: UnsafeMutablePointer<addrinfo>?
        let online = getaddrinfo("example.com", "443", &hints, &found) == 0
        if let found { freeaddrinfo(found) }
        guard online else { return }
        let granted = try await httpsProbe("dev.test.https", grants: [.network, .processSpawn])
        #expect(granted.curl == "0", "curl fetches an HTTPS URL through the system trust store")
        #expect(granted.pbpaste == "1", "the pasteboard is still unreachable")
        let denied = try await httpsProbe("dev.test.nohttps", grants: [.processSpawn])
        #expect(denied.curl != nil && denied.curl != "0", "no network grant, no HTTPS")
    }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func dnsResolvesWithNetworkGrantOnly() async throws {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        var found: UnsafeMutablePointer<addrinfo>?
        let online = getaddrinfo("example.com", "443", &hints, &found) == 0
        if let found { freeaddrinfo(found) }
        guard online else { return }
        let script: JSONValue = .object(["resolve": .string("example.com")])
        let (h1, log1, _) = try await start("dev.test.nodns", script: script)
        #expect(await result(log1, ".resolve") == "denied")
        await h1.shutdown()
        let (h2, log2, _) = try await start("dev.test.dns", grants: [.network], script: script)
        #expect(await result(log2, ".resolve") == "ok")
        await h2.shutdown()
    }
}
