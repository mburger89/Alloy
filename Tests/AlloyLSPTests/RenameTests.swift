import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

@MainActor
struct RenameParsingTests {
    @Test func bareRange() {
        let snapshot = snap("abc def\n")
        let value = json(#"{"start":{"line":0,"character":4},"end":{"line":0,"character":7}}"#)
        #expect(RenameParsing.prepare(value, encoding: .utf16, snapshot: snapshot) == PrepareRenameInfo(range: 4..<7, placeholder: nil))
    }

    @Test func rangeWithPlaceholder() {
        let snapshot = snap("abc def\n")
        let value = json(#"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"placeholder":"abc"}"#)
        #expect(RenameParsing.prepare(value, encoding: .utf16, snapshot: snapshot) == PrepareRenameInfo(range: 0..<3, placeholder: "abc"))
    }

    @Test func defaultBehaviourHasNoRange() {
        let snapshot = snap("abc\n")
        #expect(RenameParsing.prepare(json(#"{"defaultBehavior":true}"#), encoding: .utf16, snapshot: snapshot)
                == PrepareRenameInfo(range: nil, placeholder: nil))
    }

    @Test func nullAndJunkAreNil() {
        let snapshot = snap("abc\n")
        #expect(RenameParsing.prepare(.null, encoding: .utf16, snapshot: snapshot) == nil)
        #expect(RenameParsing.prepare(json(#"{"defaultBehavior":false}"#), encoding: .utf16, snapshot: snapshot) == nil)
        #expect(RenameParsing.prepare(json(#"[]"#), encoding: .utf16, snapshot: snapshot) == nil)
    }

    @Test func encodingAndSurrogatePairs() {
        // "a😀b": the emoji is 2 UTF-16 units and 4 bytes; "b" is UTF-16 column 3, byte 5.
        let snapshot = snap("a😀b\n")
        let b = json(#"{"start":{"line":0,"character":3},"end":{"line":0,"character":4}}"#)
        #expect(RenameParsing.prepare(b, encoding: .utf16, snapshot: snapshot)?.range == 5..<6)
        let utf8 = json(#"{"start":{"line":0,"character":5},"end":{"line":0,"character":6}}"#)
        #expect(RenameParsing.prepare(utf8, encoding: .utf8, snapshot: snapshot)?.range == 5..<6)
        // A range that splits the pair does not convert: nil range, but the answer itself stands.
        let split = json(#"{"start":{"line":0,"character":2},"end":{"line":0,"character":3}}"#)
        #expect(RenameParsing.prepare(split, encoding: .utf16, snapshot: snapshot) == PrepareRenameInfo(range: nil, placeholder: nil))
    }
}

@Suite
@MainActor
struct RenameRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func script(_ replies: String, prepare: String = #""renameProvider":{"prepareProvider":true}"#,
                        method: String = "textDocument/rename") -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(prepare)},"replies":{"\#(method)":\#(replies)}}"#
    }

    private func requests(_ rig: Rig, _ method: String) -> [JSONValue] {
        guard let text = try? String(contentsOf: rig.dir.appendingPathComponent("main.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }.filter { $0["method"]?.stringValue == method }
    }

    private func open(_ rig: Rig, _ text: String = "abc def\n") async -> CodeSnapshot {
        let snapshot = snap(text)
        await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
        return snapshot
    }

    @Test func prepareReturnsRangeAndPlaceholder() async throws {
        let reply = #"[{"result":{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":7}},"placeholder":"def"}}]"#
        try await Rig.run([main], scripts: ["main": script(reply, method: "textDocument/prepareRename")]) { rig in
            let snapshot = await open(rig)
            let out = await rig.manager.prepareRename(path: "a.x", utf8Offset: 5, snapshot: snapshot)
            #expect(out == .answered(PrepareRenameInfo(range: 4..<7, placeholder: "def")))
            #expect(requests(rig, "textDocument/prepareRename").first?["params"]?["position"]?["character"]?.intValue == 5)
        }
    }

    @Test func prepareNullIsAnsweredNothing() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#, method: "textDocument/prepareRename")]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.prepareRename(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .answered(nil))
        }
    }

    @Test func prepareNeedsPrepareProvider() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#, prepare: #""renameProvider":true"#,
                                                           method: "textDocument/prepareRename")]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.prepareRename(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .unavailable)
            #expect(requests(rig, "textDocument/prepareRename").isEmpty)
        }
    }

    @Test func prepareErrorIsFailedWithTheServersMessage() async throws {
        let reply = #"[{"error":{"code":-32600,"message":"cannot rename a keyword"}}]"#
        try await Rig.run([main], scripts: ["main": script(reply, method: "textDocument/prepareRename")]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.prepareRename(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .failed("cannot rename a keyword"))
        }
    }

    @Test func documentChangesReachTheCallerUntouched() async throws {
        let reply = #"[{"result":{"documentChanges":[{"textDocument":{"uri":"file:///p/a.x","version":3},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"z"}]},{"textDocument":{"uri":"file:///p/b.x","version":null},"edits":[]}]}}]"#
        try await Rig.run([main], scripts: ["main": script(reply)]) { rig in
            let snapshot = await open(rig)
            guard case .answered(let answer?) = await rig.manager.rename(path: "a.x", utf8Offset: 1, newName: "z", snapshot: snapshot) else {
                Issue.record("expected an answer"); return
            }
            let changes = answer.edit["documentChanges"]?.arrayValue
            #expect(changes?.count == 2)
            #expect(changes?[0]["textDocument"]?["version"]?.intValue == 3)
            #expect(changes?[1]["textDocument"]?["version"] == .null)
            #expect(answer.encoding == .utf16)
        }
    }

    @Test func changesMapReachesTheCaller() async throws {
        let reply = #"[{"result":{"changes":{"file:///p/a.x":[]}}}]"#
        try await Rig.run([main], scripts: ["main": script(reply)]) { rig in
            let snapshot = await open(rig)
            guard case .answered(let answer?) = await rig.manager.rename(path: "a.x", utf8Offset: 1, newName: "z", snapshot: snapshot) else {
                Issue.record("expected an answer"); return
            }
            #expect(answer.edit["changes"]?.objectValue?.keys.sorted() == ["file:///p/a.x"])
        }
    }

    @Test func paramsCarryPositionAndNewName() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#)]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.rename(path: "a.x", utf8Offset: 5, newName: "fresh", snapshot: snapshot) == .answered(nil))
            let params = requests(rig, "textDocument/rename").first?["params"]
            #expect(params?["newName"]?.stringValue == "fresh")
            #expect(params?["position"]?["line"]?.intValue == 0)
            #expect(params?["position"]?["character"]?.intValue == 5)
            #expect(params?["textDocument"]?["uri"]?.stringValue?.hasSuffix("a.x") == true)
        }
    }

    @Test func errorReplyIsFailed() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32600,"message":"invalid name"}}]"#)]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.rename(path: "a.x", utf8Offset: 1, newName: "1x", snapshot: snapshot) == .failed("invalid name"))
        }
    }

    @Test func contentModifiedIsStale() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32801,"message":"m"}}]"#)]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.rename(path: "a.x", utf8Offset: 1, newName: "z", snapshot: snapshot) == .stale)
        }
    }

    @Test func noRenameProviderIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":{}}]"#, prepare: #""hoverProvider":true"#)]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.rename(path: "a.x", utf8Offset: 1, newName: "z", snapshot: snapshot) == .unavailable)
            #expect(requests(rig, "textDocument/rename").isEmpty)
        }
    }

    @Test func aRenameReplyNormalizesLikeAnyWorkspaceEdit() async throws {
        let range = #"{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}"#
        let reply = #"[{"result":{"documentChanges":[{"textDocument":{"uri":"file:///p/a.x","version":null},"edits":[{"range":\#(range),"newText":"X"},{"range":\#(range),"newText":"Y"}]}]}}]"#
        try await Rig.run([main], scripts: ["main": script(reply)]) { rig in
            let snapshot = await open(rig)
            guard case .answered(let answer?) = await rig.manager.rename(path: "a.x", utf8Offset: 0, newName: "z", snapshot: snapshot) else {
                Issue.record("expected an answer"); return
            }
            let root = URL(fileURLWithPath: "/p")
            // Overlapping edits are refused.
            #expect(throws: EditRejection.self) {
                try WorkspaceEditParsing.normalize(answer.edit, root: root, encoding: answer.encoding, snapshot: { _ in snapshot })
            }
        }
    }
}

@MainActor
struct RenameEditNormalizeTests {
    private let root = URL(fileURLWithPath: "/p")
    private func edit(_ sc: Int, _ ec: Int, _ line: Int = 0, _ eline: Int? = nil, _ text: String = "X") -> JSONValue {
        json(#"{"range":{"start":{"line":\#(line),"character":\#(sc)},"end":{"line":\#(eline ?? line),"character":\#(ec)}},"newText":"\#(text)"}"#)
    }
    private func doc(_ edits: [JSONValue]) -> JSONValue {
        .object(["documentChanges": .array([.object(["textDocument": .object(["uri": .string("file:///p/a.x"), "version": .null]),
                                                      "edits": .array(edits)])])])
    }

    @Test func overlapIsRefused() {
        let s = snap("abcdef\n")
        #expect(throws: EditRejection.self) {
            try WorkspaceEditParsing.normalize(doc([edit(0, 3), edit(2, 4)]), root: root, encoding: .utf16, snapshot: { _ in s })
        }
    }

    @Test func surrogatePairRangeIsRefused() {
        let s = snap("a😀b\n")
        #expect(throws: EditRejection.self) {
            try WorkspaceEditParsing.normalize(doc([edit(2, 3)]), root: root, encoding: .utf16, snapshot: { _ in s })
        }
    }

    @Test func rangePastEndClamps() throws {
        let s = snap("ab\ncd")
        let out = try WorkspaceEditParsing.normalize(doc([edit(99, 99, 9, 9)]), root: root, encoding: .utf16, snapshot: { _ in s })
        #expect(out.first?.edits == [ByteEdit(range: 5..<5, text: "X")])
    }

    @Test func resourceOperationIsRefused() {
        let s = snap("a\n")
        let op: JSONValue = .object(["documentChanges": .array([.object(["kind": .string("delete"), "uri": .string("file:///p/a.x")])])])
        #expect(throws: EditRejection.resourceOperation) {
            try WorkspaceEditParsing.normalize(op, root: root, encoding: .utf16, snapshot: { _ in s })
        }
    }
}
