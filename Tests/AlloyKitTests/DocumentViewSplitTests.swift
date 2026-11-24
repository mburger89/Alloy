import AlloyCore
@testable import AlloyHighlight
@testable import AlloyKit
import AlloyLSP
import AlloyLSPTestSupport
import AlloyRPC
import AlloyTestSupport
import Foundation
import MetalUI
import Testing

/// A workspace with an edited `login.swift` and a `main.rs`, whose servers are the scriptable fake (logging what it
/// is told), a store attached to the coordinator, and a second pane (the focused group) next to Chat.
@MainActor
private struct SplitRig {
    let rig: Rig
    let session: Session
    let coordinator: LSPCoordinator
    let store = CodePanelStore()
    let logURL: URL
    let group: PaneID

    static func run(_ body: (SplitRig) async throws -> Void) async throws {
        let r = try await SplitRig()
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            throw error
        }
        await r.rig.workspace.stopAll()
    }

    init() async throws {
        let (rig, session) = try await editedRig()
        self.rig = rig
        self.session = session
        try "fn main() {}\n".write(to: rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        logURL = rig.root.appendingPathComponent("fake-lsp.jsonl")
        let log = logURL.path
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = #"{"capabilities":{"textDocumentSync":2}}"#
            env["FAKE_LSP_LOG"] = log
            return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
        }
        let configs = [
            ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: fakeServerPath),
            ServerConfig(id: "fake-swift", name: "FakeSwift", languageID: "swift", extensions: ["swift"], command: fakeServerPath),
        ]
        coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: configs,
                                             locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                             launcher: launcher)
        group = .group(rig.workspace.codeLayout.focusedGroupID)
        store.attach(workspace: rig.workspace)
    }

    var workspace: Workspace { rig.workspace }

    /// Opens `path` in Chat and in the group, and makes both views.
    func openBoth(_ path: String) async throws -> (chat: OpenDocumentView, group: OpenDocumentView) {
        await workspace.open(path, in: .chat)
        await workspace.open(path, in: group)
        let document = try #require(workspace.document(path))
        store.ensureView(for: document, in: .chat)
        store.ensureView(for: document, in: group)
        return (try #require(store.view(for: document, in: .chat)), try #require(store.view(for: document, in: group)))
    }

    func methods() -> [String] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8))?["method"]?.stringValue }
            .filter { $0.hasPrefix("textDocument/did") }
    }

    /// Waits (the server is another process) until `condition` holds.
    func wait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now >= deadline { Issue.record("timed out waiting for \(what); log: \(methods())"); return }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func publish(_ path: String, _ items: [LSPDiagnostic]) {
        let doc = workspace.document(path)!
        coordinator.handle(.diagnostics(path: path, version: Int(doc.buffer.version), items: items))
    }

    /// Runs the view's build until `done` holds.
    func build(_ view: OpenDocumentView, until done: () -> Bool) async throws {
        try await wait("a build") {
            view.rebuildIfNeeded(workspace: workspace)
            return done()
        }
    }
}

private func problem(_ range: Range<Int>) -> LSPDiagnostic {
    LSPDiagnostic(range: range, severity: .error, message: "bad", source: "fake")
}

@MainActor
@Suite
struct DocumentViewSplitTests {
    @Test func twoViewsShareOneServices() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("login.swift")
            let services = try #require(r.store.services(for: "login.swift"))
            #expect(chat.services === services && group.services === services)
            #expect(chat !== group && chat.decorations !== group.decorations)
            #expect(services.attachedViews.count == 2)
        }
    }

    @Test func findIsPerView() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("login.swift")
            chat.showFind()
            chat.setQuery("let")
            try await r.wait("matches") { chat.findCount == 3 }
            #expect(!group.findVisible)
            #expect(group.decorations.findMatches.isEmpty)
            #expect(group.findQuery.isEmpty)
        }
    }

    @Test func scrollIsPerView() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("login.swift")
            #expect(chat.scroll !== group.scroll)
            chat.scroll.position = CodeScrollPosition(row: 5, x: 0)
            chat.leftScroll.position = CodeScrollPosition(row: 4, x: 0)
            #expect(group.scroll.position.row == 0 && group.leftScroll.position.row == 0)
            #expect(chat.scroll.position.row == 5)
        }
    }

    @Test func presentationIsPerView() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("login.swift")
            r.workspace.setPresentation(.sideBySide, of: "login.swift", in: .chat)
            try await r.build(chat) { chat.left != nil }
            group.rebuildIfNeeded(workspace: r.workspace)
            #expect(group.left == nil)
            #expect(group.tags.isEmpty)
        }
    }

    /// A view attached to a file with unsaved typing still carries the saved diff once diagnostics arrive.
    @Test func aViewAttachedToADirtyFileKeepsItsDiff() async throws {
        try await SplitRig.run { r in
            await r.workspace.open("login.swift", in: .chat)
            let document = try #require(r.workspace.document("login.swift"))
            r.store.ensureView(for: document, in: .chat)
            document.buffer.replace(0..<0, with: "x", origin: .typing)
            await r.workspace.open("login.swift", mode: .inline, in: r.group)
            r.store.ensureView(for: document, in: r.group)
            let group = try #require(r.store.view(for: document, in: r.group))
            try await r.build(group) { !group.tags.isEmpty }
            try await r.wait("the server") { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            r.publish("login.swift", [problem(5..<6)])
            #expect(group.decorations.virtualLineCount == 2, "the removed line and the message row")
        }
    }

    /// An invalidated diff leaves the author tint behind; going plain removes it.
    @Test func plainClearsTheTintOfAnInvalidatedDiff() async throws {
        try await SplitRig.run { r in
            let (chat, _) = try await r.openBoth("login.swift")
            r.workspace.setPresentation(.inline, of: "login.swift", in: .chat)
            try await r.wait("the server") { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            r.publish("login.swift", [problem(4..<5)])
            try await r.build(chat) { !chat.tags.isEmpty }
            let all = 0..<(1 << 20)
            r.publish("login.swift", [problem(4..<6)])
            // Lines more than one author wrote get a tint run; one author's edit has none, so stand one in.
            let style = chat.decorations.register(CodeStyle(background: .addedRowTint))
            chat.decorations.setHighlights([CodeStyleRun(range: 0..<3, style: style)], in: all, layer: .annotations,
                                           asOf: chat.document.buffer.version)
            #expect(!chat.decorations.highlights(in: all, layer: .annotations).isEmpty)
            // More edits than the row log keeps: the diff can no longer be carried forward.
            let document = chat.document
            for _ in 0..<4_200 { document.buffer.replace(0..<0, with: "\n", origin: .typing) }
            r.publish("login.swift", [problem(4..<6)])
            // A paint right after another one waits for the next main-actor turn.
            for _ in 0..<5 { await Task.yield() }
            r.workspace.setPresentation(.plain, of: "login.swift", in: .chat)
            chat.rebuildIfNeeded(workspace: r.workspace)
            #expect(chat.decorations.highlights(in: all, layer: .annotations).isEmpty)
        }
    }

    @Test func plainBuildsNoDiffButPaintsDiagnostics() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("login.swift")
            r.workspace.setPresentation(.inline, of: "login.swift", in: .chat)
            try await r.build(chat) { !chat.tags.isEmpty }
            group.rebuildIfNeeded(workspace: r.workspace)
            try await r.wait("the server") { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            r.publish("login.swift", [problem(4..<5)])
            #expect(group.tags.isEmpty)
            #expect(group.diagnosticsPaintCount > 0)
            // The message row of the diagnostic is there, the removed line of the diff is not.
            #expect(group.decorations.virtualLineCount == 1)
            #expect(chat.decorations.virtualLineCount == 2)
        }
    }

    /// With no diff built, a view's message rows follow its own pane's presentation (they were Chat's for every view).
    @Test func diagnosticRowsFollowTheViewsOwnPane() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("main.rs")
            r.workspace.setPresentation(.sideBySide, of: "main.rs", in: r.group)
            chat.rebuildIfNeeded(workspace: r.workspace)
            group.rebuildIfNeeded(workspace: r.workspace)
            try await r.wait("the server") { r.coordinator.status.byPath["main.rs"]?.state == .ready }
            r.publish("main.rs", [problem(0..<2)])
            #expect(chat.decorations.virtualLineCount == 1, "Chat shows inline: the message row is there")
            #expect(group.decorations.virtualLineCount == 0, "side by side hides message rows")
        }
    }

    @Test func oneLanguageServerOpenPerDocument() async throws {
        try await SplitRig.run { r in
            _ = try await r.openBoth("main.rs")
            try await r.wait("didOpen") { r.methods().contains("textDocument/didOpen") }
            for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
            #expect(r.methods() == ["textDocument/didOpen"])
            // Chat lets go; the group still holds the file.
            await r.workspace.close("main.rs", in: .chat)
            r.store.chatTabsChanged(workspace: r.workspace)
            #expect(r.store.view(for: try #require(r.workspace.document("main.rs")), in: .chat) == nil)
            for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
            #expect(r.methods() == ["textDocument/didOpen"], "no didClose while another view holds the file")
            // The last holder closes it, once.
            await r.workspace.close("main.rs", in: r.group)
            r.store.prune(pane: r.group, keeping: [])
            r.store.pruneServices(workspace: r.workspace)
            try await r.wait("didClose") { r.methods().contains("textDocument/didClose") }
            for _ in 0..<20 { await Task.yield(); try await Task.sleep(for: .milliseconds(10)) }
            #expect(r.methods() == ["textDocument/didOpen", "textDocument/didClose"])
            #expect(r.store.services(for: "main.rs") == nil)
        }
    }

    @Test func reconcileReleasesWhateverNoTabHoldsInAnyPane() async throws {
        try await SplitRig.run { r in
            _ = try await r.openBoth("main.rs")
            try await r.wait("didOpen") { r.methods().contains("textDocument/didOpen") }
            await r.workspace.close("main.rs", in: .chat)
            await r.workspace.close("main.rs", in: r.group)
            r.store.reconcile(workspace: r.workspace)
            try await r.wait("didClose") { r.methods().contains("textDocument/didClose") }
            #expect(r.store.services(for: "main.rs") == nil)
        }
    }

    @Test func editsReachEveryView() async throws {
        try await SplitRig.run { r in
            let (chat, group) = try await r.openBoth("login.swift")
            try await r.wait("highlighters") { chat.highlighter != nil && group.highlighter != nil }
            let document = chat.document
            document.buffer.replace(0..<0, with: "abc", origin: .typing)
            let services = try #require(r.store.services(for: "login.swift"))
            try await r.wait("the edit is recorded once") { services.recordedBatches == 1 }
            let engine = r.store.engine
            let answer = await engine.captures(id: document.id, byteRange: 0..<9, minVersion: document.buffer.version)
            #expect(answer.version == document.buffer.version)
            // Each view's own highlighter asks the engine and applies the new version.
            for view in [chat, group] {
                let highlighter = try #require(view.highlighter)
                highlighter.decorations(view.decorations, needHighlightsForRows: 0..<1, in: document.buffer.snapshot())
                try await r.wait("a highlight of the new version") { highlighter.appliedVersions.last == document.buffer.version }
            }
        }
    }
}
