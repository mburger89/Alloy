import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "fn main() { alpha(); beta(); }\n"
private let alphaAt = 12
private let betaAt = 21

private func hoverReply(_ markdown: String = "**alpha** docs", delayMs: Int = 0) -> String {
    IntelRig.script(extra: #","replies":{"textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"\#(markdown)"}},"delayMs":\#(delayMs)}]}"#)
}

@MainActor
@Suite
struct HoverPanelTests {
    @Test func hoverOverAWordShowsThePopover() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let point = try await r.point(of: alphaAt, in: "main.rs", window: window)
            r.rest(at: point, in: window)
            try await window.runUntil { r.exists(window, "hover-popover") }
            #expect(r.methods().contains("textDocument/hover"))
            // The pointer leaving the text closes it.
            window.hover(at: Point(x: Pixels(400), y: Pixels(point.y.value + 200)))
            window.advance(by: 0.5)
            try await window.runUntil { !r.exists(window, "hover-popover") }
        }
    }

    @Test func aDiagnosticUnderThePointerIsListedAboveTheText() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            r.coordinator.handle(.diagnostics(path: "main.rs", version: Int(doc.buffer.version), items: [
                LSPDiagnostic(range: alphaAt..<(alphaAt + 5), severity: .error, message: "unresolved name", source: "rustc", code: "E0425")]))
            let point = try await r.point(of: alphaAt, in: "main.rs", window: window)
            r.rest(at: point, in: window)
            try await window.runUntil { r.exists(window, "hover-diagnostic-0") }
            #expect(r.exists(window, "hover-popover"))
            #expect(!r.exists(window, "hover-diagnostic-1"))
        }
    }

    @Test func aDiagnosticAloneStillOpensWhenTheServerHasNothing() async throws {
        try await IntelRig.run(script: IntelRig.script(extra: #","replies":{"textDocument/hover":[{"result":null}]}"#)) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            r.coordinator.handle(.diagnostics(path: "main.rs", version: Int(doc.buffer.version), items: [
                LSPDiagnostic(range: alphaAt..<(alphaAt + 5), severity: .warning, message: "unused", source: nil, code: nil)]))
            let point = try await r.point(of: alphaAt, in: "main.rs", window: window)
            r.rest(at: point, in: window)
            try await window.runUntil { r.exists(window, "hover-diagnostic-0") }
        }
    }

    @Test func aNullAnswerOpensNothing() async throws {
        try await IntelRig.run(script: IntelRig.script(extra: #","replies":{"textDocument/hover":[{"result":null}]}"#)) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let point = try await r.point(of: alphaAt, in: "main.rs", window: window)
            r.rest(at: point, in: window)
            try await window.runUntil { r.methods().contains("textDocument/hover") }
            for _ in 0..<20 { window.tick(); await Task.yield() }
            #expect(!r.exists(window, "hover-popover"))
        }
    }

    @Test func typingClosesIt() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let point = try await r.point(of: alphaAt, in: "main.rs", window: window)
            r.rest(at: point, in: window)
            try await window.runUntil { r.exists(window, "hover-popover") }
            window.typeText("x")
            try await window.runUntil { !r.exists(window, "hover-popover") }
        }
    }

    @Test func anAnswerAfterTheBufferChangedOpensNothing() async throws {
        try await IntelRig.run(script: hoverReply(delayMs: 300)) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let point = try await r.point(of: alphaAt, in: "main.rs", window: window)
            r.rest(at: point, in: window)
            try await window.runUntil { r.methods().contains("textDocument/hover") }
            window.typeText("x")   // before the 300 ms answer lands
            try await Task.sleep(for: .milliseconds(600))
            for _ in 0..<20 { window.tick(); await Task.yield() }
            #expect(!r.exists(window, "hover-popover"))
        }
    }

    @Test func commandIOpensItAtTheCaret() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            r.rig.workspace.selectionState(for: "main.rs", in: .chat)!.select(alphaAt..<alphaAt, reveal: false)
            for _ in 0..<3 { window.tick(); await Task.yield() }
            window.typeKey("i", modifierFlags: .primary)
            try await window.runUntil { r.exists(window, "hover-popover") }
        }
    }

    @Test func noServerOrReadOnlyDocumentNeverAsks() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try r.write("notes.txt", "alpha beta\n")
            let window = try await r.open2("notes.txt")
            r.rig.workspace.selectionState(for: "notes.txt", in: .chat)?.select(0..<0, reveal: false)
            window.typeKey("i", modifierFlags: .primary)
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(!r.methods().contains("textDocument/hover"))
            #expect(!r.exists(window, "hover-popover"))
        }
    }

    @Test func aReadOnlyDocumentNeverAsks() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try Data([0x66, 0x6E, 0x20, 0xFF, 0x0A]).write(to: r.rig.root.appendingPathComponent("bad.rs"))
            let window = try await r.open2("bad.rs")
            window.typeKey("i", modifierFlags: .primary)
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(!r.methods().contains("textDocument/hover"))
            #expect(!r.exists(window, "hover-popover"))
        }
    }

    @Test func theOldTextPaneNeverHovers() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let old = "let a = 1\nlet role = \"admin\"\nlet c = 3\n"
        let new = "let a = 1\nlet role = \"root\"\nlet c = 3\n"
        try new.write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        await rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: rig.root.appendingPathComponent("login.swift").path, originalFile: old, hunks: [
                PatchHunk(oldStart: 2, oldLines: 1, newStart: 2, newLines: 1, lines: ["-let role = \"admin\"", "+let role = \"root\""])]))))
        for _ in 0..<200_000 where rig.workspace.ledger.files["login.swift"] == nil { await Task.yield() }
        let r = IntelRig(rig: rig, script: hoverReply())
        do {
            await rig.workspace.open("login.swift", mode: .sideBySide)
            let window = try alloyWindow(rig.workspace)
            try await window.runUntil { r.exists(window, "sbs-right") && r.exists(window, "sbs-left") }
            try await window.runUntil { r.coordinator.features(for: "login.swift") != FeatureSet() }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            let left = try window.element(identifier: "sbs-left").frame, right = try window.element(identifier: "sbs-right").frame
            // Sweep the pointer down the first rows of each pane (the code sits below the glass bar).
            let rows = stride(from: Float(4), to: 160, by: 6).map { $0 }
            for dy in rows {
                r.rest(at: Point(x: Pixels(left.origin.x.value + 70), y: Pixels(left.origin.y.value + dy)), in: window)
                for _ in 0..<3 { window.tick(); await Task.yield() }
            }
            #expect(!r.methods().contains("textDocument/hover"))
            #expect(!r.exists(window, "hover-popover"))
            // The same sweep over the live pane reaches text and asks.
            for dy in rows where !r.exists(window, "hover-popover") {
                r.rest(at: Point(x: Pixels(right.origin.x.value + 70), y: Pixels(right.origin.y.value + dy)), in: window)
                for _ in 0..<20 where !r.exists(window, "hover-popover") { window.tick(); await Task.yield(); if r.methods().contains("textDocument/hover") { break } }
            }
            try await window.runUntil { r.exists(window, "hover-popover") }
        } catch {
            await rig.workspace.stopAll()
            throw error
        }
        await rig.workspace.stopAll()
    }

    @Test func theSameFileInTwoGroupsHoversOnlyUnderThePointer() async throws {
        try await IntelRig.run(script: hoverReply()) { r in
            try r.write("main.rs", source)
            let workspace = r.rig.workspace
            await workspace.restoreUIState()
            workspace.setMode(.code)
            let g0 = workspace.codeLayout.focusedGroupID
            await workspace.open("main.rs", in: .group(g0))
            workspace.splitFocused(.horizontal)
            let g1 = workspace.codeLayout.focusedGroupID
            await workspace.open("main.rs", in: .group(g1))
            workspace.focusGroup(id: g0)
            let window = try alloyWindow(workspace)
            let ids = [g0, g1].map { "code-view-\($0.uuidString)" }
            try await window.runUntil { ids.allSatisfy { r.exists(window, $0) } }
            try await window.runUntil { r.coordinator.features(for: "main.rs") != FeatureSet() }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            // The pointer rests on the second group's text, from the caret its own state holds.
            let state = try #require(workspace.selectionState(for: "main.rs", in: .group(g1)))
            try window.click(window.element(identifier: ids[1]))
            state.select(alphaAt..<alphaAt, reveal: false)
            for _ in 0..<5 { window.tick(); await Task.yield() }
            let area = try #require(window.platformWindow.textInputAreas.last)
            let rect = try #require(area)
            r.rest(at: Point(x: Pixels(rect.origin.x.value + 3), y: Pixels(rect.origin.y.value + rect.size.height.value / 2)), in: window)
            try await window.runUntil { r.exists(window, "hover-popover") }
            #expect(r.methods().filter { $0 == "textDocument/hover" }.count == 1)
            #expect(try window.elements(where: { $0.identifier == "hover-popover" }).count == 1)
        }
    }
}
