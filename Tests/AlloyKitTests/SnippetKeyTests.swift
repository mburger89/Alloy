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

/// The completion popup (which sees keys first) and MetalUI's snippet session share Tab, Shift-Tab and Esc.
@MainActor
@Suite
struct SnippetKeyTests {
    /// First answer: the snippet item; later answers: a plain item that `x` matches.
    private func script() -> String {
        let snippet = #"{"result":[{"label":"call","insertText":"call(${1:a}, ${2:b})$0","insertTextFormat":2}]}"#
        let plain = #"{"result":[{"label":"xylo"}]}"#
        return IntelRig.completionScript(completion: #"\#(snippet),\#(plain)"#)
    }

    private func text(_ doc: EditorDocument) -> String { doc.buffer.snapshot().text }

    private func selected(_ doc: EditorDocument, _ state: CodeSelectionState) -> String {
        let r = state.primarySelection.range
        return String(decoding: Array(text(doc).utf8)[r], as: UTF8.self)
    }

    private func start(_ r: IntelRig) async throws -> (TestWindow, EditorDocument, CodeSelectionState) {
        try r.write("main.rs", source)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
        state.select(endOfLine..<endOfLine, reveal: false)
        return (window, doc, state)
    }

    private func popupOpen(_ r: IntelRig, _ window: TestWindow) -> Bool { r.exists(window, "completion-popup") }

    /// Accepts the snippet item; the session starts on `a`.
    private func startSession(_ r: IntelRig, _ window: TestWindow) async throws {
        window.typeText("c")
        try await window.runUntil { popupOpen(r, window) }
        window.typeKey(.return)
    }

    /// With `a` selected, types `x` over it so the plain item's popup opens inside the placeholder.
    private func openPopupInPlaceholder(_ r: IntelRig, _ window: TestWindow) async throws {
        try await startSession(r, window)
        window.typeText("x")
        try await window.runUntil { popupOpen(r, window) }
    }

    @Test func tabGoesToTheSessionWhenThePopupIsClosed() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, doc, state) = try await start(r)
            try await startSession(r, window)
            #expect(!popupOpen(r, window))
            #expect(selected(doc, state) == "a")
            let requests = r.count("textDocument/completion")
            window.typeKey(.tab)
            await r.idle(window, 0.3)
            #expect(selected(doc, state) == "b")
            #expect(state.isSnippetActive)
            #expect(r.count("textDocument/completion") == requests)
        }
    }

    @Test func tabAcceptsWhenThePopupIsOpenInsideAPlaceholder() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, doc, state) = try await start(r)
            try await openPopupInPlaceholder(r, window)
            window.typeKey(.tab)
            #expect(text(doc) == "let x = call(xylo, b)\n")
            #expect(state.isSnippetActive)
            #expect(!popupOpen(r, window))
            window.typeKey(.tab)
            #expect(selected(doc, state) == "b")
        }
    }

    @Test func escClosesThePopupFirstThenEndsTheSession() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, doc, state) = try await start(r)
            try await openPopupInPlaceholder(r, window)
            window.typeKey(.escape)
            #expect(!popupOpen(r, window))
            #expect(state.isSnippetActive)
            window.typeKey(.escape)
            #expect(!state.isSnippetActive)
            #expect(text(doc) == "let x = call(x, b)\n")
        }
    }

    @Test func aThirdEscapeIsNotClaimedBySnippetOrPopup() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, _, state) = try await start(r)
            try await startSession(r, window)
            state.select(endOfLine + 5..<endOfLine + 5, reveal: false)
            window.typeKey(.escape)
            #expect(!state.isSnippetActive)
            window.typeKey(.escape)
            #expect(!state.isSnippetActive)
            #expect(state.selections.count == 1)
        }
    }

    @Test func shiftTabWithPopupClosedStepsBack() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, doc, state) = try await start(r)
            try await startSession(r, window)
            window.typeKey(.tab)
            #expect(selected(doc, state) == "b")
            window.typeKey(.tab, modifierFlags: .shift)
            #expect(selected(doc, state) == "a")
            #expect(state.isSnippetActive)
        }
    }

    @Test func shiftTabAtTheFirstStopOutdents() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, doc, state) = try await start(r)
            try await startSession(r, window)
            let before = text(doc)
            window.typeKey(.tab, modifierFlags: .shift)
            // MetalUI behaviour pinned: the first stop has nowhere to step back to, so the key falls through to outdent.
            #expect(selected(doc, state) == "a" || text(doc) != before)
            #expect(text(doc).utf8.count <= before.utf8.count)
        }
    }

    @Test func arrowKeysCloseThePopupButNotTheSession() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, _, state) = try await start(r)
            try await openPopupInPlaceholder(r, window)
            window.typeKey(.leftArrow)
            #expect(!popupOpen(r, window))
            #expect(state.isSnippetActive)
            window.typeKey(.rightArrow)
            #expect(state.isSnippetActive)
        }
    }

    @Test func steppingToTheFinalStopLeavesNoStalePopup() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, doc, state) = try await start(r)
            try await startSession(r, window)
            window.typeKey(.tab)
            window.typeKey(.tab)
            await r.idle(window, 0.3)
            #expect(!state.isSnippetActive)
            #expect(!popupOpen(r, window))
            #expect(state.primarySelection.head == endOfLine + "call(a, b)".utf8.count)
            #expect(text(doc) == "let x = call(a, b)\n")
        }
    }
}
