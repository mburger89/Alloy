import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "let x = 1\n"
private let formatCaps = #""documentFormattingProvider":true,"documentRangeFormattingProvider":true"#

private func upper(_ from: Int, _ to: Int, _ text: String) -> String {
    #"{"range":{"start":{"line":0,"character":\#(from)},"end":{"line":0,"character":\#(to)}},"newText":"\#(text)"}"#
}

private func formatScript(_ replies: String, caps: String = formatCaps, extra: String = "") -> String {
    IntelRig.script(caps: caps, extra: #","replies":{\#(replies)}\#(extra)"#)
}

private let formatOnce = formatScript(#""textDocument/formatting":[{"result":[\#(upper(0, 3, "LET"))]}]"#)

@MainActor
@Suite
struct FormatTests {
    private func text(_ doc: EditorDocument) -> String {
        let snapshot = doc.buffer.snapshot()
        return String(decoding: snapshot.utf8(in: 0..<snapshot.utf8Count), as: UTF8.self)
    }

    private func disk(_ r: IntelRig, _ name: String) -> String {
        (try? String(contentsOf: r.rig.root.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    private func waitFor(_ window: TestWindow, _ condition: @MainActor () -> Bool) async throws {
        try await window.runUntil { condition() }
    }

    private func enableFormatOnSave(_ r: IntelRig) throws {
        var settings = r.rig.workspace.settings
        settings.languageServers["fake"] = ServerConfigOverride(formatOnSave: true)
        try r.rig.workspace.updateSettings(settings, persist: false)
    }

    private func command(_ r: IntelRig, _ c: IntelCommand) { r.rig.workspace.intelHooks.run[c]?() }

    private func view(_ r: IntelRig, _ path: String) throws -> OpenDocumentView {
        let doc = try #require(r.rig.workspace.document(path))
        return try #require(CodePanelStore.existingView(for: doc))
    }

    private func dirty(_ doc: EditorDocument) { _ = doc.buffer.replace(9..<9, with: " //") }

    // MARK: Explicit commands

    @Test func formatDocumentIsOneUndoStepAndDoesNotSave() async throws {
        try await IntelRig.run(script: formatScript(#""textDocument/formatting":[{"result":[\#(upper(0, 3, "LET"))]},{"result":[]}]"#)) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            #expect(r.rig.workspace.intelHooks.isEnabled(.formatDocument))
            command(r, .formatDocument)
            try await waitFor(window) { text(doc) == "LET x = 1\n" }
            #expect(doc.isDirty)
            #expect(disk(r, "main.rs") == source)
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            #expect(state.undo())
            #expect(text(doc) == source)
            command(r, .formatDocument)   // the server now has nothing to change
            let v = try view(r, "main.rs")
            try await waitFor(window) { v.definitionMessage == "Already formatted" }
        }
    }

    @Test func formatSelectionSendsTheRangeAndChangesOnlyIt() async throws {
        try await IntelRig.run(script: formatScript(#""textDocument/rangeFormatting":[{"result":[\#(upper(4, 5, "Y"))]}]"#)) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            #expect(!r.rig.workspace.intelHooks.isEnabled(.formatSelection))   // empty selection
            state.select(4..<9, reveal: false)
            #expect(r.rig.workspace.intelHooks.isEnabled(.formatSelection))
            command(r, .formatSelection)
            try await waitFor(window) { text(doc) == "let Y = 1\n" }
            #expect(r.methods().contains("textDocument/rangeFormatting"))
            #expect(!r.methods().contains("textDocument/formatting"))
        }
    }

    @Test func withoutTheCapabilityNothingIsSentAndTheCommandIsDisabled() async throws {
        try await IntelRig.run(script: IntelRig.script()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            #expect(!r.rig.workspace.intelHooks.isEnabled(.formatDocument))
            command(r, .formatDocument)
            for _ in 0..<20 { window.tick(); await Task.yield() }
            #expect(!r.methods().contains("textDocument/formatting"))
        }
    }

    @Test func aStaleAnswerIsDroppedAndTheTypedTextKept() async throws {
        let script = formatScript(#""textDocument/formatting":[{"result":[\#(upper(0, 3, "LET"))],"delayMs":300}]"#)
        try await IntelRig.run(script: script) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            command(r, .formatDocument)
            try await waitFor(window) { r.methods().contains("textDocument/formatting") }
            dirty(doc)
            try await Task.sleep(for: .milliseconds(600))
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(text(doc) == "let x = 1 //\n")
        }
    }

    @Test func aReadOnlyDocumentAndAFileWithoutAServerSendNothing() async throws {
        try await IntelRig.run(script: formatOnce) { r in
            try Data([0x66, 0x6E, 0x20, 0xFF, 0x0A]).write(to: r.rig.root.appendingPathComponent("bad.rs"))
            let window = try await r.open2("bad.rs")
            #expect(!r.rig.workspace.intelHooks.isEnabled(.formatDocument))
            command(r, .formatDocument)
            try r.write("notes.txt", "a\n")
            r.rig.workspace.openFilePath = "notes.txt"
            for _ in 0..<20 { window.tick(); await Task.yield() }
            #expect(!r.rig.workspace.intelHooks.isEnabled(.formatDocument))
            command(r, .formatDocument)
            for _ in 0..<20 { window.tick(); await Task.yield() }
            #expect(!r.methods().contains("textDocument/formatting"))
        }
    }

    // MARK: Format on save

    @Test func commandSFormatsWhenTheSwitchIsOn() async throws {
        try await IntelRig.run(script: formatOnce) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            dirty(try #require(r.rig.workspace.document("main.rs")))
            window.typeKey("s", modifierFlags: .command)
            try await waitFor(window) { disk(r, "main.rs") == "LET x = 1 //\n" }
            #expect(r.methods().filter { $0 == "textDocument/formatting" }.count == 1)
        }
    }

    @Test func commandSSavesAsTypedWhenTheSwitchIsOff() async throws {
        try await IntelRig.run(script: formatOnce) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            dirty(try #require(r.rig.workspace.document("main.rs")))
            window.typeKey("s", modifierFlags: .command)
            try await waitFor(window) { disk(r, "main.rs") == "let x = 1 //\n" }
            #expect(!r.methods().contains("textDocument/formatting"))
        }
    }

    @Test func autosaveNeverFormats() async throws {
        try await IntelRig.run(script: formatOnce) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            dirty(try #require(r.rig.workspace.document("main.rs")))
            for _ in 0..<5 { r.rig.clock.advance(by: 5); await Task.yield() }
            try await waitFor(window) { disk(r, "main.rs") == "let x = 1 //\n" }
            #expect(!r.methods().contains("textDocument/formatting"))
        }
    }

    @Test func focusLeavingAndClosingFormat() async throws {
        try await IntelRig.run(script: formatScript(#""textDocument/formatting":[{"result":[\#(upper(0, 3, "LET"))]},{"result":[\#(upper(0, 3, "LET"))]}]"#)) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            dirty(try #require(r.rig.workspace.document("main.rs")))
            await r.rig.workspace.focusLeft("main.rs")
            #expect(disk(r, "main.rs") == "LET x = 1 //\n")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            _ = doc.buffer.replace(0..<3, with: "let")
            await r.rig.workspace.close("main.rs")
            #expect(disk(r, "main.rs") == "LET x = 1 //\n")
            #expect(r.methods().filter { $0 == "textDocument/formatting" }.count == 2)
            _ = window
        }
    }

    @Test func aSlowServerSavesUnformattedAndSaysSoOncePerFile() async throws {
        let slow = formatScript(#""textDocument/formatting":[{"result":[\#(upper(0, 3, "LET"))],"delayMs":600},{"result":[\#(upper(0, 3, "LET"))],"delayMs":600}]"#)
        try await IntelRig.run(script: slow) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            let service = try #require(CodePanelStore.existingFormatService(for: doc))
            service.saveTimeout = .milliseconds(100)
            let v = try view(r, "main.rs")
            dirty(doc)
            try await r.rig.workspace.save("main.rs", format: true)
            #expect(disk(r, "main.rs") == "let x = 1 //\n")
            #expect(v.definitionMessage?.hasPrefix("Format on save skipped") == true)
            v.definitionMessage = nil
            _ = doc.buffer.replace(0..<0, with: "z")
            try await r.rig.workspace.save("main.rs", format: true)
            #expect(disk(r, "main.rs") == "zlet x = 1 //\n")
            #expect(v.definitionMessage == nil)
            _ = window
        }
    }

    @Test func anErrorReplySavesUnformatted() async throws {
        try await IntelRig.run(script: formatScript(#""textDocument/formatting":[{"error":{"code":-32603,"message":"boom"}}]"#)) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            _ = try await r.open("main.rs")
            dirty(try #require(r.rig.workspace.document("main.rs")))
            try await r.rig.workspace.save("main.rs", format: true)
            #expect(disk(r, "main.rs") == "let x = 1 //\n")
        }
    }

    @Test func aCrashingServerSavesUnformatted() async throws {
        try await IntelRig.run(script: formatScript(#""textDocument/formatting":[{"result":[]}]"#, extra: #","crashAfter":4"#)) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            _ = try await r.open("main.rs")
            dirty(try #require(r.rig.workspace.document("main.rs")))
            try await r.rig.workspace.save("main.rs", format: true)
            #expect(disk(r, "main.rs") == "let x = 1 //\n")
        }
    }

    @Test func aBufferEditedDuringTheWaitKeepsItsTypedTextAndDropsTheEdits() async throws {
        let script = formatScript(#""textDocument/formatting":[{"result":[\#(upper(0, 3, "LET"))],"delayMs":300}]"#)
        try await IntelRig.run(script: script) { r in
            try enableFormatOnSave(r)
            try r.write("main.rs", source)
            _ = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            dirty(doc)
            let save = Task { @MainActor in try await r.rig.workspace.save("main.rs", format: true) }
            while !r.methods().contains("textDocument/formatting") { await Task.yield() }
            _ = doc.buffer.replace(0..<0, with: "z")
            try await save.value
            #expect(text(doc) == "zlet x = 1 //\n")
            #expect(disk(r, "main.rs") == "zlet x = 1 //\n")
        }
    }
}
