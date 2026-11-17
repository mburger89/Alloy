import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import AlloyLSPTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// A workspace whose `.rs` and `.swift` files are served by the scriptable fake server, with a coordinator installed. The
/// script is the fake server's `FAKE_LSP_SCRIPT`; every message the server receives is logged.
@MainActor
struct IntelRig {
    let rig: Rig
    let coordinator: LSPCoordinator
    let log: URL

    /// A script whose server answers hover (and sync); `extra` adds keys such as `"replies":{...}` (with a leading comma).
    nonisolated static func script(caps: String = #""hoverProvider":true"#, extra: String = "") -> String {
        #"{"capabilities":{"textDocumentSync":2,\#(caps)}\#(extra)}"#
    }

    init(rig: Rig = Rig(), script: String) {
        self.rig = rig
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-intel-\(UUID().uuidString).jsonl")
        self.log = log
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = script
            env["FAKE_LSP_LOG"] = log.path
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let configs = [
            ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: fakeServerPath),
            ServerConfig(id: "fake-swift", name: "FakeSwift", languageID: "swift", extensions: ["swift"], command: fakeServerPath),
        ]
        coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: configs,
                                             locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                             launcher: launcher)
    }

    static func run(rig: Rig = Rig(), script: String, _ body: (IntelRig) async throws -> Void) async throws {
        let r = IntelRig(rig: rig, script: script)
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            try? FileManager.default.removeItem(at: r.log)
            throw error
        }
        await r.rig.workspace.stopAll()
        try? FileManager.default.removeItem(at: r.log)
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Opens `path` in Chat, waits for its server to be ready (and, when it offers hover, for the view to know), and clicks the view.
    func open(_ path: String) async throws -> TestWindow {
        rig.workspace.openFilePath = path
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try await window.runUntil { coordinator.status.byPath[path]?.state == .ready }
        try await window.runUntil { coordinator.features(for: path) != FeatureSet() }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        return window
    }

    /// Opens `path` that no server handles.
    func open2(_ path: String) async throws -> TestWindow {
        rig.workspace.openFilePath = path
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        return window
    }

    /// The methods the server received, in order.
    func methods() -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue }
    }

    func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    /// The point of the character at `offset` of `path`'s Chat view, read from where the view reports its caret.
    func point(of offset: Int, in path: String, window: TestWindow) async throws -> Point<Pixels> {
        let state = try #require(rig.workspace.selectionState(for: path, in: .chat))
        state.select(offset..<offset, reveal: false)
        for _ in 0..<5 { window.tick(); await Task.yield() }
        let area = try #require(window.platformWindow.textInputAreas.last)
        let rect = try #require(area)
        return Point(x: Pixels(rect.origin.x.value + 3), y: Pixels(rect.origin.y.value + rect.size.height.value / 2))
    }

    /// Rests the pointer on `point` past the 500 ms delay.
    func rest(at point: Point<Pixels>, in window: TestWindow) {
        window.hover(at: point)
        window.advance(by: 0.6)
    }

    /// The window, rig and typing target of `layout` of the frame guards (`CodeModePerformanceTests.rigged`) with a
    /// hover-capable fake server serving login.swift and other.swift, ready and known to the view.
    static func guardRig(layout: CodeModePerformanceTests.Layout, script: String = hoverScript())
        async throws -> (intel: IntelRig, window: TestWindow, codeViewID: String) {
        try await guardRig(layout: layout, scriptFor: { _ in script })
    }

    /// ``guardRig(layout:script:)`` with a script that depends on the workspace's rig (for locations under its root).
    static func guardRig(layout: CodeModePerformanceTests.Layout, scriptFor: @escaping (Rig) -> String)
        async throws -> (intel: IntelRig, window: TestWindow, codeViewID: String) {
        final class Box { var intel: IntelRig? }
        let box = Box()
        let (rig, window, id) = try await CodeModePerformanceTests().rigged(layout, install: { box.intel = IntelRig(rig: $0, script: scriptFor($0)) })
        let intel = try #require(box.intel)
        try await window.runUntil { intel.coordinator.status.byPath["login.swift"]?.state == .ready }
        try await window.runUntil { intel.coordinator.features(for: "login.swift").hover }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        _ = rig
        return (intel, window, id)
    }

    /// A script answering every hover with text.
    nonisolated static func hoverScript() -> String {
        script(extra: #","replies":{"textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}]}"#)
    }
}
