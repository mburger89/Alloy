import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Plugins that decorate documents cost the editor's frame guards nothing: typing holds the steady counts while three
/// plugins (one slow, one crashing, one flooding decorations) run, and idle frames do no plugin work.
@MainActor
@Suite(.serialized) struct PluginFrameCostTests {
    private typealias Perf = CodeModePerformanceTests

    private final class Keeper { var rigs: [PluginRig] = [] }

    private static func decorationFlood(uri: String, perSecond: Int, seconds: Double, counter: Bool) -> JSONValue {
        let params = JSONValue.parse(Data(#"{"uri":"\#(uri)","version":1,"items":[{"line":1,"gutterBar":"info"},{"line":2,"background":"warning","message":{"text":"flooded","role":"warning"}},{"start":4,"end":8,"underline":"error"}]}"#.utf8)) ?? .null
        return .object(["flood": .object(["method": .string("decorations/set"), "params": params, "perSecond": .number(Double(perSecond)),
                                          "seconds": .number(seconds), "counter": .bool(counter)])])
    }

    /// Enables the three plugins on `rig` and starts them (the document opens afterwards; sets for it arrive while it is typed into).
    private static func install(_ rig: Rig, keeper: Keeper, counter: Bool = true) {
        var limits = PluginLimits()
        limits.messagesPerSecond = 100_000
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], limits: limits)
        keeper.rigs.append(p)
        let uri = rig.root.appendingPathComponent("login.swift").absoluteString
        _ = try? p.fake("dev.example.slow", script: .object(["replies": .object(["commands/execute": .array([.object(["delayMs": .number(1500)])])])]),
                    contributes: .object(["commands": .array([.object(["id": .string("go"), "title": .string("Go")])])]))
        _ = try? p.fake("dev.example.crashy", script: .object(["crashAfter": .number(3)]))
        _ = try? p.fake("dev.example.flood", script: decorationFlood(uri: uri, perSecond: 1000, seconds: 120, counter: counter))
        Task { @MainActor in
            for id in ["dev.example.slow", "dev.example.crashy", "dev.example.flood"] { _ = await p.coordinator.activate(plugin: id, .command) }
            if let host = p.coordinator.host {
                _ = try? await host.request("dev.example.slow", "commands/execute", .object(["command": .string("go")]), ui: true)
            }
        }
    }

    private func typing(_ layout: Perf.Layout, steady: Int) async throws {
        let keeper = Keeper()
        let perf = Perf()
        // The plugins start as processes: the guard measures once the flooding one's first set has landed, so the typing it
        // counts runs under the flood (typing takes milliseconds headless; a plugin takes up to seconds to start under load).
        try await perf.guardTyping(layout, steady: steady, install: { Self.install($0, keeper: keeper) }, settle: { window in
            let deadline = ContinuousClock().now.advanced(by: .seconds(10))
            while (keeper.rigs.first?.coordinator.decorations.applyCount ?? 0) == 0, ContinuousClock().now < deadline {
                window.tick(); try? await Task.sleep(for: .milliseconds(20))
            }
        })
        let applied = keeper.rigs.first?.coordinator.decorations.applyCount ?? 0
        #expect(applied > 0, "decorations arrived while the guard measured: \(applied)")
        for p in keeper.rigs { await p.coordinator.shutdown() }
    }

    @Test func typingHoldsChatAndCodeGuardsWithThreePluginsChat() async throws { try await typing(.chat, steady: ViewRerunTests.steadyFrameRequests) }
    @Test func typingHoldsChatAndCodeGuardsWithThreePluginsCode1() async throws { try await typing(.code1, steady: Perf.steadyCode1) }
    @Test func typingHoldsChatAndCodeGuardsWithThreePluginsCode2() async throws { try await typing(.code2, steady: Perf.steadyCode2) }
    @Test func typingHoldsChatAndCodeGuardsWithThreePluginsCode3() async throws { try await typing(.code3, steady: Perf.steadyCode3) }

    @Test func idleTicksDoNotRunPluginWork() async throws {
        let keeper = Keeper()
        let perf = Perf()
        let (rig, window, _) = try await perf.rigged(.code1, install: { Self.install($0, keeper: keeper, counter: false) })
        let p = try #require(keeper.rigs.first)
        let store = p.coordinator.decorations
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while store.applyCount == 0, ContinuousClock().now < deadline { window.tick(); try? await Task.sleep(for: .milliseconds(20)) }
        #expect(store.applyCount >= 1, "the flooding plugin's first set landed")
        for _ in 0..<20 { window.tick(); await Task.yield() }
        let applied = store.applyCount
        var reruns: [String: Int] = [:]
        for _ in 0..<120 {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        #expect(store.applyCount == applied, "no decoration applied while idle")
        #expect(reruns.isEmpty, "no body reran while idle: \(reruns)")
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
    }

    @Test func chattyPluginMakesAtMostFourHopsPerSecond() async throws {
        let keeper = Keeper()
        let perf = Perf()
        let (rig, window, _) = try await perf.rigged(.code1, install: { Self.install($0, keeper: keeper) })
        let p = try #require(keeper.rigs.first)
        let store = p.coordinator.decorations
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while store.applyCount == 0, ContinuousClock().now < deadline { window.tick(); try? await Task.sleep(for: .milliseconds(20)) }
        #expect(store.applyCount >= 1)
        let start = store.applyCount
        let began = ContinuousClock().now
        while ContinuousClock().now < began.advanced(by: .seconds(5)) { window.tick(); try? await Task.sleep(for: .milliseconds(20)) }
        let hops = store.applyCount - start
        #expect(hops <= 20, "\(hops) applies in 5 s")
        #expect(hops >= 10, "the flood still paints: \(hops)")
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
    }
}
