import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// An ACP session costs the frame what a Claude session costs, and nothing when idle. The constants live in
/// `ViewRerunTests` / `CodeModePerformanceTests`; nothing here raises or restates one.
@MainActor
@Suite struct ACPFrameGuardTests {
    /// The element requests of 6 ticks after the window settled (an idle frame is not drawn at all, so 0).
    private func settledIdle(_ window: TestWindow) async -> Int {
        for _ in 0..<20 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        for _ in 0..<6 { window.tick(); await Task.yield() }
        return window.frameWork.reduce(0) { $0 + $1.elementRequests }
    }

    /// Streams text into the session's chat for 12 frames and returns the requests of the last 6 (steady) frames.
    private func streamingFrames(_ window: TestWindow, _ t: ScriptedTransport) async -> [Int] {
        var counts: [Int] = []
        var text = "hello"
        for i in 0..<14 {
            text += " word\(i)"
            await t.emit(.assistantBlock(messageID: "stream", block: .text(text)))
            for _ in 0..<5 { await Task.yield() }
            window.resetFrameWork()
            window.tick()
            counts.append(window.frameWork.map(\.elementRequests).reduce(0, +))
        }
        return Array(counts.suffix(6))
    }

    @Test func streamingACPChatEqualsStreamingClaudeFrameRequests() async throws {
        let claudeRig = Rig(agents: [uiFake])
        let c = await claudeRig.workspace.newSession(name: "A")
        let cw = try alloyWindow(claudeRig.workspace)
        await claudeRig.transports[0].emit(.assistantBlock(messageID: "m0", block: .text("start")))
        try await acpUntil { c.status == .working }
        let claude = await streamingFrames(cw, claudeRig.transports[0])

        let acpRig = Rig(agents: [uiFake])
        let (s, t) = try await acpIdleSession(acpRig)
        let aw = try alloyWindow(acpRig.workspace)
        await t.emit(.assistantBlock(messageID: "m0", block: .text("start")))
        try await acpUntil { s.status == .working }
        let acp = await streamingFrames(aw, t)
        print("ACPGUARD streaming claude=\(claude) acp=\(acp)")
        // The Claude row also draws its cost and token texts, so the ACP chat is never dearer and grows no faster.
        #expect(zip(acp, claude).allSatisfy { $0 <= $1 }, "claude \(claude) vs acp \(acp)")
        #expect(zip(acp, acp.dropFirst()).map { $1 - $0 } == zip(claude, claude.dropFirst()).map { $1 - $0 })
    }

    @Test func idleACPSessionCostsZero() async throws {
        let rig = Rig(agents: [uiFake])
        _ = try await acpIdleSession(rig)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let idle = await settledIdle(window)
        #expect(idle == 0, "idle frame \(idle)")
    }

    @Test func closedNewSessionMenuAddsZero() async throws {
        let rig = Rig(agents: [uiFake, uiOther])
        await rig.workspace.detectAgents()
        _ = try await acpIdleSession(rig)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(hasElement(window, "new-session-menu"))
        #expect(await settledIdle(window) == 0)
        // Open and dismissed: back to zero.
        try window.click(window.element(identifier: "new-session-menu"))
        window.tick()
        try window.dismissMenu()
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(await settledIdle(window) == 0)
    }
}
