import AlloyCore
@testable import AlloyKit
import AlloyLSP
import AlloyLSPTestSupport
import AlloyRPC
import AlloyTestSupport
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
        try await window.runUntil { intel.coordinator.features(for: "login.swift") != FeatureSet() }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        _ = rig
        return (intel, window, id)
    }

    /// A script answering every hover with text.
    nonisolated static func hoverScript() -> String {
        script(extra: #","replies":{"textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}]}"#)
    }
}

extension IntelRig {
    /// A script whose server offers completion (triggering on `.`, resolving) and, with `hover`, hover. `completion` and
    /// `resolve` are the entries of the two `replies` lists (JSON objects such as `{"result":[...]}`).
    nonisolated static func completionScript(hover: Bool = false, completion: String = #"{"result":[]}"#, resolve: String? = nil,
                                             extra: String = "") -> String {
        var caps = #""completionProvider":{"triggerCharacters":["."],"resolveProvider":\#(resolve != nil)}"#
        if hover { caps += #","hoverProvider":true"# }
        var replies = #""textDocument/completion":[\#(completion)]"#
        if let resolve { replies += #","completionItem/resolve":[\#(resolve)]"# }
        if hover { replies += #","textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}]"# }
        return script(caps: caps, extra: #","replies":{\#(replies)}\#(extra)"#)
    }

    /// How many `method` requests the server received.
    func count(_ method: String) -> Int { methods().filter { $0 == method }.count }

    /// Ticks the window for about `seconds` of real time.
    func idle(_ window: TestWindow, _ seconds: Double = 0.25) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { window.tick(); try? await Task.sleep(for: .milliseconds(20)) }
    }
}

extension IntelRig {
    /// A script whose server offers signature help (`(` triggers, `,` retriggers) and, with `completion`, completion. `answers`
    /// are the entries of the `textDocument/signatureHelp` replies.
    nonisolated static func signatureScript(answers: String, completion: String? = nil) -> String {
        var caps = #""signatureHelpProvider":{"triggerCharacters":["("],"retriggerCharacters":[","]}"#
        var replies = #""textDocument/signatureHelp":[\#(answers)]"#
        if let completion {
            caps += #","completionProvider":{"triggerCharacters":["."]}"#
            replies += #","textDocument/completion":[\#(completion)]"#
        }
        return script(caps: caps, extra: #","replies":{\#(replies)}"#)
    }

    /// One `SignatureHelp` reply entry: `signatures` are `(label, [parameter labels])` with string parameter labels.
    nonisolated static func signatureAnswer(_ signatures: [(String, [String])], active: Int = 0, activeSignature: Int = 0, delayMs: Int = 0) -> String {
        let list = signatures.map { label, params in
            #"{"label":"\#(label)","parameters":[\#(params.map { #"{"label":"\#($0)"}"# }.joined(separator: ","))]}"#
        }.joined(separator: ",")
        return #"{"result":{"signatures":[\#(list)],"activeSignature":\#(activeSignature),"activeParameter":\#(active)},"delayMs":\#(delayMs)}"#
    }
}

extension IntelRig {
    /// A script whose server offers rename (with `prepareRename` unless `prepare` is nil), hover when `hover`, and answers
    /// `rename` (a reply entry such as `{"result":null}`) to the rename request.
    nonisolated static func renameScript(prepare: String? = #"{"result":{"defaultBehavior":true}}"#, rename: String = #"{"result":null}"#,
                                         hover: Bool = false, completion: Bool = false) -> String {
        var caps = prepare != nil ? #""renameProvider":{"prepareProvider":true}"# : #""renameProvider":true"#
        var replies = #""textDocument/rename":[\#(rename)]"#
        if let prepare { replies += #","textDocument/prepareRename":[\#(prepare)]"# }
        if hover {
            caps += #","hoverProvider":true"#
            replies += #","textDocument/hover":[{"result":{"contents":{"kind":"markdown","value":"**docs**"}}}]"#
        }
        if completion {
            caps += #","completionProvider":{"triggerCharacters":["."]}"#
            replies += #","textDocument/completion":[{"result":[{"label":"alpha"},{"label":"alphabet"}]}]"#
        }
        return script(caps: caps, extra: #","replies":{\#(replies)}"#)
    }
}

extension IntelRig {
    /// The `params` of the last `method` request the server received.
    func lastParams(_ method: String) -> JSONValue? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
            .last { $0["method"]?.stringValue == method }?["params"]
    }
}
