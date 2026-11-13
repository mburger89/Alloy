import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import AlloyLSPTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Observation
import Testing


private func error(_ range: Range<Int>, _ message: String = "bad") -> LSPDiagnostic {
    LSPDiagnostic(range: range, severity: .error, message: message, source: "fake")
}

/// A workspace whose `.rs` and `.swift` files are served by the scriptable fake server (it publishes nothing here:
/// the tests hand the coordinator results themselves).
@MainActor
private struct DiagRig {
    let rig = Rig()
    let coordinator: LSPCoordinator

    init() {
        let launcher = ServerLauncher { _, resolved, root in
            var env = ProcessInfo.processInfo.environment
            env["FAKE_LSP_SCRIPT"] = #"{"capabilities":{"textDocumentSync":2}}"#
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

    static func run(_ body: (DiagRig) async throws -> Void) async throws {
        let r = DiagRig()
        do { try await body(r) } catch {
            await r.rig.workspace.stopAll()
            throw error
        }
        await r.rig.workspace.stopAll()
    }

    func open(_ path: String) async throws -> TestWindow {
        rig.workspace.openFilePath = path
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        try await window.runUntil { coordinator.status.byPath[path]?.state == .ready }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        return window
    }

    /// Hands the coordinator a result for the buffer as it is now, as the manager would.
    func publish(_ path: String, _ items: [LSPDiagnostic]) {
        let doc = rig.workspace.document(path)!
        coordinator.handle(.diagnostics(path: path, version: Int(doc.buffer.version), items: items))
    }
}

@MainActor
private func probed(_ names: [String], _ reruns: inout [String: Int], _ body: () -> Void) {
    let before = names.map(BodyProbe.count)
    body()
    for (i, n) in names.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
}

private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@MainActor
struct DiagnosticLayoutTests {
    @Test func mostSevereWinsOnOverlap() {
        let items = [
            LSPDiagnostic(range: 0..<10, severity: .warning, message: "w"),
            LSPDiagnostic(range: 4..<6, severity: .error, message: "e"),
            LSPDiagnostic(range: 8..<14, severity: .information, message: "i"),
            LSPDiagnostic(range: 20..<30, severity: .hint, message: "h"),
        ]
        let segments = DiagnosticDecorations.segments(items)
        #expect(segments.map(\.range) == [0..<4, 4..<6, 6..<10, 10..<14])
        #expect(segments.map(\.severity) == [.warning, .error, .warning, .information])
    }

    @Test func layoutShowsTheMostSevereMessageOfARow() {
        let snapshot = CodeBuffer("one\ntwo\nthree\n").snapshot()
        let items = [
            LSPDiagnostic(range: 0..<1, severity: .warning, message: "careful\nsecond line", source: "lint"),
            LSPDiagnostic(range: 2..<3, severity: .error, message: "broken"),
            LSPDiagnostic(range: 4..<5, severity: .information, message: "fyi"),
        ]
        let layout = DiagnosticDecorations.layout(items, in: snapshot)
        #expect(layout.rows.map(\.lines) == [["\u{26A0} broken"], ])
        #expect(layout.rows.map(\.anchor) == [.after(line: 0)])
        // Rows 0 and 1 differ in severity (error vs information), so they get a decoration each.
        #expect(layout.lines.map(\.lines) == [0..<1, 1..<2])
        let warnings = DiagnosticDecorations.layout([items[0]], in: snapshot)
        #expect(warnings.rows.first?.lines == ["\u{26A0} careful \u{2014} lint"])
    }

    @Test func virtualRowsCappedAt200() {
        let text = String(repeating: "line\n", count: 300)
        let snapshot = CodeBuffer(text).snapshot()
        let items = (0..<300).map { error(($0 * 5)..<($0 * 5 + 1), "e\($0)") }
        let layout = DiagnosticDecorations.layout(items, in: snapshot)
        #expect(layout.rows.count == 200)
        #expect(layout.rows.first?.lines == ["\u{26A0} e0 \u{2014} fake"])
        #expect(layout.rows.last?.lines == ["\u{26A0} e199 \u{2014} fake"])
        // All 300 rows still have their gutter bar (one decoration, as they are neighbours).
        #expect(layout.lines.map(\.lines) == [0..<300])
    }

    @Test func staleDiagnosticsArePaintedOnTheMappedRange() {
        let buffer = CodeBuffer("let value = 1\n")
        let published = buffer.version
        buffer.replace(0..<0, with: "// c\n", origin: .typing)   // two edits after the report
        buffer.replace(0..<0, with: "// d\n", origin: .typing)
        let entry = DiagnosticStore.Entry(version: Int(published), items: [error(4..<9)])
        #expect(DiagnosticDecorations.current(entry, in: buffer) == [error(14..<19)])
        // A report from the future of a buffer that was replaced wholesale is dropped.
        buffer.replace(0..<buffer.utf8Count, with: "x", origin: .typing)
        #expect(DiagnosticDecorations.current(entry, in: buffer).isEmpty)
    }

    @Test func nextProblemWraps() {
        let items = [error(10..<12), error(2..<3), LSPDiagnostic(range: 6..<7, severity: .hint, message: "h")]
        func next(_ selection: Range<Int>, _ direction: Int) -> Range<Int>? {
            DiagnosticDecorations.nextProblem(items, selection: selection, direction: direction)
        }
        #expect(next(0..<0, 1) == 2..<3)
        #expect(next(2..<3, 1) == 10..<12)
        #expect(next(10..<12, 1) == 2..<3)
        #expect(next(10..<12, -1) == 2..<3)
        #expect(next(2..<3, -1) == 10..<12)
        #expect(DiagnosticDecorations.nextProblem([], selection: 0..<0, direction: 1) == nil)
    }

    @Test func nextProblemReachesDiagnosticsThatStartTogether() {
        let items = [
            LSPDiagnostic(range: 4..<9, severity: .warning, message: "w"),
            LSPDiagnostic(range: 4..<6, severity: .error, message: "e"),
            LSPDiagnostic(range: 4..<9, severity: .warning, message: "w again"),
            error(12..<13),
        ]
        func next(_ selection: Range<Int>, _ direction: Int) -> Range<Int>? {
            DiagnosticDecorations.nextProblem(items, selection: selection, direction: direction)
        }
        // By start, then severity: the error (4..<6), then the warning (4..<9, two equal ranges are one stop), then 12.
        #expect(next(0..<0, 1) == 4..<6)
        #expect(next(4..<6, 1) == 4..<9)
        #expect(next(4..<9, 1) == 12..<13)
        #expect(next(12..<13, 1) == 4..<6)
        #expect(next(4..<9, -1) == 4..<6)
        #expect(next(4..<6, -1) == 12..<13)
        // A caret sitting on the start of a problem reaches it going forward.
        #expect(next(4..<4, 1) == 4..<6)
    }

    @Test func perPathCountsObserveOnlyTheirPath() {
        let store = DiagnosticStore()
        let a = store.counts.counts(for: "a.rs")
        let fired = Fired()
        withObservationTracking { _ = a.errors; _ = a.warnings } onChange: { fired.bump() }
        store.set(path: "b.rs", version: 1, items: [error(0..<1)])
        #expect(fired.value == 0, "another file's count changed")
        store.set(path: "a.rs", version: 1, items: [error(0..<1)])
        #expect(fired.value == 1)
        #expect(a.errors == 1)
    }

    /// The Return at the start of the row after a session's edit must not take the session's bar and tag, with or
    /// without diagnostics.
    @Test func carryingTheDiffForwardFollowsMetalUIsRule() {
        let text = "r0\nr1\nr2\nr3\n"
        let buffer = CodeBuffer(text)
        let cursor = buffer.makeEditCursor()
        var log = RowDeltaLog(base: buffer.version)
        let saved = buffer.version
        let author = Color.red
        let lines = [CodeLineDecoration(lines: 1..<3, gutterBar: author, background: nil, tag: 7)]
        let rows = [CodeVirtualRow(anchor: .before(line: 1), lines: ["old"], tag: 7),
                    CodeVirtualRow(anchor: .after(line: 2), lines: ["note"])]
        // Return at the start of row 3 (right after the block 1..<3).
        buffer.replace(9..<9, with: "\n", origin: .typing)
        guard case .edits(let edits) = cursor.drain() else { Issue.record("edits"); return }
        for edit in edits { log.record(edit) }
        let moved = log.move(lines: lines, rows: rows, from: saved, rowCount: 5, to: buffer.version)
        #expect(moved?.lines.map(\.lines) == [1..<3], "the new empty row is not the session's")
        #expect(moved?.lines.map(\.tag) == [7])
        #expect(moved?.rows.map(\.anchor) == [.before(line: 1), .after(line: 2)])
        // Return inside the block cuts a hole: the inserted row has no decoration, the halves keep theirs.
        buffer.replace(3..<3, with: "\n", origin: .typing)
        guard case .edits(let more) = cursor.drain() else { Issue.record("edits"); return }
        for edit in more { log.record(edit) }
        let split = log.move(lines: lines, rows: rows, from: saved, rowCount: 5, to: buffer.version)
        #expect(split?.lines.map(\.lines) == [1..<2, 3..<4])
        #expect(split?.lines.map(\.tag) == [7, 7])
        // The log does not reach a version older than it started.
        let later = RowDeltaLog(base: buffer.version)
        #expect(later.move(lines: lines, rows: rows, from: saved, rowCount: 5, to: buffer.version) == nil)
    }
}

@MainActor
@Suite
struct DiagnosticPanelTests {
    @Test func countsUpdateHeaderOnlyOnChange() async throws {
        try await DiagRig.run { r in
            try "fn main() {}\nlet x = 1;\n".write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
            let window = try await r.open("main.rs")
            let names = ["FilePanelHeader", "DiagnosticCountsBadge", "FilePanelView", "CodePanel"]
            var reruns: [String: Int] = [:]
            probed(names, &reruns) { r.publish("main.rs", [error(0..<2)]); window.tick() }
            #expect(reruns["DiagnosticCountsBadge"] == 1, "badge \(reruns["DiagnosticCountsBadge"]!)")
            #expect((try? window.element(identifier: "file-panel-errors"))?.label == "1 error"
                    || (try? window.element(identifier: "file-panel-errors"))?.value == "1 error")
            // The same counts again, with other ranges and a newer version: nothing re-runs.
            reruns = [:]
            for i in 0..<5 {
                probed(names, &reruns) { r.publish("main.rs", [error(i..<(i + 2), "again \(i)")]); window.tick() }
            }
            for n in names { #expect(reruns[n] == 0, "\(n) re-ran \(reruns[n]!) times on an identical republish") }
            // A real change: the badge re-runs once, the header and the panels never.
            reruns = [:]
            probed(names, &reruns) { r.publish("main.rs", [error(0..<2), error(3..<4)]); window.tick() }
            #expect(reruns["DiagnosticCountsBadge"] == 1)
            #expect(reruns["FilePanelHeader"] == 0)
            #expect(reruns["FilePanelView"] == 0 && reruns["CodePanel"] == 0)
            #expect(r.coordinator.diagnostics.counts.byPath["main.rs"]?.errors == 2)
        }
    }

    @Test func typingDoesNotRerunTheHeaderWhileDiagnosticsAreShown() async throws {
        try await DiagRig.run { r in
            try "fn main() {}\n".write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
            let window = try await r.open("main.rs")
            r.publish("main.rs", [error(0..<2)])
            window.tick()
            try window.click(window.element(identifier: "code-view"))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            var reruns: [String: Int] = [:]
            let names = ["FilePanelHeader", "DiagnosticCountsBadge", "FilePanelView", "CodePanel"]
            for _ in 0..<10 {
                probed(names, &reruns) { window.typeText("a"); window.tick() }
                await Task.yield()
            }
            // The first keystroke makes the tab dirty (header); nothing re-runs per keystroke after that.
            #expect(reruns["DiagnosticCountsBadge"] == 0)
            #expect(reruns["FilePanelHeader"]! <= 1)
            #expect(reruns["FilePanelView"] == 0 && reruns["CodePanel"] == 0)
        }
    }

    @Test func diagnosticsMergeWithDiffDecorations() async throws {
        try await DiagRig.run { r in
            let session = await r.rig.workspace.newSession(name: "A")
            _ = session
            try panelOldText.write(to: r.rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
            try await emitEdit(r.rig, old: panelOldText, new: panelNewText, toolUseID: "t1")
            r.rig.workspace.openFilePath = "login.swift"
            let window = try alloyWindow(r.rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            try await window.runUntil { r.rig.workspace.decorationBuilds >= 1 }
            try await window.runUntil { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            window.tick()
            let doc = try #require(r.rig.workspace.document("login.swift"))
            let view = try #require(CodePanelStore.existingView(for: doc))
            @MainActor func bars() -> Int { window.scene.rects.filter { $0.bounds.size.width == 3 && $0.bounds.origin.x > 700 }.count }
            let rowsBefore = view.decorations.virtualLineCount
            let barsBefore = bars()
            #expect(rowsBefore == 1, "the removed line")
            #expect(barsBefore > 0)
            // An error on line 1 (row 0), which the session did not touch.
            r.publish("login.swift", [error(4..<5, "unused")])
            window.tick()
            #expect(view.decorations.virtualLineCount == rowsBefore + 1, "the diff's removed line and the diagnostic row")
            #expect(bars() > barsBefore, "the author bar stays and the diagnostic adds its own")
            // Clearing the diagnostics leaves the diff exactly as it was.
            r.coordinator.handle(.diagnostics(path: "login.swift", version: Int(doc.buffer.version), items: []))
            // A paint right after another one waits for the next main-actor turn.
            for _ in 0..<3 { await Task.yield(); window.tick() }
            #expect(view.decorations.virtualLineCount == rowsBefore)
            #expect(bars() == barsBefore)
            // Unsaved typing above shifts the diff and the diagnostics together (control: the same without them).
            doc.buffer.replace(0..<0, with: "\n", origin: .typing)
            window.tick()
            let typedBars = bars()
            r.publish("login.swift", [error(5..<6, "unused")])
            window.tick()
            #expect(view.decorations.virtualLineCount == rowsBefore + 1)
            #expect(bars() > typedBars)
            r.coordinator.handle(.diagnostics(path: "login.swift", version: Int(doc.buffer.version), items: []))
            // A paint right after another one waits for the next main-actor turn.
            for _ in 0..<3 { await Task.yield(); window.tick() }
            #expect(view.decorations.virtualLineCount == rowsBefore)
            #expect(bars() == typedBars)
        }
    }

    @Test func publishBurstsPaintOncePerTurnAndLeaveTheAuthorRunsAlone() async throws {
        try await DiagRig.run { r in
            _ = await r.rig.workspace.newSession(name: "A")
            try panelOldText.write(to: r.rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
            try await emitEdit(r.rig, old: panelOldText, new: panelNewText, toolUseID: "t1")
            r.rig.workspace.openFilePath = "login.swift"
            let window = try alloyWindow(r.rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            try await window.runUntil { r.rig.workspace.decorationBuilds >= 1 }
            try await window.runUntil { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            window.tick()
            let doc = try #require(r.rig.workspace.document("login.swift"))
            let view = try #require(CodePanelStore.existingView(for: doc))
            try await window.runUntil { view.annotationApplyCount >= 1 }
            for _ in 0..<5 { window.tick(); await Task.yield() }
            let annotations = view.annotationApplyCount
            let paints = view.diagnosticsPaintCount
            // Ten publishes in one main-actor turn: the first paints at once, one more paint follows in the next turn.
            for i in 0..<10 { r.publish("login.swift", [error(4..<5, "unused \(i)")]) }
            #expect(view.diagnosticsPaintCount == paints + 1)
            for _ in 0..<5 { window.tick(); await Task.yield() }
            #expect(view.diagnosticsPaintCount == paints + 2, "painted \(view.diagnosticsPaintCount - paints) times")
            // The diff did not change, so its author-run layer was left alone; the diagnostics are shown.
            #expect(view.annotationApplyCount == annotations)
            #expect(view.decorations.virtualLineCount == 2)
            // Quiet again: the next publish paints at once.
            r.publish("login.swift", [])
            #expect(view.diagnosticsPaintCount == paints + 3)
            #expect(view.decorations.virtualLineCount == 1)
        }
    }

    @Test func sideBySideKeepsThePanesLevel() async throws {
        try await DiagRig.run { r in
            _ = await r.rig.workspace.newSession(name: "A")
            try panelOldText.write(to: r.rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
            try await emitEdit(r.rig, old: panelOldText, new: panelNewText, toolUseID: "t1")
            r.rig.workspace.openFilePath = "login.swift"
            let window = try alloyWindow(r.rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            try await window.runUntil { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            let doc = try #require(r.rig.workspace.document("login.swift"))
            doc.diffMode = .sideBySide
            try await window.runUntil { (try? window.element(identifier: "sbs-left")) != nil }
            let view = try #require(CodePanelStore.existingView(for: doc))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            let left = try #require(view.left)
            let before = (view.decorations.virtualLineCount, left.decorations.virtualLineCount)
            r.publish("login.swift", [error(4..<5, "unused"), error(30..<33, "second")])
            window.tick()
            #expect(view.decorations.virtualLineCount == before.0, "no message rows in the right pane")
            #expect(left.decorations.virtualLineCount == before.1)
            #expect(r.coordinator.diagnostics.counts.byPath["login.swift"]?.errors == 2, "tint and bars remain")
        }
    }

    @Test func returnAfterASessionBlockKeepsTheDiffIdenticalWithDiagnostics() async throws {
        try await DiagRig.run { r in
            _ = await r.rig.workspace.newSession(name: "A")
            try panelOldText.write(to: r.rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
            try await emitEdit(r.rig, old: panelOldText, new: panelNewText, toolUseID: "t1")
            r.rig.workspace.openFilePath = "login.swift"
            let window = try alloyWindow(r.rig.workspace)
            try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
            try await window.runUntil { r.rig.workspace.decorationBuilds >= 1 }
            try await window.runUntil { r.coordinator.status.byPath["login.swift"]?.state == .ready }
            window.tick()
            let doc = try #require(r.rig.workspace.document("login.swift"))
            // (top, height) of the 3 pt bars. A message row above shifts the ones below it by its height.
            @MainActor func bars() -> [[Float]] {
                window.scene.rects.filter { $0.bounds.size.width == 3 && $0.bounds.origin.x > 700 }
                    .map { [Float($0.bounds.origin.y), Float($0.bounds.size.height)] }.sorted { $0[0] < $1[0] }
            }
            // Return at the start of row 2, right after the session's row 1.
            doc.buffer.replace(28..<28, with: "\n", origin: .typing)
            window.tick()
            // The typed row shifts the bars once the view has drained the edit: settle before taking the baseline.
            for _ in 0..<10 { await Task.yield(); window.tick() }
            let baseline = bars()
            r.publish("login.swift", [error(4..<5, "unused")])
            window.tick()
            let with = bars()
            // The session's bar is still one row tall: the new empty row was not taken into it.
            var remaining = with.map { $0[1] }
            for bar in baseline {
                guard let i = remaining.firstIndex(of: bar[1]) else { Issue.record("a bar of height \(bar[1]) is gone: \(baseline) \(with)"); continue }
                remaining.remove(at: i)
            }
            #expect(with.count == baseline.count + 1, "only the diagnostic's own bar and its message row's (one run)")
            r.coordinator.handle(.diagnostics(path: "login.swift", version: Int(doc.buffer.version), items: []))
            // A paint right after another one waits for the next main-actor turn.
            for _ in 0..<10 { await Task.yield(); window.tick() }
            #expect(bars() == baseline)
        }
    }

    @Test func nextProblemMovesCaret() async throws {
        try await DiagRig.run { r in
            try "aaaa\nbbbb\ncccc\ndddd\n".write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            r.publish("main.rs", [error(6..<8), error(11..<12), error(16..<18)])
            window.tick()
            try window.click(window.element(identifier: "code-view"))
            for _ in 0..<5 { window.tick(); await Task.yield() }
            doc.buffer.select(0..<0, reveal: false)
            @MainActor func selection() -> Range<Int> { doc.buffer.primarySelection.range }
            window.typeKey(FilePanelView.f8)
            #expect(selection() == 6..<8)
            window.typeKey(FilePanelView.f8)
            #expect(selection() == 11..<12)
            window.typeKey(FilePanelView.f8)
            #expect(selection() == 16..<18)
            window.typeKey(FilePanelView.f8)
            #expect(selection() == 6..<8, "wraps")
            window.typeKey(FilePanelView.f8, modifierFlags: .shift)
            #expect(selection() == 16..<18, "wraps backwards")
            window.typeKey(FilePanelView.f8, modifierFlags: .shift)
            #expect(selection() == 11..<12)
        }
    }

    @Test func virtualRowsCappedAt200InThePanel() async throws {
        try await DiagRig.run { r in
            try String(repeating: "line\n", count: 300).write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            let view = try #require(CodePanelStore.existingView(for: doc))
            r.publish("main.rs", (0..<300).map { error(($0 * 5)..<($0 * 5 + 1)) })
            window.tick()
            #expect(view.decorations.virtualLineCount == 200)
            #expect(r.coordinator.diagnostics.counts.byPath["main.rs"]?.errors == 300)
        }
    }

    @Test func movingAPathToAnotherServerClearsTheOldServersDiagnostics() async throws {
        try await DiagRig.run { r in
            try "fn main() {}\n".write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
            let window = try await r.open("main.rs")
            r.publish("main.rs", [error(0..<2)])
            window.tick()
            #expect(r.coordinator.diagnostics.entry(for: "main.rs") != nil)
            var settings = r.rig.workspace.settings
            settings.languageServers["fake"] = ServerConfigOverride(extensions: ["nothing"])
            settings.languageServers["fake-swift"] = ServerConfigOverride(extensions: ["rs"])
            try r.rig.workspace.updateSettings(settings)
            window.tick()
            #expect(r.coordinator.diagnostics.entry(for: "main.rs") == nil)
            #expect(r.coordinator.diagnostics.counts.byPath["main.rs"] == nil)
        }
    }

    @Test func closingTheTabClearsTheDiagnostics() async throws {
        try await DiagRig.run { r in
            try "fn main() {}\n".write(to: r.rig.root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
            let window = try await r.open("main.rs")
            r.publish("main.rs", [error(0..<2)])
            window.tick()
            #expect(r.coordinator.diagnostics.counts.byPath["main.rs"] != nil)
            await r.rig.workspace.close("main.rs")
            window.tick()
            #expect(r.coordinator.diagnostics.entry(for: "main.rs") == nil)
            #expect(r.coordinator.diagnostics.counts.byPath.isEmpty)
        }
    }
}
