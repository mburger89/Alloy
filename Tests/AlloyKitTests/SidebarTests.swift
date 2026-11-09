import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SidebarTests {
    @Test func newSessionButtonAddsRow() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "new-session"))
        try await window.runUntil { rig.workspace.sessions.count == 1 }
        let id = rig.workspace.sessions[0].id
        try await window.runUntil { (try? window.element(identifier: "session-row-\(id.uuidString)")) != nil }
        let row = try window.element(identifier: "session-row-\(id.uuidString)")
        #expect(row.label == rig.workspace.sessions[0].name)
        #expect(rig.workspace.sessions[0].name == "Session 1")
    }

    @Test func newSessionIsAPlusAtTheRightOfTheSessionsHeader() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let plus = try window.element(identifier: "new-session")
        let header = try window.element(identifier: "section-header-sessions")
        #expect(plus.label == "New session")
        #expect(plus.frame.size.width.value < 40)
        #expect(plus.frame.origin.x.value > header.frame.origin.x.value + 100)
        let plusMid = plus.frame.origin.y.value + plus.frame.size.height.value / 2
        let headerMid = header.frame.origin.y.value + header.frame.size.height.value / 2
        #expect(abs(plusMid - headerMid) <= 3)
    }

    /// The colours of the scene's rects that overlap `frame`: (background, border) as RGB triples.
    private func rects(in window: TestWindow, overlapping frame: Bounds<Pixels>) -> [(bg: [Float], border: [Float], alpha: Float)] {
        func rgb(_ h: MUIHsla) -> [Float] {
            let c = Hsla(h: h.h, s: h.s, l: h.l, a: h.a).toRgba()
            return [c.r, c.g, c.b]
        }
        return window.scene.rects.compactMap { r in
            let b = r.bounds
            guard b.origin.x < frame.origin.x.value + frame.size.width.value, b.origin.x + b.size.width > frame.origin.x.value,
                  b.origin.y < frame.origin.y.value + frame.size.height.value, b.origin.y + b.size.height > frame.origin.y.value
            else { return nil }
            return (rgb(r.background), rgb(r.borderColor), r.background.a)
        }
    }

    private func near(_ a: [Float], _ b: Color.Resolved) -> Bool {
        abs(a[0] - b.red) < 0.01 && abs(a[1] - b.green) < 0.01 && abs(a[2] - b.blue) < 0.01
    }

    @Test(arguments: [false, true]) func selectedRowPaintsTheSelectionFillAndTheTintStaysOffControls(dark: Bool) async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let b = await rig.workspace.newSession(name: "B")
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800)), colorScheme: dark ? .dark : .light) {
            rootView(workspace: rig.workspace)
        }
        window.tick(); window.tick()
        let resolved = try resolvedInWindow([.sessionSelection, Color(ColorToken.accent)], dark: dark)
        let selection = resolved[0], accent = resolved[1]
        let rowA = try window.element(identifier: "session-row-\(a.id.uuidString)").frame
        let rowB = try window.element(identifier: "session-row-\(b.id.uuidString)").frame
        #expect(rig.workspace.selectedSessionID == a.id)
        #expect(rects(in: window, overlapping: rowA).contains { $0.bg.count == 3 && $0.alpha > 0.99 && near($0.bg, selection) })
        #expect(!rects(in: window, overlapping: rowB).contains { near($0.bg, selection) })
        #expect(!rects(in: window, overlapping: rowA).contains { near($0.bg, accent) })
        // Renaming puts a TextField in the selected row; its focus ring and selection stay accent, not the row tint.
        try window.doubleClick(window.element(identifier: "session-name-\(a.id.uuidString)"))
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) != nil }
        window.tick()
        let field = try window.element(identifier: "rename-\(a.id.uuidString)").frame
        let inField = rects(in: window, overlapping: field)
        #expect(!inField.contains { near($0.border, selection) }, "the focus ring is not drawn in the row tint")
        #expect(inField.contains { near($0.border, accent) }, "the focus ring is the accent")
    }

    @Test func selectingRowSelectsSession() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let b = await rig.workspace.newSession(name: "B")
        #expect(rig.workspace.selectedSessionID == a.id)
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "session-row-\(b.id.uuidString)"))
        try await window.runUntil { rig.workspace.selectedSessionID == b.id }
    }

    @Test func changedFilesShowOneDotPerAuthor() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        _ = await rig.workspace.newSession(name: "B")
        let path = rig.root.appendingPathComponent("login.swift").path
        let v1 = "func a() {}\n", v2 = "func a() { 1 }\n"
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t0", isError: false, text: "ok",
            result: .write(filePath: path, isCreate: true, content: v1, originalFile: nil, hunks: []))))
        await settle { rig.workspace.changedFiles.first?.authors == [.session(a.id)] }
        await rig.transports[1].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .write(filePath: path, isCreate: false, content: v2, originalFile: v1, hunks: []))))
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { rig.workspace.changedFiles.first?.authors.count == 2 }
        let file = try window.element(identifier: "changed-file-login.swift")
        let ids = descendants(of: file, in: window).compactMap(\.identifier)
        #expect(ids.contains("author-dot-0") && ids.contains("author-dot-1"))
    }

    @Test func exitedSessionShowsStatus() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        await rig.transports[0].exit(status: 1, stderr: "boom")
        try await window.runUntil { if case .exited = a.status { return true } else { return false } }
        try await window.runUntil { (try? window.element(identifier: "session-row-\(a.id.uuidString)")) != nil }
        let row = try window.element(identifier: "session-row-\(a.id.uuidString)")
        let texts = descendants(of: row, in: window).compactMap { $0.value ?? $0.label }
        #expect(texts.contains("Exited"), "\(texts)")
    }
}

extension SidebarTests {
    @Test func formatters() {
        #expect(tokenText(0) == "0 tok" && tokenText(999) == "999 tok" && tokenText(1000) == "1.0k tok")
        #expect(tokenText(12_345) == "12.3k tok")
        #expect(modelShortName("claude-opus-5-5") == "Opus" && modelShortName("claude-sonnet-5-5") == "Sonnet")
        #expect(modelShortName("claude-haiku-4") == "Haiku" && modelShortName("gpt-x") == "gpt-x")
        #expect(modeBadge("default") == nil && modeBadge(nil) == nil && modeBadge("unknown") == nil)
        #expect(modeBadge("acceptEdits") == "Accept edits" && modeBadge("plan") == "Plan" && modeBadge("dontAsk") == "Don't ask")
    }

    @Test func escInRenameFieldDoesNotInterruptWorkingSession() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("working")))
        await settle { a.status == .working }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "session-name-\(a.id.uuidString)")) != nil }
        try window.doubleClick(window.element(identifier: "session-name-\(a.id.uuidString)"))
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) != nil }
        window.typeKey(.escape)
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) == nil }
        for _ in 0..<50 { await Task.yield(); window.tick() }
        let sent = await rig.transports[0].sent
        #expect(!sent.contains { if case .control(_, .interrupt) = $0 { true } else { false } })
        #expect(a.status == .working)
    }

    @Test func losingFocusCommitsRename() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "session-name-\(a.id.uuidString)")) != nil }
        try window.doubleClick(window.element(identifier: "session-name-\(a.id.uuidString)"))
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) != nil }
        window.typeKey(KeyEquivalent("a"), modifierFlags: .command)
        window.typeText("Blurred")
        for _ in 0..<5 { window.tick() }
        try window.click(window.element(identifier: "composer"))
        try await window.runUntil { a.name == "Blurred" }
    }

    @Test func rowShowsTokensAndMode() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.systemInit(SystemInit(model: "claude-opus-5-5", permissionMode: "plan", sessionID: "s", tools: [],
                                            slashCommands: [], terminalSlashCommands: [])))
        await t.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 1.234, inputTokens: 5_000,
                                        outputTokens: 2_345, sessionID: "s", terminalReason: nil,
                                        cacheCreationTokens: 3_000, cacheReadTokens: 1_955)))
        await settle { a.status == .idle && a.model != nil }
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "session-row-\(a.id.uuidString)")) != nil }
        let row = try window.element(identifier: "session-row-\(a.id.uuidString)")
        let texts = descendants(of: row, in: window).compactMap { $0.value ?? $0.label }
        #expect(texts.contains("Idle") && texts.contains("$1.23") && texts.contains("12.3k tok"), "\(texts)")
        #expect(texts.contains("Opus") && texts.contains("Plan"), "\(texts)")
    }

    @Test func doubleClickRenamesOnReturn() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "session-name-\(a.id.uuidString)")) != nil }
        try window.doubleClick(window.element(identifier: "session-name-\(a.id.uuidString)"))
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) != nil }
        let field = try window.element(identifier: "rename-\(a.id.uuidString)")
        try window.click(field)
        window.typeKey(KeyEquivalent("a"), modifierFlags: .command)
        window.typeText("Renamed")
        window.typeKey(.return)
        try await window.runUntil { a.name == "Renamed" }
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) == nil }
    }

    @Test func escCancelsRename() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "session-name-\(a.id.uuidString)")) != nil }
        try window.doubleClick(window.element(identifier: "session-name-\(a.id.uuidString)"))
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) != nil }
        try window.click(window.element(identifier: "rename-\(a.id.uuidString)"))
        window.typeText("zzz")
        window.typeKey(.escape)
        try await window.runUntil { (try? window.element(identifier: "rename-\(a.id.uuidString)")) == nil }
        #expect(a.name == "A")
    }
}

@MainActor
private func settle(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<200_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("timed out")
}

@MainActor
@Suite struct SessionMenuTests {
    private func settled(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        Issue.record("timed out"); throw CancellationError()
    }

    @Test func sessionMenuForksAndRenames() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                        outputTokens: 0, sessionID: "s", terminalReason: nil)))
        try await settled { s.status == .idle && s.hasConversation }
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "session-menu-\(s.id.uuidString)"))
        window.tick()
        let titles = window.presentedMenu?.items.map(\.title)
        #expect(titles == ["Fork", "Rename"])
        try window.chooseMenuItem("Fork")
        try await window.runUntil { rig.workspace.sessions.count == 2 }
        #expect(rig.workspace.sessions[1].name == "A (fork)")

        try window.click(window.element(identifier: "session-menu-\(s.id.uuidString)"))
        window.tick()
        try window.chooseMenuItem("Rename")
        try await window.runUntil { (try? window.element(identifier: "rename-\(s.id.uuidString)")) != nil }
        try window.typeText("X", into: window.element(identifier: "rename-\(s.id.uuidString)"))
        window.typeKey(.return)
        try await window.runUntil { s.name != "A" }
        #expect(s.name == "AX")
    }

    @Test func forkIsDisabledWithoutAConversation() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "session-menu-\(s.id.uuidString)"))
        window.tick()
        let items = try #require(window.presentedMenu?.items)
        #expect(items.map(\.title) == ["Fork", "Nothing to fork yet", "Rename"])
        #expect(items[0].isEnabled == false)
        #expect(throws: (any Error).self) { try window.chooseMenuItem("Fork") }
        try window.dismissMenu()
        #expect(rig.workspace.sessions.count == 1)
    }
}
