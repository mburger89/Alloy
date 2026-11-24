@testable import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized) struct PluginEventTests {
    private static let reader = "dev.test.reader"
    private static let watcher = "dev.test.watcher"

    private func make(clock: any AutosaveClock = SystemAutosaveClock()) async throws -> PluginRig {
        let rig = Rig()
        try "let a = 1\n".write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        try "let b = 2\n".write(to: rig.root.appendingPathComponent("other.swift"), atomically: true, encoding: .utf8)
        var limits = PluginLimits()
        limits.messagesPerSecond = 100_000
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], clock: clock, limits: limits)
        await rig.workspace.restoreUIState()
        return p
    }

    private func log(_ folder: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private func entries(_ folder: URL, _ method: String) -> [JSONValue] { log(folder).filter { $0["method"]?.stringValue == method } }

    private func eventually(_ what: String = "condition", _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "timed out waiting for \(what)")
    }

    private func uri(_ p: PluginRig, _ name: String) -> String {
        URL(fileURLWithPath: p.rig.root.path + "/" + name).absoluteString
    }

    @Test func documentEventsReachOnlyProjectReadPlugins() async throws {
        let p = try await make()
        let a = try p.fake(Self.reader, permissions: ["project.read"])
        let b = try p.fake(Self.watcher, permissions: ["sessions.read"])
        for id in [Self.reader, Self.watcher] { _ = await p.coordinator.activate(plugin: id, .command) }
        await p.rig.workspace.open("login.swift")
        await eventually("opened") { !entries(a, "document/opened").isEmpty }
        let opened = try #require(entries(a, "document/opened").first?["params"])
        #expect(opened["uri"]?.stringValue == uri(p, "login.swift"))
        #expect(opened["languageId"]?.stringValue == "swift")
        #expect(opened["version"]?.intValue != nil)
        let doc = try #require(p.rig.workspace.document("login.swift"))
        _ = doc.buffer.replace(0..<0, with: "// x\n")
        try await p.rig.workspace.save("login.swift")
        await eventually("saved") { !entries(a, "document/saved").isEmpty }
        #expect(entries(a, "document/saved").first?["params"]?["uri"]?.stringValue == uri(p, "login.swift"))
        await p.rig.workspace.close("login.swift")
        await eventually("closed") { !entries(a, "document/closed").isEmpty }
        #expect(log(b).compactMap { $0["method"]?.stringValue }.allSatisfy { !$0.hasPrefix("document/") })
        await p.coordinator.shutdown()
    }

    @Test func startedPluginGetsOpenDocumentsReplayed() async throws {
        let p = try await make()
        let a = try p.fake(Self.reader, permissions: ["project.read"])
        await p.rig.workspace.open("login.swift")
        await p.rig.workspace.open("other.swift")
        _ = await p.coordinator.activate(plugin: Self.reader, .command)
        await eventually("replay") { entries(a, "document/opened").count >= 2 }
        let uris = Set(entries(a, "document/opened").compactMap { $0["params"]?["uri"]?.stringValue })
        #expect(uris == [uri(p, "login.swift"), uri(p, "other.swift")])
        await p.coordinator.shutdown()
    }

    @Test func onLanguageStartsPluginOnOpen() async throws {
        let p = try await make()
        let a = try p.fake(Self.reader, permissions: ["project.read"], activation: ["onLanguage:swift"])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await p.coordinator.host?.state(of: Self.reader) != .running, "not started before a swift document opens")
        await p.rig.workspace.open("notes.txt")
        #expect(await p.coordinator.host?.state(of: Self.reader) != .running)
        await p.rig.workspace.open("login.swift")
        await eventually("started by the open") { !entries(a, "document/opened").isEmpty }
        #expect(await p.coordinator.host?.state(of: Self.reader) == .running)
        #expect(entries(a, "document/opened").first?["params"]?["uri"]?.stringValue == uri(p, "login.swift"))
        await p.coordinator.shutdown()
    }

    @Test func sessionEventsReachOnlySessionsReadPlugins() async throws {
        let p = try await make()
        let a = try p.fake(Self.watcher, permissions: ["sessions.read"])
        let b = try p.fake(Self.reader, permissions: ["project.read"])
        for id in [Self.reader, Self.watcher] { _ = await p.coordinator.activate(plugin: id, .command) }
        let s = await p.rig.workspace.newSession(name: "Ada")
        await p.rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1,
                                                          outputTokens: 1, sessionID: "x", terminalReason: nil)))
        await eventually("turnEnded") { !entries(a, "session/turnEnded").isEmpty }
        let params = try #require(entries(a, "session/turnEnded").first?["params"])
        #expect(params["sessionId"]?.stringValue == s.id.uuidString)
        #expect(params["isError"]?.boolValue == false)
        #expect(params["agent"]?.stringValue == "claude")
        await p.rig.workspace.stop(s.id)
        await eventually("ended") { !entries(a, "session/ended").isEmpty }
        #expect(entries(a, "session/ended").first?["params"]?["agent"]?.stringValue == "claude")
        #expect(log(b).compactMap { $0["method"]?.stringValue }.allSatisfy { !$0.hasPrefix("session/") })
        await p.coordinator.shutdown()
    }

    @Test func toolUsedCarriesPaths() async throws {
        let p = try await make()
        let a = try p.fake(Self.watcher, permissions: ["sessions.read"])
        _ = await p.coordinator.activate(plugin: Self.watcher, .command)
        let s = await p.rig.workspace.newSession(name: "Ada")
        let input: JSONValue = .object(["file_path": .string(p.rig.root.appendingPathComponent("login.swift").path)])
        let request = HookRequest(event: .postToolUse, toolName: "Write", toolUseID: "t1", toolInput: input, cliSessionID: "c")
        _ = await p.rig.workspace.answerHook(request, MCPCaller(sessionID: s.id))
        await eventually("toolUsed") { !entries(a, "claude/toolUsed").isEmpty }
        let params = try #require(entries(a, "claude/toolUsed").first?["params"])
        #expect(params["toolName"]?.stringValue == "Write")
        #expect(params["paths"]?.arrayValue?.compactMap(\.stringValue) == ["login.swift"])
        await p.coordinator.shutdown()
    }

    @Test func documentTextReturnsBufferAndVersion() async throws {
        let p = try await make()
        await p.rig.workspace.open("login.swift")
        let doc = try #require(p.rig.workspace.document("login.swift"))
        let request = JSONValue.object(["method": .string("document/text"), "id": .number(7),
                                        "params": .object(["uri": .string(uri(p, "login.swift"))])])
        let a = try p.fake(Self.reader, script: .object(["afterInitialized": .array([request])]), permissions: ["project.read"])
        _ = await p.coordinator.activate(plugin: Self.reader, .command)
        await eventually("answer") { log(a).contains { $0["id"]?.intValue == 7 } }
        let answer = try #require(log(a).first { $0["id"]?.intValue == 7 })
        #expect(answer["result"]?["text"]?.stringValue == "let a = 1\n")
        #expect(answer["result"]?["version"]?.intValue == Int(doc.buffer.version))
        await p.coordinator.shutdown()
    }

    @Test func documentTextForClosedUriFails() async throws {
        let p = try await make()
        let request = JSONValue.object(["method": .string("document/text"), "id": .number(8),
                                        "params": .object(["uri": .string(uri(p, "other.swift"))])])
        let a = try p.fake(Self.reader, script: .object(["afterInitialized": .array([request])]), permissions: ["project.read"])
        _ = await p.coordinator.activate(plugin: Self.reader, .command)
        await eventually("answer") { log(a).contains { $0["id"]?.intValue == 8 } }
        let answer = try #require(log(a).first { $0["id"]?.intValue == 8 })
        #expect(answer["error"]?["code"]?.intValue == -32012)
        await p.coordinator.shutdown()
    }

    @Test func showMessagePostsANoticeAtMostEvery5s() async throws {
        let clock = ManualClock()
        let todo = "dev.test.todo"
        let p = try await make(clock: clock)
        let script: JSONValue = .object(["onReceive": .object(["test/ping": .array([
            .object(["method": .string("window/showMessage"), "params": .object(["type": .string("info"), "message": .string("hi")])])])])])
        let a = try p.fake(todo, script: script)
        _ = await p.coordinator.activate(plugin: todo, .command)
        let ws = p.rig.workspace
        func pings() -> Int { entries(a, "test/ping").count }
        p.coordinator.notifyPlugin(todo, "test/ping", nil)
        await eventually("first notice") { ws.notices.count == 1 }
        #expect(ws.notices.first?.text == "\(todo): hi")
        clock.advance(by: 1)
        p.coordinator.notifyPlugin(todo, "test/ping", nil)
        await eventually("second ping") { pings() == 2 }
        await eventually("dropped and logged") { !(p.coordinator.commandErrors[todo] ?? []).isEmpty }
        #expect(ws.notices.count == 1)
        clock.advance(by: 5)
        p.coordinator.notifyPlugin(todo, "test/ping", nil)
        await eventually("third notice") { ws.notices.count == 2 }
        await p.coordinator.shutdown()
    }

    @Test func typingSendsNoEvents() async throws {
        final class Keeper { var rigs: [PluginRig] = []; var folders: [URL] = [] }
        let keeper = Keeper()
        let perf = CodeModePerformanceTests()
        try await perf.guardTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, install: { rig in
            var limits = PluginLimits()
            limits.messagesPerSecond = 100_000
            let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], limits: limits)
            keeper.rigs.append(p)
            if let folder = try? p.fake(Self.reader, permissions: ["project.read", "sessions.read"]) { keeper.folders.append(folder) }
            Task { @MainActor in _ = await p.coordinator.activate(plugin: Self.reader, .command) }
        })
        let folder = try #require(keeper.folders.first)
        try await Task.sleep(for: .milliseconds(300))
        let methods = log(folder).compactMap { $0["method"]?.stringValue }
        // The handshake and the document that was open: nothing per keystroke (the 20 typed frames leave no event).
        let allowed: Set<String> = ["initialize", "initialized", "workspace/opened", "document/opened"]
        #expect(Set(methods).isSubset(of: allowed), "\(methods)")
        #expect(methods.filter { $0 == "document/opened" }.count <= 2)
        for p in keeper.rigs { await p.coordinator.shutdown() }
    }
}
