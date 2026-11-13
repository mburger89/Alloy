import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import AlloyLSPTestSupport
import Foundation
import MetalUI
import MetalUITesting
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

            try window.openSettingsFromMenu()
            try await window.runUntil { (try? window.element(identifier: "settings-view")) != nil }
            try await window.runUntil { (try? window.element(identifier: "settings-lsp-fake")) != nil }
            try window.click(window.element(identifier: "settings-lsp-fake"))
            #expect(r.rig.workspace.settings.languageServers["fake"]?.enabled == false)

            try await r.wait(window, "server stopped") { r.processes.running == 0 && r.coordinator.status.byPath.isEmpty }
            window.typeKey(.escape)
            try await window.runUntil { (try? window.element(identifier: "settings-view")) == nil }
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
