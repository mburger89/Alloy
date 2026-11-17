import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "fn alpha() {}\nfn beta() {}\n"

private func sym(_ name: String, line: Int, from: Int, to: Int) -> String {
    #"{"name":"\#(name)","kind":12,"range":{"start":{"line":\#(line),"character":0},"end":{"line":\#(line),"character":13}},"selectionRange":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}}}"#
}

private func symbolScript(delayMs: Int = 0) -> String {
    let result = "[\(sym("alpha", line: 0, from: 3, to: 8)),\(sym("beta", line: 1, from: 3, to: 7))]"
    return IntelRig.script(caps: #""documentSymbolProvider":true"#,
                           extra: #","replies":{"textDocument/documentSymbol":[{"result":\#(result),"delayMs":\#(delayMs)}]}"#)
}

private func loc(_ uri: String, line: Int, character: Int = 3) -> String {
    #"{"uri":"\#(uri)","range":{"start":{"line":\#(line),"character":\#(character)},"end":{"line":\#(line),"character":\#(character + 4)}}}"#
}

@MainActor
@Suite struct QuickOpenIntelTests {
    private func exists(_ w: TestWindow, _ id: String) -> Bool { (try? w.element(identifier: id)) != nil }

    private func texts(_ w: TestWindow, _ id: String) -> [String] {
        guard let row = try? w.element(identifier: id) else { return [] }
        return ([row] + descendants(of: row, in: w)).compactMap { $0.value ?? $0.label }
    }

    private func primary(_ r: IntelRig, _ path: String) -> Range<Int>? {
        guard let s = r.rig.workspace.selectionState(for: path, in: .chat)?.primarySelection else { return nil }
        return min(s.anchor, s.head)..<max(s.anchor, s.head)
    }

    private func pause(_ w: TestWindow, seconds: Double) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { w.tick(); try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func shiftCmdOOpensSymbolsAndReturnJumps() async throws {
        try await IntelRig.run(script: symbolScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            window.typeKey("o", modifierFlags: [.command, .shift])
            try await window.runUntil { texts(window, "symbols-row-1").contains("beta") }
            #expect(texts(window, "symbols-row-0").contains("alpha"))
            #expect(exists(window, "symbols-palette"))
            window.typeKey(.downArrow)
            window.typeKey(.return)
            try await window.runUntil { primary(r, "main.rs") == 17..<21 }
            try await window.runUntil { !exists(window, "symbols-palette") }
        }
    }

    @Test func atSignInQuickOpenSwitchesToSymbolsAndBack() async throws {
        try await IntelRig.run(script: symbolScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            window.typeKey("p", modifierFlags: .command)
            try await window.runUntil { exists(window, "quick-open-field") }
            window.typeText("@")
            try await window.runUntil { texts(window, "symbols-row-1").contains("beta") }
            window.typeText("bet")
            try await window.runUntil { texts(window, "symbols-row-0").contains("beta") && !exists(window, "symbols-row-1") }
            for _ in 0..<4 { window.typeKey(.delete) }
            try await window.runUntil { !exists(window, "symbols-palette") }
            try await window.runUntil { exists(window, "quick-open-row-0") }
        }
    }

    @Test func aDocumentWithoutServerShowsOnlyTheEmptyRow() async throws {
        try await IntelRig.run(script: symbolScript()) { r in
            try r.write("notes.txt", "hello\n")
            let window = try await r.open2("notes.txt")
            window.typeKey("o", modifierFlags: [.command, .shift])
            try await window.runUntil { texts(window, "symbols-row-0").contains("No symbols for this file") }
            #expect(!exists(window, "symbols-row-1"))
            window.typeKey(.return)
            for _ in 0..<5 { window.tick(); await Task.yield() }
            #expect(exists(window, "symbols-palette"))
            window.typeKey(.escape)
            try await window.runUntil { !exists(window, "symbols-palette") }
        }
    }

    @Test func aServerWithoutTheCapabilityShowsOnlyTheEmptyRow() async throws {
        try await IntelRig.run(script: IntelRig.script()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            window.typeKey("o", modifierFlags: [.command, .shift])
            try await window.runUntil { texts(window, "symbols-row-0").contains("No symbols for this file") }
            #expect(!r.methods().contains("textDocument/documentSymbol"))
        }
    }

    @Test func aNullAnswerShowsTheEmptyRow() async throws {
        let script = IntelRig.script(caps: #""documentSymbolProvider":true"#, extra: #","replies":{"textDocument/documentSymbol":[{"result":null}]}"#)
        try await IntelRig.run(script: script) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            window.typeKey("o", modifierFlags: [.command, .shift])
            try await window.runUntil { texts(window, "symbols-row-0").contains("No symbols for this file") }
        }
    }

    @Test func theJumpFollowsTextTypedAboveWhileThePaletteWasOpen() async throws {
        try await IntelRig.run(script: symbolScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            window.typeKey("o", modifierFlags: [.command, .shift])
            try await window.runUntil { texts(window, "symbols-row-1").contains("beta") }
            let doc = try #require(r.rig.workspace.document("main.rs"))
            _ = doc.buffer.replace(0..<0, with: "// top\n")
            window.typeKey(.downArrow)
            window.typeKey(.return)
            try await window.runUntil { primary(r, "main.rs") == 24..<28 }
        }
    }

    // MARK: References

    private func referenceScript(root: URL, delayMs: Int = 0) -> String {
        let main = root.appendingPathComponent("main.rs").absoluteString
        let other = root.appendingPathComponent("other.rs").absoluteString
        let result = "[\(loc(other, line: 1)),\(loc(main, line: 0)),\(loc("file:///elsewhere/x.rs", line: 0)),\(loc("file:///elsewhere/y.rs", line: 2)),\(loc("file:///elsewhere/z.rs", line: 4)),\(loc(main, line: 1))]"
        return IntelRig.script(caps: #""referencesProvider":true"#,
                               extra: #","replies":{"textDocument/references":[{"result":\#(result),"delayMs":\#(delayMs)}]}"#)
    }

    private func references(delayMs: Int = 0, _ body: (IntelRig, TestWindow) async throws -> Void) async throws {
        let rig = Rig()
        let r = IntelRig(rig: rig, script: referenceScript(root: rig.root, delayMs: delayMs))
        do {
            try r.write("main.rs", source)
            try r.write("other.rs", "// c\nfn gamma(alpha) {}\n")
            let window = try await r.open("main.rs")
            try await body(r, window)
        } catch {
            await r.rig.workspace.stopAll()
            try? FileManager.default.removeItem(at: r.log)
            throw error
        }
        await r.rig.workspace.stopAll()
        try? FileManager.default.removeItem(at: r.log)
    }

    @Test func shiftF12ListsReferencesGroupedByFileAndOpensAHit() async throws {
        try await references { r, window in
            window.typeKey(FilePanelView.f12, modifierFlags: .shift)
            try await window.runUntil { exists(window, "references-palette") }
            #expect(texts(window, "references-row-0").contains("main.rs:1"))
            #expect(texts(window, "references-row-0").contains("fn alpha() {}"))
            #expect(texts(window, "references-row-1").contains("main.rs:2"))
            #expect(texts(window, "references-row-2").contains("other.rs:2"))
            #expect(!exists(window, "references-row-3"))
            #expect(texts(window, "references-footer").contains("3 more outside the project"))
            window.typeKey(.downArrow)
            window.typeKey(.downArrow)
            window.typeKey(.return)
            try await window.runUntil { r.rig.workspace.activeTab == "other.rs" }
            try await window.runUntil { primary(r, "other.rs") == 8..<12 }
            try await window.runUntil { !exists(window, "references-palette") }
        }
    }

    @Test func aStaleReferencesAnswerOpensNothing() async throws {
        try await references(delayMs: 600) { r, window in
            window.typeKey(FilePanelView.f12, modifierFlags: .shift)
            window.typeText("x")
            await pause(window, seconds: 1.5)
            #expect(!exists(window, "references-palette"))
        }
    }

    @Test func switchingTabsWhileInFlightOpensNothing() async throws {
        try await references(delayMs: 600) { r, window in
            window.typeKey(FilePanelView.f12, modifierFlags: .shift)
            await r.rig.workspace.open("other.rs")
            await pause(window, seconds: 1.5)
            #expect(!exists(window, "references-palette"))
            #expect(r.rig.workspace.activeTab == "other.rs")
        }
    }

    @Test func noReferencesSaysSo() async throws {
        let script = IntelRig.script(caps: #""referencesProvider":true"#, extra: #","replies":{"textDocument/references":[{"result":[]}]}"#)
        try await IntelRig.run(script: script) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            window.typeKey(FilePanelView.f12, modifierFlags: .shift)
            try await window.runUntil { texts(window, "file-panel-definition-message").contains("No references found") }
            #expect(!exists(window, "references-palette"))
        }
    }
}
