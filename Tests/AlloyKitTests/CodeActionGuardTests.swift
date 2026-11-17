import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The frame guards with a code-action-capable server: the lightbulb's marker lane and the shared suggestion overlay must
/// cost no more per frame than the same file without a server (the constants are the ones without a server; never raise
/// them), idle frames cost nothing, and opening the action list re-runs only the overlay.
@MainActor
@Suite struct CodeActionGuardTests {
    private typealias Perf = CodeModePerformanceTests

    private static let actionOnly = IntelRig.script(
        caps: #""codeActionProvider":true"#,
        extra: #","replies":{"textDocument/codeAction":[{"result":[{"title":"Fix","kind":"quickfix","edit":{"changes":{}}}]}]}"#)

    /// Moves the caret to the second line, waits for the lightbulb and returns its view.
    private func showBulb(_ intel: IntelRig, _ window: TestWindow, id: String) async throws -> OpenDocumentView {
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let view = try #require(CodePanelStore.existingView(for: doc, in: intel.rig.workspace.defaultPane))
        let state = view.selection()
        let offset = doc.buffer.snapshot().lineRange(1).lowerBound
        state.select(offset..<offset, reveal: false)
        await intel.idle(window, 0.6)
        try await window.runUntil { view.lightbulbLine != nil }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        return view
    }

    /// A closed overlay and a shown lightbulb cost nothing over the steady frame (never raise the constants).
    private func typingWithBulb(_ layout: Perf.Layout, steady: Int) async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: layout, script: Self.actionOnly)
        let view = try await showBulb(intel, window, id: id)
        let t = try await perf.typing(window, intel.rig, codeViewID: id, names: Perf.watched)
        #expect(t.documentGrew)
        print("CODEACTIONGUARD typing \(layout.rawValue) perFrame=\(t.perFrame) requests=\(t.requests) bodies=\(t.bodies)")
        #expect(t.perFrame.allSatisfy { $0 <= steady }, "per-frame element requests \(t.perFrame)")
        #expect(t.reruns["CodePanel"] == 0, "CodePanel re-ran \(t.reruns["CodePanel"] ?? -1) times while typing")
        let chat = try await perf.chatBodies()
        #expect(t.bodies <= chat, "\(layout) bodies \(t.bodies) > chat \(chat)")
        withExtendedLifetime((intel, window, view)) {}
    }

    @Test func lightbulbShownTypingChat() async throws { try await typingWithBulb(.chat, steady: ViewRerunTests.steadyFrameRequests) }
    @Test func lightbulbShownTypingCode1() async throws { try await typingWithBulb(.code1, steady: Perf.steadyCode1) }
    @Test func lightbulbShownTypingCode2() async throws { try await typingWithBulb(.code2, steady: Perf.steadyCode2) }
    @Test func lightbulbShownTypingCode3() async throws { try await typingWithBulb(.code3, steady: Perf.steadyCode3) }

    /// Idle with the lightbulb shown costs no more than the same file without a server, and re-runs nothing.
    @Test func idleWithTheLightbulbShownCostsNothing() async throws {
        let perf = Perf()
        func idle(_ window: TestWindow) async -> (requests: Int, reruns: [String: Int]) {
            window.resetFrameWork()
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                await Task.yield()
            }
            return (window.frameWork.reduce(0) { $0 + $1.elementRequests }, reruns)
        }
        let (rig, window, id) = try await perf.rigged(.chat)
        try window.click(window.element(identifier: id))
        for _ in 0..<15 { window.tick(); await Task.yield() }
        let baseline = await idle(window)
        let (intel, window2, id2) = try await IntelRig.guardRig(layout: .chat, script: Self.actionOnly)
        let view = try await showBulb(intel, window2, id: id2)
        for _ in 0..<15 { window2.tick(); await Task.yield() }
        let withBulb = await idle(window2)
        print("CODEACTIONGUARD idle baseline=\(baseline.requests) withBulb=\(withBulb.requests)")
        #expect(view.lightbulbLine != nil)
        #expect(withBulb.reruns.isEmpty, "idle ticks re-ran \(withBulb.reruns)")
        #expect(withBulb.requests <= baseline.requests, "idle requests \(withBulb.requests) > \(baseline.requests) without a server")
        withExtendedLifetime((rig, window, intel, window2)) {}
    }

    /// Opening and closing the action list re-runs only the overlay content.
    @Test func openingAndClosingTheListReRunsOnlyTheOverlay() async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code1, script: Self.actionOnly)
        let view = try await showBulb(intel, window, id: id)
        var reruns: [String: Int] = [:]
        for _ in 0..<3 {
            for (k, v) in perf.allProbes({ window.typeKey(KeyEquivalent("."), modifierFlags: .primary) }) { reruns[k, default: 0] += v }
            try await window.runUntil { intel.exists(window, "code-action-menu") }
            for (k, v) in perf.allProbes({ window.typeKey(.escape) }) { reruns[k, default: 0] += v }
            for _ in 0..<5 { window.tick(); await Task.yield() }
            #expect(!intel.exists(window, "code-action-menu"))
        }
        print("CODEACTIONGUARD list reruns=\(reruns)")
        #expect((reruns["CodePanel"] ?? 0) == 0, "CodePanel re-ran \(reruns["CodePanel"] ?? 0) times")
        for n in Perf.watched { #expect((reruns[n] ?? 0) == 0, "\(n) re-ran \(reruns[n] ?? 0) times") }
        withExtendedLifetime((intel, window, view)) {}
    }

    /// The same file in two panes: only the focused pane probes.
    @Test func onlyTheFocusedPaneProbes() async throws {
        let (intel, window, id) = try await IntelRig.guardRig(layout: .code2, script: Self.actionOnly)
        let workspace = intel.rig.workspace
        let doc = try #require(workspace.document("login.swift"))
        let focused = workspace.codeLayout.focusedGroupID
        let other = try #require(workspace.codeLayout.tree.groupIDs.first { $0 != focused })
        let mine = try await showBulb(intel, window, id: id)
        let theirs = try #require(CodePanelStore.existingView(for: doc, in: .group(other)))
        #expect(mine.pane == .group(focused))
        #expect((mine.scheduler?.probeRequestCount ?? 0) >= 1)
        #expect(theirs.scheduler?.probeRequestCount == 0)
        #expect(theirs.lightbulbLine == nil)
        #expect(intel.count("textDocument/codeAction") == mine.scheduler?.probeRequestCount)
        withExtendedLifetime((intel, window)) {}
    }
}
