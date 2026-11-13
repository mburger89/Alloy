import AlloyCore
import AlloyLSPTestSupport
import Foundation
import Testing
@testable import AlloyLSP


/// Hands the launched process back to the test.
private final class LaunchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [ServerProcess] = []
    func add(_ p: ServerProcess) { lock.lock(); processes.append(p); lock.unlock() }
    var all: [ServerProcess] { lock.lock(); defer { lock.unlock() }; return processes }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private struct Harness {
    let server: LanguageServer
    let launches: LaunchBox
    let logURL: URL

    init(script: [String: JSONValue] = [:]) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-lsp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("log.jsonl")
        let scriptText = String(decoding: try JSONEncoder().encode(JSONValue.object(script)), as: UTF8.self)
        var env = ProcessInfo.processInfo.environment
        env["FAKE_LSP_SCRIPT"] = scriptText
        env["FAKE_LSP_LOG"] = logURL.path
        let launches = LaunchBox()
        self.launches = launches
        let environment = env
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "fake", command: fakeServerPath)
        server = LanguageServer(config: config, root: dir, launcher: {
            let p = try ServerProcess(executable: fakeServerPath, arguments: [], environment: environment, currentDirectory: dir)
            launches.add(p)
            return p
        }, now: { ContinuousClock.now })
    }

    init(script: [String: JSONValue], now: @escaping @Sendable () -> ContinuousClock.Instant) throws {
        let base = try Harness(script: script)
        // Rebuild with the injected clock, sharing the base directory and environment.
        logURL = base.logURL
        launches = LaunchBox()
        let launches = self.launches
        let dir = base.logURL.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["FAKE_LSP_SCRIPT"] = String(decoding: try JSONEncoder().encode(JSONValue.object(script)), as: UTF8.self)
        env["FAKE_LSP_LOG"] = logURL.path
        let environment = env
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "fake", command: fakeServerPath)
        server = LanguageServer(config: config, root: dir, launcher: {
            let p = try ServerProcess(executable: fakeServerPath, arguments: [], environment: environment, currentDirectory: dir)
            launches.add(p)
            return p
        }, now: now)
    }

    /// Parsed log lines.
    func log() -> [JSONValue] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    func methods() -> [String] { log().compactMap { $0["method"]?.stringValue } }

    func cleanup() { try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent()) }
}

/// Polls `condition` until true or `timeout`.
@Suite
struct LanguageServerTests {
    @Test func handshakeNegotiatesUTF8() async throws {
        let h = try Harness(script: ["capabilities": .object([
            "positionEncoding": .string("utf-8"),
            "textDocumentSync": .number(2),
            "definitionProvider": .bool(true),
        ])])
        defer { h.cleanup() }
        await h.server.start()
        #expect(await h.server.state == .ready)
        let caps = try #require(await h.server.capabilities)
        #expect(caps.positionEncoding == .utf8)
        #expect(caps.sync == .incremental)
        #expect(caps.definition)
        #expect(await waitUntil { h.methods().contains("initialized") })
        let methods = h.methods()
        #expect(methods.first == "initialize")
        #expect(methods.dropFirst().first == "initialized")
        let initialize = try #require(h.log().first)
        #expect(initialize["params"]?["clientInfo"]?["name"]?.stringValue == "Alloy")
        #expect(initialize["params"]?["capabilities"]?["general"]?["positionEncodings"]?.arrayValue?.count == 2)
        #expect(initialize["params"]?["workspaceFolders"]?.arrayValue?.count == 1)
        await h.server.shutdown()
    }

    @Test func defaultsToUTF16WhenServerSilent() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.server.start()
        let caps = try #require(await h.server.capabilities)
        #expect(caps.positionEncoding == .utf16)
        #expect(caps.sync == .none)
        #expect(!caps.definition)
        #expect(caps.semanticTokens == nil)
        await h.server.shutdown()
    }

    @Test func answersWorkspaceConfigurationWithNulls() async throws {
        let h = try Harness(script: ["serverRequests": .array([
            .object(["id": .number(900), "method": .string("workspace/configuration"),
                     "params": .object(["items": .array([.object([:]), .object([:])])])]),
            .object(["id": .number(901), "method": .string("window/workDoneProgress/create"), "params": .object([:])]),
            .object(["id": .number(902), "method": .string("client/registerCapability"), "params": .object([:])]),
            .object(["id": .number(903), "method": .string("workspace/workspaceFolders")]),
        ])])
        defer { h.cleanup() }
        await h.server.start()
        func reply(_ id: Int) -> JSONValue? { h.log().first { $0["id"]?.intValue == id && $0["method"] == nil } }
        #expect(await waitUntil { reply(900) != nil && reply(903) != nil })
        #expect(reply(900)?["result"] == .array([.null, .null]))
        #expect(reply(901)?["result"] == .null)
        #expect(reply(902)?["result"] == .null)
        #expect(reply(903)?["result"]?.arrayValue?.count == 1)
        await h.server.shutdown()
    }

    @Test func crashRestartsThenFails() async throws {
        let fixed = ContinuousClock.now
        let h = try Harness(script: ["crashAfter": .number(1)], now: { fixed })
        defer { h.cleanup() }
        let restarts = Counter()
        await h.server.setOnRestart { restarts.bump() }
        await h.server.start()
        let failed = await waitUntil {
            if case .failed = await h.server.state { return true }
            return false
        }
        #expect(failed)
        #expect(restarts.value <= 3)
        #expect(h.launches.all.count == 4)
        if case .failed(let reason) = await h.server.state {
            #expect(reason.contains("crashing after 1 messages"))
        }
        await h.server.shutdown()
    }

    @Test func successfulRestartCallsOnRestartExactlyOnce() async throws {
        let fixed = ContinuousClock.now
        let h = try Harness(script: ["crashAfter": .number(1), "crashLaunches": .number(1)], now: { fixed })
        defer { h.cleanup() }
        let restarts = Counter()
        await h.server.setOnRestart { restarts.bump() }
        await h.server.start()
        #expect(await waitUntil { restarts.value >= 1 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(restarts.value == 1)
        #expect(await h.server.state == .ready)
        #expect(h.launches.all.count == 2)
        await h.server.shutdown()
    }

    @Test func failedRestartDoesNotCallOnRestart() async throws {
        let fixed = ContinuousClock.now
        let h = try Harness(script: [
            "crashAfter": .number(1), "crashLaunches": .number(1), "exitOnInitializeFromLaunch": .number(2),
        ], now: { fixed })
        defer { h.cleanup() }
        let restarts = Counter()
        await h.server.setOnRestart { restarts.bump() }
        await h.server.start()
        #expect(await waitUntil {
            if case .failed = await h.server.state { return true }
            return false
        })
        #expect(restarts.value == 0)
        await h.server.shutdown()
    }

    @Test func crashDuringInitializeFollowsRestartPolicy() async throws {
        let fixed = ContinuousClock.now
        let h = try Harness(script: ["exitOnInitializeFromLaunch": .number(1)], now: { fixed })
        defer { h.cleanup() }
        let restarts = Counter()
        await h.server.setOnRestart { restarts.bump() }
        await h.server.start()
        #expect(await waitUntil {
            if case .failed = await h.server.state { return true }
            return false
        })
        #expect(h.launches.all.count == 4)  // first launch plus 3 restarts
        #expect(restarts.value == 0)
        if case .failed(let reason) = await h.server.state { #expect(reason.contains("dying during initialize")) }
        await h.server.shutdown()
    }

    @Test func shutdownIsBoundedWhenServerStopsReadingStdin() async throws {
        let h = try Harness(script: ["stallAfterInitialized": .bool(true)])
        defer { h.cleanup() }
        await h.server.start()
        let process = try #require(h.launches.all.first)
        let rpc = try await h.server.connection()
        let big = JSONValue.object(["text": .string(String(repeating: "x", count: 300_000))])
        for _ in 0..<4 { try await rpc.notify("textDocument/didChange", big) }
        try await Task.sleep(for: .milliseconds(300))  // let the writer block on the full pipe
        let clock = ContinuousClock()
        let start = clock.now
        await h.server.shutdown()
        #expect(start.duration(to: clock.now) < .seconds(6))
        #expect(!process.isRunning)
        #expect(await h.server.state == .stopped)
    }

    @Test func restartWindowForgetsOldCrashes() async throws {
        let base = ContinuousClock.now
        let offset = Counter()
        // Each restart looks 6 minutes after the previous one, so the budget never runs out.
        let h = try Harness(script: ["crashAfter": .number(1)], now: { base.advanced(by: .seconds(360 * offset.value)) })
        defer { h.cleanup() }
        let restarts = Counter()
        await h.server.setOnRestart { restarts.bump(); offset.bump() }
        await h.server.start()
        #expect(await waitUntil { restarts.value >= 5 })
        if case .failed = await h.server.state { Issue.record("should keep restarting") }
        await h.server.shutdown()
    }

    @Test func shutdownSendsShutdownThenExit() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        await h.server.start()
        let process = try #require(h.launches.all.first)
        await h.server.shutdown()
        #expect(await h.server.state == .stopped)
        var code: Int32?
        for await c in process.exited { code = c }
        #expect(code == 0)
        #expect(!process.isRunning)
        #expect(h.methods() == ["initialize", "initialized", "shutdown", "exit"])
    }

    @Test func missingCommandIsNotInstalled() async throws {
        let config = ServerConfig(id: "x", name: "X", languageID: "x", command: "definitely-not-a-real-lsp-binary")
        let server = LanguageServer(config: config, root: FileManager.default.temporaryDirectory, launcher: {
            try ServerProcess(executable: config.command, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                              currentDirectory: FileManager.default.temporaryDirectory)
        })
        await server.start()
        #expect(await server.state == .notInstalled(command: "definitely-not-a-real-lsp-binary"))
        await #expect(throws: LanguageServerError.self) { _ = try await server.connection() }
    }

    @Test func connectionServesRequests() async throws {
        let h = try Harness(script: ["definition": .object(["uri": .string("file:///x")])])
        defer { h.cleanup() }
        await h.server.start()
        let rpc = try await h.server.connection()
        let result = try await rpc.request("textDocument/definition", .object([:]))
        #expect(result["uri"]?.stringValue == "file:///x")
        await h.server.shutdown()
    }
}

@Suite struct ServerCapabilitiesTests {
    @Test func parsesSemanticTokensAndDiagnostics() {
        let caps = ServerCapabilities(json: .object([
            "positionEncoding": .string("utf-32"),
            "textDocumentSync": .object(["change": .number(1)]),
            "definitionProvider": .object([:]),
            "diagnosticProvider": .object(["interFileDependencies": .bool(false)]),
            "semanticTokensProvider": .object([
                "legend": .object(["tokenTypes": .array([.string("type")]), "tokenModifiers": .array([.string("static")])]),
                "full": .object(["delta": .bool(true)]),
            ]),
        ]))
        #expect(caps.positionEncoding == .utf32)
        #expect(caps.sync == .full)
        #expect(caps.definition)
        #expect(caps.pullDiagnostics)
        #expect(caps.semanticTokens == SemanticTokensLegend(tokenTypes: ["type"], tokenModifiers: ["static"]))
        #expect(caps.semanticTokensDelta)
    }

    @Test func unknownEncodingFallsBackToUTF16() {
        #expect(ServerCapabilities(json: .object(["positionEncoding": .string("utf-99")])).positionEncoding == .utf16)
    }
}
