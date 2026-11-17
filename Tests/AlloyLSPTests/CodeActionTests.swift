import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }

private func diag(_ line: Int, _ ch: Int, _ end: Int, _ message: String, code: String = "E1") -> String {
    #"{"range":{"start":{"line":\#(line),"character":\#(ch)},"end":{"line":\#(line),"character":\#(end)}},"severity":1,"message":"\#(message)","code":"\#(code)"}"#
}

private func script(replies: String, diagnostics: [String] = [], caps: String = #""codeActionProvider":{"resolveProvider":true}"#) -> String {
    let d = diagnostics.isEmpty ? "" : #","diagnostics":[\#(diagnostics.joined(separator: ","))]"#
    return #"{"capabilities":{"textDocumentSync":2,\#(caps)},"replies":{"textDocument/codeAction":\#(replies),"codeAction/resolve":[{"result":{"title":"R","data":1,"edit":{"changes":{}}}}]}\#(d)}"#
}

@Suite
@MainActor
struct CodeActionParsingTests {
    private func item(_ text: String, role: ServerRole = .main) -> CodeActionItem? {
        CodeActionParsing.item(from: json(text), serverID: "s", serverName: "S", role: role)
    }

    @Test func everyShapeParses() {
        let inline = item(#"{"title":"A","kind":"quickfix","isPreferred":true,"edit":{"changes":{}},"diagnostics":[{"message":"m"}]}"#)
        #expect(inline?.edit != nil && inline?.isPreferred == true && inline?.kind == "quickfix" && inline?.diagnostics.count == 1)
        let dataOnly = item(#"{"title":"B","data":{"id":7}}"#)
        #expect(dataOnly?.edit == nil && dataOnly?.data != nil && dataOnly?.command == nil)
        let bare = item(#"{"title":"C","command":"do.it","arguments":[1,"x"]}"#)
        #expect(bare?.command == CodeActionCommand(command: "do.it", arguments: [.number(1), .string("x")]))
        let both = item(#"{"title":"D","edit":{"changes":{}},"command":{"title":"t","command":"c","arguments":[]}}"#)
        #expect(both?.edit != nil && both?.command?.command == "c")
        let off = item(#"{"title":"E","disabled":{"reason":"nope"}}"#)
        #expect(off?.disabledReason == "nope")
        #expect(item(#"{"kind":"x"}"#) == nil)
    }

    @Test func displayTitleNamesLintersOnly() {
        #expect(item(#"{"title":"Fix"}"#)?.displayTitle == "Fix")
        #expect(item(#"{"title":"Fix"}"#, role: .linter)?.displayTitle == "S: Fix")
    }

    @Test func unlistedCommandIsDropped() {
        let items = [item(#"{"title":"only","command":"bad"}"#)!, item(#"{"title":"both","edit":{"changes":{}},"command":{"title":"t","command":"bad"}}"#)!,
                     item(#"{"title":"ok","command":"good"}"#)!]
        let kept = CodeActionParsing.filter(items, commands: ["good"])
        #expect(kept.map(\.title) == ["both", "ok"])
        #expect(kept[0].command == nil)
        #expect(kept[1].command?.command == "good")
    }

    @Test func orderingIsPreferredThenQuickfixThenRest() {
        let list = ["r1:refactor", "q1:quickfix", "p:refactor:P", "q2:quickfix.x", "r2:source"].map { spec -> CodeActionItem in
            let parts = spec.split(separator: ":").map(String.init)
            let preferred = parts.count == 3
            return item(#"{"title":"\#(parts[0])","kind":"\#(parts[1])","isPreferred":\#(preferred)}"#)!
        }
        #expect(CodeActionParsing.order(list).map(\.title) == ["p", "q1", "q2", "r1", "r2"])
    }

    @Test func matchesByIdentityThenFallbackThenNot() {
        let raw = json(diag(0, 0, 1, "msg"))
        let d = LSPDiagnostic(range: 0..<1, severity: .error, message: "msg", code: "E1", raw: raw)
        #expect(CodeActionMatching.matches(item(#"{"title":"a","diagnostics":[\#(diag(0, 0, 1, "msg"))]}"#)!, diagnostic: d))
        // The server rewrote the object (added data, changed severity) but kept range, code and message.
        let rewritten = #"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":2,"message":"msg","code":"E1","data":5}"#
        #expect(CodeActionMatching.matches(item(#"{"title":"a","diagnostics":[\#(rewritten)]}"#)!, diagnostic: d))
        #expect(!CodeActionMatching.matches(item(#"{"title":"a","diagnostics":[\#(diag(0, 0, 1, "other"))]}"#)!, diagnostic: d))
        #expect(!CodeActionMatching.matches(item(#"{"title":"a"}"#)!, diagnostic: d))
        #expect(!CodeActionMatching.matches(item(#"{"title":"a","diagnostics":[\#(diag(0, 0, 1, "msg"))]}"#)!,
                                            diagnostic: LSPDiagnostic(range: 0..<1, severity: .error, message: "msg")))
    }
}

@Suite
@MainActor
struct CodeActionRequestTests {
    private let main = Rig.config("main", ext: "x")
    private let lint = Rig.linter("lint", ext: "x")

    private func requests(_ rig: Rig, _ id: String, _ method: String = "textDocument/codeAction") -> [JSONValue] {
        guard let text = try? String(contentsOf: rig.dir.appendingPathComponent("\(id).jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }.filter { $0["method"]?.stringValue == method }
    }

    private func open(_ rig: Rig, _ text: String = "abcd\nefgh\n") async -> CodeSnapshot {
        let snapshot = snap(text)
        await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
        return snapshot
    }

    @Test func mainOnlySendsOverlappingDiagnosticOnly() async throws {
        let reply = #"[{"result":[{"title":"Fix","kind":"quickfix"}]}]"#
        try await Rig.run([main], scripts: ["main": script(replies: reply, diagnostics: [diag(0, 0, 2, "near"), diag(1, 0, 2, "far")])]) { rig in
            let seen = Collector(rig.manager.results)
            let snapshot = await open(rig)
            #expect(await waitUntil { seen.all.contains { if case .diagnostics(_, _, let i) = $0 { i.count == 2 } else { false } } })
            let outcome = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false)
            guard case .answered(let items) = outcome else { Issue.record("\(outcome)"); return }
            #expect(items.map(\.title) == ["Fix"])
            let sent = requests(rig, "main")
            #expect(sent.count == 1)
            let context = sent[0]["params"]?["context"]
            #expect(context?["diagnostics"]?.arrayValue?.map { $0["message"]?.stringValue } == ["near"])
            #expect(context?["triggerKind"]?.intValue == 1)
            #expect(sent[0]["params"]?["range"]?["end"]?["character"]?.intValue == 1)
            _ = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: true)
            #expect(requests(rig, "main").last?["params"]?["context"]?["triggerKind"]?.intValue == 2)
        }
    }

    @Test func mainAndLinterAreMergedAndOrdered() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script(replies: #"[{"result":[{"title":"Refactor","kind":"refactor"},{"title":"MainFix","kind":"quickfix"}]}]"#),
            "lint": script(replies: #"[{"result":[{"title":"LintPref","kind":"quickfix","isPreferred":true}]}]"#),
        ]) { rig in
            let snapshot = await open(rig)
            let outcome = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false)
            guard case .answered(let items) = outcome else { Issue.record("\(outcome)"); return }
            #expect(items.map(\.displayTitle) == ["Lint lint: LintPref", "MainFix", "Refactor"])
            #expect(items.map(\.serverID) == ["lint", "main", "main"])
        }
    }

    @Test func serverWithoutCapabilityIsNeverAsked() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script(replies: #"[{"result":[{"title":"M"}]}]"#),
            "lint": script(replies: #"[{"result":[{"title":"L"}]}]"#, caps: #""hoverProvider":true"#),
        ]) { rig in
            let snapshot = await open(rig)
            let outcome = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false)
            #expect(outcome == .answered([]) || { if case .answered(let i) = outcome { i.map(\.title) == ["M"] } else { false } }())
            #expect(requests(rig, "lint").isEmpty)
            #expect(requests(rig, "main").count == 1)
        }
    }

    @Test func oneServerErroringStillReturnsTheOther() async throws {
        try await Rig.run([main, lint], scripts: [
            "main": script(replies: #"[{"error":{"code":-32603,"message":"boom"}}]"#),
            "lint": script(replies: #"[{"result":[{"title":"L","kind":"quickfix"}]}]"#),
        ]) { rig in
            let snapshot = await open(rig)
            let outcome = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false)
            guard case .answered(let items) = outcome else { Issue.record("\(outcome)"); return }
            #expect(items.map(\.title) == ["L"])
        }
    }

    @Test func allFailingReportsTheFailure() async throws {
        try await Rig.run([main], scripts: ["main": script(replies: #"[{"error":{"code":-32801,"message":"modified"}}]"#)]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false) == .stale)
        }
    }

    @Test func nullAnswerIsEmptyList() async throws {
        try await Rig.run([main], scripts: ["main": script(replies: #"[{"result":null}]"#)]) { rig in
            let snapshot = await open(rig)
            #expect(await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false) == .answered([]))
        }
    }

    @Test func unlistedCommandIsDroppedFromAnswer() async throws {
        let reply = #"[{"result":[{"title":"Bad","command":{"title":"t","command":"nope"}},{"title":"Good","command":{"title":"t","command":"yes"}}]}]"#
        try await Rig.run([main], scripts: ["main": script(replies: reply, caps: #""codeActionProvider":true,"executeCommandProvider":{"commands":["yes"]}"#)]) { rig in
            let snapshot = await open(rig)
            let outcome = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false)
            guard case .answered(let items) = outcome else { Issue.record("\(outcome)"); return }
            #expect(items.map(\.title) == ["Good"])
        }
    }

    @Test func staleSnapshotIsStale() async throws {
        try await Rig.run([main], scripts: ["main": script(replies: #"[{"result":[]}]"#)]) { rig in
            let buffer = CodeBuffer("abcd\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: buffer.snapshot())
            buffer.replace(0..<0, with: "z", origin: .typing)
            // The manager was not told about the edit: the request's text is newer than the one it synced.
            #expect(await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: buffer.snapshot(), automatic: false) == .stale)
        }
    }

    @Test func resolveFillsEdit() async throws {
        try await Rig.run([main], scripts: ["main": script(replies: #"[{"result":[{"title":"Lazy","data":{"k":1}}]}]"#)]) { rig in
            let snapshot = await open(rig)
            guard case .answered(let items) = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false) else {
                Issue.record("no items"); return
            }
            #expect(items[0].edit == nil)
            guard case .answered(let resolved) = await rig.manager.resolveCodeAction(path: "a.x", item: items[0], snapshot: snapshot) else {
                Issue.record("no resolve"); return
            }
            #expect(resolved.edit != nil)
            #expect(resolved.serverID == "main")
            #expect(requests(rig, "main", "codeAction/resolve").first?["params"]?["data"]?["k"]?.intValue == 1)
        }
    }

    @Test func resolveWithoutCapabilityIsUnavailable() async throws {
        try await Rig.run([main], scripts: ["main": script(replies: #"[{"result":[{"title":"Lazy","data":1}]}]"#, caps: #""codeActionProvider":true"#)]) { rig in
            let snapshot = await open(rig)
            guard case .answered(let items) = await rig.manager.codeActions(path: "a.x", range: 0..<1, snapshot: snapshot, automatic: false) else {
                Issue.record("no items"); return
            }
            #expect(await rig.manager.resolveCodeAction(path: "a.x", item: items[0], snapshot: snapshot) == .unavailable)
        }
    }
}
