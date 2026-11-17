import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

private let source = "let x = \n"
private let endOfLine = 8

private func items(_ labels: String...) -> String {
    #"{"result":[\#(labels.map { #"{"label":"\#($0)"}"# }.joined(separator: ","))]}"#
}

@MainActor
@Suite
struct CompletionPanelTests {
    private func text(_ doc: EditorDocument) -> String { doc.buffer.snapshot().text }

    /// Opens `main.rs` with the caret at the end of its first line.
    private func start(_ r: IntelRig) async throws -> (TestWindow, EditorDocument, CodeSelectionState) {
        try r.write("main.rs", source)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
        state.select(endOfLine..<endOfLine, reveal: false)
        return (window, doc, state)
    }

    private func view(_ r: IntelRig) throws -> OpenDocumentView {
        let doc = try #require(r.rig.workspace.document("main.rs"))
        return try #require(CodePanelStore.existingView(for: doc))
    }

    @Test func typingAnIdentifierCharacterOpensThePopup() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo", "fob", "bar"))) { r in
            let (window, _, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            #expect(r.exists(window, "completion-row-0") && r.exists(window, "completion-row-1"))
            #expect(!r.exists(window, "completion-row-2"))
            #expect(try view(r).overlayModel.rows.map(\.label) == ["fob", "foo"])
        }
    }

    @Test func arrowsMoveAndReturnAcceptsInOneUndoStep() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo", "fob"))) { r in
            let (window, doc, state) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.downArrow)
            #expect(try view(r).overlayModel.selected == 1)
            window.typeKey(.upArrow)
            window.typeKey(.downArrow)
            window.typeKey(.return)
            #expect(text(doc) == "let x = foo\n")
            #expect(state.primarySelection.head == endOfLine + 3)
            try await window.runUntil { !r.exists(window, "completion-popup") }
            state.undo()
            #expect(text(doc) == "let x = f\n")
        }
    }

    @Test func tabAcceptsToo() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("fooBar"))) { r in
            let (window, doc, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.tab)
            #expect(text(doc) == "let x = fooBar\n")
        }
    }

    @Test func escapeClosesAndInsertsNothing() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("fooBar"))) { r in
            let (window, doc, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.escape)
            try await window.runUntil { !r.exists(window, "completion-popup") }
            #expect(text(doc) == "let x = f\n")
        }
    }

    @Test func aCommitCharacterAcceptsThenIsInserted() async throws {
        let script = IntelRig.completionScript(completion: #"{"result":[{"label":"fooBar","commitCharacters":[";"]}]}"#)
        try await IntelRig.run(script: script) { r in
            let (window, doc, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeText(";")
            #expect(text(doc) == "let x = fooBar;\n")
        }
    }

    @Test func typingInsideTheWordRefiltersWithoutAnotherRequest() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo", "fab"))) { r in
            let (window, _, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            #expect(try view(r).overlayModel.rows.count == 2)
            window.typeText("o")
            try await window.runUntil { (try? view(r).overlayModel.rows.map(\.label)) == ["foo"] }
            await r.idle(window, 0.3)
            #expect(r.count("textDocument/completion") == 1)
        }
    }

    @Test func aNewWordStartRequestsAgain() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo"))) { r in
            let (window, _, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeText(" ")
            try await window.runUntil { !r.exists(window, "completion-popup") }
            window.typeText("f")
            try await window.runUntil { r.count("textDocument/completion") == 2 }
            try await window.runUntil { r.exists(window, "completion-popup") }
        }
    }

    @Test func anIncompleteListRequestsAgainWhileTyping() async throws {
        let script = IntelRig.completionScript(completion: #"{"result":{"isIncomplete":true,"items":[{"label":"foo"}]}}"#)
        try await IntelRig.run(script: script) { r in
            let (window, _, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeText("o")
            try await window.runUntil { r.count("textDocument/completion") == 2 }
            #expect(r.exists(window, "completion-popup"))
        }
    }

    @Test func aTriggerCharacterOpensItAtOnce() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("len", "push"))) { r in
            let (window, doc, _) = try await start(r)
            window.typeText("v.")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.return)
            #expect(text(doc) == "let x = v.len\n")
        }
    }

    @Test func resolveShowsTheDocsAndAddsItsEdits() async throws {
        let script = IntelRig.completionScript(
            completion: #"{"result":[{"label":"HashMap","data":7}]}"#,
            resolve: #"{"result":{"label":"HashMap","documentation":{"kind":"markdown","value":"A **hash** map"},"additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"use std::collections::HashMap;\n"}]}}"#)
        try await IntelRig.run(script: script) { r in
            let (window, doc, state) = try await start(r)
            window.typeText("H")
            try await window.runUntil { r.exists(window, "completion-popup") }
            try await window.runUntil { r.exists(window, "completion-doc") }
            window.typeKey(.return)
            #expect(text(doc) == "use std::collections::HashMap;\nlet x = HashMap\n")
            // The word and the import are one undo step.
            state.undo()
            #expect(text(doc) == "let x = H\n")
        }
    }

    @Test func aSnippetIsInsertedAsPlainText() async throws {
        let script = IntelRig.completionScript(completion: #"{"result":[{"label":"println","insertText":"println!(\"${1:msg}\")$0","insertTextFormat":2}]}"#)
        try await IntelRig.run(script: script) { r in
            let (window, doc, state) = try await start(r)
            window.typeText("p")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.return)
            #expect(text(doc) == "let x = println!(\"msg\")\n")
            #expect(state.primarySelection.head == endOfLine + "println!(\"msg\")".utf8.count)
        }
    }

    @Test func aStaleAnswerAfterMoreTypingIsDropped() async throws {
        let script = IntelRig.completionScript(completion: #"{"result":[{"label":"STALE"}],"delayMs":500},{"result":[{"label":"great"}]}"#)
        try await IntelRig.run(script: script) { r in
            let (window, _, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.count("textDocument/completion") == 1 }
            window.typeText(" ")
            window.typeText("g")
            try await window.runUntil { r.count("textDocument/completion") == 2 }
            try await window.runUntil { r.exists(window, "completion-popup") }
            await r.idle(window, 0.7)
            #expect(try view(r).overlayModel.rows.map(\.label) == ["great"])
        }
    }

    @Test func controlSpaceOpensItWithNoTyping() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("alpha", "beta"))) { r in
            let (window, _, state) = try await start(r)
            state.select(endOfLine..<endOfLine, reveal: false)
            window.typeKey(.space, modifierFlags: .control)
            try await window.runUntil { r.exists(window, "completion-popup") }
            #expect(r.count("textDocument/completion") == 1)
        }
    }

    @Test func noPopupWithTwoCaretsASelectionOrAMovedFocus() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo"))) { r in
            let (window, _, state) = try await start(r)
            state.setSelections([CodeSelection(caret: 0), CodeSelection(caret: endOfLine)], primary: 1)
            window.typeText("f")
            await r.idle(window, 0.3)
            #expect(r.count("textDocument/completion") == 0)
            #expect(!r.exists(window, "completion-popup"))
        }
    }

    @Test func noSchedulerWithoutACompletionServer() async throws {
        try await IntelRig.run(script: IntelRig.script()) { r in
            let (window, _, _) = try await start(r)
            #expect(try view(r).scheduler == nil)
            window.typeText("f")
            await r.idle(window, 0.2)
            #expect(r.count("textDocument/completion") == 0)
        }
    }

    @Test func aReadOnlyDocumentGetsNoSchedulerAndNeverAsks() async throws {
        try await IntelRig.run(script: IntelRig.completionScript()) { r in
            try Data([0xff, 0xfe, 0x66, 0x6f]).write(to: r.rig.root.appendingPathComponent("bin.rs"))
            r.rig.workspace.openFilePath = "bin.rs"
            let window = try alloyWindow(r.rig.workspace)
            await r.idle(window, 0.3)
            let doc = try #require(r.rig.workspace.document("bin.rs"))
            let v = try #require(CodePanelStore.existingView(for: doc))
            #expect(doc.state != .editable)
            #expect(v.scheduler == nil)
            #expect(r.count("textDocument/completion") == 0)
            #expect(!r.exists(window, "completion-popup"))
        }
    }

    @Test func acceptingBeforeTheResolveAnswerStillAddsItsImport() async throws {
        let script = IntelRig.completionScript(
            completion: #"{"result":[{"label":"HashMap","data":7}]}"#,
            resolve: #"{"result":{"label":"HashMap","additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"use std::collections::HashMap;\n"}]},"delayMs":300}"#)
        try await IntelRig.run(script: script) { r in
            let (window, doc, _) = try await start(r)
            window.typeText("H")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeKey(.return)
            try await window.runUntil { self.text(doc) == "use std::collections::HashMap;\nlet x = HashMap\n" }
        }
    }

    @Test func aCommitCharacterBeforeTheResolveAnswerWaitsThenTypesIt() async throws {
        let script = IntelRig.completionScript(
            completion: #"{"result":[{"label":"HashMap","data":7,"commitCharacters":[";"]}]}"#,
            resolve: #"{"result":{"label":"HashMap","additionalTextEdits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"use std::collections::HashMap;\n"}]},"delayMs":300}"#)
        try await IntelRig.run(script: script) { r in
            let (window, doc, _) = try await start(r)
            window.typeText("H")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeText(";")
            try await window.runUntil { self.text(doc) == "use std::collections::HashMap;\nlet x = HashMap;\n" }
        }
    }

    @Test func focusLossClosesThePopup() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo"))) { r in
            let (window, _, _) = try await start(r)
            try view(r).findVisible = true
            try await window.runUntil { r.exists(window, "find-field") }
            try window.click(window.element(identifier: "code-view"))
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            try window.focus(window.element(identifier: "find-field"))
            try await window.runUntil { !r.exists(window, "completion-popup") }
        }
    }

    @Test func aSelectionMovedOntoTheWordAcceptsNothing() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo"))) { r in
            let (window, doc, state) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            state.select(0..<3, reveal: false)
            window.typeKey(.return)
            #expect(!text(doc).contains("foo"))
            try await window.runUntil { !r.exists(window, "completion-popup") }
        }
    }

    @Test func aTabSwitchClosesThePopup() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo"))) { r in
            let (window, _, _) = try await start(r)
            try r.write("other.rs", "x\n")
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            r.rig.workspace.openFilePath = "other.rs"
            try await window.runUntil { !r.exists(window, "completion-popup") }
            r.rig.workspace.openFilePath = "main.rs"
            await r.idle(window, 0.3)
            #expect(!r.exists(window, "completion-popup"))
        }
    }

    @Test func aServerThatDiesClearsThePopup() async throws {
        // initialize, initialized, didOpen, didChange and completion are five messages; the server exits after answering the fifth.
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("foo"), extra: #","crashAfter":5"#)) { r in
            let (window, _, _) = try await start(r)
            window.typeText("f")
            try await window.runUntil { r.exists(window, "completion-popup") }
            window.typeText("o")
            try await window.runUntil { !r.exists(window, "completion-popup") }
        }
    }

    @Test func theMenuItemTriggersCompletion() async throws {
        try await IntelRig.run(script: IntelRig.completionScript(completion: items("alpha"))) { r in
            let (window, _, _) = try await start(r)
            try window.testApp.performMenuBarItem(accessibilityIdentifier: "menu-trigger-completion")
            try await window.runUntil { r.exists(window, "completion-popup") }
        }
    }
}
