import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Typing into the code view must not re-evaluate the bodies that show nothing per-keystroke.
@MainActor
@Suite struct ViewRerunTests {
    @Test func idleTicksDoNotRerunScreenBodies() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let before = BodyProbe.count("SidebarView"), before2 = BodyProbe.count("AlloyScreen")
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(BodyProbe.count("SidebarView") == before)
        #expect(BodyProbe.count("AlloyScreen") == before2)
    }

    @Test func typingLeavesSidebarScreenAndChatAlone() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let names = ["SidebarView", "AlloyScreen", "FilePanelView", "ChatView", "ChatColumn", "CodePanel", "FilePanelHeader", "FileTabStrip"]
        let before = Dictionary(uniqueKeysWithValues: names.map { ($0, BodyProbe.count($0)) })
        let doc = try #require(rig.workspace.document("login.swift"))
        let version = doc.buffer.version
        let textLength = doc.buffer.snapshot().text.count
        window.resetFrameWork()
        for _ in 0..<20 { window.typeText("a"); window.tick(); await Task.yield() }
        #expect(doc.buffer.version != version)
        let work = window.frameWork
        let requests = work.reduce(0) { $0 + $1.elementRequests }, prepaints = work.reduce(0) { $0 + $1.elementPrepaints }
        let hits = work.reduce(0) { $0 + $1.retainedHits }, misses = work.reduce(0) { $0 + $1.retainedMisses }
        let ineligible = work.reduce(into: [String: Int]()) { $0.merge($1.retainedIneligibleReasons, uniquingKeysWith: +) }
        // Before: 4377 requests / 0 retained hits over these 20 keystrokes. Retained sidebar and chat pay the build
        // recursion only; the editor pane stays ineligible (caret blink).
        #expect(requests < 3000, "element requests \(requests)")
        #expect(hits > 0)
        print("FRAMEWORK frames=\(work.count) requests=\(requests) prepaints=\(prepaints) hits=\(hits) misses=\(misses) ineligible=\(ineligible)")
        let after = Dictionary(uniqueKeysWithValues: names.map { ($0, BodyProbe.count($0)) })
        #expect(doc.buffer.snapshot().text.count == textLength + 20)
        // The header and tab strip show the dirty dot: one re-run for clean to dirty, none per keystroke after that.
        for n in ["FilePanelHeader", "FileTabStrip"] { #expect(after[n]! - before[n]! <= 1, "\(n)") }
        for n in ["SidebarView", "AlloyScreen", "FilePanelView", "ChatView", "ChatColumn", "CodePanel"] {
            #expect(after[n] == before[n], "\(n) re-ran \(after[n]! - before[n]!) times")
        }
    }

    @Test func settingsButtonFollowsStateClosedElsewhere() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        func shown() -> Bool { (try? window.element(identifier: "settings-view")) != nil }
        for round in 0..<2 {
            try window.click(window.element(identifier: "settings"))
            try await window.runUntil { shown() }
            // Closed from SettingsView, not from the sidebar that owns the button.
            try window.click(window.element(identifier: "settings-close"))
            try await window.runUntil { !shown() }
            for _ in 0..<3 { window.tick(); await Task.yield() }
            #expect(!shown(), "round \(round)")
        }
    }
}
