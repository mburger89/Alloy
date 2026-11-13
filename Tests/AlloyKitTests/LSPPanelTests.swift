import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import AlloyLSPTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing


private let sourceText = "fn main() {}\n"

private final class Processes: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ServerProcess] = []
    func add(_ p: ServerProcess) { lock.withLock { all.append(p) } }
    var launched: Int { lock.withLock { all.count } }
    var running: Int { lock.withLock { all.filter(\.isRunning).count } }
}

/// A workspace with `main.rs` and a coordinator whose `.rs` server is the scriptable fake.
@MainActor
private struct LSPRig {
    let rig = Rig()
    let coordinator: LSPCoordinator
    let logURL: URL
    fileprivate let processes = Processes()

    /// Runs `body`, then always stops the workspace (and so the fake servers), also when `body` throws.
    static func run(_ body: (LSPRig) async throws -> Void) async throws {
        let r = try LSPRig()
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            throw error
        }
        await r.rig.workspace.stopAll()
    }

    init() throws {
        try sourceText.write(to: rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        logURL = rig.root.appendingPathComponent("fake-lsp.jsonl")
        let log = logURL.path, processes = processes
        let launcher = ServerLauncher { config, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = #"{"capabilities":{"textDocumentSync":2}}"#
            env["FAKE_LSP_LOG"] = log
            let p = try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
            processes.add(p)
            return p
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: fakeServerPath)
        coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: [config],
                                             locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                             launcher: launcher)
    }

    private func lines(_ path: String) -> [JSONValue] {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }
    func methods() -> [String] {
        lines(logURL.path).compactMap { $0["method"]?.stringValue }
            .filter { $0.hasPrefix("textDocument/did") }
    }
    /// The fake's reconstructed text after each didOpen/didChange.
    func texts() -> [String] { lines(logURL.path + ".docs").compactMap { $0["text"]?.stringValue } }

    func openWindow() async throws -> TestWindow {
        rig.workspace.openFilePath = "main.rs"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        return window
    }

    /// Ticks the window until `condition` holds (the language server runs in another process).
    func wait(_ window: TestWindow, _ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            if clock.now >= deadline { Issue.record("timed out waiting for \(what); log: \(methods())"); return }
            window.tick()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private func probed(_ names: [String], _ reruns: inout [String: Int], _ body: () -> Void) {
    let before = names.map(BodyProbe.count)
    body()
    for (i, n) in names.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
}

@MainActor
@Suite
struct LSPPanelTests {
    @Test func typingInPanelReachesServer() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "didOpen") { r.methods().contains("textDocument/didOpen") }
            try window.click(window.element(identifier: "code-view"))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            window.typeText("zq")
            try await r.wait(window, "didChange") { r.methods().contains("textDocument/didChange") }
            try await r.wait(window, "typed text") { r.texts().last?.contains("zq") == true }
            let methods = r.methods()
            #expect(methods.first == "textDocument/didOpen")
            #expect(methods.contains("textDocument/didChange"))
            #expect(try #require(methods.firstIndex(of: "textDocument/didOpen")) < #require(methods.firstIndex(of: "textDocument/didChange")))
            #expect(r.texts().first == sourceText)
            #expect(r.texts().last?.count == sourceText.count + 2)
        }
    }

    @Test func savingSendsDidSave() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "didOpen") { r.methods().contains("textDocument/didOpen") }
            try window.click(window.element(identifier: "code-view"))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            window.typeText("q")
            try await r.rig.workspace.save("main.rs")
            try await r.wait(window, "didSave") { r.methods().contains("textDocument/didSave") }
            // The save follows the edits it saved.
            #expect(r.methods() == ["textDocument/didOpen", "textDocument/didChange", "textDocument/didSave"])
        }
    }

    @Test func closingTabSendsDidClose() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "didOpen") { r.methods().contains("textDocument/didOpen") }
            await r.rig.workspace.close("main.rs")
            try await r.wait(window, "didClose") { r.methods().contains("textDocument/didClose") }
            #expect(r.methods() == ["textDocument/didOpen", "textDocument/didClose"])
        }
    }

    @Test func quittingStopsTheServer() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "didOpen") { r.methods().contains("textDocument/didOpen") }
            #expect(r.processes.running == 1)
            await r.rig.workspace.stopAll()
            let all = (try? String(contentsOf: r.logURL, encoding: .utf8)) ?? ""
            #expect(all.contains("\"shutdown\"") && all.contains("\"exit\""))
            #expect(r.processes.running == 0, "the server process is still alive after quit")
            #expect(r.coordinator.status.byPath.isEmpty)
        }
    }

    @Test func statusModelShowsTheServerState() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "ready") { r.coordinator.status.byPath["main.rs"]?.state == .ready }
            #expect(r.coordinator.status.byPath["main.rs"]?.name == "Fake")
        }
    }

    @Test func settingsChangeRestartsTheServer() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "ready") { r.coordinator.status.byPath["main.rs"]?.state == .ready }
            var settings = r.rig.workspace.settings
            settings.languageServers["fake"] = ServerConfigOverride(arguments: ["--changed"])
            try r.rig.workspace.updateSettings(settings)
            try await r.wait(window, "second didOpen") { r.methods().filter { $0 == "textDocument/didOpen" }.count == 2 }
            try await r.wait(window, "restart settled") {
                r.processes.launched == 2 && r.processes.running == 1 && r.coordinator.status.byPath["main.rs"]?.state == .ready
            }
            // A late `.stopped` of the old instance would clear the new one's status; give it time to arrive.
            for _ in 0..<15 { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(r.coordinator.status.byPath["main.rs"]?.state == .ready)
            #expect(r.processes.running == 1)
        }
    }

    @Test func fileWithoutServerCreatesNoManager() async throws {
        try await LSPRig.run { r in
            try "hello\n".write(to: r.rig.root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            r.rig.workspace.openFilePath = "notes.txt"
            let window = try alloyWindow(r.rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            #expect(!r.coordinator.hasManager)
            #expect(r.processes.launched == 0)
        }
    }

    @Test func fileOverTheSizeCapReachesNoServer() async throws {
        try await LSPRig.run { r in
            let cap = 1_048_576
            let line = String(repeating: "a", count: 99) + "\n"
            let big = String(repeating: line, count: cap / 100 + 1)   // just over the cap
            try big.write(to: r.rig.root.appendingPathComponent("big.rs"), atomically: true, encoding: .utf8)
            r.rig.workspace.openFilePath = "big.rs"
            let window = try alloyWindow(r.rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            let doc = try #require(r.rig.workspace.document("big.rs"))
            #expect(doc.buffer.snapshot().utf8Count > cap)
            for _ in 0..<10 { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            // No manager, no status entry, no process, and typing sends nothing.
            #expect(!r.coordinator.hasManager)
            #expect(r.coordinator.status.byPath.isEmpty)
            doc.buffer.replace(0..<0, with: "x", origin: .typing)
            for _ in 0..<10 { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(!r.coordinator.hasManager)
            #expect(r.processes.launched == 0)

            // Shrinking below the cap opens it.
            let over = doc.buffer.snapshot().utf8Count - cap
            doc.buffer.replace(0..<(over + 100), with: "", origin: .typing)
            #expect(doc.buffer.snapshot().utf8Count <= cap)
            try await r.wait(window, "didOpen after shrinking") { r.methods().contains("textDocument/didOpen") }
            #expect(r.coordinator.hasManager)

            // Growing past the cap closes it again, and later edits are not sent.
            doc.buffer.replace(0..<0, with: String(repeating: "b", count: 200), origin: .typing)
            try await r.wait(window, "didClose after growing") { r.methods().contains("textDocument/didClose") }
            let before = r.methods()
            doc.buffer.replace(0..<0, with: "c", origin: .typing)
            for _ in 0..<15 { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(r.methods() == before)
            #expect(before == ["textDocument/didOpen", "textDocument/didClose"])
        }
    }

    @Test func typingWithServerActiveDoesNotRerunScreenBodies() async throws {
        try await LSPRig.run { r in
            let window = try await r.openWindow()
            try await r.wait(window, "ready") { r.coordinator.status.byPath["main.rs"]?.state == .ready }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            try window.click(window.element(identifier: "code-view"))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            let names = ["SidebarView", "AlloyScreen", "FilePanelView", "ChatView", "ChatColumn", "CodePanel"]
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                probed(names, &reruns) { window.typeText("a"); window.tick() }
                await Task.yield()
            }
            try await r.wait(window, "all typing") { r.texts().last?.count == sourceText.count + 20 }
            for n in names { #expect(reruns[n] == 0, "\(n) re-ran \(reruns[n]!) times") }
        }
    }
}
