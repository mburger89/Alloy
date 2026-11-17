import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

@MainActor
struct CompletionParsingTests {
    @Test func arrayAndListResults() {
        let s = snap("ab\n")
        let a = CompletionParsing.parse(json(#"[{"label":"x"},{"label":"y"}]"#), encoding: .utf16, snapshot: s)
        #expect(a?.items.map(\.label) == ["x", "y"])
        #expect(a?.isIncomplete == false)
        let l = CompletionParsing.parse(json(#"{"isIncomplete":true,"items":[{"label":"z","kind":3,"detail":"d","sortText":"1","filterText":"f","insertText":"zz","deprecated":true}]}"#), encoding: .utf16, snapshot: s)
        #expect(l?.isIncomplete == true)
        #expect(l?.items.first == CompletionItem(label: "z", detail: "d", kind: 3, sortText: "1", filterText: "f", insertText: "zz", deprecated: true))
    }

    @Test func nullAndWrongShapes() {
        let s = snap("ab\n")
        #expect(CompletionParsing.parse(.null, encoding: .utf16, snapshot: s) == CompletionList(items: []))
        #expect(CompletionParsing.parse(json(#"[]"#), encoding: .utf16, snapshot: s)?.items.isEmpty == true)
        #expect(CompletionParsing.parse(json(#"5"#), encoding: .utf16, snapshot: s) == nil)
        #expect(CompletionParsing.parse(json(#"{"x":1}"#), encoding: .utf16, snapshot: s) == nil)
        // An item without a label is skipped, the list survives.
        #expect(CompletionParsing.parse(json(#"[{"kind":1},{"label":"ok"}]"#), encoding: .utf16, snapshot: s)?.items.map(\.label) == ["ok"])
    }

    @Test func textEditAndInsertReplace() {
        let s = snap("abcdef\n")
        let r = CompletionParsing.parse(json(#"""
        [{"label":"a","textEdit":{"newText":"abc","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":2}}}},
         {"label":"b","textEdit":{"newText":"bcd","insert":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}},"replace":{"start":{"line":0,"character":1},"end":{"line":0,"character":5}}}}]
        """#), encoding: .utf16, snapshot: s)
        #expect(r?.items[0].edit == CompletionEdit(insert: 0..<2, newText: "abc"))
        #expect(r?.items[1].edit == CompletionEdit(insert: 1..<3, replace: 1..<5, newText: "bcd"))
    }

    @Test func encodingsAgreeOnEmojiLine() {
        // "a😀bc": "b" is UTF-16 column 3, UTF-8 column 5 and byte 5.
        let s = snap("a😀bc\n")
        func list(_ col: Int) -> JSONValue {
            json(#"[{"label":"b","textEdit":{"newText":"b!","range":{"start":{"line":0,"character":\#(col)},"end":{"line":0,"character":\#(col + 1)}}}}]"#)
        }
        #expect(CompletionParsing.parse(list(3), encoding: .utf16, snapshot: s)?.items[0].edit?.insert == 5..<6)
        #expect(CompletionParsing.parse(list(5), encoding: .utf8, snapshot: s)?.items[0].edit?.insert == 5..<6)
    }

    @Test func editInsideSurrogatePairDropsOnlyTheEdit() {
        let s = snap("a😀bc\n")
        let r = CompletionParsing.parse(json(#"[{"label":"q","insertText":"q","textEdit":{"newText":"x","range":{"start":{"line":0,"character":2},"end":{"line":0,"character":3}}}}]"#), encoding: .utf16, snapshot: s)
        #expect(r?.items.count == 1)
        #expect(r?.items[0].edit == nil)
        #expect(r?.items[0].insertText == "q")
    }

    @Test func additionalEditsAndSnippetFlag() {
        let s = snap("ab\ncd\n")
        let r = CompletionParsing.parse(json(#"[{"label":"i","insertTextFormat":2,"additionalTextEdits":[{"newText":"import x\n","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]}]"#), encoding: .utf16, snapshot: s)
        #expect(r?.items[0].isSnippet == true)
        #expect(r?.items[0].additionalEdits == [ByteEdit(range: 0..<0, text: "import x\n")])
    }

    @Test func hugeListsAreCut() {
        let s = snap("a\n")
        let items = (0..<6_000).map { #"{"label":"i\#($0)"}"# }.joined(separator: ",")
        let r = CompletionParsing.parse(json("[\(items)]"), encoding: .utf16, snapshot: s)
        #expect(r?.items.count == 5_000)
        #expect(r?.isIncomplete == true)
    }

    @Test func documentationShapes() {
        let s = snap("a\n")
        let r = CompletionParsing.parse(json(#"[{"label":"a","documentation":"plain"},{"label":"b","documentation":{"kind":"markdown","value":"**m**"}},{"label":"c","documentation":""}]"#), encoding: .utf16, snapshot: s)
        #expect(r?.items.map(\.documentation) == ["plain", "**m**", nil])
    }

    @Test func itemDefaultsApply() {
        let s = snap("abcdef\n")
        let r = CompletionParsing.parse(json(#"""
        {"isIncomplete":false,"itemDefaults":{"commitCharacters":[";"],"insertTextFormat":2,"editRange":{"start":{"line":0,"character":1},"end":{"line":0,"character":3}}},
         "items":[{"label":"p"},{"label":"q","commitCharacters":["."],"textEdit":{"newText":"own","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}}]}
        """#), encoding: .utf16, snapshot: s)
        #expect(r?.items[0].commitCharacters == [";"])
        #expect(r?.items[0].edit == CompletionEdit(insert: 1..<3, newText: "p"))
        #expect(r?.items[0].isSnippet == true)
        #expect(r?.items[1].commitCharacters == ["."])
        #expect(r?.items[1].edit == CompletionEdit(insert: 0..<1, newText: "own"))
    }

    @Test func crlfLineAddressing() {
        let s = snap("ab\r\ncd\r\n")
        let r = CompletionParsing.parse(json(#"[{"label":"c","textEdit":{"newText":"cc","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}}}}]"#), encoding: .utf16, snapshot: s)
        #expect(r?.items[0].edit?.insert == 4..<6)
    }
}

@Suite
@MainActor
struct CompletionRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func script(_ replies: String, caps: String = #""completionProvider":{"resolveProvider":true}"#,
                        resolve: String = #"[{"result":{"label":"a"}}]"#) -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(caps)},"replies":{"textDocument/completion":\#(replies),"completionItem/resolve":\#(resolve)}}"#
    }

    private func requests(_ rig: Rig, _ method: String) -> [JSONValue] {
        guard let text = try? String(contentsOf: rig.dir.appendingPathComponent("main.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }.filter { $0["method"]?.stringValue == method }
    }

    @Test func completionAnswersThroughTheKernel() async throws {
        let replies = #"[{"result":[{"label":"a"}]},{"result":[{"label":"b"}]},{"result":{"isIncomplete":true,"items":[]}}]"#
        try await Rig.run([main], scripts: ["main": script(replies)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .invoked)
                == .answered(CompletionList(items: [CompletionItem(label: "a")])))
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .character("."))
                == .answered(CompletionList(items: [CompletionItem(label: "b")])))
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .incomplete)
                == .answered(CompletionList(items: [], isIncomplete: true)))
            let contexts = requests(rig, "textDocument/completion").map { $0["params"]?["context"] }
            #expect(contexts.map { $0?["triggerKind"]?.intValue } == [1, 2, 3])
            #expect(contexts[1]?["triggerCharacter"]?.stringValue == ".")
            #expect(requests(rig, "textDocument/completion")[0]["params"]?["position"]?["character"]?.intValue == 1)
        }
    }

    @Test func nullReplyIsAnAnsweredEmptyList() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .invoked)
                == .answered(CompletionList(items: [])))
        }
    }

    @Test func contentModifiedIsStale() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32801,"message":"m"}}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .invoked) == .stale)
        }
    }

    @Test func serverErrorFails() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32603,"message":"boom"}}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .invoked) == .failed("boom"))
        }
    }

    @Test func withoutCapabilityIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":[]}]"#, caps: #""hoverProvider":true"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.completion(path: "a.x", utf8Offset: 1, snapshot: snapshot, trigger: .invoked) == .unavailable)
            #expect(!rig.methods("main").contains("textDocument/completion"))
        }
    }

    @Test func resolveRoundTripReturnsDocsAndAdditionalEdits() async throws {
        let resolve = #"[{"result":{"label":"a","detail":"fn a()","documentation":{"kind":"markdown","value":"docs"},"additionalTextEdits":[{"newText":"use a;\n","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]}}]"#
        try await Rig.run([main], scripts: ["main": script(#"[{"result":[]}]"#, resolve: resolve)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let item = CompletionItem(label: "a", insertText: "a()", edit: CompletionEdit(insert: 0..<1, newText: "a"),
                                      resolveData: .object(["id": .number(7)]))
            let out = await rig.manager.resolveCompletion(path: "a.x", item: item, snapshot: snapshot)
            guard case .answered(let resolved) = out else { Issue.record("not answered: \(out)"); return }
            #expect(resolved.documentation == "docs")
            #expect(resolved.detail == "fn a()")
            #expect(resolved.additionalEdits == [ByteEdit(range: 0..<0, text: "use a;\n")])
            // Fields the answer lacks stay.
            #expect(resolved.insertText == "a()")
            #expect(resolved.edit == item.edit)
            let sent = requests(rig, "completionItem/resolve").first?["params"]
            #expect(sent?["label"]?.stringValue == "a")
            #expect(sent?["data"]?["id"]?.intValue == 7)
            #expect(sent?["textEdit"]?["newText"]?.stringValue == "a")
        }
    }
}
