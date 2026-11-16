@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import CoreGraphics
import ImageIO
import MetalUIPlatform
import UniformTypeIdentifiers
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite(.timeLimit(.minutes(2))) struct CodeChatColumnTests {
    private func codeWindow(_ rig: Rig) async throws -> TestWindow {
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<3 { window.tick() }
        return window
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    private func frame(_ window: TestWindow, _ id: String) throws -> Bounds<Pixels> { try window.element(identifier: id).frame }

    private func settled(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("condition never held"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func openMenu(_ window: TestWindow) throws {
        try window.click(window.element(identifier: "code-session-menu"))
        window.tick()
    }

    @Test func columnShowsTheSelectedSession() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        let b = await rig.workspace.newSession(name: "Bea", purpose: .coding, select: false)
        await rig.transports[0].emit(.assistantBlock(messageID: "ma", block: .text("alpha words")))
        await rig.transports[1].emit(.assistantBlock(messageID: "mb", block: .text("bravo words")))
        try await settled { !a.transcript.blocks.isEmpty && !b.transcript.blocks.isEmpty }
        let window = try await codeWindow(rig)
        try await window.runUntil { (try? window.element(label: "alpha words")) != nil }
        #expect((try? window.element(label: "bravo words")) == nil)
        let island = try frame(window, "island-code-chat"), composer = try frame(window, "composer")
        let text = try frame(window, "island-code-chat")
        #expect(composer.minX >= island.minX && composer.maxX <= island.maxX && composer.maxY <= text.maxY)
        #expect(exists(window, "code-session-status") && exists(window, "code-chat-collapse"))
        #expect(rig.workspace.selectedSessionID == a.id)
        let alpha = try window.element(label: "alpha words").frame
        #expect(alpha.minX >= island.minX && alpha.maxX <= island.maxX)
        let menu = try window.element(identifier: "code-session-menu")
        #expect(([menu.label, menu.value].compactMap { $0 } + descendants(of: menu, in: window).compactMap { $0.value ?? $0.label })
            .joined(separator: " ").contains("Ada"))
        rig.workspace.selectedSessionID = b.id
        try await window.runUntil { (try? window.element(label: "bravo words")) != nil }
        #expect((try? window.element(label: "alpha words")) == nil)
    }

    @Test func sessionMenuSwitchesSessions() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        let b = await rig.workspace.newSession(name: "Bea", purpose: .coding, select: false)
        let window = try await codeWindow(rig)
        #expect(rig.workspace.selectedSessionID == a.id)
        try openMenu(window)
        let menu = try #require(window.presentedMenu)
        #expect(menu.item(accessibilityIdentifier: "code-session-\(b.id.uuidString)")?.title == "Bea \u{2014} \(statusWord(b.status))")
        #expect(menu.item(accessibilityIdentifier: "code-session-new")?.title == "New Session")
        try window.chooseMenuItem(accessibilityIdentifier: "code-session-\(b.id.uuidString)")
        window.tick()
        #expect(rig.workspace.selectedSessionID == b.id)
        rig.workspace.setMode(.chat)
        window.tick()
        #expect(rig.workspace.selectedSessionID == b.id)
    }

    @Test func sessionMenuNewSession() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "Ada")
        let window = try await codeWindow(rig)
        try openMenu(window)
        try window.chooseMenuItem(accessibilityIdentifier: "code-session-new")
        try await window.runUntil { rig.workspace.sessions.count == 2 }
        #expect(rig.workspace.selectedSessionID == rig.workspace.sessions[1].id)
    }

    private func png() -> Data {
        var pixels = [UInt8](repeating: 120, count: 4 * 4 * 4)
        let ctx = pixels.withUnsafeMutableBytes {
            CGContext(data: $0.baseAddress, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func chipCount(_ window: TestWindow) throws -> Int {
        var seen = Set<String>()
        return try window.elements(where: { $0.identifier?.hasPrefix("attachment-chip-") == true }).filter { seen.insert($0.identifier ?? "").inserted }.count
    }

    @Test func draftSurvivesAModeSwitch() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "Ada")
        let window = try await codeWindow(rig)
        try window.typeText("keep me", into: window.element(identifier: "composer"))
        let item = ClipboardItem(payloads: [ClipboardPayload(type: PasteboardType(identifier: "public.png", conformsTo: ["public.image", "public.data", "public.item"]),
                                                             bytes: .now([UInt8](png())))])
        #expect(window.setClipboard(items: [item]))
        window.typeKey("v", modifierFlags: [.command])
        try await window.runUntil { ((try? self.chipCount(window)) ?? 0) == 1 }
        window.typeKey("1", modifierFlags: [.control, .command]); window.tick(); window.tick()
        window.typeKey("2", modifierFlags: [.control, .command]); window.tick(); window.tick()
        let composer = try window.element(identifier: "composer")
        #expect(composer.value == "keep me", "\(composer.value ?? "nil")")
        #expect(try chipCount(window) == 1)
    }

    @Test func collapseAndExpand() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "Ada")
        let window = try await codeWindow(rig)
        let before = try frame(window, "island-code-editor")
        try window.click(window.element(identifier: "code-chat-collapse"))
        window.tick(); window.tick()
        #expect(rig.workspace.codeLayout.chatCollapsed)
        #expect(!exists(window, "island-code-chat") && exists(window, "island-code-chat-strip"))
        let strip = try frame(window, "island-code-chat-strip"), editor = try frame(window, "island-code-editor")
        #expect(abs(strip.maxX.value - 1200) < 12 && strip.minX > editor.maxX)
        #expect(editor.maxX.value - editor.minX.value > before.maxX.value - before.minX.value)
        #expect(abs(Double(strip.maxX.value - strip.minX.value) - codeChatStripWidth(AppearanceStyle.defaults)) < 0.5)
        try window.click(window.element(identifier: "code-chat-expand"))
        window.tick(); window.tick()
        #expect(!rig.workspace.codeLayout.chatCollapsed && exists(window, "island-code-chat") && !exists(window, "island-code-chat-strip"))
        window.typeKey("c", modifierFlags: [.command, .shift]); window.tick(); window.tick()
        #expect(rig.workspace.codeLayout.chatCollapsed && exists(window, "island-code-chat-strip"))
        window.typeKey("c", modifierFlags: [.command, .shift]); window.tick(); window.tick()
        #expect(!rig.workspace.codeLayout.chatCollapsed && exists(window, "island-code-chat"))
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "view-toggle-chat-column")
        #expect(rig.workspace.codeLayout.chatCollapsed)
    }

    @Test func collapsingSchedulesAStateWrite() async throws {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        let before = rig.workspace.uiStateWriteCount
        rig.workspace.codeLayout.chatCollapsed = true
        rig.workspace.codeLayout.chatCollapsed = true
        try await settled { rig.clock.pendingSleepers == 1 }
        rig.clock.advance(by: 1)
        try await settled { rig.workspace.uiStateWriteCount == before + 1 }
    }

    @Test func stripDotShowsNeedsApprovalWithoutOpening() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        let window = try await codeWindow(rig)
        rig.workspace.codeLayout.chatCollapsed = true
        window.tick(); window.tick()
        func label() -> String? { (try? window.element(identifier: "code-chat-expand"))?.label }
        #expect(exists(window, "code-chat-expand") && !exists(window, "code-chat-strip-status"))
        try await window.runUntil { label() == "Expand chat, \(statusWord(a.status))" }
        await rig.transports[0].emit(.assistantBlock(messageID: "m1", block: .text("busy")))
        try await settled { a.status == .working }
        try await window.runUntil { label() == "Expand chat, Working" }
        await rig.transports[0].emit(.controlRequest(ControlRequest(requestID: "r1", kind: .canUseTool(
            toolName: "Bash", input: .object(["command": .string("ls")]), description: nil, toolUseID: "t1", suggestions: []))))
        try await settled { a.status == .awaitingPermission }
        try await window.runUntil { label() == "Expand chat, Needs approval" }
        #expect(statusDotColor(a) == .warningInk)
        #expect(rig.workspace.codeLayout.chatCollapsed && !exists(window, "island-code-chat"))
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 0,
                                                        outputTokens: 0, sessionID: "s", terminalReason: nil)))
        try await settled { a.status == .idle }
        try await window.runUntil { label() == "Expand chat, Idle" }
    }

    @Test func stripAndHeaderIgnoreStreamedChunks() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        let window = try await codeWindow(rig)
        await rig.transports[0].emit(.assistantBlock(messageID: "m0", block: .text("first")))
        try await settled { a.transcript.blocks.count == 1 }
        window.tick(); window.tick()
        // Count only inside the synchronous ticks: the process-wide counter also moves while this test awaits.
        var header = 0, strip = 0
        func stream(_ range: Range<Int>, _ ticks: () -> Void) async throws {
            for i in range {
                await rig.transports[0].emit(.assistantBlock(messageID: "m\(i)", block: .text("chunk \(i)")))
                try await settled { a.transcript.blocks.count == i + 1 }
                let h = BodyProbe.count("SessionMenuHeader"), c = BodyProbe.count("CollapsedChatStrip")
                ticks()
                header += BodyProbe.count("SessionMenuHeader") - h
                strip += BodyProbe.count("CollapsedChatStrip") - c
            }
        }
        try await stream(1..<6) { window.tick() }
        rig.workspace.codeLayout.chatCollapsed = true
        window.tick(); window.tick()
        try await stream(6..<11) { window.tick() }
        #expect(header == 0, "header \(header)")
        #expect(strip == 0, "strip \(strip)")
    }

    @Test func statusDotColours() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "Ada")
        a.status = .working
        #expect(statusDotColor(a) == Color(ColorToken.accent))
        a.status = .exited(status: 1, message: "")
        #expect(statusDotColor(a) == .errorInk)
        a.status = .idle
        #expect(statusDotColor(a) == .mutedInk)
    }

    @Test func coordinationWarningsShowAtTheTop() async throws {
        let rig = Rig()
        let base = (1...30).map { "line\($0)\n" }.joined()
        try base.write(to: rig.root.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let a = await rig.workspace.newSession(name: "Ada"), b = await rig.workspace.newSession(name: "Bea", purpose: .coding, select: false)
        var l = TextLines(base); l.lines[9] = "BBB"
        await rig.workspace.appendToLedger("f.txt", saved: nil, baseline: base, edits: [(.session(b.id), l.text)])
        await rig.workspace.settle()
        let input: JSONValue = .object(["file_path": .string(rig.root.appendingPathComponent("f.txt").path),
                                        "old_string": .string("line11\n"), "new_string": .string("changed\n")])
        _ = rig.workspace.handleHook(HookRequest(event: .preToolUse, toolName: "Edit", toolUseID: "ta", toolInput: input, cliSessionID: "cli"),
                                     caller: MCPCaller(sessionID: a.id))
        let window = try await codeWindow(rig)
        try await window.runUntil { exists(window, "coordination-notice") }
        let notice = try frame(window, "coordination-notice"), island = try frame(window, "island-code-chat")
        let composer = try frame(window, "composer")
        #expect(notice.minX >= island.minX && notice.maxX <= island.maxX)
        #expect(notice.maxY <= composer.minY)
    }

    @Test func noChangedFilesListInCodeMode() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "Ada")
        let window = try await codeWindow(rig)
        let found = try window.elements { ($0.identifier ?? "").hasPrefix("changed-file-") }
        #expect(found.isEmpty)
    }
}
