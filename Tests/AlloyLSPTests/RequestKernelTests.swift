import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private func hoverScript(_ extra: String = "", caps: String = #""hoverProvider":true"#) -> String {
    #"{"capabilities":{"textDocumentSync":2,\#(caps)}\#(extra)}"#
}

@MainActor
private func hover(_ manager: LSPManager, path: String = "a.x", snapshot: CodeSnapshot,
                   timeout: Duration = .seconds(5)) async -> LSPOutcome<JSONValue> {
    await manager.send(.hover, path: path, snapshot: snapshot, timeout: timeout,
                       params: { uri, enc in LSPManager.textDocumentPosition(uri: uri, offset: 0, snapshot: snapshot, encoding: enc) },
                       parse: { answer, _, _ in answer })
}

@Suite
@MainActor
struct RequestKernelTests {
    private let main = Rig.config("main", ext: "x")
    private let lint = Rig.linter("lint", ext: "x")

    @Test func answeredWhenSupported() async throws {
        let script = hoverScript(#","replies":{"textDocument/hover":[{"result":{"contents":"hi"}}]}"#)
        try await Rig.run([main], scripts: ["main": script]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            guard case .answered(let value) = await hover(rig.manager, snapshot: snapshot) else {
                Issue.record("not answered"); return
            }
            #expect(value["contents"]?.stringValue == "hi")
        }
    }

    @Test func unavailableWithoutCapabilityOrServer() async throws {
        try await Rig.run([main], scripts: ["main": hoverScript(caps: #""definitionProvider":true"#)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await hover(rig.manager, snapshot: snapshot) == .unavailable)
            #expect(await hover(rig.manager, path: "nope.x", snapshot: snapshot) == .unavailable)
            #expect(!rig.methods("main").contains("textDocument/hover"))
        }
    }

    @Test func errorsAreMapped() async throws {
        let replies = #","replies":{"textDocument/hover":[{"error":{"code":-32801,"message":"m"}},{"error":{"code":-32800,"message":"c"}},{"error":{"code":-32603,"message":"boom"}}]}"#
        try await Rig.run([main], scripts: ["main": hoverScript(replies)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await hover(rig.manager, snapshot: snapshot) == .stale)
            #expect(await hover(rig.manager, snapshot: snapshot) == .stale)
            #expect(await hover(rig.manager, snapshot: snapshot) == .failed("boom"))
        }
    }

    @Test func unreadableAnswerFails() async throws {
        try await Rig.run([main], scripts: ["main": hoverScript()]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let outcome: LSPOutcome<Int> = await rig.manager.send(
                .hover, path: "a.x", snapshot: snapshot, timeout: .seconds(5),
                params: { uri, enc in LSPManager.textDocumentPosition(uri: uri, offset: 0, snapshot: snapshot, encoding: enc) },
                parse: { _, _, _ in nil })
            #expect(outcome == .failed("unreadable answer"))
        }
    }

    @Test func slowAnswerTimesOut() async throws {
        let replies = #","replies":{"textDocument/hover":[{"result":null,"delayMs":500}]}"#
        try await Rig.run([main], scripts: ["main": hoverScript(replies)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            #expect(await hover(rig.manager, snapshot: snapshot, timeout: .milliseconds(100)) == .timedOut)
        }
    }

    @Test func editedDocumentIsStaleAndAsksNothing() async throws {
        try await Rig.run([main], scripts: ["main": hoverScript()]) { rig in
            let buffer = CodeBuffer("abc\n")
            let cursor = buffer.makeEditCursor()
            let before = buffer.snapshot()
            await rig.manager.documentOpened(path: "a.x", snapshot: before)
            buffer.replace(0..<0, with: "z", origin: .typing)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
            await rig.manager.documentChanged(path: "a.x", change: .edits(edits, after: buffer.snapshot()))
            #expect(await hover(rig.manager, snapshot: before) == .stale)
            #expect(!rig.methods("main").contains("textDocument/hover"))
        }
    }

    @Test func cancellingSendsCancelRequest() async throws {
        let replies = #","replies":{"textDocument/hover":[{"hold":true}]}"#
        try await Rig.run([main], scripts: ["main": hoverScript(replies)]) { rig in
            let snapshot = snap("abc\n")
            await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
            let manager = rig.manager
            let task = Task { await hover(manager, snapshot: snapshot, timeout: .seconds(20)) }
            #expect(await waitUntil { rig.methods("main").contains("textDocument/hover") })
            task.cancel()
            #expect(await task.value == .unavailable)
            #expect(await waitUntil { rig.methods("main").contains("$/cancelRequest") })
        }
    }

    @Test func targetsListMainThenLinterWithCapabilities() async throws {
        let caps = hoverScript()
        try await Rig.run([main, lint], scripts: ["main": caps, "lint": hoverScript(caps: #""documentFormattingProvider":true"#)]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.x", snapshot: snap("abc\n"))
            #expect(await waitUntil {
                seen.all.contains { if case .features(_, let f) = $0 { f.hover && f.formatting } else { false } }
            })
            let all = await rig.manager.requestTargets(path: "a.x", roles: [.main, .linter])
            #expect(all.map(\.id) == ["main", "lint"])
            #expect(all.map(\.role) == [.main, .linter])
            #expect(all[0].capabilities?.hover == true)
            #expect(all[1].capabilities?.documentFormatting == true)
            #expect(await rig.manager.requestTargets(path: "a.x", roles: [.linter]).map(\.id) == ["lint"])
            #expect(await rig.manager.requestTargets(path: "a.x", roles: [.main]).map(\.id) == ["main"])
            #expect(await rig.manager.requestTargets(path: "zz.x", roles: [.main]).isEmpty)
        }
    }

    @Test func failedLinterIsSkipped() async throws {
        let dead = Rig.linter("dead", ext: "x", command: "/nonexistent/server")
        try await Rig.run([main, dead], scripts: ["main": hoverScript()]) { rig in
            await rig.manager.documentOpened(path: "a.x", snapshot: snap("abc\n"))
            let ids = await rig.manager.requestTargets(path: "a.x", roles: [.main, .linter]).map(\.id)
            #expect(ids == ["main"])
        }
    }

    @Test func featuresAreReportedOncePerChange() async throws {
        try await Rig.run([main, lint], scripts: ["main": hoverScript(),
                                                   "lint": hoverScript(caps: #""documentFormattingProvider":true"#)]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.x", snapshot: snap("abc\n"))
            #expect(await waitUntil {
                seen.all.contains { if case .features(_, let f) = $0 { f.hover && f.formatting } else { false } }
            })
            try await Task.sleep(for: .milliseconds(150))
            let sets = seen.all.compactMap { r -> FeatureSet? in if case .features(_, let f) = r { f } else { nil } }
            #expect(sets.last == FeatureSet(hover: true, formatting: true))
            #expect(Set(sets.map { "\($0)" }).count == sets.count, "duplicates in \(sets)")
        }
    }

    @Test func positionEncodingFollowsTheServer() async throws {
        for (encoding, expected) in [("utf-16", 2), ("utf-8", 4)] {
            let script = #"{"capabilities":{"textDocumentSync":2,"hoverProvider":true,"positionEncoding":"\#(encoding)"}}"#
            try await Rig.run([main], scripts: ["main": script]) { rig in
                let snapshot = snap("\u{1F600}x\n")
                await rig.manager.documentOpened(path: "a.x", snapshot: snapshot)
                let offset = 4   // after the emoji
                let outcome: LSPOutcome<JSONValue> = await rig.manager.send(
                    .hover, path: "a.x", snapshot: snapshot, timeout: .seconds(5),
                    params: { uri, enc in LSPManager.textDocumentPosition(uri: uri, offset: offset, snapshot: snapshot, encoding: enc) },
                    parse: { answer, _, _ in answer })
                _ = outcome
                let text = try String(contentsOf: rig.dir.appendingPathComponent("main.jsonl"), encoding: .utf8)
                let line = try #require(text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
                    .first { $0["method"]?.stringValue == "textDocument/hover" })
                #expect(line["params"]?["position"]?["character"]?.intValue == expected)
            }
        }
    }
}
