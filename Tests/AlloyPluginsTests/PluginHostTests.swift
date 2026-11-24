import AlloyCore
import AlloyRPC
import AlloyTestSupport
import Foundation
import Testing
@testable import AlloyPlugins

/// A gate a test holds a service call behind until it opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { c in
            let ready = lock.withLock { () -> Bool in
                if open { return true }
                waiters.append(c)
                return false
            }
            if ready { c.resume() }
        }
    }
    func release() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { waiters = [] }
            return waiters
        }
        for c in all { c.resume() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

private func waitFor(_ timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

@Suite("PluginHost", .serialized)
struct PluginHostTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-host-tests-\(UUID().uuidString)")
    let paths: PluginPaths

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = PluginPaths(appSupport: root)
    }

    private var environment: [String: String] {
        ["PATH": "\(fakePluginDirectory):/usr/bin:/bin", "HOME": root.path, "LANG": "en_US.UTF-8"]
    }

    /// Writes the fake plugin and loads its config.
    private func plugin(_ id: String, grants: Set<PluginPermission> = [], script: JSONValue = .object([:]),
                        apiVersion: Int = 1) throws -> (config: PluginRuntimeConfig, folder: URL) {
        let folder = try writeFakePlugin(id: id, in: paths.plugins, permissions: grants.map(\.rawValue), script: script,
                                         apiVersion: apiVersion)
        let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: [fakePluginDirectory]).get()
        return (PluginRuntimeConfig(manifest: manifest, folder: folder, grants: grants, values: ["x": .bool(true)]), folder)
    }

    private func host(limits: PluginLimits = PluginLimits(), services: PluginHostServices = PluginHostServices()) -> PluginHost {
        PluginHost(paths: paths, limits: limits, baseEnvironment: environment, services: services)
    }

    private func log(_ folder: URL, _ name: String = "log.jsonl") -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private func methods(_ folder: URL) -> [String] { log(folder).compactMap { $0["method"]?.stringValue } }

    private func uri(_ url: URL) -> String { URL(fileURLWithPath: url.path, isDirectory: false).absoluteString }

    // MARK: -

    @Test func nothingStartsBeforeActivation() async throws {
        let (config, folder) = try plugin("dev.test.idle")
        let host = host()
        await host.configure([config])
        #expect(await host.runningCount == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("log.jsonl").path))
        await host.shutdown()
    }

    @Test func handshakeSendsApiVersionGrantsAndSettings() async throws {
        let (config, folder) = try plugin("dev.test.hello", grants: [.projectRead])
        let host = host()
        let project = root.appendingPathComponent("proj")
        await host.configure([config])
        await host.setWorkspace(root: project)
        #expect(await host.activate("dev.test.hello", .command))
        #expect(await waitFor { methods(folder).count >= 3 })
        let messages = log(folder)
        #expect(messages[0]["method"]?.stringValue == "initialize")
        #expect(messages[0]["params"] == .object([
            "apiVersion": .number(1), "pluginId": .string("dev.test.hello"), "grants": .array([.string("project.read")]),
            "settings": .object(["x": .bool(true)]), "root": .string(uri(project)),
        ]))
        #expect(messages[1]["method"]?.stringValue == "initialized")
        #expect(messages[2]["method"]?.stringValue == "workspace/opened")
        #expect(messages[2]["params"]?["root"]?.stringValue == uri(project))
        #expect(await host.state(of: "dev.test.hello") == .running)
        await host.shutdown()
    }

    @Test func manifestApiMismatchNeverStarts() async throws {
        let (config, folder) = try plugin("dev.test.api", apiVersion: 2)
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.api", .command) == false)
        #expect(await host.state(of: "dev.test.api") == .needsAPI(2))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("log.jsonl").path))
        await host.shutdown()
    }

    @Test func initializeAnswerMismatchStops() async throws {
        let (config, _) = try plugin("dev.test.three", script: .object(["initializeResult": .object(["apiVersion": .number(3)])]))
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.three", .command) == false)
        #expect(await host.state(of: "dev.test.three") == .needsAPI(3))
        #expect(await host.runningCount == 0)
        #expect(PluginRunningFile.read(paths.running).isEmpty)
        await host.shutdown()
    }

    @Test func deniedMethodGetsPermissionError() async throws {
        let (config, folder) = try plugin("dev.test.deny", script: .object([
            "afterInitialized": .array([.object(["method": .string("document/text"), "params": .object([:]), "id": .number(7)])]),
        ]))
        let calls = Counter()
        let host = host(services: PluginHostServices { _, _, _ in calls.bump(); return .success(.null) })
        await host.configure([config])
        #expect(await host.activate("dev.test.deny", .command))
        #expect(await waitFor { log(folder).contains { $0["id"]?.intValue == 7 } })
        let answer = try #require(log(folder).first { $0["id"]?.intValue == 7 })
        #expect(answer["error"]?["code"]?.intValue == -32003)
        #expect(answer["error"]?["data"]?["permission"]?.stringValue == "project.read")
        #expect(calls.count == 0)
        await host.shutdown()
    }

    @Test func stopKillsThePluginsChild() async throws {
        let (config, folder) = try plugin("dev.test.child", script: .object(["spawnChild": .bool(true)]))
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.child", .command))
        let childFile = folder.appendingPathComponent("log.jsonl.child")
        #expect(await waitFor { FileManager.default.fileExists(atPath: childFile.path) })
        let pid = try #require(Int32(try String(contentsOf: childFile, encoding: .utf8)))
        #expect(alive(pid))
        await host.stop("dev.test.child")
        #expect(await waitFor(.seconds(3)) { !alive(pid) })
        await host.shutdown()
    }

    @Test func sigtermIgnoringPluginIsKilledAfterGrace() async throws {
        let (config, _) = try plugin("dev.test.stubborn", script: .object(["ignoreSigterm": .bool(true)]))
        var limits = PluginLimits()
        limits.stopGrace = .milliseconds(300)
        let host = host(limits: limits)
        await host.configure([config])
        #expect(await host.activate("dev.test.stubborn", .command))
        let pid = try #require(PluginRunningFile.read(paths.running).first?.pid)
        #expect(alive(pid))
        await host.stop("dev.test.stubborn")
        #expect(await waitFor(.seconds(3)) { !alive(pid) })
        await host.shutdown()
    }

    @Test func runningFileTracksLiveGroups() async throws {
        let (config, _) = try plugin("dev.test.file")
        let host = host()
        await host.configure([config])
        #expect(PluginRunningFile.read(paths.running).isEmpty)
        #expect(await host.activate("dev.test.file", .command))
        let entries = PluginRunningFile.read(paths.running)
        #expect(entries.count == 1 && entries[0].id == "dev.test.file" && entries[0].pid > 1)
        await host.stop("dev.test.file")
        #expect(PluginRunningFile.read(paths.running).isEmpty)
        await host.shutdown()
    }

    @Test func staleRunningFileGroupIsKilledAtLaunch() async throws {
        let probe = LiveProcessProbe()
        let process = try ServerProcess(executable: "/bin/sh", arguments: ["-c", "sleep 600"], environment: environment,
                                        currentDirectory: root, processGroup: true)
        let pid = process.processIdentifier
        defer { kill(-pid, SIGKILL) }
        let start = try #require(probe.startTime(pid: pid))
        PluginRunningFile.write([.init(id: "dev.stale.one", pid: pid, start: start)], to: paths.running)
        PluginHost.killStaleGroups(paths: paths, probe: probe)
        #expect(await waitFor(.seconds(3)) { !process.isRunning })
        #expect(PluginRunningFile.read(paths.running).isEmpty)
    }

    @Test func staleEntryWithOtherStartTimeIsLeftAlone() async throws {
        let probe = LiveProcessProbe()
        let process = try ServerProcess(executable: "/bin/sh", arguments: ["-c", "sleep 600"], environment: environment,
                                        currentDirectory: root, processGroup: true)
        let pid = process.processIdentifier
        defer { kill(-pid, SIGKILL) }
        let start = try #require(probe.startTime(pid: pid))
        PluginRunningFile.write([.init(id: "dev.stale.two", pid: pid, start: start + 1000)], to: paths.running)
        PluginHost.killStaleGroups(paths: paths, probe: probe)
        try await Task.sleep(for: .milliseconds(300))
        #expect(process.isRunning)
        #expect(PluginRunningFile.read(paths.running).isEmpty)
        await process.stop(grace: .milliseconds(200))
    }

    @Test func noRunningFileMeansNothingIsWritten() throws {
        PluginHost.killStaleGroups(paths: paths, probe: LiveProcessProbe())
        #expect(!FileManager.default.fileExists(atPath: paths.running.path))
        #expect(!FileManager.default.fileExists(atPath: paths.plugins.path))
    }

    /// A group whose leader is gone but whose member lives on: `sh` starts `sleep` and exits.
    private func orphanGroup() async throws -> (pgid: Int32, leaderStart: Double) {
        let probe = LiveProcessProbe()
        let process = try ServerProcess(executable: "/bin/sh", arguments: ["-c", "sleep 600 & exit 0"], environment: environment,
                                        currentDirectory: root, processGroup: true)
        let pgid = process.processIdentifier
        let start = try #require(probe.startTime(pid: pgid))
        #expect(await waitFor(.seconds(5)) { probe.startTime(pid: pgid) == nil && !probe.groupMembers(pgid: pgid).isEmpty })
        return (pgid, start)
    }

    @Test func staleGroupWithGoneLeaderIsKilledWhenMembersAreNotOlder() async throws {
        let probe = LiveProcessProbe()
        let (pgid, start) = try await orphanGroup()
        defer { kill(-pgid, SIGKILL) }
        PluginRunningFile.write([.init(id: "dev.stale.orphan", pid: pgid, start: start)], to: paths.running)
        PluginHost.killStaleGroups(paths: paths, probe: probe)
        #expect(await waitFor(.seconds(3)) { probe.groupMembers(pgid: pgid).isEmpty })
        #expect(PluginRunningFile.read(paths.running).isEmpty)
    }

    @Test func staleGroupWithAnOlderMemberIsLeftAlone() async throws {
        let probe = LiveProcessProbe()
        let (pgid, start) = try await orphanGroup()
        defer { kill(-pgid, SIGKILL) }
        // The recorded start is later than the member's: the group id was reused by something else.
        PluginRunningFile.write([.init(id: "dev.stale.reused", pid: pgid, start: start + 1000)], to: paths.running)
        PluginHost.killStaleGroups(paths: paths, probe: probe)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!probe.groupMembers(pgid: pgid).isEmpty)
        #expect(PluginRunningFile.read(paths.running).isEmpty)
    }

    @Test func stoppingAPluginThatStoppedReadingDoesNotHang() async throws {
        let (config, _) = try plugin("dev.test.deafstop", script: .object(["stopReadingAfterInit": .bool(true)]))
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.deafstop", .command))
        let pid = try #require(PluginRunningFile.read(paths.running).first?.pid)
        let payload = JSONValue.object(["text": .string(String(repeating: "x", count: 16 << 10))])
        for _ in 0..<13 { await host.notify(["dev.test.deafstop"], "custom/big", payload) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        await host.shutdown()
        #expect(ContinuousClock.now - start < .milliseconds(2500), "stop took \(ContinuousClock.now - start)")
        #expect(await waitFor(.seconds(3)) { !alive(pid) })
    }

    @Test func missingCommandSaysPluginNotLanguageServer() async throws {
        var (config, _) = try plugin("dev.test.gone")
        config.manifest.main = PluginMain(command: "no-such-plugin-command")
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.gone", .command) == false)
        guard case .failedToStart(let why) = await host.state(of: "dev.test.gone") else { Issue.record("expected failedToStart"); return }
        #expect(!why.contains("Language server") && why.contains("Plugin command not found"), "\(why)")
        await host.shutdown()
    }

    @Test func startupActivationIsSticky() async throws {
        let (config, _) = try plugin("dev.test.sticky")
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.sticky", .startup))
        #expect(await host.activate("dev.test.sticky", .command))
        await host.setWorkspace(root: root.appendingPathComponent("elsewhere"))
        #expect(await host.state(of: "dev.test.sticky") == .running)
        await host.shutdown()
    }

    @Test func workspaceSwitchCancelsInFlightAndReopens() async throws {
        let (keeper, keeperFolder) = try plugin("dev.test.keeper", grants: [.projectRead], script: .object([
            "afterInitialized": .array([.object(["method": .string("project/read"), "params": .object([:]), "id": .number(100)])]),
        ]))
        let (visitor, _) = try plugin("dev.test.visitor")
        let gate = Gate()
        let asked = Counter()
        let host = host(services: PluginHostServices { _, method, _ in
            if method == "project/read" { asked.bump(); await gate.wait() }
            return .success(.null)
        })
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        await host.configure([keeper, visitor])
        await host.setWorkspace(root: a)
        #expect(await host.activate("dev.test.keeper", .startup))
        #expect(await host.activate("dev.test.visitor", .command))
        #expect(await waitFor { asked.count == 1 })
        await host.setWorkspace(root: b)
        #expect(await waitFor { log(keeperFolder).contains { $0["id"]?.intValue == 100 } })
        let answer = try #require(log(keeperFolder).first { $0["id"]?.intValue == 100 })
        #expect(answer["error"]?["code"]?.intValue == -32800)
        #expect(await waitFor { methods(keeperFolder).filter { $0.hasPrefix("workspace/") }.count == 3 })
        let seen = log(keeperFolder).filter { $0["method"]?.stringValue?.hasPrefix("workspace/") == true }
            .map { "\($0["method"]!.stringValue!) \($0["params"]?["root"]?.stringValue ?? "")" }
        #expect(seen == ["workspace/opened \(uri(a))", "workspace/closed \(uri(a))", "workspace/opened \(uri(b))"])
        #expect(await host.state(of: "dev.test.keeper") == .running)
        #expect(await host.state(of: "dev.test.visitor") == .stopped)
        #expect(await host.runningCount == 1)
        gate.release()
        await host.shutdown()
    }

    @Test func environmentIsMinimal() async throws {
        let (config, folder) = try plugin("dev.test.env", script: .object([
            "logEnv": .array(["HOME", "TMPDIR", "ALLOY_PLUGIN_ID", "ALLOY_CLAUDE_PATH"].map { .string($0) }),
        ]))
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.env", .command))
        let envFile = folder.appendingPathComponent("log.jsonl.env")
        #expect(await waitFor { FileManager.default.fileExists(atPath: envFile.path) })
        let values = try #require(JSONValue.parse(try Data(contentsOf: envFile)))
        #expect(values["HOME"]?.stringValue == root.path)
        #expect(values["TMPDIR"]?.stringValue == paths.scratch("dev.test.env").path)
        #expect(values["ALLOY_PLUGIN_ID"]?.stringValue == "dev.test.env")
        #expect(values["ALLOY_CLAUDE_PATH"] == nil)
        await host.shutdown()
    }

    @Test func notifyEncodesOnce() async throws {
        let ids = ["dev.test.n1", "dev.test.n2", "dev.test.n3"]
        let built = try ids.map { try plugin($0) }
        let host = host()
        await host.configure(built.map(\.config))
        for id in ids { #expect(await host.activate(id, .command)) }
        let before = await host.encodeCount
        await host.notify(ids, "custom/ping", .object(["n": .number(5)]))
        #expect(await host.encodeCount == before + 1)
        for (_, folder) in built {
            #expect(await waitFor { methods(folder).contains("custom/ping") })
            let ping = try #require(log(folder).first { $0["method"]?.stringValue == "custom/ping" })
            #expect(ping["params"] == .object(["n": .number(5)]))
        }
        await host.shutdown()
    }
}
