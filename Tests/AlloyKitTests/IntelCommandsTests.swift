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

private let allCaps = #""hoverProvider":true,"documentSymbolProvider":true,"referencesProvider":true,"documentFormattingProvider":true,"documentRangeFormattingProvider":true"#

private func fullScript(caps: String = allCaps, uri: String = "file:///x/main.rs") -> String {
    let edit = #"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}},"newText":"FN"}"#
    return IntelRig.script(caps: caps, extra: #","replies":{"textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}],"textDocument/documentSymbol":[{"result":[{"name":"alpha","kind":12,"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":9}},"selectionRange":{"start":{"line":0,"character":3},"end":{"line":0,"character":7}}}]}],"textDocument/references":[{"result":[{"uri":"\#(uri)","range":{"start":{"line":0,"character":3},"end":{"line":0,"character":7}}}]}],"textDocument/formatting":[{"result":[\#(edit)]}],"textDocument/rangeFormatting":[{"result":[\#(edit)]}]}"#)
}

private let ids = ["menu-go-symbol", "menu-find-references", "menu-format", "menu-format-selection", "menu-show-hover"]

@MainActor
@Suite
struct IntelCommandsTests {
    private func menu(_ window: TestWindow, _ id: String) throws { try window.testApp.performMenuBarItem(accessibilityIdentifier: id) }

    private func isDisabled(_ window: TestWindow, _ id: String) -> Bool {
        do { try menu(window, id); return false } catch { return true }
    }

    private func text(_ doc: EditorDocument) -> String {
        let snapshot = doc.buffer.snapshot()
        return String(decoding: snapshot.utf8(in: 0..<snapshot.utf8Count), as: UTF8.self)
    }

    private func selectWord(_ r: IntelRig, _ path: String = "main.rs") throws {
        let state = try #require(r.rig.workspace.selectionState(for: path, in: .chat))
        state.select(alphaAt..<(alphaAt + 5), reveal: false)
    }

    @Test func formatItemsFormat() async throws {
        try await IntelRig.run(script: fullScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            try menu(window, "menu-format")
            try await window.runUntil { text(doc).hasPrefix("FN") }
            #expect(r.methods().contains("textDocument/formatting"))
        }
    }

    @Test func formatSelectionNeedsASelection() async throws {
        try await IntelRig.run(script: fullScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            state.select(0..<0, reveal: false)
            #expect(isDisabled(window, "menu-format-selection"))
            #expect(!r.methods().contains("textDocument/rangeFormatting"))
            state.select(0..<5, reveal: false)
            try menu(window, "menu-format-selection")
            try await window.runUntil { text(doc).hasPrefix("FN") }
            #expect(r.methods().contains("textDocument/rangeFormatting"))
        }
    }

    @Test func showHoverOpensThePopover() async throws {
        try await IntelRig.run(script: fullScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            state.select(alphaAt..<alphaAt, reveal: false)
            try menu(window, "menu-show-hover")
            try await window.runUntil { r.exists(window, "hover-popover") }
        }
    }

    @Test func goToSymbolAndFindReferencesOpenTheirPalettes() async throws {
        let rig = Rig()
        let script = fullScript(uri: rig.root.appendingPathComponent("main.rs").absoluteString)
        try await IntelRig.run(rig: rig, script: script) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            try menu(window, "menu-go-symbol")
            try await window.runUntil { r.exists(window, "symbols-palette") }
            window.typeKey(.escape)
            try await window.runUntil { !r.exists(window, "symbols-palette") }
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            state.select(alphaAt..<alphaAt, reveal: false)
            try menu(window, "menu-find-references")
            try await window.runUntil { r.methods().contains("textDocument/references") }
            try await window.runUntil { r.exists(window, "references-palette") }
        }
    }

    @Test func aServerWithoutTheCapabilitiesDisablesTheItems() async throws {
        try await IntelRig.run(script: IntelRig.script(caps: #""textDocumentSync":2"#)) { r in
            try r.write("main.rs", source)
            let window = try await r.open2("main.rs")
            try selectWord(r)
            for id in ids where id != "menu-go-symbol" { #expect(isDisabled(window, id), "\(id) disabled") }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(r.methods().filter { $0.hasPrefix("textDocument/") && $0 != "textDocument/didOpen" && $0 != "textDocument/didChange" }.isEmpty)
        }
    }

    @Test func aDocumentWithoutAServerDisablesTheServerItems() async throws {
        try await IntelRig.run(script: fullScript()) { r in
            try r.write("notes.txt", "plain words here\n")
            let window = try await r.open2("notes.txt")
            let state = try #require(r.rig.workspace.selectionState(for: "notes.txt", in: .chat))
            state.select(0..<5, reveal: false)
            for id in ["menu-find-references", "menu-format", "menu-format-selection", "menu-show-hover"] {
                #expect(isDisabled(window, id), "\(id) disabled")
            }
            #expect(r.methods().isEmpty)
        }
    }

    @Test func aReadOnlyDocumentDisablesTheItems() async throws {
        try await IntelRig.run(script: fullScript()) { r in
            try r.write("main.rs", source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            try selectWord(r)
            doc.state = .readOnly(reason: "test")
            for _ in 0..<3 { window.tick(); await Task.yield() }
            for id in ["menu-format", "menu-format-selection", "menu-show-hover", "menu-find-references"] {
                #expect(isDisabled(window, id), "\(id) disabled")
            }
            #expect(!r.methods().contains("textDocument/formatting"))
            #expect(!r.methods().contains("textDocument/hover"))
        }
    }

    @Test func noMenuItemsRunWithoutAnEditor() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        for id in ids { #expect(isDisabled(window, id), "\(id) disabled") }
    }

    @Test func theGoMenuIsOneMenuWithTheDefinitionItem() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let goMenus = window.testApp.menuBar.filter { $0.title == "Go" }
        #expect(goMenus.count == 1)
    }

    @Test func codeModeItemsAct() async throws {
        let (intel, window, _) = try await IntelRig.guardRig(layout: .code1, script: fullScript())
        let doc = try #require(intel.rig.workspace.document("login.swift"))
        try await window.runUntil { intel.rig.workspace.intelHooks.isEnabled(.formatDocument) }
        try menu(window, "menu-format")
        try await window.runUntil { text(doc).hasPrefix("FN") }
    }
}
