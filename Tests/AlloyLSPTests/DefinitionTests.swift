import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP


private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }
private func range(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> LSPRange {
    LSPRange(start: LSPPosition(line: sl, character: sc), end: LSPPosition(line: el, character: ec))
}

struct DefinitionParsingTests {
    let root = URL(fileURLWithPath: "/work/proj")

    @Test func parsesLocationLocationArrayAndLinks() {
        let location = json(#"{"uri":"file:///work/proj/src/a.rs","range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}"#)
        #expect(DefinitionParsing.parse(location, root: root) == [.inWorkspace(path: "src/a.rs", range: range(1, 2, 1, 5))])
        let array = json(#"[{"uri":"file:///work/proj/b.rs","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}},{"uri":"file:///work/proj/c.rs","range":{"start":{"line":3,"character":0},"end":{"line":4,"character":0}}}]"#)
        #expect(DefinitionParsing.parse(array, root: root).count == 2)
        let links = json(#"[{"targetUri":"file:///work/proj/d.rs","targetRange":{"start":{"line":0,"character":0},"end":{"line":9,"character":0}},"targetSelectionRange":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}},"originSelectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]"#)
        #expect(DefinitionParsing.parse(links, root: root) == [.inWorkspace(path: "d.rs", range: range(2, 4, 2, 8))])
        #expect(DefinitionParsing.parse(.null, root: root).isEmpty)
        #expect(DefinitionParsing.parse(json("[]"), root: root).isEmpty)
    }

    @Test func externalTargetsAreMarkedExternal() {
        let outside = json(#"[{"uri":"file:///usr/lib/std.rs","range":{"start":{"line":7,"character":0},"end":{"line":7,"character":3}}},{"uri":"file:///work/proj-other/x.rs","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]"#)
        let targets = DefinitionParsing.parse(outside, root: root)
        #expect(targets == [.external(url: URL(fileURLWithPath: "/usr/lib/std.rs"), range: range(7, 0, 7, 3)),
                            .external(url: URL(fileURLWithPath: "/work/proj-other/x.rs"), range: range(0, 0, 0, 1))])
    }
}

@Suite
@MainActor
struct DefinitionRequestTests {
    private func rig(script: String) throws -> (URL, LSPManager) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-def-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let launcher = ServerLauncher { config, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = script
            env["FAKE_LSP_LOG"] = dir.appendingPathComponent("log.jsonl").path
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "fake", extensions: ["fk"], command: fakeServerPath)
        let manager = LSPManager(root: dir, registry: ServerRegistry(builtIn: [config]),
                                 locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }), launcher: launcher)
        return (dir, manager)
    }

    private func methods(_ dir: URL) -> [String] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue }
    }

    @Test func definitionIsRequestedAndParsed() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"definitionProvider":true},"definition":[{"uri":"file:///elsewhere/lib.fk","range":{"start":{"line":3,"character":1},"end":{"line":3,"character":4}}}]}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("one\ntwo\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        let targets = await manager.definition(path: "a.fk", utf8Offset: 5, snapshot: snapshot)
        await manager.shutdownAll()
        #expect(targets == [.external(url: URL(fileURLWithPath: "/elsewhere/lib.fk"), range: range(3, 1, 3, 4))])
        #expect(methods(dir).contains("textDocument/definition"))
    }

    @Test func serverWithoutDefinitionSupportAnswersNothing() async throws {
        let (dir, manager) = try rig(script: #"{"capabilities":{"textDocumentSync":2}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("one\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        #expect(await manager.definition(path: "a.fk", utf8Offset: 0, snapshot: snapshot).isEmpty)
        await manager.shutdownAll()
        #expect(!methods(dir).contains("textDocument/definition"))
    }

    @Test func requestCancelledWhenCaretMovesAgain() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"definitionProvider":true},"delayMs":600,"definition":null}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("one\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        let first = Task { await manager.definition(path: "a.fk", utf8Offset: 0, snapshot: snapshot) }
        // Wait until the server has the request, then abandon it as a second F12 does.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, !methods(dir).contains("textDocument/definition") { try await Task.sleep(for: .milliseconds(20)) }
        first.cancel()
        #expect(await first.value.isEmpty)
        let cancelDeadline = clock.now.advanced(by: .seconds(10))
        while clock.now < cancelDeadline, !methods(dir).contains("$/cancelRequest") { try await Task.sleep(for: .milliseconds(20)) }
        await manager.shutdownAll()
        #expect(methods(dir).contains("$/cancelRequest"))
    }

    @Test func documentChangedAfterTheCaretIsStale() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"definitionProvider":true},"definition":null}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let buffer = CodeBuffer("one\n")
        let before = buffer.snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: before)
        buffer.replace(0..<0, with: "x", origin: .typing)
        await manager.documentChanged(path: "a.fk", change: .resync(buffer.snapshot()))
        let outcome = await manager.definitionOutcome(path: "a.fk", utf8Offset: 0, snapshot: before)
        await manager.shutdownAll()
        #expect(outcome == .stale)
        #expect(!methods(dir).contains("textDocument/definition"))
    }
}
