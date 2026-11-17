import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

@MainActor
struct HoverParsingTests {
    @Test func markupContentWithRangeAfterAnEmoji() {
        // "a😀b": the emoji is 2 UTF-16 units and 4 bytes; "b" is UTF-16 column 3, byte 5.
        let snapshot = snap("a😀b\n")
        let result = json(#"{"contents":{"kind":"markdown","value":"**b**"},"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":4}}}"#)
        let info = HoverParsing.parse(result, encoding: .utf16, snapshot: snapshot)
        #expect(info == HoverInfo(markdown: "**b**", range: 5..<6))
        #expect(HoverParsing.parse(result, encoding: .utf8, snapshot: snapshot)?.range == 3..<4)
    }

    @Test func markedStringsBecomeBlocks() {
        let snapshot = snap("x\n")
        let result = json(#"{"contents":["plain",{"language":"rust","value":"fn x()"}]}"#)
        #expect(HoverParsing.parse(result, encoding: .utf16, snapshot: snapshot)?.markdown == "plain\n\n```rust\nfn x()\n```")
        #expect(HoverParsing.parse(json(#"{"contents":"just text"}"#), encoding: .utf16, snapshot: snapshot)?.markdown == "just text")
        #expect(HoverParsing.parse(json(#"{"contents":{"language":"c","value":"int x"}}"#), encoding: .utf16, snapshot: snapshot)?.markdown == "```c\nint x\n```")
    }

    @Test func emptyAnswersAreNil() {
        let snapshot = snap("x\n")
        #expect(HoverParsing.parse(.null, encoding: .utf16, snapshot: snapshot) == nil)
        #expect(HoverParsing.parse(json(#"{"contents":""}"#), encoding: .utf16, snapshot: snapshot) == nil)
        #expect(HoverParsing.parse(json(#"{"contents":"  \n "}"#), encoding: .utf16, snapshot: snapshot) == nil)
        #expect(HoverParsing.parse(json(#"{"contents":{"kind":"markdown","value":"\n"}}"#), encoding: .utf16, snapshot: snapshot) == nil)
        #expect(HoverParsing.parse(json(#"{"contents":[]}"#), encoding: .utf16, snapshot: snapshot) == nil)
        #expect(HoverParsing.parse(json(#"{}"#), encoding: .utf16, snapshot: snapshot) == nil)
    }
}

@Suite
@MainActor
struct HoverRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func script(_ replies: String, caps: String = #""hoverProvider":true"#) -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(caps)},"replies":{"textDocument/hover":\#(replies)}}"#
    }

    @Test func answeredText() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":{"contents":"hi"}}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.hover(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .answered(HoverInfo(markdown: "hi")))
        }
    }

    @Test func nullIsAnsweredNothing() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.hover(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .answered(nil))
        }
    }

    @Test func contentModifiedIsStale() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32801,"message":"m"}}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.hover(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .stale)
        }
    }

    @Test func capabilityAbsentIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":{"contents":"x"}}]"#, caps: #""definitionProvider":true"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.hover(path: "a.x", utf8Offset: 1, snapshot: snapshot) == .unavailable)
            #expect(!rig.methods("main").contains("textDocument/hover"))
        }
    }
}
