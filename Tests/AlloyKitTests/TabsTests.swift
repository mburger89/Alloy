@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The tab strip over the code panel and the keys that drive it (⌘W, ⌃Tab, ⌘1-9).
@MainActor
@Suite struct TabsTests {
    /// A rig with `names` written as files and opened in order (the last is active).
    private func rigWithTabs(_ names: [String]) async throws -> Rig {
        let rig = Rig()
        for name in names {
            try "text of \(name)\n".write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for name in names { await rig.workspace.open(name) }
        return rig
    }

    /// The tab strip's button for the file at `path`, by its identifier `tab-<path>` (G13).
    private func tab(_ window: TestWindow, _ path: String) -> TestElement? {
        try? window.elements(where: { $0.identifier == "tab-\(path)" }).first
    }

    /// The close button of the tab for `path`, by its identifier `tab-close-<path>` (G13).
    private func closeButton(_ window: TestWindow, _ path: String) -> TestElement? {
        try? window.elements(where: { $0.identifier == "tab-close-\(path)" }).first
    }

    /// Minor 9: a document replaced behind a background tab (a read-only file made valid again) must not leave the
    /// tab's old view, with its engine document and decorations, alive until the tab is activated.
    @Test func replacedDocumentInABackgroundTabGetsANewView() async throws {
        let rig = Rig()
        let a = rig.root.appendingPathComponent("a.txt")
        try Data([0xFF, 0xFE, 0x41, 0x0A]).write(to: a)          // not UTF-8: opens read-only
        try "text of b\n".write(to: rig.root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        await rig.workspace.open("b.txt")
        let old = try #require(rig.workspace.document("a.txt"))
        #expect(old.state != .editable)
        let window = try alloyWindow(rig.workspace)
        // Visit a so it has a view, then go back to b: a is now a background tab.
        try await window.runUntil { tab(window, "a.txt") != nil && tab(window, "b.txt") != nil }
        try window.click(#require(tab(window, "a.txt")))
        try await window.runUntil { rig.workspace.activeTab == "a.txt" && CodePanelStore.existingView(for: old) != nil }
        let oldView = try #require(CodePanelStore.existingView(for: old))
        try window.click(#require(tab(window, "b.txt")))
        try await window.runUntil { rig.workspace.activeTab == "b.txt" }
        // The file becomes valid text: the watcher replaces the document.
        try "valid text\n".write(to: a, atomically: true, encoding: .utf8)
        rig.workspace.startWatching()
        rig.changes.send([a.path])
        for _ in 0..<2_000 where rig.workspace.pendingOutside.isEmpty { await Task.yield() }
        rig.clock.advance(by: 0.15)
        await rig.workspace.settle()
        let new = try #require(rig.workspace.document("a.txt"))
        #expect(new !== old)
        #expect(rig.workspace.activeTab == "b.txt")
        try await window.runUntil { CodePanelStore.existingView(for: new) != nil }
        #expect(oldView.closed)
    }

    @Test func tabsOpenAndClose() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "a.txt") != nil && tab(window, "b.txt") != nil }
        #expect(rig.workspace.tabs == ["a.txt", "b.txt"])
        // Clicking a tab selects it.
        try window.click(#require(tab(window, "a.txt")))
        try await window.runUntil { rig.workspace.activeTab == "a.txt" }
        // The selected tab's close button closes it.
        let close = try #require(closeButton(window, "a.txt"))
        try window.click(close)
        try await window.runUntil { rig.workspace.tabs == ["b.txt"] }
        try await window.runUntil { tab(window, "a.txt") == nil }
        #expect(rig.workspace.activeTab == "b.txt")
    }

    @Test func cmdWClosesActive() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "b.txt") != nil }
        window.typeKey("w", modifierFlags: .command)
        try await window.runUntil { rig.workspace.tabs == ["a.txt"] }
        #expect(rig.workspace.activeTab == "a.txt")
    }

    @Test func ctrlTabCycles() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt", "c.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "c.txt") != nil }
        #expect(rig.workspace.activeTab == "c.txt")
        window.typeKey(.tab, modifierFlags: .control)
        #expect(rig.workspace.activeTab == "a.txt")
        window.typeKey(.tab, modifierFlags: .control)
        #expect(rig.workspace.activeTab == "b.txt")
        window.typeKey(.tab, modifierFlags: [.control, .shift])
        #expect(rig.workspace.activeTab == "a.txt")
        window.typeKey(.tab, modifierFlags: [.control, .shift])
        #expect(rig.workspace.activeTab == "c.txt")
    }

    @Test func cmdNumberSelectsTab() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt", "c.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "c.txt") != nil }
        window.typeKey("1", modifierFlags: .command)
        #expect(rig.workspace.activeTab == "a.txt")
        window.typeKey("2", modifierFlags: .command)
        #expect(rig.workspace.activeTab == "b.txt")
        window.typeKey("9", modifierFlags: .command)   // no ninth tab: nothing changes
        #expect(rig.workspace.activeTab == "b.txt")
    }

    @Test func dirtyDotShows() async throws {
        let rig = try await rigWithTabs(["a.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "a.txt") != nil }
        #expect(tab(window, "a.txt")?.value == nil)
        let doc = try #require(rig.workspace.document("a.txt"))
        doc.buffer.replace(0..<0, with: "typed ")
        try await window.runUntil { tab(window, "a.txt")?.value == "edited" }
    }

    @Test func accentIsLastSessionColor() async throws {
        let (rig, session) = try await editedRig()
        await rig.workspace.open("login.swift")
        let author = try #require(rig.workspace.lastSessionEditor(of: "login.swift"))
        #expect(author == .session(session.id))
        #expect(FileTabStrip.accent(path: "login.swift", workspace: rig.workspace) == Color.sessionColor(session.colorIndex))
        // The rendered accent bar (3 x 14 pt, in the strip) is the colour of the gutter bar (3 pt, in the code view).
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let top = try window.element(identifier: "code-view").frame.origin.y.value
        func accentBar() -> [Float]? {
            window.scene.rects.first { $0.bounds.size.width == 3 && $0.bounds.size.height == 14 && $0.bounds.origin.y < top }
                .map { [$0.background.h, $0.background.s, $0.background.l] }
        }
        func gutterBar() -> [Float]? {
            window.scene.rects.first { $0.bounds.size.width == 3 && $0.bounds.origin.x > 700 && $0.bounds.origin.y >= top }
                .map { [$0.background.h, $0.background.s, $0.background.l] }
        }
        try await window.runUntil { accentBar() != nil && gutterBar() != nil }
        #expect(accentBar() == gutterBar())
        // A file no session edited has no accent.
        try "x\n".write(to: rig.root.appendingPathComponent("plain.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("plain.txt")
        #expect(rig.workspace.lastSessionEditor(of: "plain.txt") == nil)
        #expect(FileTabStrip.accent(path: "plain.txt", workspace: rig.workspace) == nil)
    }

    /// A real drag over the rendered strip reaches `.onMoveTab` and reorders `workspace.tabs`.
    @Test func draggingATabReordersThroughTheStrip() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt", "c.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "a.txt") != nil && tab(window, "c.txt") != nil }
        try await window.runUntil { try window.elements(where: { $0.identifier == "file-tabs" }).count == 1 }
        let a = try #require(tab(window, "a.txt")).frame, c = try #require(tab(window, "c.txt")).frame
        let y = a.origin.y + a.size.height / 2
        window.drag(from: Point(x: a.origin.x + a.size.width / 2, y: y), to: Point(x: c.origin.x + c.size.width, y: y))
        try await window.runUntil { rig.workspace.tabs == ["b.txt", "c.txt", "a.txt"] }
    }

    /// The ids follow the path, not the position: after a drag reorder and after a close, each id still reaches its own
    /// tab (clicking `tab-b.txt` selects b.txt) and the closed tab's ids are gone.
    @Test func tabIdentifiersSurviveReorderAndClose() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt", "c.txt"])
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { tab(window, "a.txt") != nil && tab(window, "c.txt") != nil }
        let a = try #require(tab(window, "a.txt")).frame, c = try #require(tab(window, "c.txt")).frame
        let y = a.origin.y + a.size.height / 2
        window.drag(from: Point(x: a.origin.x + a.size.width / 2, y: y), to: Point(x: c.origin.x + c.size.width, y: y))
        try await window.runUntil { rig.workspace.tabs == ["b.txt", "c.txt", "a.txt"] }
        // Rendered order follows the new order, and each id still belongs to its own tab.
        try await window.runUntil {
            guard let b = tab(window, "b.txt"), let a = tab(window, "a.txt") else { return false }
            return b.frame.origin.x < a.frame.origin.x
        }
        try window.click(#require(tab(window, "c.txt")))
        try await window.runUntil { rig.workspace.activeTab == "c.txt" }
        try window.click(#require(closeButton(window, "a.txt")))
        try await window.runUntil { rig.workspace.tabs == ["b.txt", "c.txt"] }
        try await window.runUntil { tab(window, "a.txt") == nil && closeButton(window, "a.txt") == nil }
        #expect(tab(window, "b.txt") != nil && tab(window, "c.txt") != nil)
        try window.click(#require(tab(window, "b.txt")))
        try await window.runUntil { rig.workspace.activeTab == "b.txt" }
        try window.click(#require(closeButton(window, "c.txt")))
        try await window.runUntil { rig.workspace.tabs == ["b.txt"] }
    }

    @Test func tabsMoveByDrag() async throws {
        let rig = try await rigWithTabs(["a.txt", "b.txt", "c.txt"])
        rig.workspace.moveTab(from: 0, to: 2)
        #expect(rig.workspace.tabs == ["b.txt", "c.txt", "a.txt"])
        rig.workspace.moveTab(from: 2, to: 0)
        #expect(rig.workspace.tabs == ["a.txt", "b.txt", "c.txt"])
        rig.workspace.moveTab(from: 5, to: 0)   // out of range: nothing
        #expect(rig.workspace.tabs == ["a.txt", "b.txt", "c.txt"])
    }

    @Test func duplicateNamesShowTheFullPath() async throws {
        #expect(FileTabStrip.titles(["a/x.swift", "b/x.swift", "y.swift"]) == ["a/x.swift", "b/x.swift", "y.swift"])
        #expect(FileTabStrip.titles(["a/x.swift", "y.swift"]) == ["x.swift", "y.swift"])
    }

    /// Regression guard on the keymap order: the global keys are shortcuts, which run after the panel's own ⌘F.
    @Test func cmdFStillReachesCodeView() async throws {
        let (rig, _) = try await editedRig()
        await rig.workspace.open("login.swift")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try window.click(window.element(identifier: "code-view"))
        window.typeKey("f", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        // The global keys are not swallowed by the code view either.
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "quick-open-field")) != nil }
    }

    @Test func ctrlShiftTabIsNotTheComposersModeCycle() async {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let model = ComposerModel(workspace: rig.workspace, sessionID: session.id)
        #expect(model.handleKey(.tab, modifiers: [.control, .shift]) == .ignored)
        #expect(model.handleKey(.tab, modifiers: .shift) == .handled)
    }

    @Test func globalKeysWaitOutIMEComposition() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        try "x\n".write(to: rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("a.txt")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "composer")) != nil }
        try window.click(window.element(identifier: "composer"))
        #expect(window.setMarkedText("\u{306B}"))
        window.typeKey("w", modifierFlags: .command)
        #expect(rig.workspace.tabs == ["a.txt"])
        window.typeKey("p", modifierFlags: .command)
        #expect((try? window.element(identifier: "quick-open-field")) == nil)
        #expect(window.commitMarkedText())
        window.typeKey("w", modifierFlags: .command)
        try await window.runUntil { rig.workspace.tabs.isEmpty }
    }
}
