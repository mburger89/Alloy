@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import MetalUICodeBuffer
import Testing

/// ⌘S: a deliberate save of the focused pane's active tab, which runs the format-on-save hook.
@MainActor
@Suite struct SaveKeyTests {
    private final class Calls { var count = 0 }

    private func rigWithDirtyFile(mode: WorkspaceMode) async throws -> (Rig, Calls) {
        let rig = Rig()
        try "hello\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(mode)
        await rig.workspace.open("a.txt")
        let doc = try #require(rig.workspace.document("a.txt"))
        _ = doc.buffer.replace(0..<0, with: "x")
        let calls = Calls()
        rig.workspace.formatBeforeSave = { _ in calls.count += 1 }
        return (rig, calls)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    private func saved(_ rig: Rig) -> String? {
        try? String(contentsOf: rig.root.appendingPathComponent("a.txt"), encoding: .utf8)
    }

    @Test func commandSFormatsAndSavesInChatMode() async throws {
        let (rig, calls) = try await rigWithDirtyFile(mode: .chat)
        let window = try alloyWindow(rig.workspace)
        let id = rig.workspace.mode == .code ? "code-view-\(rig.workspace.codeLayout.focusedGroupID.uuidString)" : "code-view"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        try window.click(window.element(identifier: id))
        window.typeKey("s", modifierFlags: .command)
        try await waitFor { saved(rig) == "xhello\n" }
        #expect(calls.count == 1)
    }

    @Test func commandSFormatsAndSavesInCodeMode() async throws {
        let (rig, calls) = try await rigWithDirtyFile(mode: .code)
        let window = try alloyWindow(rig.workspace)
        let id = rig.workspace.mode == .code ? "code-view-\(rig.workspace.codeLayout.focusedGroupID.uuidString)" : "code-view"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        try window.click(window.element(identifier: id))
        window.typeKey("s", modifierFlags: .command)
        try await waitFor { saved(rig) == "xhello\n" }
        #expect(calls.count == 1)
    }
}
