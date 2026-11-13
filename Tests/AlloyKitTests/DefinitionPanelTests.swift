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


/// A workspace whose `.rs` files are served by the fake server, which answers `textDocument/definition` with `answer(root)`.
@MainActor
private struct DefRig {
    let rig = Rig()
    let coordinator: LSPCoordinator
    let log: URL

    init(delayMs: Int = 0, hold: Bool = false, answer: @escaping @Sendable (URL) -> String) {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-defpanel-\(UUID().uuidString).jsonl")
        self.log = log
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = #"{"capabilities":{"textDocumentSync":2,"definitionProvider":true},"delayMs":\#(delayMs),"holdDefinition":\#(hold),"definition":\#(answer(root))}"#
            env["FAKE_LSP_LOG"] = log.path
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: fakeServerPath)
        coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: [config],
                                             locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                             launcher: launcher)
    }

    static func run(delayMs: Int = 0, hold: Bool = false, answer: @escaping @Sendable (URL) -> String,
                    _ body: (DefRig) async throws -> Void) async throws {
        let r = DefRig(delayMs: delayMs, hold: hold, answer: answer)
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            try? FileManager.default.removeItem(at: r.log)
            throw error
        }
        await r.rig.workspace.stopAll()
        try? FileManager.default.removeItem(at: r.log)
    }

    func open(_ path: String) async throws -> TestWindow {
        rig.workspace.openFilePath = path
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try await window.runUntil { coordinator.status.byPath[path]?.state == .ready }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        return window
    }

    func methods() -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue }
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

private func location(_ uri: String, _ line: Int, _ from: Int, _ to: Int) -> String {
    #"[{"uri":"\#(uri)","range":{"start":{"line":\#(line),"character":\#(from)},"end":{"line":\#(line),"character":\#(to)}}}]"#
}

@MainActor
@Suite
struct DefinitionPanelTests {
    @Test func f12OpensTargetAndSelects() async throws {
        try await DefRig.run(answer: { root in location(root.appendingPathComponent("lib.rs").absoluteString, 1, 3, 8) }) { r in
            try r.write("main.rs", "use lib;\nfn main() { call(); }\n")
            try r.write("lib.rs", "// lib\nfn call() {}\n")
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            doc.buffer.select(20..<20, reveal: false)
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { r.rig.workspace.activeTab == "lib.rs" && r.rig.workspace.document("lib.rs") != nil
                && r.rig.workspace.document("lib.rs")?.buffer.primarySelection.range != 0..<0 }
            let lib = try #require(r.rig.workspace.document("lib.rs"))
            // "// lib\n" is 7 bytes; line 1, characters 3..<8 is "call(".. "fn call" -> bytes 10..<15
            #expect(lib.buffer.primarySelection.range == 10..<15)
            #expect(String(decoding: lib.buffer.snapshot().utf8(in: 10..<15), as: UTF8.self) == "call(")
            #expect(r.rig.workspace.tabs.contains("main.rs"))
        }
    }

    private static let cSource = "int add(int a, int b) { return a + b; }\n\nint main(void) {\n    int x = add(1);\n    return x;\n}\n"

    @Test func sameFileLocationSelectsTheName() async throws {
        try await DefRig.run(answer: { root in location(root.appendingPathComponent("main.rs").absoluteString, 0, 4, 7) }) { r in
            try r.write("main.rs", Self.cSource)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            doc.buffer.select(75..<75, reveal: false)
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { doc.buffer.primarySelection.range == 4..<7 }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(doc.buffer.primarySelection.range == 4..<7)
        }
    }

    @Test func sameFileLocationLinkSelectsTheSelectionRange() async throws {
        let link: @Sendable (URL) -> String = { root in
            #"[{"targetUri":"\#(root.appendingPathComponent("main.rs").absoluteString)","targetRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":39}},"targetSelectionRange":{"start":{"line":0,"character":4},"end":{"line":0,"character":7}}}]"#
        }
        try await DefRig.run(answer: link) { r in
            try r.write("main.rs", Self.cSource)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            doc.buffer.select(75..<75, reveal: false)
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { doc.buffer.primarySelection.range == 4..<7 }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(doc.buffer.primarySelection.range == 4..<7)
        }
    }

    @Test func noResultShowsMessage() async throws {
        try await DefRig.run(answer: { _ in "null" }) { r in
            try r.write("main.rs", "fn main() {}\n")
            let window = try await r.open("main.rs")
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { (try? window.element(identifier: "file-panel-definition-message")) != nil }
            let shown = try window.element(identifier: "file-panel-definition-message")
            #expect(shown.label == "No definition found" || shown.value == "No definition found")
            try await window.runUntil(timeout: .seconds(6)) { (try? window.element(identifier: "file-panel-definition-message")) == nil }
        }
    }

    @Test func externalTargetShowsItsLocation() async throws {
        try await DefRig.run(answer: { _ in location("file:///opt/sdk/std.rs", 41, 4, 9) }) { r in
            try r.write("main.rs", "fn main() {}\n")
            let window = try await r.open("main.rs")
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { (try? window.element(identifier: "file-panel-definition-message")) != nil }
            let shown = try window.element(identifier: "file-panel-definition-message")
            let text = shown.label ?? shown.value
            #expect(text == "Definition: /opt/sdk/std.rs:42:5")
            #expect(r.rig.workspace.activeTab == "main.rs")
        }
    }

    @Test func secondF12CancelsTheFirst() async throws {
        // The server holds a definition request until it is cancelled, so the cancel is the only way on.
        try await DefRig.run(hold: true, answer: { _ in "null" }) { r in
            try r.write("main.rs", "fn main() {}\n")
            let window = try await r.open("main.rs")
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { r.methods().contains("textDocument/definition") }
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { r.methods().contains("$/cancelRequest") }
            #expect(r.methods().filter { $0 == "textDocument/definition" }.count >= 1)
        }
    }

    @Test func tabSwitchDropsTheAnswer() async throws {
        try await DefRig.run(hold: true, answer: { root in location(root.appendingPathComponent("lib.rs").absoluteString, 0, 0, 3) }) { r in
            try r.write("main.rs", "fn main() {}\n")
            try r.write("other.rs", "fn other() {}\n")
            try r.write("lib.rs", "fn lib() {}\n")
            let window = try await r.open("main.rs")
            window.typeKey(FilePanelView.f12)
            try await window.runUntil { r.methods().contains("textDocument/definition") }
            await r.rig.workspace.open("other.rs")
            try await window.runUntil { r.methods().contains("$/cancelRequest") }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(r.rig.workspace.activeTab == "other.rs")
            #expect(r.rig.workspace.document("lib.rs") == nil)
            #expect((try? window.element(identifier: "file-panel-definition-message")) == nil)
        }
    }

    @Test func typingAfterF12DropsTheAnswerSilently() async throws {
        try await DefRig.run(answer: { root in location(root.appendingPathComponent("lib.rs").absoluteString, 0, 0, 3) }) { r in
            try r.write("main.rs", "fn main() {}\n")
            try r.write("lib.rs", "fn lib() {}\n")
            let window = try await r.open("main.rs")
            // F12 and a keystroke in the same turn: the text changes before the request can be made.
            window.typeKey(FilePanelView.f12)
            window.typeText("x")
            for _ in 0..<30 { window.tick(); await Task.yield(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(r.rig.workspace.activeTab == "main.rs")
            #expect(r.rig.workspace.document("lib.rs") == nil)
            #expect((try? window.element(identifier: "file-panel-definition-message")) == nil, "no false \"No definition found\"")
        }
    }

    @Test func menuShortcutIsPlainF12() {
        #expect(goToDefinitionShortcut.modifiers.isEmpty)
        #expect(goToDefinitionShortcut.key == FilePanelView.f12)
    }
}
