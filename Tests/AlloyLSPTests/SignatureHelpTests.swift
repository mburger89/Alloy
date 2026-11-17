import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

struct SignatureHelpParsingTests {
    @Test func utf16OffsetsConvertToUtf8WithEmoji() {
        // "f(😀: Int, b: Int)": UTF-16 units: f ( 😀(2) : space I n t , ...
        let r = SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"f(😀: Int, b: Int)","parameters":[{"label":[2,9]},{"label":[11,17]}]}],"activeParameter":1}"#))
        let label = "f(😀: Int, b: Int)"
        let p = r?.signatures[0].parameters
        let bytes = Array(label.utf8)
        func text(_ l: ParameterLabel) -> String { String(decoding: bytes[l.start..<l.end], as: UTF8.self) }
        #expect(text(p![0]) == "😀: Int")
        #expect(text(p![1]) == "b: Int")
        #expect(r?.activeParameter == 1)
    }

    @Test func stringLabelsUseFirstSubstringMatch() {
        let r = SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"f(a: Int, b: Int)","parameters":[{"label":"b: Int"},{"label":"zzz"}]}]}"#))
        #expect(r?.signatures[0].parameters == [ParameterLabel(start: 10, end: 16), ParameterLabel(start: 0, end: 0)])
    }

    @Test func badOffsetsGiveEmptyRanges() {
        let r = SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a😀b","parameters":[{"label":[2,3]},{"label":[0,99]},{"label":[3,1]},{"label":5}]}]}"#))
        #expect(r?.signatures[0].parameters == Array(repeating: ParameterLabel(start: 0, end: 0), count: 4))
    }

    @Test func signatureActiveParameterOverrides() {
        let r = SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a"},{"label":"b","activeParameter":2}],"activeSignature":1,"activeParameter":0}"#))
        #expect(r?.activeSignature == 1)
        #expect(r?.activeParameter == 2)
        let top = SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a"}],"activeParameter":3}"#))
        #expect(top?.activeParameter == 3)
        #expect(SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a"}]}"#))?.activeParameter == nil)
    }

    @Test func activeSignatureClamps() {
        #expect(SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a"}],"activeSignature":5}"#))?.activeSignature == 0)
        #expect(SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a"}],"activeSignature":-1}"#))?.activeSignature == 0)
    }

    @Test func nullAndEmptyGiveNil() {
        #expect(SignatureHelpParsing.parse(.null) == nil)
        #expect(SignatureHelpParsing.parse(json(#"{"signatures":[]}"#)) == nil)
        #expect(SignatureHelpParsing.parse(json(#"{"signatures":[{"kind":1}]}"#)) == nil)
    }

    @Test func documentationShapes() {
        let r = SignatureHelpParsing.parse(json(#"{"signatures":[{"label":"a","documentation":"plain"},{"label":"b","documentation":{"kind":"markdown","value":"**m**"}}]}"#))
        #expect(r?.signatures.map(\.documentation) == ["plain", "**m**"])
    }
}

@Suite
@MainActor
struct SignatureHelpRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func script(_ replies: String, caps: String = #""signatureHelpProvider":{"triggerCharacters":["("]}"#) -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(caps)},"replies":{"textDocument/signatureHelp":\#(replies)}}"#
    }

    private func requests(_ rig: Rig) -> [JSONValue] {
        guard let text = try? String(contentsOf: rig.dir.appendingPathComponent("main.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
            .filter { $0["method"]?.stringValue == "textDocument/signatureHelp" }
    }

    @Test func contextsAndAnswers() async throws {
        let sig = #"{"result":{"signatures":[{"label":"f(a)","parameters":[{"label":"a"}]}],"activeParameter":0}}"#
        let replies = "[\(sig),\(sig),\(sig),\(sig),{\"result\":null}]"
        try await Rig.run([main], scripts: ["main": script(replies)]) { rig in
            let snapshot = snap("f(\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let expected = SignatureInfo(signatures: [Signature(label: "f(a)", parameters: [ParameterLabel(start: 2, end: 3)])], activeSignature: 0, activeParameter: 0)
            for trigger in [SignatureTrigger.invoked, .character("("), .retrigger(","), .retrigger(nil)] {
                #expect(await rig.manager.signatureHelp(path: "a.x", utf8Offset: 2, snapshot: snapshot, trigger: trigger) == .answered(expected))
            }
            #expect(await rig.manager.signatureHelp(path: "a.x", utf8Offset: 2, snapshot: snapshot, trigger: .invoked) == .answered(nil))
            let contexts = requests(rig).map { $0["params"]?["context"] }
            #expect(contexts.prefix(4).map { $0?["triggerKind"]?.intValue } == [1, 2, 2, 3])
            #expect(contexts.prefix(4).map { $0?["isRetrigger"]?.boolValue } == [false, false, true, true])
            #expect(contexts[1]?["triggerCharacter"]?.stringValue == "(")
            #expect(contexts[2]?["triggerCharacter"]?.stringValue == ",")
            #expect(contexts[3]?["triggerCharacter"] == nil)
        }
    }

    @Test func withoutCapabilityIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script(#"[{"result":null}]"#, caps: #""hoverProvider":true"#)]) { rig in
            let snapshot = snap("f(\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.signatureHelp(path: "a.x", utf8Offset: 2, snapshot: snapshot, trigger: .invoked) == .unavailable)
        }
    }
}
