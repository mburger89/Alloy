import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A scripted plugin that runs inside the macOS sandbox and sits idle costs the editor's frames nothing.
@MainActor
@Suite(.serialized) struct PluginSandboxTests {
    private typealias Perf = CodeModePerformanceTests

    private final class Keeper { var rigs: [PluginRig] = [] }

    @Test(.enabled(if: PluginSandbox.backendAvailable))
    func sandboxedIdlePluginCostsNothing() async throws {
        let keeper = Keeper()
        let perf = Perf()
        let (rig, window, _) = try await perf.rigged(.code1, install: { rig in
            let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], sandbox: .none)
            keeper.rigs.append(p)
            _ = try? p.fake("dev.example.idle", script: .object([:]))
            Task { @MainActor in _ = await p.coordinator.activate(plugin: "dev.example.idle", .command) }
        })
        let p = try #require(keeper.rigs.first)
        let host = try #require(p.coordinator.host)
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while await host.state(of: "dev.example.idle") != .running, ContinuousClock().now < deadline {
            window.tick()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await host.state(of: "dev.example.idle") == .running, "the plugin runs in the sandbox")
        for _ in 0..<20 { window.tick(); await Task.yield() }
        var reruns: [String: Int] = [:]
        for _ in 0..<120 {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        #expect(reruns.isEmpty, "no body reran while a sandboxed plugin idles: \(reruns)")
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
    }
}
