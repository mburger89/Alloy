import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing

/// File > Open… (⌘O): an injected chooser supplies the URLs; each opens in a tab, a file outside the project opens
/// as `alloy <file>` does (through `CommandCenter.openOutsideProject`).
@MainActor @Suite struct OpenFileCommandTests {
    private func write(_ rig: Rig, _ names: [String]) throws {
        for name in names { try "x\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
    }

    @Test func openMenuItemHasCmdO() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let file = try #require(window.testApp.menuBar.first { $0.title == "File" })
        let titles = file.items.map(\.title).filter { ["New Terminal Tab", "Open\u{2026}", "Quick Open"].contains($0) }
        #expect(titles == ["New Terminal Tab", "Open\u{2026}", "Quick Open"], "\(titles)")
        let item = try #require(file.items.first { $0.title == "Open\u{2026}" })
        #expect(item.shortcut == PlatformKeyEquivalent(key: "o", modifiers: [.command]))
        #expect(item.isEnabled)
    }

    @Test func openCancelledDoesNothing() async throws {
        let rig = Rig()
        let center = testCenter(for: rig.workspace)
        var outside: [URL] = []
        center.chooseFiles = { _ in [] }
        center.openOutsideProject = { outside.append($0) }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-open")
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(rig.workspace.tabs.isEmpty && outside.isEmpty)
    }

    @Test func openTwoProjectFilesOpensBothTabs() async throws {
        let rig = Rig()
        try write(rig, ["a.txt", "b.txt"])
        let center = testCenter(for: rig.workspace)
        let urls = ["a.txt", "b.txt"].map { rig.root.appendingPathComponent($0) }
        center.chooseFiles = { _ in urls }
        center.openOutsideProject = { _ in Issue.record("inside files never go outside") }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-open")
        try await window.runUntil { rig.workspace.tabs == ["a.txt", "b.txt"] }
        #expect(rig.workspace.activeTab == "b.txt")
    }

    @Test func openOutsideFileBehavesLikeAlloyFileArgument() async throws {
        let rig = Rig()
        try write(rig, ["a.txt"])
        let elsewhere = TempFiles.url("alloy-open", ext: ".txt")
        try "y\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let center = testCenter(for: rig.workspace)
        var outside: [URL] = []
        center.chooseFiles = { _ in [rig.root.appendingPathComponent("a.txt"), elsewhere] }
        center.openOutsideProject = { outside.append($0) }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-open")
        try await window.runUntil { outside.count == 1 && rig.workspace.tabs == ["a.txt"] }
        #expect(outside == [elsewhere])
    }

    @Test func openDialogStartsInTheProjectFolder() async throws {
        let rig = Rig()
        let center = testCenter(for: rig.workspace)
        var asked: [URL?] = []
        center.chooseFiles = { directory in asked.append(directory); return [] }
        let window = try alloyWindow(rig.workspace)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-open")
        try await window.runUntil { asked.count == 1 }
        #expect(asked.first??.standardizedFileURL.path == rig.workspace.projectRoot.standardizedFileURL.path)
    }
}
