import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "let x = 1\nlet y = x\n"

@MainActor
@Suite
struct RenamePanelTests {
    private func document(_ r: IntelRig, _ path: String = "main.rs") throws -> EditorDocument {
        try #require(r.rig.workspace.document(path))
    }

    private func view(_ r: IntelRig, _ path: String = "main.rs") throws -> OpenDocumentView {
        try #require(CodePanelStore.existingView(for: document(r, path)))
    }

    /// Opens main.rs, waits for the view to know rename, puts the caret on `x` and begins the rename.
    private func begin(_ r: IntelRig, caret: Int = 5, text: String = source, open: Bool = true) async throws -> (TestWindow, OpenDocumentView) {
        try r.write("main.rs", text)
        let window = try await r.open("main.rs")
        let doc = try document(r)
        try await window.runUntil { CodePanelStore.existingView(for: doc)?.features.rename == true }
        let v = try view(r)
        try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat)).select(caret..<caret, reveal: false)
        if open {
            v.beginRename(workspace: r.rig.workspace)
            try await window.runUntil { r.exists(window, "rename-field") }
            for _ in 0..<3 { window.tick(); await Task.yield() }
        }
        return (window, v)
    }

    private func text(_ r: IntelRig) throws -> String {
        let snapshot = try document(r).buffer.snapshot()
        return String(decoding: snapshot.utf8(in: 0..<snapshot.utf8Count), as: UTF8.self)
    }

    private func renameReply(_ rig: Rig, to name: String) -> String {
        let uri = rig.root.appendingPathComponent("main.rs").absoluteString
        func e(_ line: Int, _ from: Int, _ to: Int) -> String {
            #"{"range":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}},"newText":"\#(name)"}"#
        }
        return #"{"result":{"documentChanges":[{"textDocument":{"uri":"\#(uri)","version":null},"edits":[\#(e(0, 4, 5)),\#(e(1, 8, 9))]}]}}"#
    }

    @Test func theFieldOpensFocusedAndSelectsTheSymbol() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            let (window, _) = try await begin(r)
            #expect(try window.element(identifier: "rename-field").isFocused)
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            #expect(state.primarySelection.range == 4..<5)
        }
    }

    @Test func escapeOnlyDismissesAndFocusGoesBack() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            let (window, _) = try await begin(r)
            window.typeText("zz")
            window.typeKey(.escape)
            try await window.runUntil { !r.exists(window, "rename-field") }
            for _ in 0..<5 { window.tick(); await Task.yield() }
            #expect(r.count("textDocument/rename") == 0)
            #expect(try text(r) == source)
            #expect(try window.focusedElement?.identifier == "code-view")
        }
    }

    @Test func returnSendsTheTypedNameOnceAndApplies() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: renameReply(rig, to: "total"))) { r in
            let (window, _) = try await begin(r)
            window.typeText("total")   // the old name is selected, so typing replaces it
            window.typeKey(.return)
            try await window.runUntil { !r.exists(window, "rename-field") && r.count("textDocument/rename") == 1 }
            try await window.runUntil { (try? text(r)) == "let total = 1\nlet y = total\n" }
            #expect(r.count("textDocument/rename") == 1)
        }
    }

    @Test func anUnchangedOrEmptyNameOnlyCloses() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            let (window, _) = try await begin(r)
            window.typeKey(.return)   // unchanged
            try await window.runUntil { !r.exists(window, "rename-field") }
            let (window2, v) = (window, try view(r))
            v.beginRename(workspace: r.rig.workspace)
            try await window2.runUntil { r.exists(window2, "rename-field") }
            for _ in 0..<3 { window2.tick(); await Task.yield() }
            window2.typeKey(.delete)   // empties the selected name
            window2.typeKey(.return)
            try await window2.runUntil { !r.exists(window2, "rename-field") }
            #expect(r.count("textDocument/rename") == 0)
            #expect(try text(r) == source)
        }
    }

    @Test func surroundingWhitespaceIsTrimmed() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: renameReply(rig, to: "z"))) { r in
            let (window, _) = try await begin(r)
            window.typeText("  z  ")
            window.typeKey(.return)
            try await window.runUntil { r.count("textDocument/rename") == 1 }
            let sent = try #require(r.lastParams("textDocument/rename"))
            #expect(sent["newName"]?.stringValue == "z")
        }
    }

    @Test func typingInTheBufferDismissesTheField() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            let (window, v) = try await begin(r)
            let doc = try document(r)
            _ = doc.buffer.replace(0..<0, with: "// c\n")
            try await window.runUntil { !r.exists(window, "rename-field") }
            #expect(v.popoverSlot.rename == nil)
            #expect(r.count("textDocument/rename") == 0)
        }
    }

    @Test func aRefusedPrepareShowsTheMessageAndOpensNoField() async throws {
        try await IntelRig.run(script: IntelRig.renameScript(prepare: #"{"result":null}"#)) { r in
            let (window, v) = try await begin(r, open: false)
            v.beginRename(workspace: r.rig.workspace)
            try await window.runUntil { v.definitionMessage != nil }
            #expect(v.definitionMessage == "Cannot rename this symbol")
            #expect(!r.exists(window, "rename-field"))
            #expect(r.count("textDocument/rename") == 0)
        }
    }

    @Test func hoverAndRenameNeverCoexist() async throws {
        try await IntelRig.run(script: IntelRig.renameScript(hover: true)) { r in
            let (window, v) = try await begin(r, open: false)
            v.showHover(at: 5, workspace: r.rig.workspace)
            try await window.runUntil { r.exists(window, "hover-popover") }
            v.beginRename(workspace: r.rig.workspace)
            try await window.runUntil { r.exists(window, "rename-field") }
            #expect(!r.exists(window, "hover-popover"))
            // The pointer resting on text asks nothing while the field is open.
            let before = r.count("textDocument/hover")
            let point = try await r.point(of: 14, in: "main.rs", window: window)
            _ = point
            v.showHover(at: 14, workspace: r.rig.workspace)
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(r.count("textDocument/hover") == before)
            #expect(!r.exists(window, "hover-popover"))
        }
    }

    @Test func beginningARenameClosesCompletion() async throws {
        try await IntelRig.run(script: IntelRig.renameScript(completion: true)) { r in
            let (window, v) = try await begin(r, caret: 7, text: "let alp", open: false)
            window.typeText("h")
            try await window.runUntil { r.exists(window, "completion-popup") }
            v.beginRename(workspace: r.rig.workspace)
            try await window.runUntil { r.exists(window, "rename-field") }
            #expect(!r.exists(window, "completion-popup"))
        }
    }

    @Test func noRenameCapabilityDoesNothing() async throws {
        try await IntelRig.run(script: IntelRig.script()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let v = try view(r)
            #expect(!v.renameAttached(editable: true))
            v.beginRename(workspace: r.rig.workspace)
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(!r.exists(window, "rename-field"))
            #expect(r.count("textDocument/prepareRename") == 0)
            #expect(v.popoverSlot.rename == nil)
        }
    }

    @Test func theSameFileInTwoGroupsOpensTheFieldInTheAskedViewOnly() async throws {
        try await IntelRig.run(script: IntelRig.renameScript()) { r in
            try r.write("main.rs", source)
            let workspace = r.rig.workspace
            await workspace.restoreUIState()
            workspace.setMode(.code)
            let g0 = workspace.codeLayout.focusedGroupID
            await workspace.open("main.rs", in: .group(g0))
            workspace.splitFocused(.horizontal)
            let g1 = workspace.codeLayout.focusedGroupID
            await workspace.open("main.rs", in: .group(g1))
            let window = try alloyWindow(workspace)
            try await window.runUntil { r.coordinator.features(for: "main.rs").rename }
            let doc = try document(r)
            let views = try [g0, g1].map { try #require(CodePanelStore.existingView(for: doc, in: .group($0))) }
            try await window.runUntil { views.allSatisfy { $0.features.rename } }
            workspace.selectionState(for: "main.rs", in: .group(g1))?.select(5..<5, reveal: false)
            views[1].beginRename(workspace: workspace)
            try await window.runUntil { views[1].popoverSlot.rename != nil }
            #expect(views[0].popoverSlot.rename == nil)
        }
    }

    // MARK: Summary

    private func uri(_ r: Rig, _ name: String) -> String { r.root.appendingPathComponent(name).absoluteString }

    private func threeFileReply(_ r: Rig) -> String {
        func e(_ name: String, _ line: Int, _ from: Int, _ to: Int) -> String {
            #"{"textDocument":{"uri":"\#(uri(r, name))","version":null},"edits":[{"range":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}},"newText":"z"}]}"#
        }
        return #"{"result":{"documentChanges":[\#(e("main.rs", 0, 4, 5)),\#(e("other.rs", 0, 0, 1)),\#(e("closed.rs", 0, 0, 1))]}}"#
    }

    private func disk(_ r: IntelRig, _ name: String) -> String {
        (try? String(contentsOf: r.rig.root.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    private func docText(_ r: IntelRig, _ path: String) throws -> String {
        let snapshot = try #require(r.rig.workspace.document(path)).buffer.snapshot()
        return String(decoding: snapshot.utf8(in: 0..<snapshot.utf8Count), as: UTF8.self)
    }

    /// Renames x to z over main.rs (open, focused), other.rs (open) and closed.rs (closed) and waits for the summary.
    private func renamed(_ r: IntelRig) async throws -> (TestWindow, OpenDocumentView) {
        try r.write("other.rs", "x\n")
        try r.write("closed.rs", "x\n")
        let (window, v) = try await begin(r, open: false)
        await r.rig.workspace.open("other.rs")
        r.rig.workspace.openFilePath = "main.rs"
        try await window.runUntil { CodePanelStore.existingView(for: try document(r)) != nil }
        v.beginRename(workspace: r.rig.workspace)
        try await window.runUntil { r.exists(window, "rename-field") }
        for _ in 0..<3 { window.tick(); await Task.yield() }
        window.typeText("z")
        window.typeKey(.return)
        try await window.runUntil { r.exists(window, "rename-summary") }
        for _ in 0..<3 { window.tick(); await Task.yield() }
        return (window, v)
    }

    @Test func theSummaryListsEachFileAndKeepAllKeeps() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: threeFileReply(rig))) { r in
            let (window, v) = try await renamed(r)
            #expect(!r.exists(window, "rename-field"))
            for i in 0..<3 { #expect(r.exists(window, "rename-summary-file-\(i)")) }
            #expect(v.popoverSlot.summary?.summary == "Renamed 3 occurrences in 3 files")
            try window.click(window.element(identifier: "rename-keep-all"))
            try await window.runUntil { v.popoverSlot.summary?.rows.allSatisfy { $0.state == .kept } == true }
            #expect(v.popoverSlot.summary?.summary == "Kept 3 files")
            #expect(v.popoverSlot.summary?.isOpen == false)
            #expect(try docText(r, "main.rs") == "let z = 1\nlet y = x\n")
            #expect(disk(r, "closed.rs") == "z\n")
        }
    }

    @Test func revertAllRestoresEveryFile() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: threeFileReply(rig))) { r in
            let (window, v) = try await renamed(r)
            try window.click(window.element(identifier: "rename-revert-all"))
            try await window.runUntil { v.popoverSlot.summary?.rows.allSatisfy { $0.state == .reverted } == true }
            // Open files are rewritten on disk; the buffers follow through the file watcher.
            #expect(disk(r, "main.rs") == source)
            #expect(disk(r, "other.rs") == "x\n")
            #expect(disk(r, "closed.rs") == "x\n")
            #expect(v.popoverSlot.summary?.summary == "Reverted 3 files")
        }
    }

    @Test func revertAllAfterTypingInOneFileListsAConflictAndLosesNoText() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: threeFileReply(rig))) { r in
            let (window, v) = try await renamed(r)
            let other = try #require(r.rig.workspace.document("other.rs"))
            _ = other.buffer.replace(0..<1, with: "typed")
            try await r.rig.workspace.save("other.rs")
            try window.click(window.element(identifier: "rename-revert-all"))
            try await window.runUntil { v.popoverSlot.summary?.busy == false && v.popoverSlot.summary?.isOpen == false }
            let rows = try #require(v.popoverSlot.summary?.rows)
            let conflicts = rows.filter { if case .conflict = $0.state { true } else { false } }
            #expect(conflicts.count == 1 && conflicts[0].path == "other.rs")
            #expect(try docText(r, "other.rs").contains("typed"))
            #expect(disk(r, "other.rs").contains("typed"))
            #expect(disk(r, "main.rs") == source)
            #expect(disk(r, "closed.rs") == "x\n")
        }
    }

    @Test func undoInOneFileThenRevertAllNeverCorruptsText() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: threeFileReply(rig))) { r in
            let (window, v) = try await renamed(r)
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            #expect(state.undo())
            #expect(try docText(r, "main.rs") == source)
            try window.click(window.element(identifier: "rename-revert-all"))
            try await window.runUntil { v.popoverSlot.summary?.busy == false && v.popoverSlot.summary?.isOpen == false }
            #expect(disk(r, "other.rs") == "x\n")
            #expect(disk(r, "main.rs") == source)
            #expect(try docText(r, "main.rs") == source)
            #expect(disk(r, "closed.rs") == "x\n")
        }
    }

    @Test func doneDismissesAndLeavesTheEditsLive() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: IntelRig.renameScript(rename: threeFileReply(rig))) { r in
            let (window, v) = try await renamed(r)
            let group = try #require(v.popoverSlot.summary?.group)
            try window.click(window.element(identifier: "rename-done"))
            try await window.runUntil { !r.exists(window, "rename-summary") }
            #expect(v.popoverSlot.summary == nil)
            #expect(r.rig.workspace.hasEdit(group: group, path: "closed.rs"))
            #expect(disk(r, "closed.rs") == "z\n")
        }
    }
}
