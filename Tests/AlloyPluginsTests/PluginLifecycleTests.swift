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

private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

/// A probe the test steers: resident bytes and CPU seconds as functions of the test's manual clock.
private final class FakeProbe: PluginProcessProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var _resident: UInt64 = 10 << 20
    private var _cpu: @Sendable () -> Double = { 0 }
    var resident: UInt64 { get { lock.withLock { _resident } } set { lock.withLock { _resident = newValue } } }
    func setCPU(_ f: @escaping @Sendable () -> Double) { lock.withLock { _cpu = f } }
    func startTime(pid: Int32) -> Double? { Double(pid) }
    func sample(pid: Int32) -> (residentBytes: UInt64, cpuSeconds: Double)? {
        let (r, c) = lock.withLock { (_resident, _cpu) }
        return (r, c())
    }
}

@Suite("PluginLifecycle", .serialized)
struct PluginLifecycleTests {
    let root = TempFiles.url("alloy-life-tests")
    let paths: PluginPaths
    let clock = ManualClock()

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = PluginPaths(appSupport: root)
    }

    private var environment: [String: String] {
        ["PATH": "\(fakePluginDirectory):/usr/bin:/bin", "HOME": root.path, "LANG": "en_US.UTF-8"]
    }

    private func plugin(_ id: String, script: JSONValue = .object([:])) throws -> (config: PluginRuntimeConfig, folder: URL) {
        let folder = try writeFakePlugin(id: id, in: paths.plugins, script: script)
        let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: [fakePluginDirectory]).get()
        return (PluginRuntimeConfig(manifest: manifest, folder: folder), folder)
    }

    private func host(limits: PluginLimits = PluginLimits(), probe: any PluginProcessProbe = LiveProcessProbe(),
                      services: PluginHostServices = PluginHostServices()) -> PluginHost {
        PluginHost(paths: paths, limits: limits, clock: clock, probe: probe, baseEnvironment: environment, services: services, sandbox: PassthroughSandbox.override)
    }

    private func log(_ folder: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private func spawns(_ folder: URL) -> Int { log(folder).filter { $0["method"]?.stringValue == "initialize" }.count }

    /// Lets timers register and woken tasks run before and after the manual clock moves.
    private func advance(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(80))
        clock.advance(by: seconds)
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func crashing(_ id: String) throws -> (config: PluginRuntimeConfig, folder: URL) {
        try plugin(id, script: .object(["crashAfter": .number(1)]))
    }

    // MARK: - Crashes

    @Test func crashRestartsAfter1Then5Then30() async throws {
        var limits = PluginLimits()
        limits.crashWindow = 3
        let (config, folder) = try crashing("dev.test.crash")
        let host = host(limits: limits)
        await host.configure([config])
        _ = await host.activate("dev.test.crash", .startup)
        #expect(await waitFor { await host.state(of: "dev.test.crash") == .crashed(1) })
        #expect(spawns(folder) == 1)
        await advance(0.9)
        #expect(spawns(folder) == 1)
        await advance(0.1)
        #expect(await waitFor { spawns(folder) == 2 })
        #expect(await waitFor { await host.state(of: "dev.test.crash") == .crashed(2) })
        await advance(4.9)
        #expect(spawns(folder) == 2)
        await advance(0.1)
        #expect(await waitFor { spawns(folder) == 3 })
        #expect(await waitFor { await host.state(of: "dev.test.crash") == .crashed(1) })
        await advance(29.9)
        #expect(spawns(folder) == 3)
        await advance(0.1)
        #expect(await waitFor { spawns(folder) == 4 })
        await host.shutdown()
    }

    @Test func threeCrashesInTenMinutesDisable() async throws {
        let (config, folder) = try crashing("dev.test.three")
        let host = host()
        await host.configure([config])
        _ = await host.activate("dev.test.three", .startup)
        #expect(await waitFor { spawns(folder) == 1 })
        await advance(1)
        #expect(await waitFor { spawns(folder) == 2 })
        await advance(5)
        #expect(await waitFor { spawns(folder) == 3 })
        #expect(await waitFor { await host.state(of: "dev.test.three") == .disabledAfterCrashes })
        await advance(100)
        #expect(spawns(folder) == 3)
        #expect(await host.activate("dev.test.three", .command) == false)
        #expect(spawns(folder) == 3)
        await host.shutdown()
    }

    @Test func crashesSpreadOver10MinutesDoNotDisable() async throws {
        var limits = PluginLimits()
        limits.backoff = [400, 400, 400]
        let (config, folder) = try crashing("dev.test.spread")
        let host = host(limits: limits)
        await host.configure([config])
        _ = await host.activate("dev.test.spread", .startup)
        #expect(await waitFor { spawns(folder) == 1 })
        await advance(400)
        #expect(await waitFor { spawns(folder) == 2 })
        await advance(400)
        #expect(await waitFor { spawns(folder) == 3 })
        #expect(await waitFor { await host.state(of: "dev.test.spread") == .crashed(2) })
        await host.shutdown()
    }

    // MARK: - Idle and the cap

    @Test func idleStopAfterTenMinutes() async throws {
        let (config, folder) = try plugin("dev.test.idle")
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.idle", .command))
        await advance(599)
        #expect(await host.state(of: "dev.test.idle") == .running)
        await advance(1)
        #expect(await waitFor { await host.state(of: "dev.test.idle") == .stopped })
        #expect(await host.runningCount == 0)
        #expect(await host.activate("dev.test.idle", .command))
        #expect(spawns(folder) == 2)
        await host.shutdown()
    }

    @Test func openPanelKeepsItAlive() async throws {
        let (config, _) = try plugin("dev.test.panel")
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.panel", .panel))
        await host.setPanelOpen("dev.test.panel", true)
        await advance(900)
        #expect(await host.state(of: "dev.test.panel") == .running)
        await host.setPanelOpen("dev.test.panel", false)
        await advance(599)
        #expect(await host.state(of: "dev.test.panel") == .running)
        await advance(1)
        #expect(await waitFor { await host.state(of: "dev.test.panel") == .stopped })
        await host.shutdown()
    }

    @Test func ninthStartStopsOldestLastMessage() async throws {
        let ids = (1...9).map { "dev.test.cap\($0)" }
        let built = try ids.map { try plugin($0) }
        let host = host()
        await host.configure(built.map(\.config))
        for id in ids.prefix(8) {
            #expect(await host.activate(id, .command))
            clock.advance(by: 1)
        }
        #expect(await host.runningCount == 8)
        // The first plugin hears something, so the second is now the one with the oldest message.
        await host.notify([ids[0]], "custom/ping", nil)
        #expect(await host.activate(ids[8], .command))
        #expect(await host.runningCount == 8)
        #expect(await host.state(of: ids[1]) == .stopped)
        #expect(await host.state(of: ids[0]) == .running)
        #expect(await host.state(of: ids[8]) == .running)
        await host.shutdown()
    }

    // MARK: - Timeouts

    @Test func threeTimeoutsInARowRestart() async throws {
        var limits = PluginLimits()
        limits.uiTimeout = .milliseconds(100)
        let (config, _) = try plugin("dev.test.hang", script: .object([
            "replies": .object(["commands/execute": .array([.object(["hold": .bool(true)])])]),
        ]))
        let host = host(limits: limits)
        await host.configure([config])
        #expect(await host.activate("dev.test.hang", .command))
        for _ in 0..<3 { await #expect(throws: JSONRPCError.self) { try await host.request("dev.test.hang", "commands/execute", nil, ui: true) } }
        #expect(await host.state(of: "dev.test.hang") == .crashed(1))
        #expect(await host.runningCount == 0)
        await host.shutdown()
    }

    @Test func twoTimeoutsThenAnswerDoesNotRestart() async throws {
        var limits = PluginLimits()
        limits.uiTimeout = .milliseconds(100)
        let (config, _) = try plugin("dev.test.slow", script: .object([
            "replies": .object(["commands/execute": .array([
                .object(["hold": .bool(true)]), .object(["hold": .bool(true)]), .object(["result": .string("ok")]),
            ])]),
        ]))
        let host = host(limits: limits)
        await host.configure([config])
        #expect(await host.activate("dev.test.slow", .command))
        for _ in 0..<2 { await #expect(throws: JSONRPCError.self) { try await host.request("dev.test.slow", "commands/execute", nil, ui: true) } }
        #expect(try await host.request("dev.test.slow", "commands/execute", nil, ui: true) == .string("ok"))
        #expect(await host.state(of: "dev.test.slow") == .running)
        // The counter was reset by the answer: two more timeouts still do not restart.
        await host.shutdown()
    }

    // MARK: - Floods and a polluted stream

    @Test func chattyPluginIsPausedThenRestarted() async throws {
        let (config, _) = try plugin("dev.test.chatty", script: .object([
            "flood": .object(["method": .string("custom/noise"), "params": .object([:]),
                              "perSecond": .number(1000), "seconds": .number(30)]),
        ]))
        let host = host()
        let seen = Tally()
        let counter = Task { for await event in host.events { if case .notification = event { seen.bump() } } }
        await host.configure([config])
        #expect(await host.activate("dev.test.chatty", .startup))
        for second in 1...4 {
            // The answer to `initialize` takes one of the first second's 200 slots.
            let expected = 200 * second - 1
            #expect(await waitFor { seen.count >= expected })
            try await Task.sleep(for: .milliseconds(150))
            #expect(seen.count == expected)
            await advance(1)
        }
        #expect(await waitFor { await host.state(of: "dev.test.chatty") == .crashed(1) })
        #expect(seen.count <= 1200)  // five clock seconds at 200 each, never the thousands the plugin sent
        await host.shutdown()
        counter.cancel()
    }

    @Test func pollutedStdoutCountsAsCrash() async throws {
        let (config, _) = try plugin("dev.test.garbage", script: .object(["garbageStdout": .bool(true)]))
        let host = host()
        await host.configure([config])
        #expect(await host.activate("dev.test.garbage", .command) == false)
        #expect(await waitFor { await host.state(of: "dev.test.garbage") == .crashed(1) })
        #expect(await host.runningCount == 0)
        await host.shutdown()
    }

    @Test func fullWriteQueueRestarts() async throws {
        var limits = PluginLimits()
        limits.writeQueueBytes = 64 << 10
        let (config, _) = try plugin("dev.test.deaf", script: .object(["stopReadingAfterInit": .bool(true)]))
        let host = host(limits: limits)
        await host.configure([config])
        #expect(await host.activate("dev.test.deaf", .command))
        let payload = JSONValue.object(["text": .string(String(repeating: "x", count: 16 << 10))])
        var sent = 0
        while sent < 400, await host.state(of: "dev.test.deaf") == .running {
            await host.notify(["dev.test.deaf"], "custom/big", payload)
            sent += 1
            if sent % 8 == 0 { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(await waitFor { await host.state(of: "dev.test.deaf") == .crashed(1) })
        #expect(sent > 4)
        await host.shutdown()
    }

    // MARK: - Sampler

    @Test func samplerKillsAboveMemory() async throws {
        let probe = FakeProbe()
        let (config, _) = try plugin("dev.test.fat")
        let host = host(probe: probe)
        await host.configure([config])
        #expect(await host.activate("dev.test.fat", .command))
        let pid = try #require(PluginRunningFile.read(paths.running).first?.pid)
        probe.resident = 600 << 20
        await advance(5)
        #expect(await waitFor { await host.state(of: "dev.test.fat") == .crashed(1) })
        #expect(await waitFor(.seconds(3)) { kill(pid, 0) != 0 })
        await host.shutdown()
    }

    @Test func samplerKillsSustainedCpu() async throws {
        let probe = FakeProbe()
        let clock = self.clock
        probe.setCPU { clock.now * 0.95 }
        let (config, _) = try plugin("dev.test.hot")
        let host = host(probe: probe)
        await host.configure([config])
        #expect(await host.activate("dev.test.hot", .command))
        for _ in 0..<5 {
            await advance(5)
            #expect(await host.state(of: "dev.test.hot") == .running)
        }
        await advance(5)
        #expect(await waitFor { await host.state(of: "dev.test.hot") == .crashed(1) })
        await host.shutdown()
    }

    @Test func samplerExistsOnlyWhileAProcessRuns() async throws {
        let (config, _) = try plugin("dev.test.sampler")
        let host = host()
        await host.configure([config])
        #expect(await host.hasSamplerTask == false)
        #expect(await host.activate("dev.test.sampler", .command))
        #expect(await host.hasSamplerTask)
        await advance(600)
        #expect(await waitFor { await host.state(of: "dev.test.sampler") == .stopped })
        #expect(await host.hasSamplerTask == false)
        await host.shutdown()
    }
}
