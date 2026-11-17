import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func fmtScript(caps: String = #""documentFormattingProvider":true"#, replies: String = "", encoding: String = "") -> String {
    let enc = encoding.isEmpty ? "" : #","positionEncoding":"\#(encoding)""#
    let rep = replies.isEmpty ? "" : #","replies":{\#(replies)}"#
    return #"{"capabilities":{"textDocumentSync":2,\#(caps)\#(enc)}\#(rep)}"#
}

private func edit(_ line: Int, _ from: Int, _ to: Int, _ text: String) -> String {
    #"{"range":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}},"newText":"\#(text)"}"#
}

@Suite
@MainActor
struct FormatterChoiceTests {
    private let main = Rig.config("main", ext: "x")
    private let lint = Rig.linter("lint", ext: "x")

    private func choice(_ configs: [ServerConfig], _ scripts: [String: String], preferred: [String: String] = [:],
                        rangeOnly: Bool = false) async throws -> FormatTargetChoice? {
        var result: FormatTargetChoice?
        try await Rig.run(configs, scripts: scripts) { rig in
            await rig.manager.documentOpened(path: "a.x", snapshot: snap("abc\n"))
            result = await rig.manager.formatChoice(path: "a.x", formatters: preferred, rangeOnly: rangeOnly)
        }
        return result
    }

    @Test func mainOnly() async throws {
        #expect(try await choice([main], ["main": fmtScript()]) == FormatTargetChoice(serverID: "main", role: .main))
    }

    @Test func aCapableLinterBeatsTheMainServer() async throws {
        #expect(try await choice([main, lint], ["main": fmtScript(), "lint": fmtScript()])
                == FormatTargetChoice(serverID: "lint", role: .linter))
    }

    @Test func aLinterWithoutFormattingFallsBackToMain() async throws {
        #expect(try await choice([main, lint], ["main": fmtScript(), "lint": fmtScript(caps: #""hoverProvider":true"#)])
                == FormatTargetChoice(serverID: "main", role: .main))
    }

    @Test func thePreferredServerOverridesTheLinter() async throws {
        #expect(try await choice([main, lint], ["main": fmtScript(), "lint": fmtScript()], preferred: ["main": "main"])
                == FormatTargetChoice(serverID: "main", role: .main))
    }

    @Test func anIncapableOrAbsentPreferenceFallsBackToTheDefaultRule() async throws {
        let scripts = ["main": fmtScript(caps: #""hoverProvider":true"#), "lint": fmtScript()]
        #expect(try await choice([main, lint], scripts, preferred: ["main": "main"]) == FormatTargetChoice(serverID: "lint", role: .linter))
        #expect(try await choice([main, lint], scripts, preferred: ["main": "ghost"]) == FormatTargetChoice(serverID: "lint", role: .linter))
    }

    @Test func nothingCapableIsNil() async throws {
        #expect(try await choice([main], ["main": fmtScript(caps: #""hoverProvider":true"#)]) == nil)
    }

    @Test func rangeOnlyNeedsRangeFormatting() async throws {
        #expect(try await choice([main], ["main": fmtScript()], rangeOnly: true) == nil)
        #expect(try await choice([main], ["main": fmtScript(caps: #""documentRangeFormattingProvider":true"#)], rangeOnly: true)
                == FormatTargetChoice(serverID: "main", role: .main))
    }
}

@Suite
@MainActor
struct FormatRequestTests {
    private let main = Rig.config("main", ext: "x")

    private func format(_ script: String, text: String = "a😀b  \n", range: Range<Int>? = nil) async throws -> LSPOutcome<[ByteEdit]> {
        var out: LSPOutcome<[ByteEdit]> = .unavailable
        try await Rig.run([main], scripts: ["main": script]) { rig in
            let snapshot = snap(text)
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            out = await rig.manager.format(path: "a.x", snapshot: snapshot, range: range, serverID: "main", timeout: .seconds(5))
        }
        return out
    }

    private func replies(_ edits: String) -> String { #""textDocument/formatting":[{"result":[\#(edits)]}]"# }

    @Test func editsOnANonASCIILineLandOnTheRightBytesForUTF16() async throws {
        // "a😀b  ": b is UTF-16 column 3; the two trailing spaces are columns 4..<6, bytes 6..<8.
        #expect(try await format(fmtScript(replies: replies(edit(0, 4, 6, "")))) == .answered([ByteEdit(range: 6..<8, text: "")]))
    }

    @Test func editsOnANonASCIILineLandOnTheRightBytesForUTF8() async throws {
        #expect(try await format(fmtScript(replies: replies(edit(0, 6, 8, "")), encoding: "utf-8"))
                == .answered([ByteEdit(range: 6..<8, text: "")]))
    }

    @Test func nullIsNoEdits() async throws {
        #expect(try await format(fmtScript(replies: #""textDocument/formatting":[{"result":null}]"#)) == .answered([]))
    }

    @Test func overlappingEditsFail() async throws {
        let out = try await format(fmtScript(replies: replies(edit(0, 0, 2, "x") + "," + edit(0, 1, 3, "y"))))
        #expect(out == .failed("server sent an invalid edit"))
    }

    @Test func anEditInsideASurrogatePairFails() async throws {
        let out = try await format(fmtScript(replies: replies(edit(0, 2, 3, "x"))))
        #expect(out == .failed("server sent an invalid edit"))
    }

    @Test func contentModifiedIsStale() async throws {
        let out = try await format(fmtScript(replies: #""textDocument/formatting":[{"error":{"code":-32801,"message":"m"}}]"#))
        #expect(out == .stale)
    }

    @Test func aMissingCapabilityIsUnavailable() async throws {
        #expect(try await format(fmtScript(caps: #""hoverProvider":true"#)) == .unavailable)
    }

    @Test func rangeFormattingSendsTheRange() async throws {
        var methods: [String] = []
        try await Rig.run([main], scripts: ["main": fmtScript(caps: #""documentRangeFormattingProvider":true"#,
                                                               replies: #""textDocument/rangeFormatting":[{"result":[]}]"#)]) { rig in
            let snapshot = snap("abc\ndef\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await rig.manager.format(path: "a.x", snapshot: snapshot, range: 4..<7, serverID: "main", timeout: .seconds(5)) == .answered([]))
            methods = rig.methods("main")
        }
        #expect(methods.contains("textDocument/rangeFormatting"))
        #expect(!methods.contains("textDocument/formatting"))
    }
}
