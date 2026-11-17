@testable import AlloyCore
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

private let caps = #""hoverProvider":true,"documentSymbolProvider":true,"referencesProvider":true,"definitionProvider":true,"documentFormattingProvider":true,"documentRangeFormattingProvider":true,"completionProvider":{"triggerCharacters":["."]},"signatureHelpProvider":{"triggerCharacters":["("]},"codeActionProvider":true"#

private func edit(_ from: Int, _ to: Int, _ text: String) -> String {
    #"{"range":{"start":{"line":0,"character":\#(from)},"end":{"line":0,"character":\#(to)}},"newText":"\#(text)"}"#
}

private func script(uri: String = "file:///x/main.rs") -> String {
    let symbol = #"{"name":"alpha","kind":12,"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":9}},"selectionRange":{"start":{"line":0,"character":3},"end":{"line":0,"character":7}}}"#
    return IntelRig.script(caps: caps, extra: #","replies":{"textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}},{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}],"textDocument/documentSymbol":[{"result":[\#(symbol)]}],"textDocument/references":[{"result":[{"uri":"\#(uri)","range":{"start":{"line":0,"character":3},"end":{"line":0,"character":7}}}]}],"textDocument/completion":[{"result":[{"label":"alphabet"},{"label":"alpine"}]},{"result":[{"label":"alphabet"},{"label":"alpine"}]}],"textDocument/formatting":[{"result":[\#(edit(0, 2, "FUNC"))]}],"textDocument/rangeFormatting":[{"result":[\#(edit(0, 2, "FN"))]}]}"#)
}

/// Completion, signature help, code actions and the explicit commands with several carets: the spec opens the first three
/// only with a single selection, hover and navigation use the primary caret, and Format Selection needs exactly one selection.
@MainActor @Suite struct MultiCaretIntelTests {
    private func menu(_ window: TestWindow, _ id: String) throws { try window.testApp.performMenuBarItem(accessibilityIdentifier: id) }
    private func isDisabled(_ window: TestWindow, _ id: String) -> Bool {
        do { try menu(window, id); return false } catch { return true }
    }
    private func text(_ doc: EditorDocument) -> String { doc.buffer.snapshot().text }

    private func start(_ r: IntelRig, source: String = source) async throws -> (TestWindow, CodeSelectionState) {
        try r.write("main.rs", source)
        let window = try await r.open("main.rs")
        let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
        return (window, state)
    }

    private func carets(_ state: CodeSelectionState, _ offsets: [Int], primary: Int = 0) {
        state.setSelections(offsets.map { CodeSelection(caret: $0) }, primary: primary)
    }

    /// The `params` of every `method` request the server received.
    private func params(_ r: IntelRig, _ method: String) -> [JSONValue] {
        guard let text = try? String(contentsOf: r.log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
            .filter { $0["method"]?.stringValue == method }.compactMap { $0["params"] }
    }

    private func characters(_ r: IntelRig, _ method: String) -> [Int] {
        params(r, method).compactMap { $0["position"]?["character"]?.intValue }
    }

    @Test func typingWithThreeCaretsRequestsNoCompletionOrProbe() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r)
            carets(state, [0, alphaAt, betaAt])
            for _ in 0..<3 { window.tick(); await Task.yield() }
            window.typeText("a")
            await r.idle(window, 0.8)
            #expect(state.selections.count == 3)
            #expect(r.count("textDocument/completion") == 0)
            #expect(r.count("textDocument/codeAction") == 0)
            #expect(r.count("textDocument/signatureHelp") == 0)
            #expect(!r.exists(window, "completion-popup"))
            #expect(!r.exists(window, "signature-help"))
            #expect(!r.exists(window, "lightbulb"))
        }
    }

    @Test func triggerCompletionSignatureAndQuickFixDisabledWithSeveralCarets() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r)
            carets(state, [alphaAt])
            for _ in 0..<3 { window.tick(); await Task.yield() }
            let ids = ["menu-trigger-completion", "menu-signature-help", "menu-quick-fix"]
            let hooks = r.rig.workspace.intelHooks
            #expect(hooks.isEnabled(.triggerCompletion) && hooks.isEnabled(.triggerSignature) && hooks.isEnabled(.quickFix))
            carets(state, [alphaAt, betaAt])
            for _ in 0..<3 { window.tick(); await Task.yield() }
            for id in ids { #expect(isDisabled(window, id), "\(id) disabled with two carets") }
            state.collapseToPrimary()
            for _ in 0..<3 { window.tick(); await Task.yield() }
            #expect(hooks.isEnabled(.triggerCompletion) && hooks.isEnabled(.triggerSignature) && hooks.isEnabled(.quickFix))
            try menu(window, "menu-trigger-completion")
        }
    }

    @Test func openCompletionClosesWhenASecondCaretIsAdded() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r, source: "let x = \n")
            state.select(8..<8, reveal: false)
            window.typeText("a")
            try await window.runUntil { r.exists(window, "completion-popup") }
            state.setSelections([CodeSelection(caret: 9), CodeSelection(caret: 0)], primary: 0)
            try await window.runUntil { !r.exists(window, "completion-popup") }
        }
    }

    @Test func showHoverUsesThePrimaryCaret() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r)
            carets(state, [0, alphaAt], primary: 1)
            for _ in 0..<3 { window.tick(); await Task.yield() }
            try menu(window, "menu-show-hover")
            try await window.runUntil { r.count("textDocument/hover") >= 1 }
            #expect(characters(r, "textDocument/hover").last == alphaAt)
            #expect(state.selections.count == 2)
        }
    }

    @Test func goToDefinitionAndReferencesUsePrimaryCaret() async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: script(uri: rig.root.appendingPathComponent("main.rs").absoluteString)) { r in
            let (window, state) = try await start(r)
            carets(state, [0, alphaAt], primary: 1)
            for _ in 0..<3 { window.tick(); await Task.yield() }
            try menu(window, "menu-find-references")
            try await window.runUntil { r.count("textDocument/references") >= 1 }
            #expect(characters(r, "textDocument/references").last == alphaAt)
        }
    }

    @Test func formatSelectionDisabledWithSeveralSelections() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r)
            state.setSelections([CodeSelection(anchor: 0, head: 2), CodeSelection(anchor: alphaAt, head: alphaAt + 5)], primary: 0)
            for _ in 0..<3 { window.tick(); await Task.yield() }
            #expect(isDisabled(window, "menu-format-selection"))
            // Even an explicit run does nothing: only one selection may be formatted.
            r.rig.workspace.intelHooks.run[.formatSelection]?()
            await r.idle(window, 0.3)
            #expect(r.count("textDocument/rangeFormatting") == 0)
            // A non-empty primary beside an empty second caret is still several selections.
            state.setSelections([CodeSelection(anchor: 0, head: 2), CodeSelection(caret: alphaAt)], primary: 0)
            for _ in 0..<3 { window.tick(); await Task.yield() }
            #expect(isDisabled(window, "menu-format-selection"))
            state.setSelections([CodeSelection(anchor: 0, head: 2)], primary: 0)
            for _ in 0..<3 { window.tick(); await Task.yield() }
            try menu(window, "menu-format-selection")
            try await window.runUntil { r.count("textDocument/rangeFormatting") >= 1 }
        }
    }

    @Test func formatDocumentWithSeveralCaretsKeepsThem() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r)
            let doc = try #require(r.rig.workspace.document("main.rs"))
            carets(state, [5, alphaAt, betaAt])
            for _ in 0..<3 { window.tick(); await Task.yield() }
            try menu(window, "menu-format")
            try await window.runUntil { text(doc).hasPrefix("FUNC") }
            // "fn" became "FUNC": two bytes longer, so every caret after it moves by two.
            #expect(state.selections.map(\.head) == [7, alphaAt + 2, betaAt + 2])
            #expect(state.selections.count == 3)
            #expect(state.undo())
            #expect(text(doc) == source)
            #expect(state.selections.map(\.head) == [5, alphaAt, betaAt])
        }
    }

    @Test func saveWithFormatOnSaveKeepsAllCarets() async throws {
        try await IntelRig.run(script: script()) { r in
            var settings = r.rig.workspace.settings
            settings.languageServers["fake"] = ServerConfigOverride(formatOnSave: true)
            try r.rig.workspace.updateSettings(settings, persist: false)
            let (window, state) = try await start(r)
            let doc = try #require(r.rig.workspace.document("main.rs"))
            carets(state, [5, alphaAt, betaAt])
            _ = doc.buffer.replace(source.utf8.count..<source.utf8.count, with: "//\n")
            window.typeKey("s", modifierFlags: .command)
            try await window.runUntil { text(doc).hasPrefix("FUNC") && !doc.isDirty }
            #expect(state.selections.count == 3)
            #expect(state.selections.map(\.head) == [7, alphaAt + 2, betaAt + 2])
            #expect(r.count("textDocument/formatting") == 1)
            let onDisk = try String(contentsOf: r.rig.root.appendingPathComponent("main.rs"), encoding: .utf8)
            #expect(onDisk == text(doc))
        }
    }

    @Test func findNextSelectsOneMatchFromSeveralCarets() async throws {
        try await IntelRig.run(script: script()) { r in
            let (window, state) = try await start(r)
            let doc = try #require(r.rig.workspace.document("main.rs"))
            let view = try #require(CodePanelStore.existingView(for: doc))
            carets(state, [0, alphaAt, betaAt])
            view.setQuery("();")
            try await window.runUntil { view.findCount == 2 }
            view.step(1)
            #expect(state.selections.count == 1)
            #expect(state.selections[0].range == view.decorations.findMatches[view.decorations.currentMatch ?? 0])
        }
    }
}
