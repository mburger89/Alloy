import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import Testing

/// Guard d: the plugin host and three idle running plugin connections cost the app almost no memory.
@Suite(.serialized) struct PluginMemoryTests {
    /// phys_footprint delta of creating the host and three idle running fakes, after a 1 s settle.
    /// Measured: 0.02-0.4 MiB alone (host actor, three connections and their readers), rounded up to the next whole MiB.
    /// The footprint is the whole test process's, so memory other suites are still releasing or allocating drifts it in
    /// a full run (1.7 MiB seen). Each trial therefore subtracts the drift of an equal window with no host, and the guard
    /// takes the smallest of three trials: a real cost shows in every trial, noise does not.
    static let budgetMiB = 1.0

    @Test func hostAndThreeIdleConnectionsStayUnderBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-plugin-mem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PluginPaths(appSupport: root)
        var configs: [PluginRuntimeConfig] = []
        for i in 1...3 {
            let folder = try writeFakePlugin(id: "dev.test.mem\(i)", in: paths.plugins)
            let manifest = try PluginManifestLoader.load(folder: folder, pathDirs: [fakePluginDirectory]).get()
            configs.append(PluginRuntimeConfig(manifest: manifest, folder: folder))
        }
        // Warm the process first so one-time runtime costs are not charged to the host.
        try await Task.sleep(for: .milliseconds(200))
        var deltas: [Double] = []
        for _ in 0..<3 {
            let quietStart = Footprint.mib
            try await Task.sleep(for: .seconds(1))
            let drift = Footprint.mib - quietStart
            let before = Footprint.mib
            let host = PluginHost(paths: paths, baseEnvironment: ["PATH": "\(fakePluginDirectory):/usr/bin:/bin", "HOME": root.path, "LANG": "en_US.UTF-8"],
                                  sandbox: PassthroughSandbox.override)
            await host.configure(configs)
            for config in configs { #expect(await host.activate(config.manifest.id, .command)) }
            try await Task.sleep(for: .seconds(1))
            deltas.append(Footprint.mib - before - drift)
            await host.shutdown()
        }
        let delta = deltas.min() ?? .infinity
        print("PLUGINMEM deltas \(deltas) MiB, guard uses \(delta)")
        #expect(delta < Self.budgetMiB, "host and three idle connections cost \(delta) MiB (trials \(deltas))")
    }
}
