import AlloyCore
@testable import AlloyLSP
import AlloyLSPTestSupport
import AlloyRPC
import Foundation
import MetalUICodeBuffer
import Testing

private func json(_ text: String) -> JSONValue { JSONValue.parse(Data(text.utf8))! }
private func r(_ s: Int, _ e: Int) -> FoldRange { FoldRange(startLine: s, endLine: e) }

struct FoldingRangeParsingTests {
    @Test func parsesRangesAndIgnoresKinds() {
        let result = json(#"[{"startLine":1,"endLine":4,"kind":"region"},{"startLine":0,"endLine":9}]"#)
        #expect(FoldingRangeParsing.parse(result, lineCount: 10) == [r(0, 9), r(1, 4)])
    }

    @Test func dropsInvalidClampsAndDedupes() {
        let result = json(#"[{"startLine":3,"endLine":3},{"startLine":5,"endLine":2},{"startLine":2,"endLine":500},{"startLine":2,"endLine":6},{"startLine":"x"}]"#)
        #expect(FoldingRangeParsing.parse(result, lineCount: 8) == [r(2, 7)])
    }

    @Test func nullAndGarbageAreEmpty() {
        #expect(FoldingRangeParsing.parse(.null, lineCount: 10).isEmpty)
        #expect(FoldingRangeParsing.parse(json("{}"), lineCount: 10).isEmpty)
        #expect(FoldingRangeParsing.parse(json(#""x""#), lineCount: 10).isEmpty)
    }
}

struct ServerCapabilitiesFoldingTests {
    @Test func capabilityDetected() {
        #expect(ServerCapabilities(json: json(#"{"capabilities":{"foldingRangeProvider":true}}"#)).foldingRange)
        #expect(ServerCapabilities(json: json(#"{"capabilities":{"foldingRangeProvider":{}}}"#)).foldingRange)
        #expect(!ServerCapabilities(json: json(#"{"capabilities":{}}"#)).foldingRange)
        #expect(!ServerCapabilities(json: json(#"{"capabilities":{"foldingRangeProvider":false}}"#)).foldingRange)
    }

    @Test func clientAdvertisesFoldingRange() {
        let caps = LanguageServer.clientCapabilities
        #expect(caps["textDocument"]?["foldingRange"]?["lineFoldingOnly"] == .bool(true))
    }
}

@Suite
@MainActor
struct FoldingRangeRequestTests {
    private func rig(script: String) throws -> (URL, LSPManager) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let launcher = ServerLauncher { _, resolved, root in
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

    @Test func foldingRangesAreRequestedAndParsed() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"foldingRangeProvider":true},"foldingRanges":[{"startLine":0,"endLine":2},{"startLine":1,"endLine":1}]}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("a\n b\n c\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        let outcome = await manager.foldingRanges(path: "a.fk", snapshot: snapshot)
        await manager.shutdownAll()
        #expect(outcome == .answered([r(0, 2)]))
        #expect(methods(dir).contains("textDocument/foldingRange"))
    }

    @Test func serverWithoutSupportIsUnavailableAndNotAsked() async throws {
        let (dir, manager) = try rig(script: #"{"capabilities":{"textDocumentSync":2}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("a\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        let outcome = await manager.foldingRanges(path: "a.fk", snapshot: snapshot)
        await manager.shutdownAll()
        #expect(outcome == .unavailable)
        #expect(!methods(dir).contains("textDocument/foldingRange"))
    }

    @Test func untrackedPathIsUnavailable() async throws {
        let (dir, manager) = try rig(script: #"{"capabilities":{"textDocumentSync":2,"foldingRangeProvider":true}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = await manager.foldingRanges(path: "nope.fk", snapshot: CodeBuffer("a\n").snapshot())
        await manager.shutdownAll()
        #expect(outcome == .unavailable)
    }

    @Test func documentChangedBeforeTheRequestIsStale() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"foldingRangeProvider":true},"foldingRanges":[]}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let buffer = CodeBuffer("one\n")
        let before = buffer.snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: before)
        buffer.replace(0..<0, with: "x", origin: .typing)
        await manager.documentChanged(path: "a.fk", change: .resync(buffer.snapshot()))
        let outcome = await manager.foldingRanges(path: "a.fk", snapshot: before)
        await manager.shutdownAll()
        #expect(outcome == .stale)
        #expect(!methods(dir).contains("textDocument/foldingRange"))
    }

    @Test func cancelledRequestIsUnavailableAndCancelsOnTheServer() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"foldingRangeProvider":true},"holdFoldingRanges":true}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("a\n b\n").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        let task = Task { await manager.foldingRanges(path: "a.fk", snapshot: snapshot) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, !methods(dir).contains("textDocument/foldingRange") { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        #expect(await task.value == .unavailable)
        let cancelDeadline = clock.now.advanced(by: .seconds(10))
        while clock.now < cancelDeadline, !methods(dir).contains("$/cancelRequest") { try await Task.sleep(for: .milliseconds(20)) }
        await manager.shutdownAll()
        #expect(methods(dir).contains("$/cancelRequest"))
    }

    @Test func rangesBeyondTheDocumentAreClamped() async throws {
        let script = #"{"capabilities":{"textDocumentSync":2,"foldingRangeProvider":true},"foldingRanges":[{"startLine":0,"endLine":99}]}"#
        let (dir, manager) = try rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshot = CodeBuffer("a\nb\nc").snapshot()
        await manager.documentOpened(path: "a.fk", snapshot: snapshot)
        let outcome = await manager.foldingRanges(path: "a.fk", snapshot: snapshot)
        await manager.shutdownAll()
        #expect(outcome == .answered([r(0, 2)]))
    }
}
