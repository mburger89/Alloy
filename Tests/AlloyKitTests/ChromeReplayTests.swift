@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The chrome beside the focused view (theme bar, coordination notice, launch failure row) is not re-evaluated by a keystroke.
@MainActor
@Suite struct ChromeReplayTests {
    private final class Holder { var controller: ThemeController? }

    static let chrome = ["ChatIslandBody", "ThemeBar", "CoordinationNotice", "LaunchFailureRow", "ChatView", "ChatColumn", "ComposerView",
                         "CodeChatColumn", "FilePanelHeader", "FileTabStrip", "GroupBar", "GroupTabStrip", "EditorGroupView", "EditorAreaView", "IslandRow", "CodeIslandRow"]

    struct Result { var perFrame: [Int]; var reruns: [String: Int]; var hits: Int; var misses: Int; var prepaints: Int }

    private func themedWindow(_ rig: Rig) throws -> (TestWindow, ThemeController) {
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace))
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.testApp.app, watcher: nil)
        holder.controller = controller
        window.installAlloyMenu(rig.workspace, themes: controller)
        window.tick(); window.tick()
        return (window, controller)
    }

    private func keys(_ window: TestWindow) async -> Result {
        for i in 0..<40 {
            window.typeText("a"); window.tick(); await Task.yield()
            let last = window.frameWork.suffix(2).map(\.elementRequests)
            if i >= 9, last.count == 2, last[0] == last[1] { break }
        }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            let before = Self.chrome.map(BodyProbe.count)
            window.typeText("a"); window.tick()
            for (i, n) in Self.chrome.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
            await Task.yield()
        }
        let work = window.frameWork
        return Result(perFrame: work.map(\.elementRequests), reruns: reruns, hits: work.reduce(0) { $0 + $1.retainedHits },
                      misses: work.reduce(0) { $0 + $1.retainedMisses }, prepaints: work.reduce(0) { $0 + $1.elementPrepaints })
    }

    func composerKeys() async throws -> Result {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let (window, controller) = try themedWindow(rig)
        defer { controller.stop() }
        try window.click(window.element(identifier: "composer"))
        for _ in 0..<10 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        return await keys(window)
    }

    func codeViewKeys() async throws -> Result {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let (window, controller) = try themedWindow(rig)
        defer { controller.stop() }
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        return await keys(window)
    }

    /// Before: the theme bar, the notice and the failure row (and the island body over them) re-ran on every key, 20 of 20.
    @Test func composerKeysReplayTheChatChromeAndItStillUpdates() async throws {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let (window, controller) = try themedWindow(rig)
        defer { controller.stop() }
        try window.click(window.element(identifier: "composer"))
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let r = await keys(window)
        for name in ["ChatIslandBody", "ThemeBar", "CoordinationNotice", "LaunchFailureRow", "ChatColumn"] { #expect(r.reruns[name] == 0, "\(name) re-ran \(r.reruns[name]!)") }
        #expect(r.reruns["ComposerView"] == 20, "the focused composer still re-runs per key")
        #expect(r.hits > 0)
        // Real input changes still repaint the chrome, after a run of replayed keystrokes.
        let draft = ThemeFile(name: "Paper", appearance: .light, base: "solarized-light", colors: [:])
        controller.preview(draft, resolved: controller.library.resolve(draft: draft).theme, session: UUID())
        try await window.runUntil { (try? window.element(identifier: "theme-preview-bar")) != nil }
        controller.discardPreview()
        try await window.runUntil { (try? window.element(identifier: "theme-preview-bar")) == nil }
        session.status = .failedToLaunch("boom")
        try await window.runUntil { (try? window.element(identifier: "session-launch-error")) != nil }
        session.status = .idle
        try await window.runUntil { (try? window.element(identifier: "session-launch-error")) == nil }
    }

    @Test func codeViewKeysLeaveTheChatChromeAlone() async throws {
        let r = try await codeViewKeys()
        for name in ["ChatIslandBody", "ThemeBar", "CoordinationNotice", "LaunchFailureRow"] { #expect(r.reruns[name] == 0, "\(name) re-ran \(r.reruns[name]!)") }
    }
}
