import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The frame guards with a completion-capable server: the suggestion overlay chained on every code view must cost no
/// element per frame while closed (the constants are the ones without a server; never raise them), and an open popup
/// re-runs only itself.
@MainActor
@Suite struct CompletionGuardTests {
    private typealias Perf = CodeModePerformanceTests
    private static let knownPopoverGap = 0
    private static let siblings = ["CodeIslandRow", "EditorAreaView", "CodeChatColumn", "CodeSidebarView", "TitleIsland", "IslandBackdrop",
                                   "GlassBackdrop", "ChatView", "ChatColumn", "TranscriptView", "AlloyScreen"]

    private func closedTyping(_ layout: Perf.Layout, steady: Int, script: String, extra: Int, carets: Int = 1) async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: layout, script: script)
        let t = try await perf.typing(window, intel.rig, codeViewID: id, names: Perf.watched, carets: carets)
        #expect(t.documentGrew)
        print("COMPLETIONGUARD typing \(layout.rawValue) perFrame=\(t.perFrame) requests=\(t.requests) bodies=\(t.bodies)")
        #expect(t.perFrame.allSatisfy { $0 <= steady + extra }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= (steady + extra) * 20, "element requests \(t.requests)")
        #expect(t.reruns["CodePanel"] == 0, "CodePanel re-ran \(t.reruns["CodePanel"] ?? -1) times while typing")
        for n in Self.siblings { #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times") }
        let chat = try await perf.chatBodies()
        #expect(t.bodies <= chat, "\(layout) bodies \(t.bodies) > chat \(chat)")
        withExtendedLifetime((intel, window)) {}
    }

    private static let noCompletion = IntelRig.script(caps: #""referencesProvider":true"#)
    private static let completionOnly = IntelRig.completionScript()
    private static let completionAndHover = IntelRig.completionScript(hover: true)

    // (b) a server with no completion capability costs nothing over the steady frame.
    @Test func noCompletionCapabilityChat() async throws { try await closedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.noCompletion, extra: 0) }
    @Test func noCompletionCapabilityCode2() async throws { try await closedTyping(.code2, steady: Perf.steadyCode2, script: Self.noCompletion, extra: 0) }

    // (c) completion capability, popup closed: the steady frame, hover attached or not.
    @Test func closedOverlayChat() async throws { try await closedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.completionOnly, extra: 0) }
    @Test func closedOverlayCode1() async throws { try await closedTyping(.code1, steady: Perf.steadyCode1, script: Self.completionOnly, extra: 0) }
    @Test func closedOverlayCode2() async throws { try await closedTyping(.code2, steady: Perf.steadyCode2, script: Self.completionOnly, extra: 0) }
    @Test func closedOverlayCode3() async throws { try await closedTyping(.code3, steady: Perf.steadyCode3, script: Self.completionOnly, extra: 0) }
    @Test func closedOverlayWithHoverChat() async throws {
        try await closedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.completionAndHover, extra: Self.knownPopoverGap)
    }
    @Test func closedOverlayWithHoverCode1() async throws {
        try await closedTyping(.code1, steady: Perf.steadyCode1, script: Self.completionAndHover, extra: Self.knownPopoverGap)
    }

    // Three carets: typing opens no popup, so the closed-overlay budgets hold.
    @Test func closedOverlayWithThreeCaretsChat() async throws {
        try await closedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.completionAndHover, extra: Self.knownPopoverGap, carets: 3)
    }
    @Test func closedOverlayWithThreeCaretsCode1() async throws {
        try await closedTyping(.code1, steady: Perf.steadyCode1, script: Self.completionAndHover, extra: Self.knownPopoverGap, carets: 3)
    }

    // Signature help capable, strip closed: the same budgets as a closed completion overlay.
    private static let signatureOnly = IntelRig.signatureScript(answers: IntelRig.signatureAnswer([("f(a)", ["a"])]))
    @Test func closedStripChat() async throws { try await closedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, script: Self.signatureOnly, extra: 0) }
    @Test func closedStripCode2() async throws { try await closedTyping(.code2, steady: Perf.steadyCode2, script: Self.signatureOnly, extra: 0) }

    // Opening and closing the strip re-runs only the overlay content.
    @Test func openingAndClosingTheStripReRunsOnlyTheOverlay() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code1, script: Self.signatureOnly)
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        var reruns: [String: Int] = [:]
        for _ in 0..<3 {
            for (k, v) in perf.allProbes({ window.typeText("(") }) { reruns[k, default: 0] += v }
            try await window.runUntil { intel.exists(window, "signature-help") }
            for (k, v) in perf.allProbes({ window.typeKey(.escape) }) { reruns[k, default: 0] += v }
            for _ in 0..<5 { window.tick(); await Task.yield() }
            #expect(!intel.exists(window, "signature-help"))
        }
        print("COMPLETIONGUARD strip reruns=\(reruns)")
        #expect((reruns["CodePanel"] ?? 0) == 0, "CodePanel re-ran \(reruns["CodePanel"] ?? 0) times")
        for n in Perf.watched { #expect((reruns[n] ?? 0) == 0, "\(n) re-ran \(reruns[n] ?? 0) times") }
        withExtendedLifetime((intel, window)) {}
    }

    /// Idle with a closed overlay costs no more than the same file without a server, and re-runs nothing.
    @Test func idleWithAClosedOverlayCostsNothing() async throws {
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
        let (intel, window2, id2) = try await IntelRig.guardRig(layout: .chat, script: Self.completionOnly)
        let withServer = try await idle(window2, id2)
        print("COMPLETIONGUARD idle baseline=\(baseline.requests) withServer=\(withServer.requests)")
        #expect(withServer.reruns.isEmpty, "idle ticks re-ran \(withServer.reruns)")
        #expect(withServer.requests <= baseline.requests, "idle requests \(withServer.requests) > \(baseline.requests) without a server")
        withExtendedLifetime((rig, window, intel, window2)) {}
    }

    // (d) popup open, typing inside the word: only the overlay content re-runs.
    @Test func typingInsideTheWordReRunsOnlyTheOverlay() async throws {
        let perf = Perf()
        let label = String(repeating: "a", count: 80)
        let script = IntelRig.completionScript(completion: #"{"result":[{"label":"\#(label)"},{"label":"\#(label)b"}]}"#)
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code1, script: script)
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        window.typeText("a")
        try await window.runUntil { intel.exists(window, "completion-popup") }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        var reruns: [String: Int] = [:]
        for _ in 0..<15 {
            for (k, v) in perf.allProbes({ window.typeText("a") }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        print("COMPLETIONGUARD open reruns=\(reruns)")
        #expect(intel.exists(window, "completion-popup"))
        #expect((reruns["CodePanel"] ?? 0) == 0, "CodePanel re-ran \(reruns["CodePanel"] ?? 0) times")
        for n in Perf.watched { #expect((reruns[n] ?? 0) == 0, "\(n) re-ran \(reruns[n] ?? 0) times") }
        withExtendedLifetime((intel, window)) {}
    }

    // (f) the same file in two panes: only the focused pane's scheduler acts.
    @Test func onlyTheFocusedPaneAsks() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code2, script: IntelRig.completionScript(completion: #"{"result":[{"label":"alpha"}]}"#))
        let workspace = intel.rig.workspace
        let doc = try #require(workspace.document("login.swift"))
        let groups = workspace.codeLayout.tree.groupIDs
        let focused = workspace.codeLayout.focusedGroupID
        let other = try #require(groups.first { $0 != focused })
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        window.typeText("a")
        try await window.runUntil { intel.exists(window, "completion-popup") }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let mine = try #require(CodePanelStore.existingView(for: doc, in: .group(focused)))
        let theirs = try #require(CodePanelStore.existingView(for: doc, in: .group(other)))
        #expect((mine.scheduler?.requestCount ?? 0) >= 1)
        #expect(theirs.scheduler?.requestCount == 0)
        #expect(theirs.overlayModel.rows.isEmpty)
        #expect(intel.count("textDocument/completion") == mine.scheduler?.requestCount)
        _ = perf
        withExtendedLifetime((intel, window)) {}
    }
}
