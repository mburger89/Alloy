import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUIPlatform
import MetalUITesting
import Testing

/// File > New File (⌘N): an empty Untitled tab; the first save asks where and turns the tab into that file in place.
@MainActor @Suite struct NewFileTests {
    private func read(_ rig: Rig, _ name: String) -> String? {
        try? String(contentsOf: rig.root.appendingPathComponent(name), encoding: .utf8)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500_000 where !condition() { await Task.yield() }
        #expect(condition())
    }

    private func codeRig(_ files: [String] = []) async throws -> Rig {
        let rig = Rig()
        for name in files { try "hello\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        for name in files { await rig.workspace.open(name) }
        return rig
    }

    private func type(_ rig: Rig, _ key: String, _ text: String) throws {
        _ = try #require(rig.workspace.document(key)).buffer.replace(0..<0, with: text)
    }

    @Test func cmdNOpensUntitled() async throws {
        let rig = try await codeRig()
        let window = try alloyWindow(rig.workspace)
        let sessions = rig.workspace.sessions.count
        window.typeKey("n", modifierFlags: .command)
        try await window.runUntil { rig.workspace.untitled.count == 1 }
        let key = try #require(rig.workspace.untitled.first)
        #expect(rig.workspace.tabs(in: rig.workspace.defaultPane) == [key])
        #expect(rig.workspace.activeTab(in: rig.workspace.defaultPane) == key)
        #expect(rig.workspace.title(of: key) == "Untitled")
        #expect(rig.workspace.sessions.count == sessions)
    }

    @Test func cmdNInChatModeSwitchesToTheCodeView() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect(rig.workspace.mode == .chat)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-new")
        try await window.runUntil { rig.workspace.untitled.count == 1 }
        #expect(rig.workspace.mode == .code)
        #expect(rig.workspace.tabs(in: rig.workspace.defaultPane) == Array(rig.workspace.untitled))
    }

    @Test func shiftCmdNMakesOneSession() async throws {
        let rig = try await codeRig()
        let window = try alloyWindow(rig.workspace)
        let sessions = rig.workspace.sessions.count
        window.typeKey("n", modifierFlags: [.command, .shift])
        try await window.runUntil { rig.workspace.sessions.count == sessions + 1 }
        for _ in 0..<20 { window.tick(); await Task.yield() }
        #expect(rig.workspace.sessions.count == sessions + 1)
        #expect(rig.workspace.untitled.isEmpty)
    }

    @Test func fileMenuStartsWithNewFile() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let file = try #require(window.testApp.menuBar.first { $0.title == "File" })
        let items = file.items.filter { $0.kind != .separator }
        #expect(Array(items.prefix(2).map(\.title)) == ["New File", "New Session"], "\(items.map(\.title))")
        #expect(items[0].shortcut == PlatformKeyEquivalent(key: "n", modifiers: [.command]))
        #expect(items[1].shortcut == PlatformKeyEquivalent(key: "n", modifiers: [.command, .shift]))
        #expect(items[0].accessibilityIdentifier == "file-new" && items[1].accessibilityIdentifier == "file-new-session")
    }

    @Test func firstSaveAsksAndBecomesTheFile() async throws {
        let rig = try await codeRig(["a.txt", "b.txt"])
        let ws = rig.workspace
        let key = ws.newUntitled()
        ws.moveTab(from: 2, to: 1, in: ws.defaultPane)
        try type(rig, key, "typed\n")
        let center = testCenter(for: ws)
        var asked: (String, URL)?
        center.chooseSaveURL = { name, directory in asked = (name, directory); return rig.root.appendingPathComponent("new.txt") }
        let window = try alloyWindow(ws)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save")
        try await waitFor { ws.untitled.isEmpty && ws.document(key) == nil }
        #expect(ws.tabs(in: ws.defaultPane) == ["a.txt", "new.txt", "b.txt"], "\(ws.tabs(in: ws.defaultPane))")
        #expect(ws.activeTab(in: ws.defaultPane) == "new.txt")
        #expect(read(rig, "new.txt") == "typed\n")
        #expect(ws.document("new.txt")?.buffer.snapshot().text == "typed\n")
        #expect(ws.document("new.txt")?.isDirty == false)
        #expect(asked?.0 == "Untitled")
        #expect(asked?.1.standardizedFileURL.path == rig.root.standardizedFileURL.path)
    }

    @Test func saveAsOnUntitledAlsoAsks() async throws {
        let rig = try await codeRig()
        let ws = rig.workspace
        let key = ws.newUntitled()
        try type(rig, key, "x")
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("s.txt") }
        let window = try alloyWindow(ws)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save-as")
        try await waitFor { ws.tabs(in: ws.defaultPane) == ["s.txt"] }
        #expect(read(rig, "s.txt") == "x")
    }

    @Test func firstSaveCancelledKeepsUntitled() async throws {
        let rig = try await codeRig()
        let ws = rig.workspace
        let key = ws.newUntitled()
        try type(rig, key, "x")
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in nil }
        let window = try alloyWindow(ws)
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "file-save")
        for _ in 0..<30 { window.tick(); await Task.yield() }
        #expect(ws.tabs(in: ws.defaultPane) == [key] && ws.isUntitled(key))
        #expect(ws.document(key)?.buffer.snapshot().text == "x")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.root.path)) ?? []).isEmpty)
    }

    @Test func saveUntitledOverAnOpenFile() async throws {
        let rig = try await codeRig(["b.txt", "a.txt"])
        let ws = rig.workspace
        let key = ws.newUntitled()
        ws.moveTab(from: 2, to: 0, in: ws.defaultPane)          // [Untitled, b.txt, a.txt]
        try type(rig, key, "over\n")
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("a.txt") }
        #expect(await center.saveUntitledTab(key, in: ws))
        #expect(ws.tabs(in: ws.defaultPane) == ["a.txt", "b.txt"], "\(ws.tabs(in: ws.defaultPane))")
        #expect(ws.activeTab(in: ws.defaultPane) == "a.txt")
        #expect(read(rig, "a.txt") == "over\n")
        #expect(ws.untitled.isEmpty)
        #expect(ws.document("a.txt")?.buffer.snapshot().text == "over\n")
        #expect(ws.document("a.txt")?.isDirty == false)
    }

    @Test func saveUntitledOverADirtyOpenFile() async throws {
        let rig = try await codeRig(["a.txt"])
        let ws = rig.workspace
        _ = try #require(ws.document("a.txt")).buffer.replace(0..<0, with: "dirty ")   // unsaved edit
        let key = ws.newUntitled()
        try type(rig, key, "over\n")
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("a.txt") }
        #expect(await center.saveUntitledTab(key, in: ws))
        await ws.settle()
        rig.clock.advance(by: 5)
        await ws.settle()
        #expect(read(rig, "a.txt") == "over\n")
        #expect(ws.document("a.txt")?.buffer.snapshot().text == "over\n")
        #expect(ws.document("a.txt")?.isDirty == false)
        #expect(ws.tabs(in: ws.defaultPane) == ["a.txt"])
    }

    @Test func saveUntitledInSecondGroup() async throws {
        let rig = try await codeRig(["a.txt"])
        let ws = rig.workspace
        let first = ws.codeLayout.focusedGroupID
        ws.splitFocused(.horizontal)
        let second = ws.codeLayout.focusedGroupID
        #expect(second != first)
        let key = ws.newUntitled(in: .group(second))
        try type(rig, key, "two\n")
        ws.focusGroup(id: first)
        let center = testCenter(for: ws)
        center.chooseSaveURL = { _, _ in rig.root.appendingPathComponent("two.txt") }
        #expect(await center.saveUntitledTab(key, in: ws))
        #expect(ws.tabs(in: .group(second)) == ["a.txt", "two.txt"], "\(ws.tabs(in: .group(second)))")
        #expect(ws.activeTab(in: .group(second)) == "two.txt")
        #expect(ws.tabs(in: .group(first)) == ["a.txt"])
        #expect(read(rig, "two.txt") == "two\n")
    }

    @Test func saveUntitledOutsideProjectOpensItThere() async throws {
        let rig = try await codeRig(["a.txt"])
        let ws = rig.workspace
        let key = ws.newUntitled()
        try type(rig, key, "away\n")
        let elsewhere = TempFiles.url("alloy-newfile", ext: ".txt")
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        let center = testCenter(for: ws)
        var outside: [URL] = []
        center.chooseSaveURL = { _, _ in elsewhere }
        center.openOutsideProject = { outside.append($0) }
        #expect(await center.saveUntitledTab(key, in: ws))
        #expect(outside == [elsewhere])
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == "away\n")
        #expect(ws.tabs(in: ws.defaultPane) == ["a.txt"] && ws.untitled.isEmpty)
    }

    @Test func noNewShortcutClashes() async throws {
        let rig = Rig()
        let center = testCenter(for: rig.workspace)
        let clashes = ShortcutClashes(center: center, platform: .macOS)
        for id in ["file.new", "session.new"] {
            let chord = try #require(center.registry.command(id: id)?.descriptor.shortcut)
            let found = clashes.clashes(for: chord, excluding: id, overrides: [:])
            #expect(found.isEmpty, "\(id): \(found)")
        }
        let (new, session) = (center.registry.command(id: "file.new"), center.registry.command(id: "session.new"))
        #expect(new?.descriptor.shortcut != session?.descriptor.shortcut)
    }
}
