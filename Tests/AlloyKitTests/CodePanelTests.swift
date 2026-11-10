@testable import AlloyCore
@testable import AlloyKit
import AlloyHighlight
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

let panelOldText = "let a = 1\nlet role = \"admin\"\nlet c = 3\n"
let panelNewText = "let a = 1\nlet role = \"root\"\nlet c = 3\n"

/// One session whose Edit changed line 2 of `login.swift`.
@MainActor
func editedRig() async throws -> (rig: Rig, session: Session) {
    let rig = Rig()
    let session = await rig.workspace.newSession(name: "A")
    try await emitEdit(rig, old: panelOldText, new: panelNewText, toolUseID: "t1")
    return (rig, session)
}

/// Writes `new` to login.swift and tells the workspace a session's Edit did it.
@MainActor
func emitEdit(_ rig: Rig, old: String, new: String, toolUseID: String) async throws {
    let url = rig.root.appendingPathComponent("login.swift")
    let before = rig.workspace.ledger.files["login.swift"]?.version
    try new.write(to: url, atomically: true, encoding: .utf8)
    await rig.transports[0].emit(.toolResult(ToolResultMessage(
        toolUseID: toolUseID, isError: false, text: "ok",
        result: .edit(filePath: url.path, originalFile: old, hunks: [
            PatchHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1,
                      lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
    for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"]?.version == before { await Task.yield() }
}

@MainActor
@Suite struct CodePanelTests {
    private func opened(_ rig: Rig, _ path: String = "login.swift") async throws -> TestWindow {
        rig.workspace.openFilePath = path
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        return window
    }

    /// Runs until decorations were built `count` times in all.
    private func built(_ rig: Rig, _ window: TestWindow, _ count: Int = 1) async throws {
        try await window.runUntil { rig.workspace.decorationBuilds >= count }
        window.tick()
    }

    /// The top of the code view: the tab strip's 3 pt accent lies above it, the gutter bars below.
    private func codeTop(_ window: TestWindow) -> Float {
        (try? window.element(identifier: "code-view").frame.origin.y.value) ?? 0
    }

    /// The 3 pt gutter bars drawn in the file panel (right of the chat, in the code view), top to bottom.
    private func bars(_ window: TestWindow) -> [Point<Pixels>] {
        let top = codeTop(window)
        return window.scene.rects.filter { $0.bounds.size.width == 3 && $0.bounds.origin.x > 700 && $0.bounds.origin.y >= top }
            .sorted { $0.bounds.origin.y < $1.bounds.origin.y }
            .map { Point(x: Pixels($0.bounds.origin.x + 1.5), y: Pixels($0.bounds.origin.y + $0.bounds.size.height / 4)) }
    }

    private func selectEdit(_ rig: Rig, _ window: TestWindow) async throws -> UUID {
        try await built(rig, window)
        let bar = try #require(bars(window).first)
        window.click(at: bar)
        try await window.runUntil { (try? window.element(identifier: "panel-edit-bar")) != nil }
        return try #require(rig.workspace.ledger.files["login.swift"]?.edits.first?.id)
    }

    @Test func panelShowsCodeViewTextArea() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let area = try window.element(identifier: "code-view")
        #expect(area.value?.contains("let a = 1") == true, "\(area.value ?? "nil")")
        #expect(try window.element(identifier: "file-panel-path").label == "login.swift"
                || window.element(identifier: "file-panel-path").value == "login.swift")
    }

    /// The (h, s, l) of the first 3 pt bar in the code view (the gutter) or the strip (the 14 pt accent).
    private func barColour(_ window: TestWindow, accent: Bool) -> [Float]? {
        let top = codeTop(window)
        return window.scene.rects.first {
            $0.bounds.size.width == 3 && (accent ? $0.bounds.size.height == 14 && $0.bounds.origin.y < top
                                                 : $0.bounds.origin.x > 700 && $0.bounds.origin.y >= top)
        }.map { [$0.background.h, $0.background.s, $0.background.l] }
    }

    /// I1: a tool result that arrives after its change was seen on disk adopts the `.outside` record; the gutter
    /// must take the session's colour without any other ledger or save change.
    @Test func lateToolResultRecoloursTheGutter() async throws {
        let rig = Rig()
        let url = rig.root.appendingPathComponent("login.swift")
        try panelOldText.write(to: url, atomically: true, encoding: .utf8)
        let session = await rig.workspace.newSession(name: "A")
        let window = try await opened(rig)
        // An earlier session edit (line 3) gives the file a ledger; the watcher records no change for a file without one.
        let first = panelOldText.replacingOccurrences(of: "let c = 3", with: "let c = 4")
        try first.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t0", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: panelOldText, hunks: [
                PatchHunk(oldStart: 3, oldLines: 1, newStart: 3, newLines: 1, lines: ["-let c = 3", "+let c = 4"])]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"] == nil { await Task.yield() }
        // The file changes on disk and the watcher sees it before any tool result: an `.outside` record.
        let second = first.replacingOccurrences(of: "\"admin\"", with: "\"root\"")
        try second.write(to: url, atomically: true, encoding: .utf8)
        rig.workspace.startWatching()
        rig.changes.send([url.path])
        for _ in 0..<2_000 where rig.workspace.pendingOutside.isEmpty { await Task.yield() }
        rig.clock.advance(by: 0.15)
        await rig.workspace.settle()
        try await window.runUntil { rig.workspace.ledger.files["login.swift"]?.edits.last?.author == .outside && barColour(window, accent: false) != nil }
        window.tick()
        let outsideColour = try #require(barColour(window, accent: false))
        #expect(outsideColour != barColour(window, accent: true))
        // The late tool result adopts it.
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: first, hunks: [
                PatchHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1,
                          lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"]?.edits.last?.author == .outside { await Task.yield() }
        #expect(rig.workspace.ledger.files["login.swift"]?.edits.map(\.author) == [.session(session.id), .session(session.id)])
        try await window.runUntil { barColour(window, accent: true) != nil && barColour(window, accent: false) != outsideColour }
        window.tick()
        #expect(barColour(window, accent: false) == barColour(window, accent: true), "gutter \(String(describing: barColour(window, accent: false))) accent \(String(describing: barColour(window, accent: true)))")
    }

    @Test func gutterClickSelectsEdit() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try await built(rig, window)
        #expect((try? window.element(identifier: "panel-edit-bar")) == nil)
        // The removed line's bar and the added line's bar are the same colour and touch: one drawn bar.
        #expect(bars(window).count == 1, "\(bars(window))")
        let id = try await selectEdit(rig, window)
        #expect((try? window.element(identifier: "panel-keep-\(id.uuidString)")) != nil)
        #expect((try? window.element(identifier: "panel-revert-\(id.uuidString)")) != nil)
        #expect((try? window.element(identifier: "panel-show-in-chat-\(id.uuidString)")) != nil)
    }

    @Test func panelKeepRemovesBar() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await selectEdit(rig, window)
        try window.click(window.element(identifier: "panel-keep-\(id.uuidString)"))
        #expect(rig.workspace.editRecord(id: id)?.state == .kept)
        try await window.runUntil { bars(window).isEmpty }
        #expect((try? window.element(identifier: "panel-edit-bar")) == nil)
    }

    @Test func panelRevertRestoresText() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await selectEdit(rig, window)
        try window.click(window.element(identifier: "panel-revert-\(id.uuidString)"))
        let doc = try #require(rig.workspace.document("login.swift"))
        try await window.runUntil { doc.buffer.snapshot().text == panelOldText }
        await rig.workspace.settle()
        #expect(try String(contentsOf: rig.root.appendingPathComponent("login.swift"), encoding: .utf8) == panelOldText)
        #expect(!doc.isDirty)
        try await window.runUntil { bars(window).isEmpty }
    }

    @Test func revertSavesTypingFirst() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await selectEdit(rig, window)
        let doc = try #require(rig.workspace.document("login.swift"))
        doc.buffer.replace(0..<0, with: "// note\n")
        #expect(doc.isDirty)
        let outcome = await rig.workspace.revertInEditor(edit: id, path: "login.swift")
        #expect(outcome == .reverted(newText: "// note\n" + panelOldText))
        await rig.workspace.settle()
        #expect(doc.buffer.snapshot().text == "// note\n" + panelOldText)
        #expect(try String(contentsOf: rig.root.appendingPathComponent("login.swift"), encoding: .utf8) == "// note\n" + panelOldText)
    }

    @Test func findCountsMatches() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try window.click(window.element(identifier: "find-button"))
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        window.typeText("let")
        func count() -> String? { (try? window.element(identifier: "find-count")).flatMap { $0.value ?? $0.label } }
        try await window.runUntil { count() == "3 matches" }
        let doc = try #require(rig.workspace.document("login.swift"))
        try window.click(window.element(identifier: "find-next"))
        #expect(doc.buffer.primarySelection.range == 0..<3)
        try await window.runUntil { count() == "1 of 3" }
        window.typeText("x")
        try await window.runUntil { count() == "No matches" }
        window.typeKey(.escape)
        try await window.runUntil { (try? window.element(identifier: "find-field")) == nil }
    }

    @Test func openFindFollowsEdits() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try window.click(window.element(identifier: "find-button"))
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        window.typeText("let")
        func count() -> String? { (try? window.element(identifier: "find-count")).flatMap { $0.value ?? $0.label } }
        try await window.runUntil { count() == "3 matches" }
        // An edit while a search is running must not leave matches of the old text.
        let doc = try #require(rig.workspace.document("login.swift"))
        doc.buffer.replace(0..<9, with: "let a = 1\nlet b = 2")
        try await window.runUntil { count() == "4 matches" }
    }

    @Test func keystrokeDoesNotRebuildDecorations() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try await built(rig, window)
        let builds = rig.workspace.decorationBuilds
        try window.click(window.element(identifier: "code-view"))
        window.typeText("a")
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.isDirty)
        #expect(rig.workspace.decorationBuilds == builds)
    }

    @Test func sessionEditRebuildsOnce() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try await built(rig, window)
        let builds = rig.workspace.decorationBuilds
        try await emitEdit(rig, old: panelNewText, new: panelNewText.replacingOccurrences(of: "root", with: "wheel"), toolUseID: "t2")
        try await window.runUntil { rig.workspace.decorationBuilds > builds }
        await rig.workspace.settle()
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(rig.workspace.decorationBuilds == builds + 1)
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.buffer.snapshot().text.contains("wheel"))
    }

    @Test func largeFileKeystrokeShapesFewLines() async throws {
        let rig = Rig()
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Bench/Corpus/large.swift")
        try FileManager.default.copyItem(at: corpus, to: rig.root.appendingPathComponent("large.swift"))
        let window = try await opened(rig, "large.swift")
        try window.click(window.element(identifier: "code-view"))
        window.tick()
        window.typeText("a")
        window.tick()
        let doc = try #require(rig.workspace.document("large.swift"))
        #expect(doc.isDirty)
        #expect(window.lastFrameWork.codeLinesShaped <= 2, "\(window.lastFrameWork.codeLinesShaped)")
    }

    @Test func noticeStripShowsOnlyThisFilesNoticeAndDismissesOnlyIt() async throws {
        let rig = Rig()
        try "x\n".write(to: rig.root.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let window = try await opened(rig, "n.txt")
        #expect((try? window.element(identifier: "file-panel-notice")) == nil)
        // "n.txt" is a substring of "ann.txt"; only the notice whose path is exactly the open file may show.
        rig.workspace.notify(path: "n.txt", kind: .warning, text: "Your unsaved edit in n.txt overlaps A's edit; your text was kept.")
        rig.workspace.notify(path: "ann.txt", kind: .warning, text: "something about ann.txt, mentioning n.txt")
        rig.workspace.notify(path: nil, kind: .warning, text: "a notice about n.txt with no path")
        try await window.runUntil { (try? window.element(identifier: "file-panel-notice")) != nil }
        let shown = try window.element(identifier: "file-panel-notice")
        #expect((shown.value ?? shown.label ?? "").contains("overlaps A's edit"))
        try window.click(window.element(identifier: "file-panel-notice-dismiss"))
        try await window.runUntil { (try? window.element(identifier: "file-panel-notice")) == nil }
        #expect(rig.workspace.notices.map(\.path) == ["ann.txt", nil])
    }

    @Test func diffModeToggleSetsDocumentMode() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.diffMode == .inline)
        try window.click(segment("Side by side", in: window))
        #expect(doc.diffMode == .sideBySide)
        try window.click(segment("Inline", in: window))
        #expect(doc.diffMode == .inline)
    }

    @Test func headerFindIsAnIconAndModeIsASegmentedPicker() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let find = try window.element(identifier: "find-button")
        #expect(find.label == "Find")
        #expect(find.frame.size.width.value < 40)
        let picker = try window.element(identifier: "diff-mode-toggle")
        let labels = descendants(of: picker, in: window).compactMap(\.label)
        #expect(labels.contains("Inline") && labels.contains("Side by side"))
    }

    @Test func readOnlyFileShowsReasonAndRefusesTyping() async throws {
        let rig = Rig()
        try Data([0x61, 0xFF, 0x62, 0x0A]).write(to: rig.root.appendingPathComponent("bad.txt"))
        let window = try await opened(rig, "bad.txt")
        try await window.runUntil { (try? window.element(identifier: "file-panel-read-only")) != nil }
        try window.click(window.element(identifier: "code-view"))
        window.typeText("z")
        let doc = try #require(rig.workspace.document("bad.txt"))
        #expect(!doc.isDirty)
    }

    /// The view's own `codeViewEditable(false)` must refuse typing: the buffer is NOT read-only here.
    @Test func editableModifierFollowsDocumentState() async throws {
        let rig = Rig()
        try "one\n".write(to: rig.root.appendingPathComponent("r.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("r.txt")
        let doc = try #require(rig.workspace.document("r.txt"))
        doc.state = .readOnly(reason: "test")
        #expect(!doc.buffer.isReadOnly)
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try window.click(window.element(identifier: "code-view"))
        window.typeText("z")
        #expect(!doc.isDirty && doc.buffer.snapshot().text == "one\n")
    }

    /// A session A transcript with an Edit tool block "t1" followed by enough text to scroll it out of view.
    private func chatWithEdit(_ rig: Rig, fillers: Int = 60) async throws {
        let url = rig.root.appendingPathComponent("login.swift")
        try panelNewText.write(to: url, atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .toolUse(
            id: "t1", name: "Edit", input: .object(["file_path": .string(url.path)]))))
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: panelOldText, hunks: [
                PatchHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1,
                          lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        for i in 0..<fillers {
            await rig.transports[0].emit(.assistantBlock(messageID: "text\(i)", block: .text("filler paragraph number \(i) " + String(repeating: "word ", count: 40))))
        }
    }

    @Test func showInChatSelectsTheSessionAndScrollsToTheBlock() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let b = await rig.workspace.newSession(name: "B")
        try await chatWithEdit(rig)
        rig.workspace.selectedSessionID = b.id
        let window = try await opened(rig)
        try await window.runUntil { (try? window.element(identifier: "block-t1")) == nil }
        let id = try await selectEdit(rig, window)
        try window.click(window.element(identifier: "panel-show-in-chat-\(id.uuidString)"))
        #expect(rig.workspace.selectedSessionID == a.id)
        try await window.runUntil {
            guard let block = try? window.element(identifier: "block-t1") else { return false }
            let f = block.frame
            return f.origin.y.value >= 0 && f.origin.y.value + f.size.height.value <= 800
        }
    }

    /// The gutter bar is painted in the colour of the session that made the edit, not of the selected session.
    @Test func gutterBarHasTheAuthorsColour() async throws {
        let (rig, a) = try await editedRig()
        let b = await rig.workspace.newSession(name: "B")
        let window = try await opened(rig)
        try await built(rig, window)
        func stripe() -> [Float]? {
            window.scene.rects.first { $0.bounds.size.width == 4 && $0.bounds.origin.x < 600 }
                .map { [$0.background.h, $0.background.s, $0.background.l] }
        }
        func bar() -> [Float]? {
            window.scene.rects.first { $0.bounds.size.width == 3 && $0.bounds.origin.x > 700 && $0.bounds.origin.y >= codeTop(window) }
                .map { [$0.background.h, $0.background.s, $0.background.l] }
        }
        rig.workspace.selectedSessionID = a.id
        try await window.runUntil { stripe() != nil }
        let aColour = try #require(stripe())
        #expect(bar() == aColour)
        rig.workspace.selectedSessionID = b.id
        try await window.runUntil { stripe() != aColour }
        #expect(bar() == aColour)
    }

    @Test func chatRevertOfAnOpenDirtyFileKeepsTheTyping() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        try await chatWithEdit(rig, fillers: 0)
        let window = try await opened(rig)
        let doc = try #require(rig.workspace.document("login.swift"))
        doc.buffer.replace(0..<0, with: "// note\n")
        let id = try #require(rig.workspace.ledger.files["login.swift"]?.edits.first?.id)
        try await window.runUntil { (try? window.element(identifier: "revert-\(id.uuidString)")) != nil }
        try window.click(window.element(identifier: "revert-\(id.uuidString)"))
        try await window.runUntil { doc.buffer.snapshot().text == "// note\n" + panelOldText }
        await rig.workspace.settle()
        #expect(try String(contentsOf: rig.root.appendingPathComponent("login.swift"), encoding: .utf8) == "// note\n" + panelOldText)
        #expect(!doc.isDirty)
    }

    /// G12 (fixed upstream, MetalUI #243): the gutter bar's context menu opens although the code view sits under the
    /// header, and offers the four actions.
    @Test func contextMenuOffersTheFourActions() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try await built(rig, window)
        let bar = try #require(bars(window).first)
        window.rightClick(at: bar)
        let menu = try #require(window.presentedMenu)
        #expect(menu.items.map(\.title) == ["Keep", "Revert", "Show in chat", "Side by side"])
    }

    /// Right-clicks the first gutter bar and returns the edit's id with the window.
    private func contextMenu(_ rig: Rig, _ window: TestWindow) async throws -> UUID {
        try await built(rig, window)
        let bar = try #require(bars(window).first)
        window.rightClick(at: bar)
        _ = try #require(window.presentedMenu)
        return try #require(rig.workspace.ledger.files["login.swift"]?.edits.first?.id)
    }

    @Test func contextMenuKeepKeepsTheEdit() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await contextMenu(rig, window)
        #expect(rig.workspace.editRecord(id: id)?.state == .live)
        try window.chooseMenuItem(accessibilityIdentifier: "keep-\(id.uuidString)")
        #expect(rig.workspace.editRecord(id: id)?.state == .kept)
    }

    @Test func contextMenuRevertRestoresTheFile() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await contextMenu(rig, window)
        try window.chooseMenuItem(accessibilityIdentifier: "revert-\(id.uuidString)")
        let doc = try #require(rig.workspace.document("login.swift"))
        try await window.runUntil { doc.buffer.snapshot().text == panelOldText }
        await rig.workspace.settle()
        #expect(try String(contentsOf: rig.root.appendingPathComponent("login.swift"), encoding: .utf8) == panelOldText)
        #expect(rig.workspace.editRecord(id: id)?.state != .live)
    }

    @Test func contextMenuShowInChatSelectsTheEditsSession() async throws {
        let (rig, a) = try await editedRig()
        let b = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = b.id
        let window = try await opened(rig)
        let id = try await contextMenu(rig, window)
        #expect(rig.workspace.selectedSessionID == b.id)
        try window.chooseMenuItem(accessibilityIdentifier: "show-in-chat-\(id.uuidString)")
        #expect(rig.workspace.selectedSessionID == a.id)
    }

    @Test func contextMenuSideBySideTogglesTheDiffMode() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await contextMenu(rig, window)
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.diffMode == .inline)
        try window.chooseMenuItem(accessibilityIdentifier: "side-by-side-\(id.uuidString)")
        #expect(doc.diffMode == .sideBySide)
        try await window.runUntil { (try? window.element(identifier: "sbs-left")) != nil }
    }

    @Test func findChordOpensFindFromTheCodeViewButNotFromTheComposer() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try window.click(window.element(identifier: "composer"))
        window.typeKey("f", modifierFlags: .command)
        window.tick()
        #expect((try? window.element(identifier: "find-field")) == nil)
        try window.click(window.element(identifier: "code-view"))
        window.typeKey("f", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
    }

    @Test func escReturnsFocusToTheCodeView() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try window.click(window.element(identifier: "find-button"))
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        window.typeKey(.escape)
        try await window.runUntil { (try? window.element(identifier: "find-field")) == nil }
        try await window.runUntil { (try? window.element(identifier: "code-view").isFocused) == true }
    }

    @Test func findCountFollowsCommandG() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try window.click(window.element(identifier: "find-button"))
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        window.typeText("let")
        func count() -> String? { (try? window.element(identifier: "find-count")).flatMap { $0.value ?? $0.label } }
        try await window.runUntil { count() == "3 matches" }
        try window.click(window.element(identifier: "code-view"))
        window.typeKey("g", modifierFlags: .command)
        try await window.runUntil { count()?.hasSuffix(" of 3") == true }
    }

    @Test func findOnAFileWithoutGrammarFollowsEdits() async throws {
        let rig = Rig()
        try "ab ab\n".write(to: rig.root.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let window = try await opened(rig, "n.txt")
        try window.click(window.element(identifier: "find-button"))
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        window.typeText("ab")
        func count() -> String? { (try? window.element(identifier: "find-count")).flatMap { $0.value ?? $0.label } }
        try await window.runUntil { count() == "2 matches" }
        let doc = try #require(rig.workspace.document("n.txt"))
        doc.buffer.replace(0..<0, with: "ab ")
        try await window.runUntil { count() == "3 matches" }
    }

    @Test func findCapsAtTenThousand() async throws {
        let rig = Rig()
        try String(repeating: "a\n", count: 12_000).write(to: rig.root.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)
        let window = try await opened(rig, "many.txt")
        try window.click(window.element(identifier: "find-button"))
        try await window.runUntil { (try? window.element(identifier: "find-field")) != nil }
        window.typeText("a")
        func count() -> String? { (try? window.element(identifier: "find-count")).flatMap { $0.value ?? $0.label } }
        try await window.runUntil { count() == "10,000+" }
    }

    /// While the buffer still holds the old text (the reload is held back), a build must not be applied, even
    /// when the new ledger text has the same byte count as the buffer's.
    @Test func sameLengthSessionEditWaitsForTheBuffer() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try await built(rig, window)
        let builds = rig.workspace.decorationBuilds
        let latch = Latch()
        rig.workspace.refreshGate = { _, _ in await latch.wait() }
        // "root" -> "toor": the file keeps its byte count.
        try await emitEdit(rig, old: panelNewText, new: panelNewText.replacingOccurrences(of: "root", with: "toor"), toolUseID: "t2")
        for _ in 0..<30 { window.tick(); await Task.yield(); try await Task.sleep(for: .milliseconds(5)) }
        #expect(rig.workspace.decorationBuilds == builds, "applied a build against the old buffer text")
        await latch.open()
        try await window.runUntil { rig.workspace.decorationBuilds > builds }
        await rig.workspace.settle()
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(rig.workspace.decorationBuilds == builds + 1)
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.buffer.snapshot().text.contains("toor"))
    }

    @Test func revertThatCannotSaveTellsTheUser() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        let id = try await selectEdit(rig, window)
        let doc = try #require(rig.workspace.document("login.swift"))
        doc.buffer.replace(0..<0, with: "// note\n")
        // A read-only directory makes the save's temporary file fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: rig.root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.root.path) }
        let outcome = await rig.workspace.revertInEditor(edit: id, path: "login.swift")
        guard case .conflict = outcome else { Issue.record("\(outcome)"); return }
        #expect(rig.workspace.revertConflicts[id] != nil)
        #expect(doc.buffer.snapshot().text.hasPrefix("// note\n"))
    }

    @Test func focusLeavingSavesTypedText() async throws {
        let (rig, _) = try await editedRig()
        let window = try await opened(rig)
        try window.click(window.element(identifier: "code-view"))
        window.typeText("q")
        let doc = try #require(rig.workspace.document("login.swift"))
        #expect(doc.isDirty)
        // Focus moves to the composer: the code view lost it, which saves.
        try window.click(window.element(identifier: "composer"))
        try await window.runUntil { !doc.isDirty }
        let onDisk = try String(contentsOf: rig.root.appendingPathComponent("login.swift"), encoding: .utf8)
        #expect(onDisk.contains("q"))
    }

    @Test func engineIsOpenedBeforeTheHighlighterAndFollowsEdits() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        await rig.workspace.settle()
        let doc = try #require(rig.workspace.document("login.swift"))
        let engine = HighlightEngine()
        let view = OpenDocumentView(document: doc, engine: engine)
        #expect(view.highlighter == nil)
        for _ in 0..<2_000_000 where view.highlighter == nil { await Task.yield() }
        #expect(view.highlighter != nil)
        let opened = await engine.captures(id: doc.id, byteRange: 0..<9, minVersion: doc.buffer.version)
        #expect(opened.version == doc.buffer.version && !opened.runs.isEmpty)
        doc.buffer.replace(0..<3, with: "var", origin: .typing)
        doc.buffer.replace(0..<3, with: "let", origin: .typing)
        let after = await engine.captures(id: doc.id, byteRange: 0..<9, minVersion: doc.buffer.version)
        #expect(after.version == doc.buffer.version, "engine at \(after.version), buffer at \(doc.buffer.version)")
        view.close()
    }

    /// A search that finishes after the buffer moved on must not set the matches of the old text.
    @Test func staleSearchResultIsNeverApplied() async throws {
        let rig = Rig()
        try "ab ab\n".write(to: rig.root.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.open("n.txt")
        let doc = try #require(rig.workspace.document("n.txt"))
        let view = OpenDocumentView(document: doc, engine: HighlightEngine())
        let latch = Latch()
        view.searchGate = { await latch.wait() }
        view.findVisible = true
        view.setQuery("ab")
        let v1 = doc.buffer.version
        doc.buffer.replace(0..<0, with: "ab ")
        await latch.open()
        for _ in 0..<2_000_000 where view.findCount != 3 { await Task.yield() }
        #expect(view.findCount == 3)
        #expect(view.appliedSearchVersions == [doc.buffer.version], "applied \(view.appliedSearchVersions), first search was at \(v1)")
        view.close()
    }

    @Test func scrollTargetIsKeptUntilItsBlockExists() {
        let blocks: [ChatBlock] = [.assistantText(id: "a", text: "x")]
        #expect(TranscriptView.scrollDecision(target: "t1", blocks: blocks, historyPending: true) == .keep)
        #expect(TranscriptView.scrollDecision(target: "t1", blocks: blocks, historyPending: false) == .drop)
        #expect(TranscriptView.scrollDecision(target: "a", blocks: blocks, historyPending: true) == .scroll("a"))
        #expect(TranscriptView.scrollDecision(target: nil, blocks: blocks, historyPending: false) == .drop)
    }

    @Test func nestedToolEditResolvesToItsTopLevelBlock() {
        let edit = UUID()
        let parent = ChatBlock.tool(ToolBlock(toolUseID: "agent1", name: "Agent", kind: .subagent, summary: "", editIDs: [edit]))
        #expect(topLevelBlockID(forToolUse: "nested9", edit: edit, in: [parent]) == "agent1")
        #expect(topLevelBlockID(forToolUse: "agent1", edit: edit, in: [parent]) == "agent1")
        #expect(topLevelBlockID(forToolUse: "nested9", edit: UUID(), in: [parent]) == "nested9")
    }
}

actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// The segment of the diff-mode picker whose label is `label`.
@MainActor
func segment(_ label: String, in window: TestWindow) throws -> TestElement {
    let picker = try window.element(identifier: "diff-mode-toggle")
    return try #require(descendants(of: picker, in: window).first { $0.label == label })
}
