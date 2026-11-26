@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// The tint on the user's own unsaved edits in the code editor.
@MainActor
@Suite struct OwnEditMarksTests {
    static let base = "l1\nl2\nl3\nl4\nl5\nl6\n"

    @MainActor struct Fixture {
        let rig: Rig
        let window: TestWindow
        let doc: EditorDocument
        let view: OpenDocumentView
        var marks: OwnEditMarks { view.ownMarks! }

        func quiesce(_ rounds: Int = 40) async {
            for _ in 0..<rounds { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
        }

        func settle(_ what: String, advance: Double = 0, _ condition: () -> Bool) async {
            for _ in 0..<3000 where !condition() {
                if advance > 0 { rig.clock.advance(by: advance) }
                window.tick()
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            #expect(condition(), Comment(rawValue: "never became true: \(what)"))
        }

        func setting(enabled: Bool, hex: String? = nil) throws {
            var s = rig.workspace.settings
            s.ownEditTint = OwnEditTint(enabled: enabled, colorHex: hex)
            try rig.workspace.updateSettings(s, persist: false)
        }

        /// The owner names of the rows' painted backgrounds that belong to the own tint.
        func ownRows() -> [Int] {
            (0..<doc.buffer.snapshot().lineCount).filter { view.decorations.paintedLineDecoration(row: $0)?.backgroundOwner == "own" }
        }

        func typeAtEnd(_ text: String) {
            let end = doc.buffer.snapshot().utf8Count
            doc.buffer.replace(end..<end, with: text)
        }

        /// Types `X` into line 1 (after "l2").
        func typeIntoLine1() { doc.buffer.replace(5..<5, with: "X") }

        /// Types, lets the edit reach the view's timer, then moves the clock past the pause.
        func typeAndPause() async {
            typeIntoLine1()
            await quiesce(20)
            rig.clock.advance(by: 0.35)
        }
    }

    private func fixture(enabled: Bool, text: String = OwnEditMarksTests.base, name: String = "a.txt") async throws -> Fixture {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        if enabled {
            var s = rig.workspace.settings
            s.ownEditTint = OwnEditTint(enabled: true)
            try rig.workspace.updateSettings(s, persist: false)
        }
        rig.workspace.openFilePath = name
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let doc = try #require(rig.workspace.document(name))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .chat))
        for _ in 0..<2000 where view.ownMarks == nil { window.tick(); await Task.yield() }
        _ = try #require(view.ownMarks)
        let f = Fixture(rig: rig, window: window, doc: doc, view: view)
        await f.quiesce(10)
        return f
    }

    @Test func offByDefaultTypingSpawnsNothing() async throws {
        let f = try await fixture(enabled: false)
        f.typeIntoLine1()
        await f.quiesce(20)
        f.rig.clock.advance(by: 0.35)
        await f.quiesce(40)
        #expect(f.marks.recomputeCount == 0)
        #expect(!f.marks.isShowing)
        #expect(f.ownRows().isEmpty)
    }

    @Test func onTypingTintsTheEditedLineAfterThePause() async throws {
        let f = try await fixture(enabled: true)
        f.typeIntoLine1()
        await f.quiesce(30)
        #expect(f.ownRows().isEmpty, "no tint before the pause has passed")
        f.rig.clock.advance(by: 0.35)
        await f.settle("tinted") { f.ownRows() == [1] }
        #expect(f.marks.lastDiffOffMain == true)
        #expect(f.view.decorations.paintedLineDecoration(row: 1)?.gutterBar?.owner == "own")
    }

    @Test func saveClearsTheTint() async throws {
        let f = try await fixture(enabled: true)
        await f.typeAndPause()
        await f.settle("tinted") { f.ownRows() == [1] }
        try await f.rig.workspace.save("a.txt")
        await f.settle("cleared") { f.ownRows().isEmpty }
        #expect(!f.marks.isShowing)
    }

    @Test func undoToSavedClearsTheTint() async throws {
        let f = try await fixture(enabled: true)
        await f.typeAndPause()
        await f.settle("tinted") { f.ownRows() == [1] }
        f.doc.buffer.replace(5..<6, with: "")
        #expect(f.doc.buffer.snapshot().text == Self.base)
        await f.quiesce(20)
        f.rig.clock.advance(by: 0.35)
        await f.settle("cleared") { f.ownRows().isEmpty }
    }

    @Test func toggleOffClearsOpenViews() async throws {
        let f = try await fixture(enabled: true)
        await f.typeAndPause()
        await f.settle("tinted") { f.ownRows() == [1] }
        try f.setting(enabled: false)
        await f.settle("cleared") { f.ownRows().isEmpty }
        let count = f.marks.recomputeCount
        await f.typeAndPause()
        await f.quiesce(40)
        #expect(f.marks.recomputeCount == count)
        #expect(f.ownRows().isEmpty)
    }

    @Test func overSizeLimitNoTintNoWork() async throws {
        let line = String(repeating: "x", count: 1023) + "\n"
        let big = String(repeating: line, count: (GitGutterMarks.sizeLimit / 1024) + 8)
        let f = try await fixture(enabled: true, text: big, name: "big.txt")
        await f.typeAndPause()
        await f.quiesce(60)
        #expect(f.marks.recomputeCount == 0)
        #expect(f.ownRows().isEmpty)
    }

    @Test func colourSettingChangeRepaintsWithoutTheSettingBeingOff() async throws {
        let f = try await fixture(enabled: true)
        await f.typeAndPause()
        await f.settle("tinted") { f.ownRows() == [1] }
        let before = f.marks.recomputeCount
        try f.setting(enabled: true, hex: "#FF0000")
        await f.settle("recomputed") { f.marks.recomputeCount == before + 1 }
        await f.settle("still tinted") { f.ownRows() == [1] }
    }

    @Test func savedUserEditsAreNotTintedEitherWay() async throws {
        for enabled in [false, true] {
            let f = try await fixture(enabled: enabled)
            await f.typeAndPause()
            let builds = f.rig.workspace.decorationBuilds
            try await f.rig.workspace.save("a.txt")
            #expect(f.rig.workspace.ledger.files["a.txt"]?.edits.last?.author == .user, "still recorded")
            await f.settle("diff rebuilt") { f.rig.workspace.decorationBuilds > builds }
            await f.quiesce(30)
            for row in 0..<f.doc.buffer.snapshot().lineCount {
                #expect(f.view.decorations.paintedLineDecoration(row: row)?.gutterBar == nil, "row \(row), enabled \(enabled)")
            }
        }
    }

    @Test func agentEditTintUnchanged() async throws {
        let f = try await fixture(enabled: true)
        let session = await f.rig.workspace.newSession(name: "A")
        let url = f.rig.root.appendingPathComponent("a.txt")
        let new = "l1\nl2\nNEW\nl4\nl5\nl6\n"
        try new.write(to: url, atomically: true, encoding: .utf8)
        let hunk = PatchHunk(oldStart: 3, oldLines: 1, newStart: 3, newLines: 1, lines: ["-l3", "+NEW"])
        await f.rig.transports[0].emit(.toolResult(ToolResultMessage(
            toolUseID: "t1", isError: false, text: "ok",
            result: .edit(filePath: url.path, originalFile: Self.base, hunks: [hunk]))))
        await f.settle("session bar") { f.view.decorations.paintedLineDecoration(row: 2)?.gutterBar != nil }
        let bar = try #require(f.view.decorations.paintedLineDecoration(row: 2)?.gutterBar)
        #expect(bar.owner == nil)
        #expect(bar.color == Color.sessionColor(session.colorIndex))
    }

    @Test func idleTicksRerunNothingWithTintOn() async throws {
        let f = try await fixture(enabled: true)
        await f.typeAndPause()
        await f.settle("tinted") { f.ownRows() == [1] }
        await f.quiesce(10)
        let counts = BodyProbe.counts
        let recomputes = f.marks.recomputeCount
        for _ in 0..<20 { f.window.tick(); await Task.yield() }
        #expect(BodyProbe.counts == counts)
        #expect(f.marks.recomputeCount == recomputes)
    }
}
