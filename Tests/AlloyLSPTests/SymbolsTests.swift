import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

@MainActor
struct SymbolParsingTests {
    private func range(_ line: Int, _ from: Int, _ to: Int) -> String {
        #"{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}}"#
    }

    @Test func hierarchicalFlattensPreOrderWithDepth() {
        let snapshot = snap("class A {\n  func m() {\n    let x = 1\n  }\n}\nfunc z() {}\n")
        let r = { (l: Int) in range(l, 0, 1) }
        let text = #"[{"name":"A","kind":5,"range":\#(r(0)),"selectionRange":\#(r(0)),"children":[{"name":"m","kind":6,"detail":"()","range":\#(r(1)),"selectionRange":\#(range(1, 7, 8)),"children":[{"name":"x","kind":13,"range":\#(r(2)),"selectionRange":\#(r(2))}]}]},{"name":"z","kind":12,"range":\#(r(5)),"selectionRange":\#(r(5))}]"#
        let symbols = SymbolParsing.parse(json(text), encoding: .utf16, snapshot: snapshot)
        #expect(symbols.map(\.name) == ["A", "m", "x", "z"])
        #expect(symbols.map(\.depth) == [0, 1, 2, 0])
        #expect(symbols[1].detail == "()")
        #expect(symbols[1].range == 17..<18)
    }

    @Test func utf16ServerAfterAnEmoji() {
        // "a😀b": "b" is UTF-16 column 3 and byte 5.
        let snapshot = snap("a😀b\n")
        let text = #"[{"name":"b","kind":13,"range":\#(range(0, 0, 4)),"selectionRange":\#(range(0, 3, 4))}]"#
        #expect(SymbolParsing.parse(json(text), encoding: .utf16, snapshot: snapshot).first?.range == 5..<6)
        #expect(SymbolParsing.parse(json(text), encoding: .utf8, snapshot: snapshot).first?.range == 3..<4)
    }

    @Test func flatSymbolInformation() {
        let snapshot = snap("one\ntwo\n")
        let text = #"[{"name":"two","kind":12,"containerName":"Mod","location":{"uri":"file:///x.rs","range":\#(range(1, 0, 3))}},{"name":"one","kind":12,"location":{"uri":"file:///x.rs","range":\#(range(0, 0, 3))}}]"#
        let symbols = SymbolParsing.parse(json(text), encoding: .utf16, snapshot: snapshot)
        #expect(symbols == [DocSymbol(name: "two", detail: "Mod", kind: 12, depth: 0, range: 4..<7),
                            DocSymbol(name: "one", detail: nil, kind: 12, depth: 0, range: 0..<3)])
    }

    @Test func emptyAnswers() {
        let snapshot = snap("x\n")
        #expect(SymbolParsing.parse(.null, encoding: .utf16, snapshot: snapshot).isEmpty)
        #expect(SymbolParsing.parse(json("[]"), encoding: .utf16, snapshot: snapshot).isEmpty)
        #expect(SymbolParsing.parse(json(#"{"a":1}"#), encoding: .utf16, snapshot: snapshot).isEmpty)
    }

    @Test func moreThanTheLimitIsCut() {
        let snapshot = snap("x\n")
        let item = #"{"name":"s","kind":13,"range":\#(range(0, 0, 1)),"selectionRange":\#(range(0, 0, 1))}"#
        let text = "[" + Array(repeating: item, count: 6_000).joined(separator: ",") + "]"
        #expect(SymbolParsing.parse(json(text), encoding: .utf16, snapshot: snapshot).count == 5_000)
    }
}

@Suite
@MainActor
struct SymbolRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func script(_ replies: String, caps: String = #""documentSymbolProvider":true"#) -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(caps)},"replies":{"textDocument/documentSymbol":\#(replies)}}"#
    }

    @Test func answered() async throws {
        let reply = #"[{"result":[{"name":"f","kind":12,"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"selectionRange":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}}}]}]"#
        try await Rig.run([main], scripts: ["main": script(reply)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.documentSymbols(path: "a.x", snapshot: snapshot)
                    == .answered([DocSymbol(name: "f", kind: 12, depth: 0, range: 1..<2)]))
        }
    }

    @Test func nullIsEmpty() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.documentSymbols(path: "a.x", snapshot: snapshot) == .answered([]))
        }
    }

    @Test func contentModifiedIsStale() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"error":{"code":-32801,"message":"m"}}]"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.documentSymbols(path: "a.x", snapshot: snapshot) == .stale)
        }
    }

    @Test func capabilityAbsentIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script("[]", caps: #""hoverProvider":true"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.documentSymbols(path: "a.x", snapshot: snapshot) == .unavailable)
            #expect(!rig.methods("main").contains("textDocument/documentSymbol"))
        }
    }
}
