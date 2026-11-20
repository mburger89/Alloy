@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The chat's launch-failure row: shown for a session that could not start, absent otherwise, free when idle.
@MainActor
@Suite struct LaunchFailureViewTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func settle(_ window: TestWindow, _ n: Int = 6) async { for _ in 0..<n { window.tick(); await Task.yield() } }

    @Test func rowShowsTheMessageForAFailedSessionAndIsAbsentOtherwise() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        rig.workspace.selectedSessionID = s.id
        let window = try alloyWindow(rig.workspace)
        await settle(window)
        #expect(!exists(window, "session-launch-error"))
        s.status = .failedToLaunch("claude not found. Tried: /x. " + Workspace.claudeInstallHint)
        await settle(window)
        let row = try window.element(identifier: "session-launch-error")
        #expect(row.frame.maxX.value > row.frame.minX.value && row.frame.maxY.value > row.frame.minY.value)
        s.status = .idle
        await settle(window)
        #expect(!exists(window, "session-launch-error"))
    }

    @Test func hugeAndEmptyMessagesStillRenderARow() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        rig.workspace.selectedSessionID = s.id
        let window = try alloyWindow(rig.workspace)
        s.status = .failedToLaunch(String(repeating: "word ", count: 1000))
        await settle(window)
        let huge = try window.element(identifier: "session-launch-error")
        let chat = try window.element(identifier: "composer")
        // The text wraps (several lines tall) and stays within the column, and is no wider than the chat column (the composer is inset from it).
        #expect(huge.frame.maxY.value - huge.frame.minY.value > 60, "\(huge.frame)")
        #expect(huge.frame.maxX.value - huge.frame.minX.value <= chat.frame.maxX.value - chat.frame.minX.value + 100, "\(huge.frame) vs \(chat.frame)")
        s.status = .failedToLaunch("")
        await settle(window)
        #expect(exists(window, "session-launch-error"))
    }

    @Test func idleFramesWithAFailedSessionCostNothing() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        rig.workspace.selectedSessionID = s.id
        s.status = .failedToLaunch("boom")
        let window = try alloyWindow(rig.workspace)
        await settle(window, 12)
        window.resetFrameWork()
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(window.frameWork.allSatisfy { $0.elementRequests == 0 }, "\(window.frameWork.map(\.elementRequests))")
    }
}
