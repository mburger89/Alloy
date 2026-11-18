@testable import AlloyCore
@testable import AlloyHighlight
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The fold coordinator costs typing nothing: the frame guards of `CodeModePerformanceTests` hold with it running, and
/// no keystroke starts a build.
@MainActor
@Suite struct FoldGuardTests {
    private func guardedTyping(_ layout: CodeModePerformanceTests.Layout, steady: Int) async throws {
        let perf = CodeModePerformanceTests()
        let (rig, window, id) = try await perf.rigged(layout)
        let doc = try #require(rig.workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc, in: rig.workspace.defaultPane))
        let folds = try #require(view.services.folds, "the store gave the document its fold coordinator")
        // The opening build runs once the engine holds the text; wait for it so only typing is measured.
        for _ in 0..<3000 where folds.buildCount(path: "login.swift") == 0 || folds.inFlight(path: "login.swift") {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(folds.buildCount(path: "login.swift") >= 1)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let builds = folds.buildCount(path: "login.swift")
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= steady + 2 }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= steady * 20 * 102 / 100, "element requests \(t.requests)")
        #expect(folds.buildCount(path: "login.swift") == builds, "typing started a fold build")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func typingWithTheCoordinatorHoldsTheChatGuardAndStartsNoBuild() async throws {
        try await guardedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests)
    }
    @Test func typingWithTheCoordinatorHoldsTheGuardCode1() async throws {
        try await guardedTyping(.code1, steady: CodeModePerformanceTests.steadyCode1)
    }
    @Test func typingWithTheCoordinatorHoldsTheGuardCode2() async throws {
        try await guardedTyping(.code2, steady: CodeModePerformanceTests.steadyCode2)
    }
    @Test func typingWithTheCoordinatorHoldsTheGuardCode3() async throws {
        try await guardedTyping(.code3, steady: CodeModePerformanceTests.steadyCode3)
    }

    // MARK: With folds and the chevron lane

    private static func blocks(_ count: Int) -> String { (0..<count).map { "func f\($0)() {\n    let x = \($0)\n}\n" }.joined() }

    /// A rig on `layout` whose login.swift starts with six blocks, their ranges built; `fold` closes the first five.
    private func foldedRig(_ layout: CodeModePerformanceTests.Layout, fold: Bool, blocks: Int = 6, foldCount: Int = 5) async throws
        -> (rig: Rig, window: TestWindow, id: String, state: CodeFoldState) {
        let perf = CodeModePerformanceTests()
        let (rig, window, id) = try await perf.rigged(layout)
        let doc = try #require(rig.workspace.document("login.swift"))
        let pane = layout == .chat ? PaneID.chat : rig.workspace.defaultPane
        let view = try #require(CodePanelStore.existingView(for: doc, in: pane))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: "login.swift") == 0 || folds.inFlight(path: "login.swift") {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let before = folds.buildCount(path: "login.swift")
        doc.buffer.replace(0..<0, with: Self.blocks(blocks))
        rig.clock.advance(by: 1)
        for _ in 0..<3000 where folds.buildCount(path: "login.swift") == before || folds.inFlight(path: "login.swift") {
            rig.clock.advance(by: 1)
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let state = try #require(rig.workspace.foldState(for: "login.swift", in: pane))
        #expect(state.foldableRanges.count >= foldCount, "ranges built: \(state.foldableRanges.count)")
        if fold { for r in state.foldableRanges.prefix(foldCount) { #expect(state.fold(r)) } }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, window, id, state)
    }

    private func foldedTyping(_ layout: CodeModePerformanceTests.Layout, steady: Int, fold: Bool, blocks: Int = 6, foldCount: Int = 5) async throws {
        let perf = CodeModePerformanceTests()
        let (rig, window, id, state) = try await foldedRig(layout, fold: fold, blocks: blocks, foldCount: foldCount)
        let t = try await perf.typing(window, rig, codeViewID: id, names: CodeModePerformanceTests.watched)
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= steady + 2 }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= steady * 20 * 102 / 100, "element requests \(t.requests)")
        #expect(fold ? !state.folded.isEmpty : true)
        if fold, foldCount >= 1000 { #expect(state.folded.count >= 1000, "folds kept through typing: \(state.folded.count)") }
        withExtendedLifetime((rig, window)) {}
    }

    @Test func typingWithFoldsHoldsTheChatGuard() async throws {
        try await foldedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, fold: true)
    }
    @Test func typingWithFoldsHoldsTheGuardCode1() async throws {
        try await foldedTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, fold: true)
    }
    @Test func typingWithFoldsHoldsTheGuardCode2() async throws {
        try await foldedTyping(.code2, steady: CodeModePerformanceTests.steadyCode2, fold: true)
    }
    @Test func typingWithFoldsHoldsTheGuardCode3() async throws {
        try await foldedTyping(.code3, steady: CodeModePerformanceTests.steadyCode3, fold: true)
    }
    @Test func typingWithTheChevronLaneHoldsTheChatGuard() async throws {
        try await foldedTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, fold: false)
    }
    @Test func typingWithTheChevronLaneHoldsTheGuardCode1() async throws {
        try await foldedTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, fold: false)
    }

    @Test func typingWith1000FoldsHoldsTheGuard() async throws {
        try await foldedTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, fold: true, blocks: 1100, foldCount: 1000)
    }
    @Test func idleWith1000FoldsCostsZero() async throws { try await idle(carets: 1, blocks: 1100, foldCount: 1000) }

    @Test func idleWithFoldsAndTheLaneCostsZero() async throws { try await idle(carets: 1) }
    @Test func idleWithFoldsAndThreeCaretsCostsZero() async throws { try await idle(carets: 3) }

    /// Unfocused (blink off) idle frames with folds and the lane cost 0 element requests and re-run no body.
    private func idle(carets: Int, blocks: Int = 6, foldCount: Int = 5) async throws {
        let perf = CodeModePerformanceTests()
        let (rig, window, _, _) = try await foldedRig(.code1, fold: true, blocks: blocks, foldCount: foldCount)
        if carets > 1 {
            let state = try #require(rig.workspace.selectionState(for: "login.swift", in: rig.workspace.defaultPane))
            state.setSelections([CodeSelection(caret: 0)], primary: 0)
            for _ in 1..<carets { rig.workspace.runMultiCursor(.addCaretBelow) }
            #expect(state.selections.count == carets, "carets placed")
        }
        for _ in 0..<15 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            rig.clock.advance(by: 0.5)
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        #expect(reruns.isEmpty, "idle re-ran \(reruns)")
        withExtendedLifetime(rig) {}
    }

    /// Note: the hover comparison below is relative (to the same move over text); the absolute floor is the harness's
    /// 46-request frame, so a gutter-specific cost below it cannot show here.
    /// Entering and leaving the gutter cost at most a steady frame; a move within it costs no more than the same move
    /// over the text (any pointer move redraws the window in the harness; the lane adds nothing to it).
    @Test func gutterHoverAddsNothingToAPointerMove() async throws {
        let (rig, window, codeID, state) = try await foldedRig(.code1, fold: false)
        let first = try #require(state.foldableRanges.first)
        let a = try window.element(identifier: "fold-chevron-\(first.lowerBound)").frame
        let t = try window.element(identifier: codeID).frame
        func at(_ r: Bounds<Pixels>, _ dx: Float, _ dy: Float) -> Point<Pixels> {
            Point(x: Pixels(r.origin.x.value + dx), y: Pixels(r.origin.y.value + dy))
        }
        func cost(_ body: () -> Void) async -> [Int] {
            window.resetFrameWork(); body(); window.tick(); await Task.yield()
            return window.frameWork.map(\.elementRequests)
        }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        window.hover(at: at(t, 300, 100)); window.tick()
        let textMove = await cost { window.hover(at: at(t, 302, 102)) }
        let enter = await cost { window.hover(at: at(a, 1, 1)) }
        #expect(enter.allSatisfy { $0 <= CodeModePerformanceTests.steadyCode1 }, "enter \(enter)")
        window.tick()
        let gutterMove = await cost { window.hover(at: at(a, 2, 2)) }
        #expect(zip(gutterMove, textMove).allSatisfy { $0 <= $1 } && gutterMove.count <= textMove.count,
                "gutter move \(gutterMove) vs text move \(textMove)")
        // Leaving the gutter ends its hover work over a few frames: wait until the window has drained it (a frame that
        // asks for no elements) instead of trusting one tick, then measure the leave move itself.
        func drained() async {
            for _ in 0..<20 {
                window.resetFrameWork(); window.tick(); await Task.yield()
                if window.frameWork.allSatisfy({ $0.elementRequests == 0 }) { return }
            }
        }
        await drained()
        let leave = await cost { window.hover(at: at(t, 300, 100)) }
        #expect(leave.allSatisfy { $0 <= CodeModePerformanceTests.steadyCode1 + 2 }, "leave \(leave)")
        withExtendedLifetime(rig) {}
    }

    // MARK: Compare views

    /// A git rig on code1 whose login.swift holds folds in the buffer, then `.compareHead` in the focused group.
    private func compareRig() async throws -> (rig: Rig, window: TestWindow, right: String, perf: CodeModePerformanceTests) {
        let perf = CodeModePerformanceTests()
        let (rig, window, _) = try await perf.rigged(.code1, git: true)
        let workspace = rig.workspace
        let g0 = workspace.codeLayout.focusedGroupID
        let doc = try #require(workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .group(g0)))
        let folds = try #require(view.services.folds)
        for _ in 0..<3000 where folds.buildCount(path: "login.swift") == 0 || folds.inFlight(path: "login.swift") {
            window.tick(); try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // Ranges go straight onto the buffer's fold state (a buffer edit before entering the compare shifts the compare's own
        // frame costs, which this test is not about).
        let state = try #require(workspace.foldState(for: "login.swift", in: .group(g0)))
        #expect(state.setFoldableRanges([1..<3, 4..<7, 8..<12], asOf: doc.buffer.version))
        for r in state.foldableRanges { _ = state.fold(r) }
        #expect(!state.folded.isEmpty, "folds: \(state.foldableRanges) \(state.folded) lines \(doc.buffer.snapshot().lineCount)")
        let buildsBefore = workspace.decorationBuilds
        workspace.setPresentation(.compareHead, of: "login.swift", in: .group(g0))
        for _ in 0..<3000 where view.compare == nil { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(view.compare != nil)
        // The compare model of the edited buffer lands asynchronously: wait until it has actually been applied (the compare
        // build counted and both panes exist), not for a fixed number of ticks, then a few warmup ticks.
        try await window.runUntil(timeout: .seconds(30)) { workspace.decorationBuilds > buildsBefore && view.compare != nil && view.left != nil }
        // The left pane opens its engine document and highlights asynchronously (the first answer lands after the build, and
        // under load after any fixed number of ticks): wait until the highlighters of both panes have applied and are idle.
        try await window.runUntil(timeout: .seconds(30)) {
            guard let left = view.left?.highlighter, let right = view.highlighter else { return false }
            return !left.appliedVersions.isEmpty && left.isIdle && right.isIdle
        }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, window, "sbs-right-\(g0.uuidString)", perf)
    }

    @Test func compareHeadTypingWithFoldsHoldsSteadyCompare() async throws {
        let (rig, window, right, perf) = try await compareRig()
        let t = try await perf.typing(window, rig, codeViewID: right, names: CodeModePerformanceTests.watched)
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= 77 }, "per-frame element requests \(t.perFrame)")
        withExtendedLifetime((rig, window)) {}
    }

    @Test func sideBySideIdleCostsZero() async throws {
        let (rig, window, _, perf) = try await compareRig()
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            rig.clock.advance(by: 0.5)
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        #expect(window.frameWork.map(\.elementRequests).allSatisfy { $0 == 0 }, "\(window.frameWork.map(\.elementRequests))")
        #expect(reruns.isEmpty, "idle re-ran \(reruns)")
        withExtendedLifetime((rig, window)) {}
    }

    // MARK: Persisted size

    /// A workspace holding `ranges` blocks, all folded, in the chat pane.
    private func foldedWorkspace(_ count: Int) async throws -> (Rig, CodeFoldState) {
        let rig = Rig()
        let text = (0..<count).map { "b\($0) {\n  x\n}\n" }.joined()
        try text.write(to: rig.root.appendingPathComponent("many.txt"), atomically: true, encoding: .utf8)
        await rig.workspace.restoreUIState()
        await rig.workspace.open("many.txt")
        let state = try #require(rig.workspace.foldState(for: "many.txt", in: rig.workspace.defaultPane))
        let ranges = (0..<count).map { FoldRange(startLine: $0 * 3, endLine: $0 * 3 + 1) }
        let version = try #require(rig.workspace.document("many.txt")).buffer.version
        rig.workspace.applyFoldRanges(path: "many.txt", choice: FoldChoice(source: .indentation, ranges: ranges), version: version)
        #expect(state.foldableRanges.count == count)
        state.folded = state.foldableRanges
        return (rig, state)
    }

    @Test func persistedFoldsAreCappedAndSmall() async throws {
        let (rig, state) = try await foldedWorkspace(1200)
        #expect(state.folded.count == 1200)
        let folds = rig.workspace.currentUIState().folds
        let saved = try #require(folds["chat"]?["many.txt"])
        #expect(saved.count == 1200)
        let bytes = try JSONEncoder().encode(folds).count
        #expect(bytes < 16 * 1024, "1,200 folds encode to \(bytes) bytes")

        let (rig2, state2) = try await foldedWorkspace(2500)
        #expect(state2.folded.count == 2500)
        let written = try #require(rig2.workspace.currentUIState().folds["chat"]?["many.txt"])
        #expect(written.count == 2000, "extras are dropped from the end")
        #expect(written.first == FoldLines(start: 0, end: 1) && written.last == FoldLines(start: 5997, end: 5998))
        let back = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(rig2.workspace.currentUIState()))
        #expect(back.folds["chat"]?["many.txt"]?.count == 2000)
        withExtendedLifetime((rig, rig2)) {}
    }
}
