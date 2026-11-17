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
private let caps = #""codeActionProvider":{"resolveProvider":true},"executeCommandProvider":{"commands":["do.it"]}"#

@MainActor
@Suite
struct CodeActionServiceTests {
    private func uri(_ r: Rig, _ name: String) -> String { r.root.appendingPathComponent(name).absoluteString }

    private func edit(_ r: Rig, _ name: String = "main.rs", _ from: Int = 0, _ to: Int = 3, _ text: String = "LET") -> String {
        #"{"changes":{"\#(uri(r, name))":[{"range":{"start":{"line":0,"character":\#(from)},"end":{"line":0,"character":\#(to)}},"newText":"\#(text)"}]}}"#
    }

    private func script(_ actions: String, resolve: String? = nil, extra: String = "") -> String {
        var replies = #""textDocument/codeAction":[{"result":\#(actions)}]"#
        if let resolve { replies += #","codeAction/resolve":[{"result":\#(resolve)}]"# }
        return IntelRig.script(caps: caps, extra: #","replies":{\#(replies),"workspace/executeCommand":[{"result":null}]}\#(extra)"#)
    }

    private func text(_ doc: EditorDocument) -> String {
        let snapshot = doc.buffer.snapshot()
        return String(decoding: snapshot.utf8(in: 0..<snapshot.utf8Count), as: UTF8.self)
    }

    private struct Fixture {
        let r: IntelRig
        let window: TestWindow
        let doc: EditorDocument
        let view: OpenDocumentView
        let service: CodeActionService
    }

    private func fixture(_ r: IntelRig) async throws -> Fixture {
        try r.write("main.rs", source)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        let service = try #require(CodePanelStore.existingCodeActionService(for: doc))
        try await window.runUntil { view.features.codeAction }
        return Fixture(r: r, window: window, doc: doc, view: view, service: service)
    }

    private func run(_ makeScript: (Rig) -> String, _ body: (Fixture) async throws -> Void) async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: makeScript(rig)) { r in try await body(try await fixture(r)) }
    }

    private func actions(_ f: Fixture) async -> [CodeActionItem] {
        await f.service.actions(for: f.view, range: 0..<3, automatic: false)
    }

    private func answers(_ r: IntelRig, id: Int) -> [JSONValue] {
        guard let data = try? String(contentsOf: r.log, encoding: .utf8) else { return [] }
        return data.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
            .filter { $0["id"]?.intValue == id && $0["method"] == nil }
    }

    @Test func inlineEditAppliesAsOneUndoStepAndOneLedgerGroup() async throws {
        try await run({ rig in script(#"[{"title":"Upper","kind":"quickfix","edit":\#(edit(rig))}]"#) }) { f in
            let items = await actions(f)
            #expect(items.map(\.title) == ["Upper"])
            let result = await f.service.choose(items[0], in: f.view)
            #expect(result == .applied)
            #expect(text(f.doc) == "LET x = 1\n")
            let state = try #require(f.r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            let record = try #require(f.r.rig.workspace.ledger.files["main.rs"]?.edits.last)
            #expect(record.group != nil)
            #expect(state.undo())
            #expect(text(f.doc) == source)
            #expect(!state.undo() || text(f.doc) == source)
        }
    }

    @Test func theGroupIsRevertable() async throws {
        try await run({ rig in script(#"[{"title":"Upper","edit":\#(edit(rig))}]"#) }) { f in
            let items = await actions(f)
            _ = await f.service.choose(items[0], in: f.view)
            let group = try #require(f.r.rig.workspace.ledger.files["main.rs"]?.edits.last?.group)
            #expect(f.r.rig.workspace.hasEdit(group: group, path: "main.rs"))
            let results = await f.r.rig.workspace.revertAll(group: group)
            #expect(results.map(\.path) == ["main.rs"])
            if case .conflict(let reason)? = results.first?.outcome { Issue.record("conflict: \(reason)") }
            let disk = try String(contentsOf: f.r.rig.root.appendingPathComponent("main.rs"), encoding: .utf8)
            #expect(disk == source)
        }
    }

    @Test func dataOnlyActionIsResolvedThenApplied() async throws {
        try await run({ rig in
            script(#"[{"title":"Later","data":{"k":1}}]"#,
                   resolve: #"{"title":"Later","data":{"k":1},"edit":\#(edit(rig))}"#)
        }) { f in
            let items = await actions(f)
            #expect(items[0].edit == nil)
            #expect(await f.service.choose(items[0], in: f.view) == .applied)
            #expect(text(f.doc) == "LET x = 1\n")
            #expect(f.r.methods().contains("codeAction/resolve"))
        }
    }

    @Test func commandOnlyRunsThenTheServersApplyEditIsAppliedAndAnswered() async throws {
        try await run({ rig in
            let after = #","afterRequest":{"workspace/executeCommand":[{"method":"workspace/applyEdit","id":900,"params":{"label":"Do","edit":\#(edit(rig))}}]}"#
            return script(#"[{"title":"Run","command":{"title":"Run","command":"do.it","arguments":[1]}}]"#, extra: after)
        }) { f in
            let items = await actions(f)
            #expect(await f.service.choose(items[0], in: f.view) == .applied)
            try await f.window.runUntil { text(f.doc) == "LET x = 1\n" }
            try await f.window.runUntil { answers(f.r, id: 900).count == 1 }
            #expect(answers(f.r, id: 900).first?["result"]?["applied"]?.boolValue == true)
            #expect(f.r.methods().contains("workspace/executeCommand"))
        }
    }

    @Test func editThenCommandAppliesTheEditFirst() async throws {
        try await run({ rig in
            script(#"[{"title":"Both","edit":\#(edit(rig)),"command":{"title":"Both","command":"do.it"}}]"#)
        }) { f in
            let items = await actions(f)
            #expect(await f.service.choose(items[0], in: f.view) == .applied)
            #expect(text(f.doc) == "LET x = 1\n")
            let methods = f.r.methods()
            let exec = try #require(methods.firstIndex(of: "workspace/executeCommand"))
            let change = try #require(methods.lastIndex(of: "textDocument/didChange"))
            #expect(change < exec)
        }
    }

    @Test func aBufferEditedBetweenRequestAndChooseAppliesNothing() async throws {
        try await run({ rig in script(#"[{"title":"Upper","edit":\#(edit(rig))}]"#) }) { f in
            let items = await actions(f)
            _ = f.doc.buffer.replace(9..<9, with: " //")
            let result = await f.service.choose(items[0], in: f.view)
            #expect(result == .failed("File changed, quick fix not applied"))
            #expect(text(f.doc) == "let x = 1 //\n")
            #expect(f.view.definitionMessage == "File changed, quick fix not applied")
        }
    }

    @Test func anEditForAClosedFileIsWrittenWithoutOpeningATab() async throws {
        try await run({ rig in script(#"[{"title":"Other","edit":\#(edit(rig, "other.rs", 0, 3, "LET"))}]"#) }) { f in
            try f.r.write("other.rs", source)
            let tabs = f.r.rig.workspace.tabs(in: f.r.rig.workspace.defaultPane)
            let items = await actions(f)
            #expect(await f.service.choose(items[0], in: f.view) == .applied)
            let disk = try String(contentsOf: f.r.rig.root.appendingPathComponent("other.rs"), encoding: .utf8)
            #expect(disk == "LET x = 1\n")
            #expect(f.r.rig.workspace.document("other.rs") == nil)
            #expect(f.r.rig.workspace.tabs(in: f.r.rig.workspace.defaultPane) == tabs)
            #expect(text(f.doc) == source)
        }
    }

    @Test func rejectedEditsApplyNothing() async throws {
        let outside = #"{"changes":{"file:///elsewhere/x.rs":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"x"}]}}"#
        let resource = #"{"documentChanges":[{"kind":"delete","uri":"file:///x"}]}"#
        try await run({ rig in
            let overlap = #"{"changes":{"\#(uri(rig, "main.rs"))":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"a"},{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"newText":"b"}]}}"#
            return script(#"[{"title":"O","edit":\#(outside)},{"title":"R","edit":\#(resource)},{"title":"V","edit":\#(overlap)}]"#)
        }) { f in
            let items = await actions(f)
            #expect(items.count == 3)
            for item in items {
                guard case .failed(let message) = await f.service.choose(item, in: f.view) else { Issue.record("applied \(item.title)"); continue }
                #expect(message.hasPrefix("The language server"))
                #expect(text(f.doc) == source)
            }
        }
    }

    @Test func aDisabledActionCannotBeChosen() async throws {
        try await run({ rig in script(#"[{"title":"No","disabled":{"reason":"not here"},"edit":\#(edit(rig))}]"#) }) { f in
            let items = await actions(f)
            #expect(await f.service.choose(items[0], in: f.view) == .failed("No: not here"))
            #expect(text(f.doc) == source)
        }
    }

    @Test func serverEditWithNoViewIsAnsweredNotApplied() async throws {
        try await run({ rig in
            let after = #","afterRequest":{"workspace/executeCommand":[{"method":"workspace/applyEdit","id":900,"params":{"edit":\#(edit(rig))}}]}"#
            return script(#"[{"title":"Run","command":{"title":"Run","command":"do.it"}}]"#, extra: after)
        }) { f in
            let items = await actions(f)
            f.service.viewFor = { _ in nil }
            _ = await f.service.choose(items[0], in: f.view)
            try await f.window.runUntil { answers(f.r, id: 900).count == 1 }
            #expect(answers(f.r, id: 900).first?["result"]?["applied"]?.boolValue == false)
            #expect(text(f.doc) == source)
        }
    }

    @Test func aFailedResolveSurfacesAMessageAndChangesNothing() async throws {
        try await run({ _ in
            IntelRig.script(caps: caps, extra: #","replies":{"textDocument/codeAction":[{"result":[{"title":"Later","data":{"k":1}}]}],"codeAction/resolve":[{"error":{"code":-32603,"message":"boom"}}]}"#)
        }) { f in
            let items = await actions(f)
            let result = await f.service.choose(items[0], in: f.view)
            #expect(result == .failed("Later could not be resolved"))
            #expect(f.view.definitionMessage == "Later could not be resolved")
            #expect(text(f.doc) == source)
        }
    }

    @Test func anActionWithNeitherEditNorCommandFails() async throws {
        try await run({ _ in script(#"[{"title":"Empty","kind":"quickfix"}]"#) }) { f in
            let items = await actions(f)
            #expect(await f.service.choose(items[0], in: f.view) == .failed("Empty has no effect"))
            #expect(text(f.doc) == source)
        }
    }

    @Test func anOlderListIsCheckedAgainstItsOwnVersion() async throws {
        try await run({ rig in script(#"[{"title":"Upper","edit":\#(edit(rig))}]"#) }) { f in
            let old = await actions(f)
            _ = f.doc.buffer.replace(9..<9, with: " //")
            _ = await actions(f)
            #expect(await f.service.choose(old[0], in: f.view) == .failed("File changed, quick fix not applied"))
            #expect(text(f.doc) == "let x = 1 //\n")
        }
    }

    @Test func noActionsWithoutAnEligibleView() async throws {
        try await run({ _ in script("[]") }) { f in
            #expect(await actions(f).isEmpty)
        }
    }
}
