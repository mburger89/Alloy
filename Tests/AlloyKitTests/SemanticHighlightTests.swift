import AlloyCore
import AlloyHighlight
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import AlloyLSPTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing


/// A workspace whose `.zig` and `.rs` files are served by the fake server, which advertises semantic tokens and answers
/// every request with a `const` keyword token at the start of the file.
@MainActor
private struct SemRig {
    let rig = Rig()
    let coordinator: LSPCoordinator
    let log: URL

    init(tokens: Bool = true) {
        let script = tokens
            ? #"{"capabilities":{"textDocumentSync":2,"semanticTokensProvider":{"legend":{"tokenTypes":["keyword"],"tokenModifiers":[]},"full":true}},"semanticTokens":{"data":[0,0,5,0,0]}}"#
            : #"{"capabilities":{"textDocumentSync":2}}"#
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-sem-\(UUID().uuidString).jsonl")
        self.log = log
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = script
            env["FAKE_LSP_LOG"] = log.path
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let configs = [
            ServerConfig(id: "fake-zig", name: "FakeZig", languageID: "zig", extensions: ["zig"], command: fakeServerPath),
            ServerConfig(id: "fake-rs", name: "FakeRs", languageID: "rust", extensions: ["rs"], command: fakeServerPath),
        ]
        coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: configs,
                                             locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                             launcher: launcher)
    }

    static func run(tokens: Bool = true, _ body: (SemRig) async throws -> Void) async throws {
        let r = SemRig(tokens: tokens)
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            try? FileManager.default.removeItem(at: r.log)
            throw error
        }
        await r.rig.workspace.stopAll()
        try? FileManager.default.removeItem(at: r.log)
    }

    func open(_ path: String, text: String = "const x = 1;\n") async throws -> TestWindow {
        try text.write(to: rig.root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = path
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try await window.runUntil { coordinator.status.byPath[path]?.state == .ready }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        return window
    }

    func requestCount() -> Int {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue?.contains("semanticTokens") == true }.count
    }

    func view(_ path: String) throws -> OpenDocumentView {
        let document = try #require(rig.workspace.document(path))
        return try #require(CodePanelStore.existingView(for: document))
    }
}

@MainActor
@Suite
struct SemanticHighlightTests {
    @Test func grammarFilesNeverRequestTokens() async throws {
        try await SemRig.run { r in
            let window = try await r.open("main.rs", text: "fn main() {}\n")
            try await window.runUntil {
                (try? String(contentsOf: r.log, encoding: .utf8))?.contains("textDocument/didOpen") == true
            }
            // Give a stray request time to show up, and type, which would schedule one.
            window.typeText("a")
            let deadline = ContinuousClock.now + .milliseconds(600)
            while ContinuousClock.now < deadline { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(r.requestCount() == 0)
            #expect(try r.view("main.rs").semantic == nil)
        }
    }

    @Test func serverWithoutTokensCostsNothingPerEdit() async throws {
        try await SemRig.run(tokens: false) { r in
            let window = try await r.open("main.zig")
            for _ in 0..<5 { window.typeText("a"); window.tick(); try await Task.sleep(for: .milliseconds(10)) }
            let deadline = ContinuousClock.now + .milliseconds(600)
            while ContinuousClock.now < deadline { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            // The opening probe found no tokens, so no request reached the server and no highlighter was made.
            #expect(r.requestCount() == 0)
            #expect(try r.view("main.zig").semantic == nil)
        }
    }

    @Test func zigFileGetsColoured() async throws {
        try await SemRig.run { r in
            let window = try await r.open("main.zig")
            let view = try r.view("main.zig")
            let semantic = try #require(view.semantic)
            try await window.runUntil { semantic.appliedCount > 0 }
            #expect(semantic.appliedRunCount == 1)
            let id = try #require(semantic.styleIDs[.keyword])
            #expect(view.decorations.style(id).foreground == SyntaxPalette.color(.keyword))
        }
    }

    @Test func supportLearnedAfterAnEditAsksForTheCurrentText() async throws {
        try await SemRig.run { r in
            let window = try await r.open("main.zig")
            let view = try r.view("main.zig")
            let first = try #require(view.semantic)
            try await window.runUntil { first.appliedCount > 0 }
            // The edit comes while there is no highlighter yet (so the view's own request for it is a no-op, and the
            // manager has cancelled the probe's answer): drop the highlighter, edit, and only then learn the support.
            view.semanticSupport(false)
            #expect(view.semantic == nil)
            window.typeText("a")
            for _ in 0..<10 { window.tick(); try await Task.sleep(for: .milliseconds(10)) }
            view.semanticSupport(true)
            let semantic = try #require(view.semantic)
            try await window.runUntil(timeout: .seconds(5)) { semantic.requestCount >= 1 }
            try await window.runUntil(timeout: .seconds(5)) { semantic.appliedCount > 0 }
        }
    }

    @Test func typingDebouncesRequests() async throws {
        try await SemRig.run { r in
            let window = try await r.open("main.zig")
            let semantic = try #require(try r.view("main.zig").semantic)
            try await window.runUntil { semantic.appliedCount > 0 }
            let before = r.requestCount()
            for _ in 0..<20 {
                window.typeText("a")
                window.tick()
                try await Task.sleep(for: .milliseconds(10))
            }
            // Wait for the debounced request to be answered and applied.
            let applied = semantic.appliedCount
            try await window.runUntil(timeout: .seconds(5)) { semantic.appliedCount > applied }
            let deadline = ContinuousClock.now + .milliseconds(500)
            while ContinuousClock.now < deadline { window.tick(); try await Task.sleep(for: .milliseconds(20)) }
            #expect(r.requestCount() - before <= 2, "requests after typing: \(r.requestCount() - before)")
            #expect(r.requestCount() - before >= 1)
        }
    }
}

@MainActor
struct SemanticHighlighterUnitTests {
    @Test func unreachableVersionIsDroppedAndAskedAgain() {
        let buffer = CodeBuffer("const x\n")
        let decorations = CodeDecorations(buffer: buffer)
        var requested = 0
        let highlighter = SemanticHighlighter(path: "a.zig", decorations: decorations) { _ in requested += 1 }
        // A version the buffer has not reached cannot be mapped: nothing is applied, the tokens are asked for again.
        highlighter.apply([(0..<5, .keyword)], version: Int(buffer.version) + 100)
        #expect(highlighter.appliedCount == 0)
        #expect(requested == 1)
        highlighter.apply([(0..<5, .keyword)], version: Int(buffer.version))
        #expect(highlighter.appliedCount == 1 && highlighter.appliedRunCount == 1)
        #expect(requested == 1)
    }
}
