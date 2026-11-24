@testable import AlloyCore
import AlloyHighlight
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

private func fr(_ a: Int, _ b: Int) -> FoldRange { FoldRange(startLine: a, endLine: b) }

/// Folds end to end: the commands and views that move the caret open the fold hiding their target; folds survive
/// a restart, a source switch and a reload; closing a tab or switching project leaves nothing behind.
@MainActor
@Suite struct FoldEndToEndTests {
    static let text = """
    func a() {
        if x {
            b()
        }
    }
    func c() {
        d()
    }

    """

    /// A chat window on `name`, with its first build applied.
    private func rigged(text: String = FoldEndToEndTests.text, name: String = "blocks.swift") async throws
        -> (rig: Rig, window: TestWindow, state: CodeFoldState, view: OpenDocumentView) {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = name
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let doc = try #require(rig.workspace.document(name))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .chat))
        let state = try #require(rig.workspace.foldState(for: name, in: .chat))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: name) == 0 || folds.inFlight(path: name) {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, window, state, view)
    }

    private func spin(_ window: TestWindow, _ rounds: Int = 10) async {
        for _ in 0..<rounds { window.tick(); await Task.yield() }
    }

    // MARK: Commands that move the caret open the fold hiding the target

    @Test func findUnfoldsTheMatchRange() async throws {
        let (rig, window, state, view) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let outer = try #require(state.foldableRanges.first)
        #expect(state.fold(outer))
        #expect(state.isHidden(line: 2))
        view.showFind()
        view.setQuery("b()")
        for _ in 0..<2000 where view.findCount != 1 { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(view.findCount == 1)
        view.step(1)
        await spin(window)
        #expect(!state.isHidden(line: 2), "the match is shown")
        #expect(state.folded.isEmpty)
    }

    @Test func goToDefinitionUnfoldsTheTarget() async throws {
        let (rig, window, state, _) = try await rigged()
        defer { withExtendedLifetime(rig) {} }
        let outer = try #require(state.foldableRanges.first)
        #expect(state.fold(outer))
        // The definition lands on `b()`, hidden in the fold: the open-and-select path go-to-definition ends in.
        await rig.workspace.open("blocks.swift", selecting: { $0.lineRange(2) }, in: .chat)
        await spin(window)
        #expect(!state.isHidden(line: 2))
        #expect(state.folded.isEmpty)
    }

    @Test func selectAllOccurrencesUnfoldsHiddenMatches() async throws {
        let text = "func foo() {\n    foo()\n}\nfoo()\n"
        let (rig, window, state, _) = try await rigged(text: text, name: "dup.swift")
        defer { withExtendedLifetime(rig) {} }
        let first = try #require(state.foldableRanges.first)
        #expect(state.fold(first))
        #expect(state.isHidden(line: 1))
        let selection = try #require(rig.workspace.selectionState(for: "dup.swift", in: .chat))
        let last = (text as NSString).range(of: "foo()", options: .backwards)
        selection.select(last.location..<last.location + 3, reveal: false)
        #expect(state.isHidden(line: 1), "a shown selection leaves the fold shut")
        #expect(rig.workspace.runMultiCursor(.selectAllOccurrences))
        await spin(window)
        #expect(selection.selections.count >= 2)
        #expect(!state.isHidden(line: 1), "the match inside the fold opened it")
    }

    // MARK: Problems, with a language server that publishes nothing by itself

    @MainActor private struct DiagRig {
        let rig = Rig()
        let coordinator: LSPCoordinator

        init(capabilities: String = #"{"capabilities":{"textDocumentSync":2}}"#) {
            let launcher = ServerLauncher { _, resolved, root in
                var env = ProcessInfo.processInfo.environment
                env["FAKE_LSP_SCRIPT"] = capabilities
                return try ServerProcess(executable: resolved, arguments: [], environment: env, currentDirectory: root)
            }
            let configs = [ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: fakeServerPath)]
            coordinator = LSPCoordinator.install(on: rig.workspace, builtIn: configs,
                                                 locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                                 launcher: launcher)
        }

        func open(_ path: String) async throws -> TestWindow {
            rig.workspace.openFilePath = path
            let window = try alloyWindow(rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            try await window.runUntil { coordinator.status.byPath[path]?.state == .ready }
            for _ in 0..<5 { window.tick(); await Task.yield() }
            return window
        }
    }

    private static let rust = "fn a() {\n    let x = 1;\n    let y = 2;\n}\n"

    @Test func stepProblemUnfoldsTheDiagnostic() async throws {
        let r = DiagRig()
        try Self.rust.write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .chat))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: "main.rs") == 0 || folds.inFlight(path: "main.rs") {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let state = try #require(r.rig.workspace.foldState(for: "main.rs", in: .chat))
        let first = try #require(state.foldableRanges.first { $0.lowerBound == 0 })
        #expect(state.fold(first))
        let at = (Self.rust as NSString).range(of: "y").location
        r.coordinator.handle(.diagnostics(path: "main.rs", version: Int(doc.buffer.version),
                                          items: [LSPDiagnostic(range: at..<at + 1, severity: .error, message: "bad", source: "fake")]))
        window.tick()
        #expect(state.isHidden(line: 2))
        view.stepProblem(1)
        await spin(window)
        #expect(!state.isHidden(line: 2), "the diagnostic's line is shown")
        await r.rig.workspace.stopAll()
    }

    @Test func lspServerWithoutFoldingRangeKeepsTreeSitter() async throws {
        let r = DiagRig()
        try Self.rust.write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .chat))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: "main.rs") == 0 || folds.inFlight(path: "main.rs") {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let outcome = await r.coordinator.foldingRanges(path: "main.rs", snapshot: doc.buffer.snapshot())
        #expect(outcome == .unavailable, "the server did not advertise foldingRange")
        folds.settled(path: "main.rs")
        for _ in 0..<3000 where folds.inFlight(path: "main.rs") || folds.buildCount(path: "main.rs") < 2 {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let got = try #require(folds.ranges["main.rs"])
        #expect(got.source == .treeSitter, "kept the grammar's ranges: \(got.source)")
        #expect(!got.ranges.isEmpty)
        await r.rig.workspace.stopAll()
    }

    // MARK: Diff review

    @Test func diffReviewUnfoldsItsTarget() async throws {
        let base = "func a() {\n    let x = 1\n    let y = 2\n}\nfunc b() {\n    let z = 3\n}\n"
        let changed = "func a() {\n    let x = 1\n    let y = 20\n}\nfunc b() {\n    let z = 3\n}\n"
        let m = try await MarkRig.make(files: ["a.swift": base], worktree: ["a.swift": changed], open: "a.swift")
        let folds = try #require(m.view.services.folds)
        await m.settle("ranges built") { folds.buildCount(path: "a.swift") >= 1 && !folds.inFlight(path: "a.swift") }
        await m.settle("a hunk") { m.marks.hunks.count == 1 }
        let state = try #require(m.workspace.foldState(for: "a.swift", in: m.pane))
        let block = try #require(state.foldableRanges.first { $0.lowerBound == 0 })
        #expect(state.fold(block))
        #expect(state.isHidden(line: 2))
        #expect(m.marks.step(1))
        await m.quiesce(10)
        #expect(!state.isHidden(line: 2), "the changed line is shown")
        #expect(state.folded.isEmpty)
    }

    // MARK: Disk, undo

    @Test func reloadFromDiskKeepsOnlyFoldsThatStillOpenARange() async throws {
        let f = FoldRig()
        let s = try await f.open("a.txt", "a {\n  x\n  y\n}\nb {\n  p\n  q\n}\nc {\n  m\n  n\n}\n")
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil && !f.coordinator.inFlight(path: "a.txt") })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        let all = state.foldableRanges
        #expect(all.map(\.lowerBound) == [0, 4, 8], "\(all)")
        for r in all { #expect(state.fold(r)) }
        // The file changes on disk: `b`'s header goes, so the fold at row 4 has no range to open.
        let doc = s.document
        let new = Array("a {\n  x\n  y\n}\nb\n  p\n  q\nc {\n  m\n  n\n}\n".utf8)
        let edit = try #require(Workspace.replacementEdit(old: doc.buffer.snapshot(), newBytes: new))
        _ = try doc.buffer.applyExternalEdits([edit], expectingVersion: doc.buffer.version)
        await f.settle(s, path: "a.txt")
        let version = doc.buffer.version
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.version == version })
        let starts = Set(state.foldableRanges.map(\.lowerBound))
        #expect(state.folded.allSatisfy { starts.contains($0.lowerBound) }, "every kept fold opens a range: \(state.folded) vs \(state.foldableRanges)")
        #expect(state.folded.contains { $0.lowerBound == 0 }, "the untouched fold stays")
        #expect(!state.folded.contains { $0.lowerBound == 4 }, "the fold whose header went opened")
    }

    @Test func wholeBufferReplaceLeavesNoFoldWithoutARange() async throws {
        let f = FoldRig()
        let s = try await f.open("a.txt", "a {\n  x\n  y\n}\nb {\n  p\n  q\n}\n")
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil && !f.coordinator.inFlight(path: "a.txt") })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        for r in state.foldableRanges { #expect(state.fold(r)) }
        let doc = s.document
        _ = doc.buffer.replace(0..<doc.buffer.snapshot().utf8Count, with: "q {\n  1\n  2\n}\nflat\nflat\n", origin: .programmatic)
        await f.settle(s, path: "a.txt")
        let version = doc.buffer.version
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.version == version })
        let starts = Set(state.foldableRanges.map(\.lowerBound))
        #expect(state.folded.allSatisfy { starts.contains($0.lowerBound) }, "\(state.folded) vs \(state.foldableRanges)")
    }

    @Test func undoDoesNotRecreateAFoldAnEditOpened() async throws {
        let f = FoldRig()
        let s = try await f.open("a.txt", "a {\n  x\n  y\n}\nb\n")
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil && !f.coordinator.inFlight(path: "a.txt") })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        #expect(state.fold(0..<3))
        let buffer = s.document.buffer
        // An edit that crosses the fold's boundary (the header's end into the hidden rows) opens it.
        _ = buffer.replace(2..<6, with: "Y", origin: .typing)
        #expect(state.folded.isEmpty, "the edit opened the fold")
        #expect(buffer.undo())
        #expect(state.folded.isEmpty, "undo does not close it again")
        #expect(buffer.redo())
        #expect(state.folded.isEmpty)
    }

    // MARK: Restart, source switch

    private func secondWorkspace(like rig: Rig) -> Workspace {
        var settings = AlloySettings()
        settings.followEdits = false
        let bag = rig.transports, source = rig.changes
        return Workspace(projectRoot: rig.root, appSupport: rig.root.appendingPathComponent("support"), settings: settings,
                         locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                         makeTransport: { _ in bag.make() }, autosaveClock: rig.clock, changes: { _ in source })
    }

    @Test func restoreEndToEnd() async throws {
        let f = FoldRig()
        let body = "a {\n  x\n  y\n}\nb {\n  p\n  q\n}\n"
        try body.write(to: f.rig.root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        await f.workspace.restoreUIState()
        f.workspace.setMode(.code)
        let first = f.workspace.codeLayout.focusedGroupID
        await f.workspace.open("a.txt", in: .group(first))
        f.workspace.splitFocused(.horizontal)
        let target = f.workspace.codeLayout.focusedGroupID
        #expect(target != first && f.workspace.codeLayout.groups.count == 2)
        await f.workspace.open("a.txt", in: .group(target))
        let doc = try #require(f.workspace.document("a.txt"))
        _ = f.workspace.selectionState(for: "a.txt", in: .group(target))
        let services = DocumentServices(document: doc, engine: f.engine)
        services.attachFolds(f.coordinator)
        #expect(await f.pump { f.coordinator.ranges["a.txt"] != nil && !f.coordinator.inFlight(path: "a.txt") })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: .group(target)))
        #expect(state.fold(4..<7))
        f.workspace.noteFoldsChanged()
        await f.workspace.flushUIState()

        // A new workspace on the same project: the folds come back after the first ranges, in the same group.
        let again = secondWorkspace(like: f.rig)
        await again.restoreUIState()
        let coordinator = FoldCoordinator(sources: f.script.sources)
        coordinator.attach(workspace: again)
        #expect(again.codeLayout.groups[target] != nil, "the group id survived")
        await again.open("a.txt", in: .group(target))
        let doc2 = try #require(again.document("a.txt"))
        let restored = try #require(again.foldState(for: "a.txt", in: .group(target)))
        #expect(restored.folded.isEmpty, "nothing folds before ranges arrive")
        let services2 = DocumentServices(document: doc2, engine: f.engine)
        services2.attachFolds(coordinator)
        for _ in 0..<600 where restored.folded.isEmpty { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(restored.folded == [4..<7])
        #expect(again.pendingFolds.isEmpty)
        let others = again.codeLayout.groups.keys.filter { $0 != target }
        for id in others { #expect(again.foldState(for: "a.txt", in: .group(id))?.folded.isEmpty ?? true) }
        withExtendedLifetime((services, services2)) {}
    }

    @Test func sourceSwitchEndToEnd() async throws {
        let f = FoldRig()
        let gate = FoldGate()
        f.script.lsp { _ in await gate.wait(); return .answered([fr(0, 3), fr(5, 6)]) }
        try await f.open("a.txt", "a {\n  x\n  y\n}\nz\nb {\n  p\n}\n")
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.source == .indentation })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        #expect(state.foldableRanges.first == 0..<3)
        #expect(state.fold(0..<3))
        gate.open()
        #expect(await f.pump { f.coordinator.ranges["a.txt"]?.source == .lsp })
        #expect(state.foldableRanges == [0..<4, 5..<7])
        #expect(state.folded == [0..<4], "the fold with the same start survives, resized")
    }

    // MARK: Failure modes

    @Test func closeTabWhileBuildInFlight() async throws {
        let f = FoldRig()
        let gate = FoldGate()
        f.script.tree { _ in await gate.wait(); return [fr(0, 3)] }
        let s = try await f.open("a.swift")
        #expect(await f.pump { f.script.treeCalls == 1 && f.coordinator.inFlight(path: "a.swift") })
        await f.workspace.close("a.swift", in: f.pane)
        s.close()
        gate.open()
        for _ in 0..<40 { await Task.yield(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(f.coordinator.ranges.isEmpty)
        #expect(!f.coordinator.inFlight(path: "a.swift"))
        #expect(f.workspace.foldState(for: "a.swift", in: f.pane) == nil)
        #expect(f.workspace.paneFolds[f.pane]?["a.swift"] == nil)
        #expect(f.workspace.pendingFolds.isEmpty)
        #expect(f.workspace.latestFold["a.swift"] == nil)
        #expect(f.workspace.foldSnapshot().isEmpty)
    }

    @Test func projectSwitchDropsEverything() async throws {
        let f = FoldRig()
        let a = try await f.open("a.txt")
        let b = try await f.open("b.txt")
        #expect(await f.pump { f.coordinator.ranges.count == 2 && !f.coordinator.inFlight(path: "a.txt") && !f.coordinator.inFlight(path: "b.txt") })
        let state = try #require(f.workspace.foldState(for: "a.txt", in: f.pane))
        #expect(state.fold(0..<3))
        // Saved folds waiting for ranges count too.
        f.workspace.pendingFolds[f.pane, default: [:]]["b.txt"] = [FoldLines(start: 0, end: 2)]
        // The project closes: every tab and document goes.
        for path in ["a.txt", "b.txt"] { await f.workspace.close(path, in: f.pane) }
        a.close(); b.close()
        for _ in 0..<20 { await Task.yield() }
        #expect(f.coordinator.ranges.isEmpty)
        #expect(!f.coordinator.inFlight(path: "a.txt") && !f.coordinator.inFlight(path: "b.txt"))
        #expect(f.workspace.paneFolds.values.allSatisfy { $0.isEmpty })
        #expect(f.workspace.pendingFolds.isEmpty)
        #expect(f.workspace.latestFold.isEmpty)
        #expect(f.workspace.foldSnapshot().isEmpty)
    }
}
