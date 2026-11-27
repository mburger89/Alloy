@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Closing or quitting with text in an Untitled tab asks Save… / Don't Save / Cancel.
@MainActor @Suite struct UntitledPromptTests {
    private func rig() async -> Rig {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        return rig
    }

    private func typed(_ rig: Rig, _ text: String = "typed") throws -> String {
        let key = rig.workspace.newUntitled()
        _ = try #require(rig.workspace.document(key)).buffer.replace(0..<0, with: text)
        return key
    }

    private func waitForPrompt(_ ws: Workspace) async throws -> UntitledPrompt {
        for _ in 0..<500_000 where ws.untitledPrompt == nil { await Task.yield() }
        return try #require(ws.untitledPrompt)
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    @Test func closingEmptyUntitledDoesNotAsk() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let key = ws.newUntitled()
        ws.requestClose(key, in: ws.defaultPane)
        await ws.settle()
        #expect(ws.untitledPrompt == nil)
        #expect(ws.tabs(in: ws.defaultPane).isEmpty && ws.document(key) == nil)
    }

    @Test func closingTypedUntitledAsksAndDontSaveDiscards() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let key = try typed(rig)
        ws.requestClose(key, in: ws.defaultPane)
        let prompt = try await waitForPrompt(ws)
        #expect(prompt.key == key)
        prompt.answer(.discard)
        await ws.settle()
        #expect(ws.untitledPrompt == nil)
        #expect(ws.tabs(in: ws.defaultPane).isEmpty && ws.untitled.isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.root.path)) ?? []).isEmpty)
    }

    @Test func closingTypedUntitledCancelKeepsIt() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let key = try typed(rig)
        ws.requestClose(key, in: ws.defaultPane)
        try await waitForPrompt(ws).answer(.cancel)
        await ws.settle()
        #expect(ws.tabs(in: ws.defaultPane) == [key] && ws.isUntitled(key))
        #expect(ws.document(key)?.buffer.snapshot().text == "typed")
    }

    @Test func closingTypedUntitledSaveWithCancelledDialogKeepsIt() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let key = try typed(rig)
        let center = testCenter(for: ws)
        var asked = 0
        center.chooseSaveURL = { _, _ in asked += 1; return nil }
        ws.requestClose(key, in: ws.defaultPane)
        try await waitForPrompt(ws).answer(.save)
        await ws.settle()
        #expect(asked == 1)
        #expect(ws.tabs(in: ws.defaultPane) == [key] && ws.isUntitled(key))
    }

    @Test func closingTypedUntitledSaveWritesAndClosesIntoTheFile() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let key = try typed(rig)
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("kept.txt") }
        ws.requestClose(key, in: ws.defaultPane)
        try await waitForPrompt(ws).answer(.save)
        await settle { ws.untitled.isEmpty }
        await ws.settle()
        #expect(try String(contentsOf: rig.root.appendingPathComponent("kept.txt"), encoding: .utf8) == "typed")
        #expect(ws.tabs(in: ws.defaultPane) == ["kept.txt"])
    }

    @Test func quitAsksPerUntitledTabAndCancelStops() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let first = try typed(rig, "one")
        let second = try typed(rig, "two")
        let model = LauncherModel(workspace: ws)
        var replies: [Bool] = []
        #expect(model.shutdownRequested { replies.append($0) } == .later)
        let p1 = try await waitForPrompt(ws)
        #expect(p1.key == first)
        p1.answer(.discard)
        await settle { ws.untitledPrompt?.key == second }
        let p2 = try #require(ws.untitledPrompt)
        p2.answer(.cancel)
        await settle { replies.count == 1 }
        #expect(replies == [false])
        #expect(ws.document(first) == nil && ws.isUntitled(second))
        #expect(ws.tabs(in: ws.defaultPane) == [second])
        #expect(!ws.isShuttingDown)
    }

    @Test func quitWithSavedChoicesProceeds() async throws {
        let rig = await rig()
        let ws = rig.workspace
        let key = try typed(rig, "saved")
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("q.txt") }
        let model = LauncherModel(workspace: ws)
        var replies: [Bool] = []
        _ = model.shutdownRequested { replies.append($0) }
        try await waitForPrompt(ws).answer(.save)
        await settle { replies.count == 1 }
        #expect(replies == [true])
        #expect(try String(contentsOf: rig.root.appendingPathComponent("q.txt"), encoding: .utf8) == "saved")
        #expect(ws.document(key) == nil && ws.isShuttingDown)
    }

    @Test func quitWithoutUntitledTextStillQuitsAtOnce() async throws {
        let rig = await rig()
        _ = rig.workspace.newUntitled()
        let model = LauncherModel(workspace: rig.workspace)
        var replies: [Bool] = []
        _ = model.shutdownRequested { replies.append($0) }
        await settle { replies.count == 1 }
        #expect(replies == [true] && rig.workspace.untitledPrompt == nil)
    }

    @Test func promptCopyMatches() async throws {
        let rig = await rig()
        let ws = rig.workspace
        _ = try typed(rig)
        let model = LauncherModel(workspace: ws)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { launcherRoot(model: model, center: testCenter(for: model)) }
        window.tick()
        ws.requestClose(ws.untitled.first!, in: ws.defaultPane)
        _ = try await waitForPrompt(ws)
        #expect(UntitledPrompt.question(for: "Untitled") == "Save changes to \u{201C}Untitled\u{201D}?")
        #expect(UntitledPrompt.message == "Your changes will be lost if you don't save them.")
        for _ in 0..<10 { window.tick(); await Task.yield() }
        window.tick()
        let alert = try #require(window.platformWindow.presentedAlerts.last, "no alert is showing")
        #expect(alert.title == "Save changes to \u{201C}Untitled\u{201D}?", "\(alert)")
        #expect(alert.message == "Your changes will be lost if you don't save them.")
        #expect(alert.buttons.map(\.title) == ["Save\u{2026}", "Don't Save", "Cancel"])
    }
}
