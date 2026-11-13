import AlloyCore
import AlloyHighlight
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP

private let legend = SemanticTokensLegend(
    tokenTypes: ["keyword", "string", "variable", "function", "type", "bogus", "enumMember", "decorator"],
    tokenModifiers: ["declaration", "readonly", "defaultLibrary"])

@MainActor
struct SemanticTokensTests {
    /// Two lines; the first holds an emoji (4 UTF-8 bytes, 2 UTF-16 units) before the tokens.
    @Test func decodesRelativeTokensUTF16() {
        let text = "😀 let x\nfn main"
        let snapshot = CodeBuffer(text).snapshot()
        // line 0: "let" at UTF-16 3..<6 (keyword), "x" at 7..<8 (variable, readonly -> constant);
        // line 1: "fn" 0..<2 (keyword), "main" 3..<7 (function, defaultLibrary -> builtin)
        let data = [0, 3, 3, 0, 0,
                    0, 4, 1, 2, 0b010,
                    1, 0, 2, 0, 0,
                    0, 3, 4, 3, 0b100]
        let runs = SemanticTokens.decode(data, legend: legend, snapshot: snapshot, encoding: .utf16)
        // The emoji and the space are 5 bytes; "let" is bytes 5..<8, "x" 9..<10; line 1 starts at byte 11.
        #expect(runs.map(\.0) == [5..<8, 9..<10, 11..<13, 14..<18])
        #expect(runs.map(\.1) == [.keyword, .constant, .keyword, .builtin])
        #expect(String(decoding: snapshot.utf8(in: 5..<8), as: UTF8.self) == "let")
    }

    @Test func decodesUTF8AndUTF32() {
        let snapshot = CodeBuffer("é kw").snapshot()
        // "kw" at UTF-8 byte 3, UTF-16/32 character 2.
        #expect(SemanticTokens.decode([0, 3, 2, 0, 0], legend: legend, snapshot: snapshot, encoding: .utf8).map(\.0) == [3..<5])
        #expect(SemanticTokens.decode([0, 2, 2, 0, 0], legend: legend, snapshot: snapshot, encoding: .utf32).map(\.0) == [3..<5])
        #expect(SemanticTokens.decode([0, 2, 2, 0, 0], legend: legend, snapshot: snapshot, encoding: .utf16).map(\.0) == [3..<5])
    }

    @Test func unknownTypesSkipped() {
        let snapshot = CodeBuffer("a b c\n").snapshot()
        // type 5 is "bogus", type 99 is outside the legend; an empty token and one past the text go too.
        let data = [0, 0, 1, 5, 0,
                    0, 2, 1, 99, 0,
                    0, 0, 0, 0, 0,
                    0, 2, 1, 1, 0,
                    4, 0, 1, 0, 0]
        let runs = SemanticTokens.decode(data, legend: legend, snapshot: snapshot, encoding: .utf16)
        #expect(runs.map(\.0) == [4..<5])
        #expect(runs.map(\.1) == [.string])
    }

    @Test func clampsTokensPastTheLineEnd() {
        let snapshot = CodeBuffer("ab\ncd\n").snapshot()
        // A token longer than its line is cut at the line's content end; one that starts past it is skipped.
        let data = [0, 0, 10, 0, 0,
                    1, 5, 2, 0, 0,
                    0, 0, 1, 1, 0]
        let runs = SemanticTokens.decode(data, legend: legend, snapshot: snapshot, encoding: .utf16)
        #expect(runs.map(\.0) == [0..<2])
    }

    @Test func rangeOnlyProviderOffersNoTokens() {
        func caps(_ full: String) -> ServerCapabilities {
            ServerCapabilities(json: JSONValue.parse(Data(#"{"semanticTokensProvider":{"legend":{"tokenTypes":["type"],"tokenModifiers":[]},\#(full)"range":true}}"#.utf8))!)
        }
        #expect(caps("").semanticTokens == nil)
        #expect(caps(#""full":false,"#).semanticTokens == nil)
        #expect(caps(#""full":true,"#).semanticTokens != nil)
        #expect(caps(#""full":{"delta":false},"#).semanticTokens != nil)
    }

    @Test func mapsTheKinds() {
        #expect(["keyword", "modifier"].allSatisfy { SemanticTokens.baseKind($0) == .keyword })
        #expect(["string", "regexp"].allSatisfy { SemanticTokens.baseKind($0) == .string })
        #expect(["type", "class", "struct", "enum", "interface", "typeParameter", "namespace"].allSatisfy { SemanticTokens.baseKind($0) == .type })
        #expect(["function", "method", "macro"].allSatisfy { SemanticTokens.baseKind($0) == .function })
        #expect(["property", "event"].allSatisfy { SemanticTokens.baseKind($0) == .property })
        #expect(SemanticTokens.baseKind("enumMember") == .constant)
        #expect(SemanticTokens.baseKind("operator") == .operator_)
        #expect(SemanticTokens.baseKind("decorator") == .attribute)
        #expect(SemanticTokens.baseKind("comment") == .comment && SemanticTokens.baseKind("number") == .number)
        #expect(SemanticTokens.baseKind("label") == nil)
    }

    @Test func appliesDeltaEdits() {
        let previous = [0, 0, 3, 0, 0,  0, 4, 1, 1, 0,  1, 0, 2, 2, 0]
        func edit(_ start: Int, _ delete: Int, _ data: [Int]?) -> JSONValue {
            var o: [String: JSONValue] = ["start": .number(Double(start)), "deleteCount": .number(Double(delete))]
            if let data { o["data"] = .array(data.map { .number(Double($0)) }) }
            return .object(o)
        }
        // Replace the middle token, then insert at the end (given out of order), then delete the first token.
        let result = SemanticTokens.applyDelta(previous, edits: [edit(15, 0, [1, 1, 1, 3, 0]), edit(5, 5, [0, 5, 2, 4, 1]), edit(0, 5, nil)])
        #expect(result == [0, 5, 2, 4, 1,  1, 0, 2, 2, 0,  1, 1, 1, 3, 0])
        #expect(SemanticTokens.applyDelta(previous, edits: []) == previous)
        // An edit past the end, and overlapping edits, do not fit.
        #expect(SemanticTokens.applyDelta(previous, edits: [edit(10, 10, nil)]) == nil)
        #expect(SemanticTokens.applyDelta(previous, edits: [edit(0, 10, nil), edit(5, 5, nil)]) == nil)
    }
}


@MainActor
@Suite
struct SemanticTokensRequestTests {
    private func rig(script: String) throws -> (URL, LSPManager) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-sem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = script
            env["FAKE_LSP_LOG"] = dir.appendingPathComponent("log.jsonl").path
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "fake", extensions: ["fk"], command: fakeServerPath)
        return (dir, LSPManager(root: dir, registry: ServerRegistry(builtIn: [config]),
                                locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }), launcher: launcher))
    }

    private func methods(_ dir: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private func nextTokens(_ manager: LSPManager) async -> (Int, [(Range<Int>, SyntaxToken)])? {
        for await result in manager.results {
            if case .semanticTokens(_, let version, let runs) = result { return (version, runs) }
        }
        return nil
    }

    private static func caps(delta: Bool = true, tokens: Bool = true) -> String {
        guard tokens else { return #""capabilities":{"textDocumentSync":2}"# }
        return #""capabilities":{"textDocumentSync":2,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword","number"],"tokenModifiers":[]},"full":\#(delta ? #"{"delta":true}"# : "true")}}"#
    }
    private static let caps = caps()
    private static let fullData = #"[0,0,3,0,0,0,4,1,1,0]"#
    private static let deltaReply = #"{"resultId":"2","edits":[{"start":5,"deleteCount":5,"data":[0,4,2,1,0]}]}"#

    private func requests(_ dir: URL) -> [JSONValue] {
        methods(dir).filter { $0["method"]?.stringValue?.contains("semanticTokens") == true }
    }

    private func waitEntered(_ hold: Hold) async -> Bool {
        await waitUntil(.seconds(5)) { await hold.entered }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        await waitUntil(.seconds(5)) { condition() }
    }

    private func nextSupport(_ manager: LSPManager) async -> Bool? {
        for await result in manager.results {
            if case .semanticSupport(_, let supported) = result { return supported }
        }
        return nil
    }

    @Test func fullThenDeltaWithResultId() async throws {
        let script = "{\(Self.caps),\"semanticTokens\":{\"resultId\":\"1\",\"data\":[0,0,3,0,0,0,4,1,1,0]},"
            + "\"semanticTokensDelta\":{\"resultId\":\"2\",\"edits\":[{\"start\":5,\"deleteCount\":5,\"data\":[0,4,2,1,0]}]}}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("let 1\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        await manager.requestSemanticTokens(path: "a.fk")
        let first = await nextTokens(manager)
        #expect(first?.1.map(\.0) == [0..<3, 4..<5])
        #expect(first?.1.map(\.1) == [.keyword, .number])

        let edited = CodeBuffer("let 12\n").snapshot()
        await manager.documentChanged(path: "a.fk", change: .resync(edited))
        await manager.requestSemanticTokens(path: "a.fk")
        let second = await nextTokens(manager)
        #expect(second?.1.map(\.0) == [0..<3, 4..<6])
        let methods = methods(dir).compactMap { $0["method"]?.stringValue }.filter { $0.contains("semanticTokens") }
        #expect(methods == ["textDocument/semanticTokens/full", "textDocument/semanticTokens/full/delta"])
        let delta = methods.isEmpty ? nil : self.methods(dir).first { $0["method"]?.stringValue?.hasSuffix("/delta") == true }
        #expect(delta?["params"]?["previousResultId"]?.stringValue == "1")
        await manager.shutdownAll()
    }

    @Test func serverWithoutTokensIsNeverAsked() async throws {
        let (dir, manager) = try rig(script: #"{"capabilities":{"textDocumentSync":2}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("x\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        try await Task.sleep(for: .milliseconds(400))
        await manager.shutdownAll()
        #expect(!methods(dir).contains { $0["method"]?.stringValue?.contains("semanticTokens") == true })
    }

    @Test func probeReportsWhetherTheServerOffersTokens() async throws {
        for (tokens, expected) in [(true, true), (false, false)] {
            let (dir, manager) = try rig(script: "{\(Self.caps(tokens: tokens)),\"semanticTokens\":{\"data\":[]}}")
            defer { try? FileManager.default.removeItem(at: dir) }
            await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("x\n").snapshot())
            await manager.requestSemanticTokens(path: "a.fk", probe: true)
            #expect(await nextSupport(manager) == expected)
            await manager.shutdownAll()
        }
    }

    @Test func failedDeltaRetriesOnceWithAFullRequest() async throws {
        let script = "{\(Self.caps),\"semanticTokens\":{\"resultId\":\"1\",\"data\":\(Self.fullData)},\"semanticTokensDeltaError\":true}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        _ = await nextTokens(manager)
        await manager.requestSemanticTokens(path: "a.fk")   // a delta, answered with an error: no colours wait for an edit
        let retried = await nextTokens(manager)
        #expect(retried?.1.map(\.0) == [0..<3, 4..<5])
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests(dir).compactMap { $0["method"]?.stringValue }
                == ["textDocument/semanticTokens/full", "textDocument/semanticTokens/full/delta", "textDocument/semanticTokens/full"],
                "exactly one retry, and it is a full request")
        await manager.shutdownAll()
    }

    @Test func deltaThatDoesNotFitFallsBackToFull() async throws {
        let bad = #"{"resultId":"2","edits":[{"start":100,"deleteCount":0,"data":[0,0,1,0,0]}]}"#
        let script = "{\(Self.caps),\"semanticTokens\":{\"resultId\":\"1\",\"data\":\(Self.fullData)},\"semanticTokensDelta\":\(bad)}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        _ = await nextTokens(manager)
        await manager.requestSemanticTokens(path: "a.fk")
        // The unusable delta is followed, on its own, by a full request whose answer is reported.
        let result = await nextTokens(manager)
        #expect(result?.1.map(\.0) == [0..<3, 4..<5])
        #expect(requests(dir).compactMap { $0["method"]?.stringValue }
                == ["textDocument/semanticTokens/full", "textDocument/semanticTokens/full/delta", "textDocument/semanticTokens/full"])
        await manager.shutdownAll()
    }

    /// A gate that really holds (a cancelled waiter does not leave it) until `release()`.
    private actor Hold {
        private var waiting: CheckedContinuation<Void, Never>?
        private var released = false
        private(set) var entered = false
        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { waiting = $0 }
        }
        func release() { released = true; waiting?.resume(); waiting = nil }
    }

    @Test func staleReplyIsDroppedButStillMovesTheBase() async throws {
        let script = "{\(Self.caps),\"semanticTokens\":{\"resultId\":\"1\",\"data\":\(Self.fullData)},\"semanticTokensDelta\":\(Self.deltaReply)}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let buffer = CodeBuffer("let 1\n")
        await manager.documentOpened(path: "a.fk", snapshot: buffer.snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        _ = await nextTokens(manager)

        let hold = Hold()
        await manager.setSemanticGate { await hold.wait() }
        await manager.requestSemanticTokens(path: "a.fk")   // a delta; its reply arrives, then waits at the gate
        #expect(await waitEntered(hold))
        // The same buffer is edited, so its version advances; the held reply is for older text.
        buffer.replace(5..<5, with: "2", origin: .typing)
        let edited = buffer.snapshot()
        #expect(edited.version > 0)
        await manager.documentChanged(path: "a.fk", change: .resync(edited))
        await hold.release()
        await manager.setSemanticGate(nil)

        // The next request is a delta from the id of the dropped reply, and the first answer reported is for the new text
        // (the dropped one was not reported).
        await manager.requestSemanticTokens(path: "a.fk")
        let result = await nextTokens(manager)
        #expect(result?.0 == Int(edited.version))
        let deltas = requests(dir).filter { $0["method"]?.stringValue?.hasSuffix("/delta") == true }
        #expect(deltas.count == 2)
        #expect(deltas.last?["params"]?["previousResultId"]?.stringValue == "2")
        await manager.shutdownAll()
    }

    @Test func supersedingRequestWaitsForItsPredecessorBeforeReadingTheBase() async throws {
        let script = "{\(Self.caps),\"semanticTokens\":{\"resultId\":\"1\",\"data\":\(Self.fullData)},\"semanticTokensDelta\":\(Self.deltaReply)}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        _ = await nextTokens(manager)

        let hold = Hold()
        await manager.setSemanticGate { await hold.wait() }
        await manager.requestSemanticTokens(path: "a.fk")   // B: a delta whose reply (id "2") waits at the gate
        #expect(await waitEntered(hold))
        await manager.requestSemanticTokens(path: "a.fk")   // C supersedes B
        // C must not read the base (still "1") while B has yet to move it: it sends nothing until B is done.
        try await Task.sleep(for: .milliseconds(300))
        #expect(requests(dir).filter { $0["method"]?.stringValue?.hasSuffix("/delta") == true }.count == 1)
        await hold.release()
        await manager.setSemanticGate(nil)
        _ = await nextTokens(manager)
        let deltas = requests(dir).filter { $0["method"]?.stringValue?.hasSuffix("/delta") == true }
        #expect(deltas.count == 2)
        #expect(deltas.last?["params"]?["previousResultId"]?.stringValue == "2", "C used the base B left")
        await manager.shutdownAll()
    }

    @Test func reloadStartsTheNewServerFromAFullRequest() async throws {
        let script = "{\(Self.caps),\"semanticTokens\":{\"resultId\":\"1\",\"data\":\(Self.fullData)},\"semanticTokensDelta\":\(Self.deltaReply)}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        _ = await nextTokens(manager)
        #expect(await manager.semanticBaseSize(path: "a.fk") == 10)
        // A changed server restarts; the document is re-opened and its tokens asked for again, without the old id.
        var changed = ServerConfig(id: "fake", name: "Fake", languageID: "fake", extensions: ["fk"], command: fakeServerPath)
        changed.arguments = ["--changed"]
        await manager.reload(registry: ServerRegistry(builtIn: [changed]))
        _ = await nextTokens(manager)
        #expect(requests(dir).compactMap { $0["method"]?.stringValue }
                == ["textDocument/semanticTokens/full", "textDocument/semanticTokens/full"],
                "the new instance was sent a delta against an id it never issued")
        await manager.shutdownAll()
    }

    @Test func editCancelsTheRequestInFlight() async throws {
        let script = "{\(Self.caps),\"holdSemanticTokens\":true}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk", probe: true)
        #expect(await waitFor { requests(dir).count == 1 })
        await manager.documentChanged(path: "a.fk", change: .resync(CodeBuffer("let 12\n").snapshot()))
        #expect(await waitFor { methods(dir).contains { $0["method"]?.stringValue == "$/cancelRequest" } })
        await manager.shutdownAll()
    }

    @Test func refreshAsksAgain() async throws {
        let script = "{\(Self.caps(delta: false)),\"semanticTokensFirst\":{\"data\":[]},\"semanticTokens\":{\"data\":\(Self.fullData)},\"refreshSemanticAfterFirst\":true}"
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
        await manager.requestSemanticTokens(path: "a.fk")
        // The first answer is empty; the server's refresh request made the manager ask again (and may supersede the
        // first answer before it is reported), so the first non-empty answer is the one to see.
        let colours: [(Range<Int>, SyntaxToken)]? = await withTaskGroup(of: [(Range<Int>, SyntaxToken)]?.self) { group in
            group.addTask {
                for await result in manager.results {
                    if case .semanticTokens(_, _, let runs) = result, !runs.isEmpty { return runs }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(colours?.map(\.0) == [0..<3, 4..<5])
        #expect(requests(dir).count == 2)
        await manager.shutdownAll()
    }

    @Test func noTokenArrayIsKeptWithoutDelta() async throws {
        for (delta, expected) in [(false, nil), (true, 10)] as [(Bool, Int?)] {
            let script = "{\(Self.caps(delta: delta)),\"semanticTokens\":{\"resultId\":\"1\",\"data\":\(Self.fullData)}}"
            let (dir, manager) = try rig(script: script)
            defer { try? FileManager.default.removeItem(at: dir) }
            await manager.documentOpened(path: "a.fk", snapshot: CodeBuffer("let 1\n").snapshot())
            await manager.requestSemanticTokens(path: "a.fk")
            _ = await nextTokens(manager)
            #expect(await manager.semanticBaseSize(path: "a.fk") == expected)
            await manager.shutdownAll()
        }
    }
}
