import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The frame guards with a rename-capable server: the rename field shares the code view's one text-anchored popover and must
/// cost no element per frame while closed (the constants are the ones without a server; never raise them).
@MainActor
@Suite struct RenameGuardTests {
    private typealias Perf = CodeModePerformanceTests
    private static let knownPopoverGap = 0
    private static let withHover = IntelRig.renameScript(hover: true)
    private static let renameOnly = IntelRig.renameScript()

    private func guardTyping(_ layout: Perf.Layout, steady: Int, script: String, carets: Int = 1) async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: layout, script: script)
        let t = try await perf.typing(window, intel.rig, codeViewID: id, names: Perf.watched, carets: carets)
        #expect(t.documentGrew)
        print("RENAMEGUARD typing \(layout.rawValue) perFrame=\(t.perFrame) requests=\(t.requests) bodies=\(t.bodies)")
        #expect(t.perFrame.allSatisfy { $0 <= steady + Self.knownPopoverGap }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= (steady + Self.knownPopoverGap) * 20, "element requests \(t.requests)")
        #expect(t.reruns["CodePanel"] == 0, "CodePanel re-ran \(t.reruns["CodePanel"] ?? -1) times while typing")
        for n in ["CodeIslandRow", "EditorAreaView", "CodeChatColumn", "CodeSidebarView", "TitleIsland", "IslandBackdrop", "GlassBackdrop",
                  "ChatView", "ChatColumn", "TranscriptView", "AlloyScreen"] {
            #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times")
        }
        let chat = try await perf.chatBodies()
        #expect(t.bodies <= chat, "\(layout) bodies \(t.bodies) > chat \(chat)")
        withExtendedLifetime((intel, window)) {}
    }

    @Test func typingHoldsTheSteadyFrameGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.withHover)
    }
    @Test func typingHoldsTheSteadyFrameGuardCode1() async throws { try await guardTyping(.code1, steady: Perf.steadyCode1, script: Self.withHover) }
    @Test func typingHoldsTheSteadyFrameGuardCode2() async throws { try await guardTyping(.code2, steady: Perf.steadyCode2, script: Self.withHover) }
    @Test func typingHoldsTheSteadyFrameGuardCode3() async throws { try await guardTyping(.code3, steady: Perf.steadyCode3, script: Self.withHover) }

    @Test func typingWithThreeCaretsHoldsTheGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.withHover, carets: 3)
    }
    @Test func typingWithThreeCaretsHoldsTheGuardCode1() async throws {
        try await guardTyping(.code1, steady: Perf.steadyCode1, script: Self.withHover, carets: 3)
    }

    /// A server with rename but no hover holds the same budget.
    @Test func renameWithoutHoverHoldsTheGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.renameOnly)
    }
    @Test func renameWithoutHoverHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Perf.steadyCode1, script: Self.renameOnly) }

    /// Idle with the rename closed: no body runs, and no more elements than the same file without a server.
    @Test func idleWithRenameClosedCostsNothing() async throws {
        let perf = Perf()
        func idle(_ window: TestWindow, _ id: String) async throws -> (requests: Int, reruns: [String: Int]) {
            try window.click(window.element(identifier: id))
            for _ in 0..<15 { window.tick(); await Task.yield() }
            window.resetFrameWork()
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                await Task.yield()
            }
            return (window.frameWork.reduce(0) { $0 + $1.elementRequests }, reruns)
        }
        let (rig, window, id) = try await perf.rigged(.chat)
        let baseline = try await idle(window, id)
        let (intel, window2, id2) = try await IntelRig.guardRig(layout: .chat, script: Self.withHover)
        let withServer = try await idle(window2, id2)
        print("RENAMEGUARD idle baseline=\(baseline.requests) withServer=\(withServer.requests)")
        #expect(withServer.reruns.isEmpty, "idle ticks re-ran \(withServer.reruns)")
        #expect(withServer.requests <= baseline.requests, "idle requests \(withServer.requests) > \(baseline.requests) without a server")
        withExtendedLifetime((rig, window, intel, window2)) {}
    }

    /// Opening and closing the field re-runs the panel (twice at most) and nothing around it.
    @Test func renameOpenAndCloseReRunOnlyThePanel() async throws {
        let perf = Perf()
        let (intel, window, _) = try await IntelRig.guardRig(layout: .chat, script: Self.withHover)
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        try await window.runUntil { view.features.rename }
        try #require(intel.rig.workspace.selectionState(for: "login.swift", in: .chat)).select(5..<5, reveal: false)
        var reruns: [String: Int] = [:]
        func note(_ body: () -> Void) { for (k, v) in perf.allProbes(body) { reruns[k, default: 0] += v } }
        view.beginRename(workspace: intel.rig.workspace)
        try await window.runUntil { intel.exists(window, "rename-field") }
        for _ in 0..<5 { note { window.tick() }; await Task.yield() }
        note { window.typeKey(.escape) }
        try await window.runUntil { !intel.exists(window, "rename-field") }
        for _ in 0..<5 { note { window.tick() }; await Task.yield() }
        print("RENAMEGUARD openClose reruns=\(reruns)")
        #expect((reruns["CodePanel"] ?? 0) <= 4, "CodePanel re-ran \(reruns["CodePanel"] ?? 0) times")
        for n in Perf.watched where n != "CodePanel" { #expect((reruns[n] ?? 0) == 0, "\(n) re-ran \(reruns[n] ?? 0) times") }
    }

    /// The summary opened and dismissed leaves idle frames as cheap as before and re-runs only the panel.
    @Test func summaryOpenedThenDismissedLeavesIdleFree() async throws {
        let perf = Perf()
        let (intel, window, _) = try await IntelRig.guardRig(layout: .chat, script: Self.withHover)
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        try await window.runUntil { view.features.rename }
        func idle() async -> (requests: Int, reruns: [String: Int]) {
            window.resetFrameWork()
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                await Task.yield()
            }
            return (window.frameWork.reduce(0) { $0 + $1.elementRequests }, reruns)
        }
        let before = await idle()
        view.popoverSlot.summary = RenameSummaryState(group: UUID(), rows: [RenameRow(path: "login.swift", edits: 2)], anchor: 5..<6)
        try await window.runUntil { intel.exists(window, "rename-summary") }
        view.dismissRename()
        try await window.runUntil { !intel.exists(window, "rename-summary") }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let after = await idle()
        print("RENAMEGUARD summary idle before=\(before.requests) after=\(after.requests)")
        #expect(after.reruns.isEmpty, "idle ticks re-ran \(after.reruns)")
        #expect(after.requests <= before.requests, "idle requests \(after.requests) > \(before.requests)")
    }
}
