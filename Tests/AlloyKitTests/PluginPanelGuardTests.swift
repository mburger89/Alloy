import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A plugin panel costs the editor nothing while it is hidden, and while it is shown, typing in the editor never re-runs it.
@MainActor
@Suite(.serialized) struct PluginPanelGuardTests {
    private typealias Perf = CodeModePerformanceTests

    /// The per-frame element requests of a keystroke in Code mode (one group) with a plugin panel shown, measured on this
    /// branch: the sidebar tab row gains one tab button and the panel's widgets sit in the sidebar, which a keystroke does not
    /// touch, so the frame costs what it does without a panel.
    static let panelVisibleCode1 = 46

    private final class Keeper { var rigs: [PluginRig] = [] }

    private static func install(_ rig: Rig, keeper: Keeper) {
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"])
        keeper.rigs.append(p)
        let render = JSONValue.parse(Data(#"{"panelId":"main","tree":\#(PanelRig.tree)}"#.utf8)) ?? .null
        let script: JSONValue = .object(["onReceive": .object(["panel/opened": .array([
            .object(["method": .string("panel/render"), "params": render])])])])
        _ = try? p.fake(PanelRig.id, script: script, contributes: .object(["panels": .array([
            .object(["id": .string("main"), "title": .string("Todo")])])]))
    }

    @Test func hiddenPanelCostsNothing() async throws {
        let keeper = Keeper()
        let perf = Perf()
        let before = BodyProbe.count("PluginPanelView")
        try await perf.guardTyping(.code1, steady: Perf.steadyCode1, install: { Self.install($0, keeper: keeper) })
        #expect(BodyProbe.count("PluginPanelView") == before, "no PluginPanelView body with the panel unselected")
        let p = try #require(keeper.rigs.first)
        #expect(p.coordinator.panels.tabs.count == 1, "the plugin has its tab")
        for p in keeper.rigs { await p.coordinator.shutdown() }
    }

    private func shown() async throws -> (rig: Rig, window: TestWindow, id: String, keeper: Keeper, perf: Perf) {
        let keeper = Keeper()
        let perf = Perf()
        let (rig, window, id) = try await perf.rigged(.code1, install: { Self.install($0, keeper: keeper) })
        rig.workspace.codeLayout.pluginPanel = "\(PanelRig.id)/main"
        let title = "plugin.panel.\(PanelRig.id).title"
        for _ in 0..<1500 where !perf.exists(window, title) { window.tick(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(perf.exists(window, title), "the panel is on screen")
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, window, id, keeper, perf)
    }

    @Test func typingWithPanelVisibleDoesNotRerunPanel() async throws {
        let (rig, window, id, keeper, perf) = try await shown()
        let panelNames = ["PluginPanelView", "PluginPanelNodeView", "PluginPanelTextField"]
        let t = try await perf.typing(window, rig, codeViewID: id, names: Perf.watched + panelNames)
        print("PANEL-VISIBLE code1 perFrame=\(t.perFrame) requests=\(t.requests)")
        #expect(t.documentGrew)
        for n in panelNames { #expect(t.reruns[n] == 0, "\(n) re-ran \(t.reruns[n] ?? -1) times while typing") }
        #expect(BodyProbe.count("PluginPanelView") > 0)
        #expect(t.perFrame.allSatisfy { $0 <= Self.panelVisibleCode1 + 2 }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= Self.panelVisibleCode1 * 20 * 102 / 100, "element requests \(t.requests)")
        for n in ["CodeIslandRow", "EditorAreaView", "CodeChatColumn", "CodeSidebarView", "ChatView", "AlloyScreen"] {
            #expect(t.reruns[n] == 0, "\(n) re-ran \(t.reruns[n] ?? -1) times")
        }
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
    }

    @Test func idleVisiblePanelCostsNothing() async throws {
        let (rig, window, _, keeper, perf) = try await shown()
        for _ in 0..<15 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        let requests = window.frameWork.reduce(0) { $0 + $1.elementRequests }
        #expect(requests == 0, "idle frames with the panel visible requested \(requests) elements")
        #expect(reruns.isEmpty, "idle ticks re-ran \(reruns)")
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
    }
}
