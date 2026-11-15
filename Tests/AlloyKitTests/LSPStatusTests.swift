import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import AlloyLSPTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Observation
import Testing


private final class Processes: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ServerProcess] = []
    func add(_ p: ServerProcess) { lock.withLock { all.append(p) } }
    var running: Int { lock.withLock { all.filter(\.isRunning).count } }
}

/// A workspace with `main.rs` and a coordinator whose `.rs` server runs `command` (the scriptable fake by default).
@MainActor
private struct StatusRig {
    let rig = Rig()
    let coordinator: LSPCoordinator
    fileprivate let processes = Processes()

    static func run(command: String = fakeServerPath, _ body: (StatusRig) async throws -> Void) async throws {
        let r = try StatusRig(command: command)
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            throw error
        }
        await r.rig.workspace.stopAll()
    }

    init(command: String) throws {
        try "fn main() {}\n".write(to: rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        let processes = processes
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = #"{"capabilities":{"textDocumentSync":2}}"#
            let p = try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
            processes.add(p)
            return p
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: command)
        coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: [config],
                                             locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                             launcher: launcher)
    }

    func openWindow() async throws -> TestWindow {
        rig.workspace.openFilePath = "main.rs"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        return window
    }

    func wait(_ window: TestWindow, _ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            if clock.now >= deadline { Issue.record("timed out waiting for \(what)"); return }
            window.tick()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private func statusText(_ window: TestWindow) -> String? {
    guard let e = try? window.element(identifier: "file-panel-lsp-status") else { return nil }
    return e.label ?? e.value
}

@MainActor
@Suite
struct LSPStatusTests {
    @Test func headerShowsServerStates() async throws {
        try await StatusRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "ready") { statusText(window) == "Fake" }
            #expect(r.coordinator.status.byPath["main.rs"]?.state == .ready)
        }
        // The text of the transient and problem states.
        #expect(ServerStatusLabel.text("Fake", .starting) == "Fake starting\u{2026}")
        #expect(ServerStatusLabel.text("Fake", .notInstalled(command: "x")) == "Fake not installed")
        #expect(ServerStatusLabel.text("Fake", .failed(reason: "boom")) == "Fake failed")
        #expect(ServerStatusLabel.text("Fake", .stopped) == nil)
    }

    @Test func headerShowsStartingThenReadyOnTheModel() async throws {
        try await StatusRig.run { r in
            let window = try await r.openWindow()
            r.coordinator.status.set(path: "main.rs", name: "Fake", state: .starting)
            try await r.wait(window, "starting text") { statusText(window) == "Fake starting\u{2026}" }
            r.coordinator.status.set(path: "main.rs", name: "Fake", state: .ready)
            try await r.wait(window, "ready text") { statusText(window) == "Fake" }
        }
    }

    @Test func missingCommandShowsNotInstalled() async throws {
        try await StatusRig.run(command: "alloy-no-such-server-xyz") { r in
            let window = try await r.openWindow()
            try await r.wait(window, "not installed") { statusText(window) == "Fake not installed" }
        }
    }

    @Test func settingsToggleDisablesServer() async throws {
        try await StatusRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "ready") { statusText(window) == "Fake" }
            #expect(r.processes.running == 1)

            let settings = try window.openSettingsFromMenu()
            try await settings.runUntil { (try? settings.element(identifier: "settings-view")) != nil }
            try await settings.runUntil { (try? settings.element(identifier: "settings-lsp-fake")) != nil }
            try settings.click(settings.element(identifier: "settings-lsp-fake"))
            #expect(r.rig.workspace.settings.languageServers["fake"]?.enabled == false)

            try await r.wait(window, "server stopped") { r.processes.running == 0 && r.coordinator.status.byPath.isEmpty }
            settings.typeKey(.escape)
            try await window.runUntil { !window.settingsController.isOpen }
            #expect(statusText(window) == nil)

            // The setting reaches disk.
            let reloaded = AlloySettings.load(appSupport: r.rig.root.appendingPathComponent("support"))
            #expect(reloaded.languageServers["fake"]?.enabled == false)
        }
    }

    @Test func headerDoesNotRerunWhileTyping() async throws {
        try await StatusRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "ready") { statusText(window) == "Fake" }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            try window.click(window.element(identifier: "code-view"))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            window.typeText("a")   // the first edit marks the tab dirty, which legitimately re-runs the header once
            for _ in 0..<5 { window.tick(); await Task.yield() }
            let names = ["FilePanelHeader", "ServerStatusLabel"]
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                let before = names.map(BodyProbe.count)
                window.typeText("a"); window.tick()
                for (i, n) in names.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
                await Task.yield()
            }
            for n in names { #expect(reruns[n] == 0, "\(n) re-ran \(reruns[n]!) times") }
        }
    }
}


@MainActor
@Suite
struct LSPLinterStatusTests {
    typealias Linter = (id: String, name: String, state: ServerState)

    @Test func headerListsReadyLinters() {
        let main = (name: "Pyright", state: ServerState.ready)
        let linters: [Linter] = [("ruff", "Ruff", .ready)]
        #expect(ServerStatusLabel.text(main: main, linters: linters) == "Pyright \u{00B7} Ruff")
        #expect(ServerStatusLabel.text(main: main, linters: []) == "Pyright")
        #expect(ServerStatusLabel.text(main: nil, linters: linters) == "Ruff")
    }

    @Test func headerShowsFailedLinter() {
        let linters: [Linter] = [("ruff", "Ruff", .failed(reason: "boom")), ("flake", "Flake", .ready)]
        #expect(ServerStatusLabel.failedLinters(linters) == ["Ruff failed"])
        #expect(ServerStatusLabel.text(main: (name: "Pyright", state: .ready), linters: linters) == "Pyright \u{00B7} Flake")
    }

    @Test func missingLinterNotInHeader() {
        let linters: [Linter] = [("a", "A", .notInstalled(command: "a")), ("b", "B", .starting), ("c", "C", .stopped)]
        #expect(ServerStatusLabel.text(main: (name: "Pyright", state: .ready), linters: linters) == "Pyright")
        #expect(ServerStatusLabel.failedLinters(linters).isEmpty)
        #expect(ServerStatusLabel.text(main: nil, linters: linters) == nil)
    }

    @Test func modelLintersDontNotifyOnNoOps() {
        let model = LSPStatusModel()
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        var changes: Int { count.n }
        func watch() {
            withObservationTracking { _ = model.linters } onChange: { count.n += 1 }
        }
        watch()
        model.setLinter(path: "a.py", id: "ruff", name: "Ruff", state: .ready)
        #expect(changes == 1)
        watch()
        model.setLinter(path: "a.py", id: "ruff", name: "Ruff", state: .ready)
        #expect(changes == 1)
        model.removeLinter(path: "a.py", id: "nope")
        #expect(changes == 1)
        model.removeLinter(path: "a.py", id: "ruff")
        #expect(changes == 2)
        #expect(model.linters["a.py"] == nil)
    }

    @Test func coordinatorRoutesLinterStatusByServerID() {
        let configs = [
            ServerConfig(id: "main", name: "Main", languageID: "python", extensions: ["py"], command: "x"),
            ServerConfig(id: "lint", name: "Lint", languageID: "python", extensions: ["py"], command: "x", role: .linter),
        ]
        let coordinator = LSPCoordinator(root: URL(fileURLWithPath: "/tmp"), builtIn: configs,
                                         locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                         launcher: ServerLauncher { _, _, _ in throw CancellationError() })
        coordinator.openPaths.insert("a.py")
        coordinator.handle(.status(path: "a.py", serverID: "lint", serverName: "Lint", state: .ready))
        #expect(coordinator.status.byPath["a.py"] == nil)
        #expect(coordinator.status.linters["a.py"]?.map(\.name) == ["Lint"])
        coordinator.handle(.status(path: "a.py", serverID: "main", serverName: "Main", state: .ready))
        #expect(coordinator.status.byPath["a.py"]?.name == "Main")
        coordinator.handle(.status(path: "a.py", serverID: "lint", serverName: "Lint", state: .failed(reason: "x")))
        #expect(ServerStatusLabel.failedLinters(coordinator.status.linters["a.py"] ?? []) == ["Lint failed"])
        coordinator.handle(.status(path: "a.py", serverID: "lint", serverName: "Lint", state: .stopped))
        #expect(coordinator.status.linters["a.py"] == nil)
        // A server that does not serve the path is ignored.
        coordinator.handle(.status(path: "a.py", serverID: "other", serverName: "Other", state: .ready))
        #expect(coordinator.status.linters["a.py"] == nil)
    }

    @Test func coordinatorLintsAFileNoMainServerClaims() {
        let configs = [ServerConfig(id: "lint", name: "Lint", languageID: "shellscript", extensions: ["sh"], command: "x", role: .linter)]
        let coordinator = LSPCoordinator(root: URL(fileURLWithPath: "/tmp"), builtIn: configs,
                                         locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                         launcher: ServerLauncher { _, _, _ in throw CancellationError() })
        #expect(coordinator.wants("a.sh"))
        #expect(!coordinator.wants("a.txt"))
        coordinator.opened(path: "a.sh", snapshot: CodeBuffer("x\n").snapshot())
        #expect(coordinator.openPaths.contains("a.sh"))
        coordinator.handle(.status(path: "a.sh", serverID: "lint", serverName: "Lint", state: .ready))
        #expect(coordinator.status.byPath["a.sh"] == nil)
        #expect(coordinator.status.linters["a.sh"]?.map(\.name) == ["Lint"])
        #expect(ServerStatusLabel.text(main: nil, linters: coordinator.status.linters["a.sh"] ?? []) == "Lint")
    }

    @Test func reloadShowsKnownStateOfANewlyApplyingLinter() {
        let main = ServerConfig(id: "main", name: "Main", languageID: "python", extensions: ["py"], command: "x")
        var lint = ServerConfig(id: "lint", name: "Lint", languageID: "python", extensions: ["py"], command: "x", role: .linter)
        lint.enabled = false
        let coordinator = LSPCoordinator(root: URL(fileURLWithPath: "/tmp"), builtIn: [main, lint],
                                         locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                         launcher: ServerLauncher { _, _, _ in throw CancellationError() })
        coordinator.opened(path: "a.py", snapshot: CodeBuffer("x\n").snapshot())
        // The linter is running for another file, so its state is known.
        coordinator.handle(.status(path: "b.py", serverID: "lint", serverName: "Lint", state: .ready))
        #expect(coordinator.status.linters["a.py"] == nil)
        coordinator.reload(overrides: ["lint": ServerConfigOverride(enabled: true)])
        #expect(coordinator.status.linters["a.py"]?.map(\.name) == ["Lint"])
    }

    private func makeCoordinator() -> LSPCoordinator {
        let main = ServerConfig(id: "main", name: "Main", languageID: "python", extensions: ["py"], command: "x")
        let lint = ServerConfig(id: "lint", name: "Lint", languageID: "python", extensions: ["py"], command: "x", role: .linter)
        return LSPCoordinator(root: URL(fileURLWithPath: "/tmp"), builtIn: [main, lint],
                              locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                              launcher: ServerLauncher { _, _, _ in throw CancellationError() })
    }

    @Test func mainStoppedKeepsLintersInHeader() {
        let coordinator = makeCoordinator()
        coordinator.openPaths.insert("a.py")
        coordinator.handle(.status(path: "a.py", serverID: "main", serverName: "Main", state: .ready))
        coordinator.handle(.status(path: "a.py", serverID: "lint", serverName: "Lint", state: .ready))
        coordinator.handle(.status(path: "a.py", serverID: "main", serverName: "Main", state: .stopped))
        #expect(coordinator.status.byPath["a.py"] == nil)
        #expect(coordinator.status.linters["a.py"]?.map(\.name) == ["Lint"])
    }

    @Test func mainFailureLeavesDiagnosticsToTheManager() {
        let coordinator = makeCoordinator()
        coordinator.openPaths.insert("a.py")
        let item = LSPDiagnostic(range: 0..<1, severity: .warning, message: "l", source: "Lint")
        coordinator.handle(.diagnostics(path: "a.py", version: 1, items: [item]))
        coordinator.handle(.status(path: "a.py", serverID: "main", serverName: "Main", state: .failed(reason: "x")))
        #expect(coordinator.diagnostics.entry(for: "a.py")?.items.count == 1)
    }

    @Test func headerListsOnlyTheLintersThatRunForThePath() {
        let coordinator = makeCoordinator()
        coordinator.openPaths.insert("a.py")
        coordinator.handle(.status(path: "a.py", serverID: "lint", serverName: "Lint", state: .ready))
        #expect(coordinator.status.linters["a.py"]?.map(\.name) == ["Lint"])
        coordinator.handle(.linters(path: "a.py", ids: []))
        #expect(coordinator.status.linters["a.py"] == nil)
        coordinator.handle(.status(path: "a.py", serverID: "lint", serverName: "Lint", state: .ready))
        #expect(coordinator.status.linters["a.py"] == nil)
        coordinator.handle(.linters(path: "a.py", ids: ["lint"]))
        #expect(coordinator.status.linters["a.py"]?.map(\.name) == ["Lint"])
    }
}
