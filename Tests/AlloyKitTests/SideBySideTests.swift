@testable import AlloyCore
@testable import AlloyKit
import AlloyHighlight
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A 200-line file whose line 100 a session changed, so both panes scroll and the edit sits mid-file.
private let longOld = (1...200).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
private let longNew = (1...200).map { $0 == 100 ? "let value100 = 30000" : "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"

@MainActor
@Suite struct SideBySideTests {
    private func rigWithEdit(old: String = longOld, new: String = longNew) async throws -> Rig {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("login.swift")
        try old.write(to: url, atomically: true, encoding: .utf8)
        try new.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: old, hunks: [
                PatchHunk(oldStart: 100, oldLines: 1, newStart: 100, newLines: 1,
                          lines: ["-let value100 = 100", "+let value100 = 30000"])]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"] == nil { await Task.yield() }
        return rig
    }

    /// Minor 3: a pane over a large old text builds its `String` off the main actor; a small one does it inline.
    @Test func leftPaneBuildsLargeTextOffMain() async throws {
        let engine = HighlightEngine()
        let small = LeftPane(bytes: Array("let a = 1\n".utf8), path: "a.swift", engine: engine)
        let bigText = (1...6_000).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        #expect(bigText.utf8.count > LeftPane.inlineTextLimit)
        let big = LeftPane(bytes: Array(bigText.utf8), path: "a.swift", engine: engine)
        for _ in 0..<200_000 where small.highlighter == nil || big.highlighter == nil { await Task.yield() }
        #expect(small.textBuiltOffMain == false)
        #expect(big.textBuiltOffMain == true)
        #expect(big.highlighter != nil)
        small.close(); big.close()
    }

    /// `a b c d` -> `a d`: the right pane needs two filler rows (inline: two removed rows).
    private func rigWithRemoval() async throws -> Rig {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("login.swift")
        try "a\nd\n".write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: "a\nb\nc\nd\n", hunks: [
                PatchHunk(oldStart: 2, oldLines: 2, newStart: 2, newLines: 0, lines: ["-b", "-c"])]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"] == nil { await Task.yield() }
        return rig
    }

    private func sideBySide(_ rig: Rig) async throws -> TestWindow {
        await rig.workspace.open("login.swift", mode: .sideBySide)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "sbs-left")) != nil && (try? window.element(identifier: "sbs-right")) != nil }
        try await window.runUntil { rig.workspace.sideBySideBuilds >= 1 }
        window.tick()
        return window
    }

    @Test func sideBySideButtonOpensMode() async throws {
        let rig = try await rigWithEdit(old: panelOldText, new: panelNewText)
        rig.workspace.openFilePath = "login.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.diffMode == .inline)
        #expect((try? window.element(identifier: "sbs-left")) == nil)
        try window.click(segment("Side by side", in: window))
        try await window.runUntil { (try? window.element(identifier: "sbs-left")) != nil && (try? window.element(identifier: "sbs-right")) != nil }
        #expect(doc.diffMode == .sideBySide)
        try await window.runUntil { rig.workspace.sideBySideBuilds >= 1 }
        window.tick()
        // The old line is on the left only, the new line on the right only.
        try await window.runUntil { (try? window.element(identifier: "sbs-left"))?.value?.contains("admin") == true }
        #expect(try window.element(identifier: "sbs-right").value?.contains("root") == true)
        // Back to inline.
        try window.click(segment("Inline", in: window))
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        #expect((try? window.element(identifier: "sbs-left")) == nil)
    }

    @Test func leftPaneHoldsTheOldTextAndRightTheNew() async throws {
        let rig = try await rigWithEdit(old: panelOldText, new: panelNewText)
        let window = try await sideBySide(rig)
        try await window.runUntil { (try? window.element(identifier: "sbs-left"))?.value?.contains("admin") == true }
        let left = try window.element(identifier: "sbs-left").value ?? "", right = try window.element(identifier: "sbs-right").value ?? ""
        #expect(left.contains("admin") && !left.contains("root"))
        #expect(right.contains("root") && !right.contains("admin"))
    }

    @Test func scrollSyncs() async throws {
        let rig = try await rigWithEdit()
        let window = try await sideBySide(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        let left = try window.element(identifier: "sbs-left")
        let pitch = 14.0
        window.scroll(at: Point(x: left.frame.origin.x + 40, y: left.frame.origin.y + 40), byDeltaX: 0, deltaY: Float(-10 * pitch))
        try await window.runUntil { view.leftScroll.position.row > 1 }
        window.tick(); window.tick()
        #expect(abs(view.leftScroll.position.row - 10) < 1.5, "\(view.leftScroll.position.row)")
        #expect(abs(view.scroll.position.row - view.leftScroll.position.row) <= 0.01)
        // And the other way.
        let right = try window.element(identifier: "sbs-right")
        let before = view.leftScroll.position.row
        window.scroll(at: Point(x: right.frame.origin.x + 40, y: right.frame.origin.y + 40), byDeltaX: 0, deltaY: Float(-5 * pitch))
        try await window.runUntil { view.scroll.position.row > before + 1 }
        window.tick(); window.tick()
        #expect(abs(view.scroll.position.row - view.leftScroll.position.row) <= 0.01)
    }

    @Test func typingDoesNotRebuildTheModel() async throws {
        let rig = try await rigWithEdit()
        let window = try await sideBySide(rig)
        let builds = rig.workspace.sideBySideBuilds
        let decorations = rig.workspace.decorationBuilds
        try window.click(window.element(identifier: "sbs-right"))
        window.typeText("abc")
        window.tick(); window.tick()
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.isDirty)
        for _ in 0..<20 { await Task.yield(); window.tick() }
        #expect(rig.workspace.sideBySideBuilds == builds)
        #expect(rig.workspace.decorationBuilds == decorations)
    }

    @Test func aLedgerChangeRebuildsTheModel() async throws {
        let rig = try await rigWithEdit(old: panelOldText, new: panelNewText)
        let window = try await sideBySide(rig)
        let builds = rig.workspace.sideBySideBuilds
        let id = try #require(rig.workspace.ledger.files["login.swift"]?.edits.first?.id)
        rig.workspace.keep(edit: id, path: "login.swift")
        try await window.runUntil { rig.workspace.sideBySideBuilds > builds }
        window.tick()
        // Kept: the old view is now the new text, so the left pane shows "root" too.
        try await window.runUntil { (try? window.element(identifier: "sbs-left"))?.value?.contains("root") == true }
    }

    @Test func leftPaneIsReadOnlyAndHighlighted() async throws {
        let rig = try await rigWithEdit(old: panelOldText, new: panelNewText)
        let window = try await sideBySide(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        let left = try #require(view.left)
        #expect(left.buffer.isReadOnly)
        try await window.runUntil { left.highlighter != nil }
        try window.click(window.element(identifier: "sbs-left"))
        window.typeText("zzz")
        #expect(left.buffer.snapshot().text == panelOldText)
        #expect(!doc.isDirty)
    }

    @Test func chatActionsOpenTheFileAndTheSideBySide() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let url = rig.root.appendingPathComponent("login.swift")
        try panelNewText.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(
            id: "t1", name: "Edit", input: .object(["file_path": .string(url.path)]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: panelOldText, hunks: [
                PatchHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1,
                          lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"] == nil { await Task.yield() }
        let id = try #require(rig.workspace.ledger.files["login.swift"]?.edits.first?.id)
        try await window.runUntil { (try? window.element(identifier: "open-in-file-\(id.uuidString)")) != nil }
        try window.click(window.element(identifier: "open-in-file-\(id.uuidString)"))
        try await window.runUntil { rig.workspace.activeTab == "login.swift" && rig.workspace.document("login.swift") != nil }
        let doc = try #require(rig.workspace.document("login.swift"))
        try await window.runUntil { doc.buffer.primarySelection.range == doc.buffer.snapshot().lineRange(1) }
        #expect(doc.diffMode == .inline)
        try window.click(window.element(identifier: "side-by-side-\(id.uuidString)"))
        try await window.runUntil { doc.diffMode == .sideBySide }
        try await window.runUntil { (try? window.element(identifier: "sbs-left")) != nil }
    }

    @Test func togglingBackBeforeABuildLandsKeepsTheRows() async throws {
        let rig = try await rigWithRemoval()
        let window = try await sideBySide(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        #expect(view.decorations.virtualLineCount == 2)
        let gate = Gate()
        view.buildGate = { await gate.wait() }
        doc.diffMode = .inline
        window.tick()
        doc.diffMode = .sideBySide
        window.tick()
        await gate.open()
        for _ in 0..<50 { await Task.yield(); window.tick() }
        #expect(view.decorations.virtualLineCount == 2)
        #expect(view.left != nil)
    }

    @Test func aStaleBuildIsDroppedAndTheNewerOneApplies() async throws {
        let rig = try await rigWithEdit(old: panelOldText, new: panelNewText)
        let window = try await sideBySide(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        let builds = rig.workspace.sideBySideBuilds
        let gate = Gate(oneShot: true)
        view.buildGate = { await gate.wait() }
        // A build for the ledger version before the keep starts and waits.
        let id = try #require(rig.workspace.ledger.files["login.swift"]?.edits.first?.id)
        rig.workspace.keep(edit: id, path: "login.swift")
        window.tick()
        // Another ledger change while it waits; this build is not held.
        let url = rig.root.appendingPathComponent("login.swift")
        let edited = panelNewText.replacingOccurrences(of: "let c = 3", with: "let c = 4")
        try edited.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t2", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: panelNewText, hunks: [
                PatchHunk(oldStart: 3, oldLines: 1, newStart: 3, newLines: 1, lines: ["-let c = 3", "+let c = 4"])]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"]?.edits.count != 2 { await Task.yield() }
        window.tick()
        // The newer build (not held) applies first: its decorations name the second, live edit.
        let second = try #require(rig.workspace.ledger.files["login.swift"]?.edits.last?.id)
        try await window.runUntil { Set(view.tags.values) == [second] && view.left?.buffer.snapshot().text == panelNewText }
        for _ in 0..<30 { await Task.yield(); window.tick() }
        let applied = rig.workspace.decorationBuilds, sbsApplied = rig.workspace.sideBySideBuilds
        #expect(sbsApplied > builds)
        // Now the held build, made for the older ledger version (first edit kept, nothing live), finishes. It must be
        // dropped: applying it would count as a build and replace the tags (it has none) until the next rebuild.
        await gate.open()
        for _ in 0..<200 { await Task.yield(); window.tick() }
        #expect(rig.workspace.decorationBuilds == applied, "the stale build was applied")
        #expect(rig.workspace.sideBySideBuilds == sbsApplied)
        #expect(Set(view.tags.values) == [second], "\(view.tags)")
        #expect(Set(view.leftTags.values) == [second], "\(view.leftTags)")
    }

    @Test func aSaveKeepsTheLeftPaneAndTheRightDecorations() async throws {
        let rig = try await rigWithRemoval()
        let window = try await sideBySide(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        let pane = try #require(view.left)
        let buffer = pane.buffer
        let builds = rig.workspace.decorationBuilds
        _ = doc.buffer.replace(0..<0, with: "// note\n")
        try await rig.workspace.save("login.swift")
        try await window.runUntil { rig.workspace.decorationBuilds > builds }
        for _ in 0..<30 { await Task.yield(); window.tick() }
        #expect(view.left === pane && view.left?.buffer === buffer)
        #expect(view.decorations.virtualLineCount == 2)
        #expect(buffer.snapshot().text == "a\nb\nc\nd\n")
    }
}

/// Holds a build until opened; one-shot holds only the first caller.
actor Gate {
    private var isOpen = false
    private var used = false
    private let oneShot: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(oneShot: Bool = false) { self.oneShot = oneShot }
    func wait() async {
        if isOpen { return }
        if oneShot { if used { return }; used = true }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}
