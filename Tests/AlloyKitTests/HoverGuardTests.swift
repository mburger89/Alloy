import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The frame guards with a hover-capable server: the hover's text-anchored popover is attached to every code view then, and
/// must cost no element per frame while closed (the constants are the ones without a server; never raise them).
@MainActor
@Suite struct HoverGuardTests {
    private typealias Perf = CodeModePerformanceTests
    private static let knownPopoverGap = 0

    private func guardTyping(_ layout: Perf.Layout, steady: Int, carets: Int = 1) async throws {
        let perf = Perf()
        let (intel, window, id) = try await IntelRig.guardRig(layout: layout)
        let t = try await perf.typing(window, intel.rig, codeViewID: id, names: Perf.watched, carets: carets)
        #expect(t.documentGrew)
        print("HOVERGUARD typing \(layout.rawValue) perFrame=\(t.perFrame) requests=\(t.requests) bodies=\(t.bodies)")
        // KNOWN MetalUI GAP (reported): the hidden text-anchored popover(item:attachmentAnchor:) adds 1-2 element requests
        // per frame while item is nil. MetalUI #343 fixed it; keep `knownPopoverGap` at 0, never raise it.
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

    @Test func typingWithAHoverCapableServerHoldsTheSteadyFrameGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests)
    }
    @Test func typingWithAHoverCapableServerHoldsTheSteadyFrameGuardCode1() async throws { try await guardTyping(.code1, steady: Perf.steadyCode1) }
    @Test func typingWithAHoverCapableServerHoldsTheSteadyFrameGuardCode2() async throws { try await guardTyping(.code2, steady: Perf.steadyCode2) }
    @Test func typingWithAHoverCapableServerHoldsTheSteadyFrameGuardCode3() async throws { try await guardTyping(.code3, steady: Perf.steadyCode3) }

    @Test func typingWithThreeCaretsAndAHoverCapableServerHoldsTheGuardChat() async throws {
        try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, carets: 3)
    }
    @Test func typingWithThreeCaretsAndAHoverCapableServerHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Perf.steadyCode1, carets: 3) }

    /// Idle with the hover closed: no body runs, and no more elements than the same file without a server.
    @Test func idleWithHoverClosedCostsNothing() async throws {
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
        let (intel, window2, id2) = try await IntelRig.guardRig(layout: .chat)
        let withServer = try await idle(window2, id2)
        print("HOVERGUARD idle baseline=\(baseline.requests) withServer=\(withServer.requests)")
        #expect(withServer.reruns.isEmpty, "idle ticks re-ran \(withServer.reruns)")
        #expect(withServer.requests <= baseline.requests, "idle requests \(withServer.requests) > \(baseline.requests) without a server")
        withExtendedLifetime((rig, window, intel, window2)) {}
    }

    /// Opening and closing the popover re-runs the panel (twice at most) and nothing around it.
    @Test func hoverShowAndHideReRunOnlyThePanel() async throws {
        let perf = Perf()
        let (intel, window, _) = try await IntelRig.guardRig(layout: .chat)
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<10 { window.tick(); await Task.yield() }
        // login.swift's second line is `let role = "root"`; rest the pointer on `role`.
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        let text = String(decoding: doc.buffer.snapshot().utf8(in: 0..<doc.buffer.utf8Count), as: UTF8.self)
        let at = text.utf8.distance(from: text.startIndex, to: try #require(text.range(of: "role")).lowerBound)
        let point = try await intel.point(of: at, in: "login.swift", window: window)
        var reruns: [String: Int] = [:]
        func note(_ body: () -> Void) { for (k, v) in perf.allProbes(body) { reruns[k, default: 0] += v } }
        note { intel.rest(at: point, in: window) }
        try await window.runUntil { intel.exists(window, "hover-popover") }
        for _ in 0..<5 { note { window.tick() }; await Task.yield() }
        note { window.hover(at: Point(x: Pixels(point.x.value), y: Pixels(point.y.value + 300))); window.advance(by: 0.5) }
        try await window.runUntil { !intel.exists(window, "hover-popover") }
        for _ in 0..<5 { note { window.tick() }; await Task.yield() }
        print("HOVERGUARD showHide reruns=\(reruns)")
        #expect((reruns["CodePanel"] ?? 0) <= 2, "CodePanel re-ran \(reruns["CodePanel"] ?? 0) times")
        for n in Perf.watched where n != "CodePanel" { #expect((reruns[n] ?? 0) == 0, "\(n) re-ran \(reruns[n] ?? 0) times") }
    }
}
