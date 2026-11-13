import AlloyCore
import AlloyLSPTestSupport
import Foundation
import MetalUICodeBuffer
import Testing
@testable import AlloyLSP


private struct Rig {
    let dir: URL
    let launches = Launches()
    let manager: LSPManager
    let registry: ServerRegistry

    static func config(_ id: String, ext: String, command: String = fakeServerPath, arguments: [String] = []) -> ServerConfig {
        ServerConfig(id: id, name: "Fake \(id)", languageID: id, extensions: [ext], command: command, arguments: arguments)
    }

    init(configs: [ServerConfig], scripts: [String: String] = [:]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-mgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let launches = launches, dir = dir
        let launcher = ServerLauncher { config, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = scripts[config.id] ?? #"{"capabilities":{"textDocumentSync":2}}"#
            env["FAKE_LSP_LOG"] = dir.appendingPathComponent("\(config.id).jsonl").path
            let p = try ServerProcess(executable: resolved, arguments: config.arguments, environment: env, currentDirectory: root)
            launches.add(config.id, p)
            return p
        }
        registry = ServerRegistry(builtIn: configs)
        manager = LSPManager(root: dir, registry: registry, locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                             launcher: launcher)
    }

    func methods(_ id: String) -> [String] {
        let url = dir.appendingPathComponent("\(id).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue }
    }

    func openedURIs(_ id: String) -> [String] {
        let url = dir.appendingPathComponent("\(id).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
            .filter { $0["method"]?.stringValue == "textDocument/didOpen" }
            .compactMap { $0["params"]?["textDocument"]?["uri"]?.stringValue }
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// Runs `body`, then always stops the servers and removes the directory, also when `body` throws.
    @MainActor static func run(_ configs: [ServerConfig], scripts: [String: String] = [:],
                    _ body: @MainActor (Rig) async throws -> Void) async throws {
        let rig = try Rig(configs: configs, scripts: scripts)
        do { try await body(rig) } catch {
            await rig.manager.shutdownAll()
            rig.cleanup()
            throw error
        }
        await rig.manager.shutdownAll()
        rig.cleanup()
    }
}

@MainActor private func snap(_ text: String) -> CodeSnapshot { CodeBuffer(text).snapshot() }

@Suite
@MainActor
struct LSPManagerTests {
    @Test func startsServerLazilyOnFirstMatchingOpen() async throws {
        try await Rig.run([Rig.config("rust", ext: "rs")]) { rig in
            let seen = Collector(rig.manager.results)
            #expect(rig.launches.count() == 0)
            // A file no server handles starts nothing.
            await rig.manager.documentOpened(path: "notes.txt", snapshot: snap("hi"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.launches.count() == 0)
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("fn a() {}\n"))
            await rig.manager.documentOpened(path: "b.rs", snapshot: snap("fn b() {}\n"))
            #expect(await waitUntil { seen.states().contains(.ready) })
            #expect(await waitUntil { rig.openedURIs("rust").count == 2 })
            #expect(rig.launches.count() == 1)
        }
    }

    @Test func missingServerIsReportedOnceAndNotRetried() async throws {
        try await Rig.run([Rig.config("rust", ext: "rs", command: "/nonexistent/alloy-no-such-server")]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("x"))
            await rig.manager.documentOpened(path: "b.rs", snapshot: snap("y"))
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("x"))
            #expect(await waitUntil { !seen.states().isEmpty })
            try await Task.sleep(for: .milliseconds(200))
            #expect(seen.states() == [.notInstalled(command: "/nonexistent/alloy-no-such-server")])
            #expect(rig.launches.count() == 0)
        }
    }

    @Test func routesDocumentsToTheirServer() async throws {
        try await Rig.run([Rig.config("rust", ext: "rs"), Rig.config("go", ext: "go")]) { rig in
            await rig.manager.documentOpened(path: "src/a.rs", snapshot: snap("fn a() {}\n"))
            await rig.manager.documentOpened(path: "main.go", snapshot: snap("package main\n"))
            #expect(await waitUntil { rig.openedURIs("rust").count == 1 && rig.openedURIs("go").count == 1 })
            #expect(rig.openedURIs("rust").first?.hasSuffix("/src/a.rs") == true)
            #expect(rig.openedURIs("go").first?.hasSuffix("/main.go") == true)
            #expect(rig.launches.count("rust") == 1 && rig.launches.count("go") == 1)
            await rig.manager.documentClosed(path: "main.go")
            #expect(await waitUntil { rig.methods("go").contains("textDocument/didClose") })
            #expect(!rig.methods("rust").contains("textDocument/didClose"))
        }
    }

    @Test func shutdownAllStopsServers() async throws {
        try await Rig.run([Rig.config("rust", ext: "rs"), Rig.config("go", ext: "go")]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("fn a() {}\n"))
            await rig.manager.documentOpened(path: "main.go", snapshot: snap("package main\n"))
            #expect(await waitUntil { seen.states().filter { $0 == .ready }.count == 2 })
            await rig.manager.shutdownAll()
            #expect(rig.launches.all.allSatisfy { !$0.isRunning })
            #expect(rig.methods("rust").suffix(2) == ["shutdown", "exit"])
            #expect(seen.states().filter { $0 == .stopped }.count == 2)
            // Nothing starts afterwards.
            await rig.manager.documentOpened(path: "b.rs", snapshot: snap("x"))
            try await Task.sleep(for: .milliseconds(100))
            #expect(rig.launches.count() == 2)
        }
    }

    @Test func reloadRestartsChangedServers() async throws {
        let rust = Rig.config("rust", ext: "rs"), go = Rig.config("go", ext: "go")
        try await Rig.run([rust, go]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("fn a() {}\n"))
            await rig.manager.documentOpened(path: "main.go", snapshot: snap("package main\n"))
            #expect(await waitUntil { seen.states().filter { $0 == .ready }.count == 2 })
            // The two servers start from concurrent tasks, so the launch order is arbitrary: pick the old rust by id.
            let oldRust = try #require(rig.launches.processes("rust").first)

            // The same registry restarts nothing.
            await rig.manager.reload(registry: rig.registry)
            #expect(rig.launches.count() == 2)

            // A changed server restarts and re-opens its documents; the other one keeps running.
            var changed = rust
            changed.arguments = ["--changed"]
            await rig.manager.reload(registry: ServerRegistry(builtIn: [changed, go]))
            #expect(await waitUntil { rig.launches.count("rust") == 2 && rig.openedURIs("rust").count == 2 })
            #expect(rig.launches.count("go") == 1)
            // The old instance is gone before the new one starts: one process at a time, `.stopped` first.
            #expect(!oldRust.isRunning)
            #expect(rig.launches.all.filter { $0.isRunning }.count == 2)
            // `.ready` reaches the collector through two hops, so it can trail the logged didOpen.
            #expect(await waitUntil { seen.states("Fake rust").last == .ready }, "\(seen.states("Fake rust"))")
            let rustStates = seen.states("Fake rust")
            let stoppedAt = try #require(rustStates.firstIndex(of: .stopped))
            #expect(rustStates[(stoppedAt + 1)...].contains(.ready), "\(rustStates)")
            #expect(rustStates.last == .ready, "\(rustStates)")
            #expect(rig.openedURIs("go").count == 1)

            // A disabled server stops, and its documents leave.
            var disabled = go
            disabled.enabled = false
            await rig.manager.reload(registry: ServerRegistry(builtIn: [changed, disabled]))
            #expect(await waitUntil { rig.methods("go").suffix(2) == ["shutdown", "exit"] })
        }
    }

    @Test func hungInitializeDoesNotBlockShutdown() async throws {
        // Every reply of this server takes a minute, so `initialize` never completes.
        try await Rig.run([Rig.config("rust", ext: "rs")], scripts: ["rust": #"{"delayMs":60000}"#]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("fn a() {}\n"))
            #expect(await waitUntil { seen.states().contains(.starting) && rig.launches.count() == 1 })
            let clock = ContinuousClock()
            let began = clock.now
            await rig.manager.shutdownAll()
            #expect(began.duration(to: clock.now) < .seconds(8))
            #expect(rig.launches.all.allSatisfy { !$0.isRunning })
        }
    }

    @Test func slowStopOfOneServerDoesNotBlockOthers() async throws {
        // The rust server answers `shutdown` after 3 s (the manager waits at most 2 s for it).
        try await Rig.run([Rig.config("rust", ext: "rs"), Rig.config("go", ext: "go")],
                          scripts: ["rust": #"{"capabilities":{"textDocumentSync":2},"shutdownDelayMs":3000}"#]) { rig in
            let seen = Collector(rig.manager.results)
            let goBuffer = CodeBuffer("package main\n")
            let cursor = goBuffer.makeEditCursor()
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("fn a() {}\n"))
            await rig.manager.documentOpened(path: "main.go", snapshot: goBuffer.snapshot())
            #expect(await waitUntil { seen.states().filter { $0 == .ready }.count == 2 })
            var changed = Rig.config("rust", ext: "rs")
            changed.arguments = ["--changed"]
            let clock = ContinuousClock()
            let began = clock.now
            await rig.manager.reload(registry: ServerRegistry(builtIn: [changed, Rig.config("go", ext: "go")]))
            #expect(began.duration(to: clock.now) < .seconds(1), "reload waited for the stop")
            goBuffer.replace(0..<0, with: "// hi\n", origin: .typing)
            guard case .edits(let edits) = cursor.drain() else { Issue.record("no edits"); return }
            await rig.manager.documentChanged(path: "main.go", change: .edits(edits, after: goBuffer.snapshot()))
            #expect(await waitUntil(.seconds(1)) { rig.methods("go").contains("textDocument/didChange") })
            #expect(rig.launches.processes("rust").first?.isRunning == true, "the rust server was still being stopped")
            #expect(await waitUntil { rig.launches.count("rust") == 2 })
        }
    }

    @Test func reloadDuringFinishRestartMakesNoSecondInstance() async throws {
        let rust = Rig.config("rust", ext: "rs")
        try await Rig.run([rust]) { rig in
            let seen = Collector(rig.manager.results)
            await rig.manager.documentOpened(path: "a.rs", snapshot: snap("fn a() {}\n"))
            await rig.manager.documentOpened(path: "b.rs", snapshot: snap("fn b() {}\n"))
            #expect(await waitUntil { seen.states().contains(.ready) })
            var second = rust
            second.arguments = ["--second"]
            var thirdConfig = rust
            thirdConfig.arguments = ["--third"]
            let third = thirdConfig
            // While the restart for `second` opens its first document, a further reload arrives.
            let fired = Fired()
            await rig.manager.setRestartGate { [manager = rig.manager] in
                guard fired.once() else { return }
                await manager.reload(registry: ServerRegistry(builtIn: [third]))
            }
            await rig.manager.reload(registry: ServerRegistry(builtIn: [second]))
            #expect(await waitUntil(.seconds(15)) { rig.launches.count("rust") >= 3 })
            #expect(await waitUntil(.seconds(15)) { rig.openedURIs("rust").count >= 4 })
            try await Task.sleep(for: .milliseconds(500))
            // One launch per registry: the original, `second` (stopped again), `third`. Never a fourth.
            #expect(rig.launches.count("rust") == 3)
            #expect(rig.launches.processes("rust").filter { $0.isRunning }.count == 1, "two instances ran at once")
            #expect(rig.launches.overlaps == 0, "a replacement launched while the old instance still ran")
            await rig.manager.setRestartGate(nil)
        }
    }

    @Test func commandLookupDoesNotBlockTheManager() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-slow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The login-shell lookup takes a while (as `zsh -l` can).
        let locator = ServerLocator(loginPATH: { Thread.sleep(forTimeInterval: 1.5); return "/usr/bin:/bin" }, xcrunFind: { _ in nil })
        let launcher = ServerLauncher { _, _, _ in throw JSONRPCError.connectionClosed }
        let config = Rig.config("slow", ext: "sl", command: "definitely-not-installed-xyz")
        let manager = LSPManager(root: dir, registry: ServerRegistry(builtIn: [config]), locator: locator, launcher: launcher)
        let opening = Task { await manager.documentOpened(path: "a.sl", snapshot: snap("x\n")) }
        try await Task.sleep(for: .milliseconds(200))   // the lookup is under way
        let clock = ContinuousClock()
        let began = clock.now
        _ = await manager.resolvedCommandCount()   // any other command queued behind it
        #expect(began.duration(to: clock.now) < .milliseconds(500), "the actor was held by the lookup")
        await opening.value
        await manager.shutdownAll()
    }
}

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time only.
    func once() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
