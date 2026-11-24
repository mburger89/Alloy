import AlloyCore
@testable import AlloyLSP
import AlloyLSPTestSupport
import AlloyRPC
import Foundation
import Testing

@Suite
struct FakeRepliesTests {
    private func rig(script: String) async throws -> (URL, JSONRPCConnection, ServerProcess) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-replies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["FAKE_LSP_SCRIPT"] = script
        env["FAKE_LSP_LOG"] = dir.appendingPathComponent("log.jsonl").path
        let process = try ServerProcess(executable: fakeServerPath, arguments: [], environment: env, currentDirectory: dir)
        let connection = JSONRPCConnection(channel: process)
        await connection.start()
        await connection.onRequest { _, _ in .success(.null) }
        _ = try await connection.request("initialize", .object([:]))
        try await connection.notify("initialized", .object([:]))
        return (dir, connection, process)
    }

    private func logLines(_ dir: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private let hoverParams: JSONValue = .object(["textDocument": .object(["uri": .string("file:///a.fk")]),
                                                  "position": .object(["line": .number(0), "character": .number(0)])])

    @Test func repliesAreConsumedInOrderAndTheLastRepeats() async throws {
        let script = #"{"capabilities":{"hoverProvider":true},"replies":{"textDocument/hover":[{"error":{"code":-32801,"message":"modified"}},{"result":{"contents":"hi"}}]}}"#
        let (dir, connection, _) = try await rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            _ = try await connection.request("textDocument/hover", hoverParams)
            Issue.record("expected an error")
        } catch let error as JSONRPCError {
            #expect(error.code == -32801)
            #expect(error.message == "modified")
        }
        for _ in 0..<2 {
            let result = try await connection.request("textDocument/hover", hoverParams)
            #expect(result["contents"]?.stringValue == "hi")
        }
        await connection.close()
    }

    @Test func repliesWinOverTheOlderDefinitionKey() async throws {
        let script = #"{"definition":"old","replies":{"textDocument/definition":[{"result":"new"}]}}"#
        let (dir, connection, _) = try await rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try await connection.request("textDocument/definition", hoverParams)
        #expect(result.stringValue == "new")
        await connection.close()
    }

    @Test func delayMsDelaysTheReply() async throws {
        let script = #"{"replies":{"textDocument/hover":[{"result":null,"delayMs":300}]}}"#
        let (dir, connection, _) = try await rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ContinuousClock()
        let start = clock.now
        _ = try await connection.request("textDocument/hover", hoverParams)
        #expect(clock.now - start >= .milliseconds(300))
        await connection.close()
    }

    @Test func holdIsAnsweredOnlyAfterCancel() async throws {
        let script = #"{"replies":{"textDocument/hover":[{"hold":true}]}}"#
        let (dir, connection, _) = try await rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        let task = Task { try await connection.request("textDocument/hover", hoverParams, timeout: .seconds(1)) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, !logLines(dir).contains(where: { $0["method"]?.stringValue == "textDocument/hover" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Nothing is answered while held: the request would time out, so cancel it instead.
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = try? await task.value
        let cancelDeadline = clock.now.advanced(by: .seconds(10))
        while clock.now < cancelDeadline, !logLines(dir).contains(where: { $0["method"]?.stringValue == "$/cancelRequest" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(logLines(dir).contains { $0["method"]?.stringValue == "$/cancelRequest" })
        await connection.close()
    }

    @Test func afterRequestSendsAServerRequestWhoseAnswerIsLogged() async throws {
        let script = #"{"replies":{"textDocument/hover":[{"result":null}]},"afterRequest":{"textDocument/hover":[{"id":7,"method":"workspace/applyEdit","params":{"edit":{}}}]}}"#
        let (dir, connection, _) = try await rig(script: script)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await connection.request("textDocument/hover", hoverParams)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        func answered() -> Bool {
            logLines(dir).contains { $0["id"]?.intValue == 7 && $0["method"] == nil }
        }
        while clock.now < deadline, !answered() { try await Task.sleep(for: .milliseconds(20)) }
        #expect(answered())
        await connection.close()
    }
}
