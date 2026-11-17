import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// A recording sleeper: every sleeper waits at the gate, and the durations asked for are kept.
private actor ProbeClock {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var durations: [Duration] = []
    var pending: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }

    func fire() {
        let all = waiters
        waiters = [:]
        for (_, c) in all { c.resume() }
    }
}

private func item(_ title: String, role: ServerRole = .main, name: String = "Fake", preferred: Bool = false,
                  diagnostics: [JSONValue] = []) -> CodeActionItem {
    CodeActionItem(title: title, isPreferred: preferred, diagnostics: diagnostics, serverID: name, serverName: name, role: role,
                   rawAction: .object(["title": .string(title)]))
}

@MainActor
private final class ActionHost: IntelligenceHost {
    let buffer: CodeBuffer
    var selectionState: CodeSelectionState { buffer.selectionState }
    var features = FeatureSet(codeAction: true)
    var isActive = true
    var requests: [(range: Range<Int>, automatic: Bool)] = []
    var reply: [CodeActionItem] = []
    var diagnostics: [LSPDiagnostic] = []
    var chosen: [String] = []
    /// Keeps the scheduler alive as long as the host.
    var keep: IntelligenceScheduler?
    var messages: [String] = []
    private(set) var lightbulbLine: Int?
    private(set) var bulbWrites = 0

    private let cursor: CodeEditCursor

    init(_ text: String) { buffer = CodeBuffer(text); cursor = buffer.makeEditCursor() }

    func drained() -> ([CodeEdit], CodeSnapshot)? {
        guard case .edits(let edits) = cursor.drain(), !edits.isEmpty else { return nil }
        return (edits, buffer.snapshot())
    }

    func flushEdits() {}
    func requestCompletion(offset: Int, snapshot: CodeSnapshot, trigger: CompletionTrigger) async -> LSPOutcome<CompletionList> { .unavailable }
    func requestResolve(item: CompletionItem, snapshot: CodeSnapshot) async -> LSPOutcome<CompletionItem> { .unavailable }
    func setLightbulb(line: Int?) { lightbulbLine = line; bulbWrites += 1 }
    func requestCodeActions(range: Range<Int>, automatic: Bool) async -> [CodeActionItem] {
        requests.append((range, automatic))
        return reply
    }
    func chooseCodeAction(_ item: CodeActionItem) async -> CodeActionResult { chosen.append(item.title); return .applied }
    func currentDiagnostics() -> [LSPDiagnostic] { diagnostics }
    func showMessage(_ text: String) { messages.append(text) }

    func move(to offset: Int) { selectionState.select(offset..<offset, reveal: false) }
}

@MainActor
@Suite
struct LightbulbSchedulerTests {
    private let clock = ProbeClock()
    private let text = "aa\nbb\ncc\n"

    private func make(_ features: FeatureSet? = nil) -> (ActionHost, IntelligenceScheduler) {
        let host = ActionHost(text)
        if let features { host.features = features }
        host.reply = [item("Fix")]
        let clock = clock
        let scheduler = IntelligenceScheduler(host: host, model: IntelligenceOverlayModel(), sleep: { try await clock.sleep($0) })
        host.keep = scheduler
        return (host, scheduler)
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func aCaretMoveProbesAfter250msAndNotBefore() async {
        let (host, scheduler) = make()
        host.move(to: 3)
        await settle()
        #expect(host.requests.isEmpty && host.lightbulbLine == nil)
        let d = await clock.durations; #expect(d == [.milliseconds(250)], "\(d)")
        await clock.fire()
        await settle()
        #expect(host.requests.count == 1 && host.requests[0].automatic)
        #expect(host.lightbulbLine == 1)
        #expect(scheduler.probeRequestCount == 1)
    }

    @Test func movingWithinTheLineAsksNothingMore() async {
        let (host, _) = make()
        host.move(to: 3)
        await settle(); await clock.fire(); await settle()
        host.move(to: 4)
        await settle()
        #expect(await clock.pending == 0)
        host.move(to: 3)
        await settle()
        #expect(host.requests.count == 1 && host.lightbulbLine == 1)
    }

    @Test func aLineWithoutActionsClearsTheMarker() async {
        let (host, _) = make()
        host.move(to: 3)
        await settle(); await clock.fire(); await settle()
        #expect(host.lightbulbLine == 1)
        host.reply = []
        host.move(to: 6)
        await settle()
        #expect(host.lightbulbLine == nil, "the marker leaves the line the caret left at once")
        await clock.fire(); await settle()
        #expect(host.lightbulbLine == nil && host.requests.count == 2)
        // Back on the first line at the same text: answered from the cache, no request.
        host.reply = [item("Fix")]
        host.move(to: 3)
        await settle()
        #expect(host.lightbulbLine == 1 && host.requests.count == 2)
    }

    @Test func aBurstOfTypingProbesOnceAfter750ms() async {
        let (host, _) = make()
        host.move(to: 2)
        await settle(); await clock.fire(); await settle()
        let before = host.requests.count
        for ch in ["x", "y", "z"] {
            _ = host.selectionState.replaceSelections(with: ch, origin: .typing)
            await settle()
        }
        #expect(await clock.pending == 1)
        let durations = await clock.durations
        #expect(durations.last == .milliseconds(750))
        await clock.fire(); await settle()
        #expect(host.requests.count == before + 1)
    }

    @Test func nothingProbesWithoutTheCapabilityThePaneOrASingleCaret() async {
        let (none, _) = make(FeatureSet())
        none.move(to: 3)
        await settle()
        #expect(await clock.pending == 0)

        let (inactive, _) = make()
        inactive.isActive = false
        inactive.move(to: 3)
        await settle()
        #expect(await clock.pending == 0 && inactive.requests.isEmpty)

        let (multi, _) = make()
        multi.selectionState.selections = [CodeSelection(caret: 0), CodeSelection(caret: 3)]
        await settle()
        #expect(await clock.pending == 0 && multi.requests.isEmpty && multi.lightbulbLine == nil)
    }

    @Test func stoppingRemovesTheMarkerAndTheTasks() async {
        let (host, scheduler) = make()
        host.move(to: 3)
        await settle(); await clock.fire(); await settle()
        #expect(host.lightbulbLine == 1)
        host.move(to: 6)
        await settle()
        scheduler.stop()
        await settle()
        #expect(host.lightbulbLine == nil)
        #expect(await clock.pending == 0)
        host.move(to: 3)
        await settle()
        #expect(await clock.pending == 0)
    }

    @Test func theListShowsLinterTitlesWithTheirNameAndTheDiagnosticsFixesFirst() async {
        let (host, scheduler) = make()
        let raw = JSONValue.object(["message": .string("bad"), "code": .string("F401")])
        host.diagnostics = [LSPDiagnostic(range: 3..<5, severity: .error, message: "bad", code: "F401", raw: raw)]
        host.reply = [item("Refactor", preferred: true), item("Remove import", role: .linter, name: "Ruff", diagnostics: [raw])]
        host.move(to: 4)
        scheduler.showActions()
        await settle()
        #expect(host.requests.last?.range == 3..<5 && host.requests.last?.automatic == false)
        #expect(scheduler.model.actions.map(\.title) == ["Ruff: Remove import", "Refactor"])
        #expect(scheduler.model.content == .actions)
    }

    @Test func anEmptyAnswerShowsAMessageAndNoList() async {
        let (host, scheduler) = make()
        host.reply = []
        scheduler.showActions()
        await settle()
        #expect(host.messages == ["No quick fixes here"])
        #expect(!scheduler.model.isPresented)
    }

    @Test func aListNeverShowsWithMultipleCaretsAndTypingClosesIt() async throws {
        let (host, scheduler) = make()
        host.selectionState.selections = [CodeSelection(caret: 0), CodeSelection(caret: 3)]
        scheduler.showActions()
        await settle()
        #expect(host.requests.isEmpty)
        host.move(to: 3)
        scheduler.showActions()
        await settle()
        #expect(scheduler.model.isPresented)
        _ = host.selectionState.replaceSelections(with: "x", origin: .typing)
        let (edits, snapshot) = try #require(host.drained())
        scheduler.edited(edits, snapshot: snapshot)
        #expect(!scheduler.model.isPresented)
    }

    @Test func aCaretMoveClosesTheOpenList() async {
        let (host, scheduler) = make()
        host.move(to: 3)
        scheduler.showActions()
        await settle()
        #expect(scheduler.model.isPresented)
        host.move(to: 6)
        await settle()
        #expect(!scheduler.model.isPresented)
    }
}


@MainActor
@Suite
struct LightbulbPanelTests {
    private static let source = "let x = 1\nlet y = 2\nlet z = 3\n"
    private static let caps = #""codeActionProvider":{"resolveProvider":true},"executeCommandProvider":{"commands":["do.it"]}"#
    private static let diagRaw = #"{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"message":"bad","code":"E1"}"#

    private func uri(_ r: Rig) -> String { r.root.appendingPathComponent("main.rs").absoluteString }

    private func edit(_ r: Rig, line: Int = 0, _ text: String = "LET") -> String {
        #"{"changes":{"\#(uri(r))":[{"range":{"start":{"line":\#(line),"character":0},"end":{"line":\#(line),"character":3}},"newText":"\#(text)"}]}}"#
    }

    private func script(_ r: Rig, actions: (Rig) -> String) -> String {
        IntelRig.script(caps: Self.caps, extra: #","replies":{"textDocument/codeAction":[{"result":\#(actions(r))}]}"#)
    }

    private struct Fixture {
        let r: IntelRig
        let window: TestWindow
        let doc: EditorDocument
        let view: OpenDocumentView
        let state: CodeSelectionState
    }

    private func fixture(_ r: IntelRig, diagnostic: Bool = false) async throws -> Fixture {
        try r.write("main.rs", Self.source)
        let window = try await r.open("main.rs")
        let doc = try #require(r.rig.workspace.document("main.rs"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
        if diagnostic {
            let raw = try #require(JSONValue.parse(Data(Self.diagRaw.utf8)))
            r.coordinator.handle(.diagnostics(path: "main.rs", version: Int(doc.buffer.version),
                                              items: [LSPDiagnostic(range: 10..<13, severity: .error, message: "bad", code: "E1", raw: raw)]))
        }
        await r.idle(window, 0.4)   // an opening probe, if any, is over
        return Fixture(r: r, window: window, doc: doc, view: view, state: state)
    }

    private func run(_ actions: @escaping (Rig) -> String, diagnostic: Bool = false, _ body: (Fixture) async throws -> Void) async throws {
        let rig = Rig()
        try await IntelRig.run(rig: rig, script: script(rig, actions: actions)) { r in try await body(try await fixture(r, diagnostic: diagnostic)) }
    }

    private func text(_ doc: EditorDocument) -> String { doc.buffer.snapshot().text }

    private func moveTo(_ f: Fixture, line: Int) {
        let offset = f.doc.buffer.snapshot().lineRange(line).lowerBound + 1
        f.state.select(offset..<offset, reveal: false)
    }

    @Test func theLightbulbAppearsOnlyAfterTheDebounceAndNotTwiceOnALine() async throws {
        try await run({ r in #"[{"title":"Upper","kind":"quickfix","edit":\#(edit(r))}]"# }) { f in
            moveTo(f, line: 2)
            for _ in 0..<3 { f.window.tick(); await Task.yield() }
            #expect(f.view.lightbulbLine != 2)
            await f.r.idle(f.window, 0.6)
            #expect(f.view.lightbulbLine == 2)
            let asked = f.r.count("textDocument/codeAction")
            let offset = f.doc.buffer.snapshot().lineRange(2).lowerBound + 2
            f.state.select(offset..<offset, reveal: false)
            await f.r.idle(f.window, 0.6)
            #expect(f.r.count("textDocument/codeAction") == asked)
            #expect(f.view.lightbulbLine == 2)
        }
    }

    @Test func clickingTheMarkerOpensTheListAndAnotherLineDoesNot() async throws {
        try await run({ r in #"[{"title":"Upper","edit":\#(edit(r))}]"# }) { f in
            moveTo(f, line: 1)
            await f.r.idle(f.window, 0.6)
            #expect(f.view.lightbulbLine == 1)
            let offset = f.doc.buffer.snapshot().lineRange(1).lowerBound
            let point = try await f.r.point(of: offset, in: "main.rs", window: f.window)
            await f.r.idle(f.window, 0.6)
            let lane = try f.window.element(identifier: "code-view").frame.origin.x + Pixels(3)
            f.window.click(at: Point(x: lane, y: point.y))
            try await f.window.runUntil { f.r.exists(f.window, "code-action-menu") }
            #expect(f.r.exists(f.window, "code-action-0"))
            f.window.typeKey(.escape)
            try await f.window.runUntil { !f.r.exists(f.window, "code-action-menu") }
            let other = try await f.r.point(of: f.doc.buffer.snapshot().lineRange(0).lowerBound, in: "main.rs", window: f.window)
            f.window.click(at: Point(x: lane, y: other.y))
            await f.r.idle(f.window, 0.3)
            #expect(!f.r.exists(f.window, "code-action-menu"))
        }
    }

    @Test func typingAKeyClosesTheOpenList() async throws {
        try await run({ r in #"[{"title":"Upper","kind":"quickfix","edit":\#(edit(r))}]"# }) { f in
            moveTo(f, line: 0)
            f.window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            try await f.window.runUntil { f.r.exists(f.window, "code-action-menu") }
            f.window.typeText("q")
            try await f.window.runUntil { !f.r.exists(f.window, "code-action-menu") }
            #expect(text(f.doc).contains("q"))
        }
    }

    @Test func commandDotListsTheActionAndReturnAppliesItInOneUndoStep() async throws {
        try await run({ r in #"[{"title":"Upper","kind":"quickfix","isPreferred":true,"edit":\#(edit(r))}]"# }) { f in
            moveTo(f, line: 0)
            f.window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            try await f.window.runUntil { f.r.exists(f.window, "code-action-menu") }
            #expect(f.view.overlayModel.actions.map(\.title) == ["Upper"])
            f.window.typeKey(.return)
            try await f.window.runUntil { text(f.doc) == "LET x = 1\nlet y = 2\nlet z = 3\n" }
            try await f.window.runUntil { !f.r.exists(f.window, "code-action-menu") }
            #expect(f.state.undo())
            #expect(text(f.doc) == Self.source)
        }
    }

    @Test func f8ThenCommandDotListsTheDiagnosticsFixesFirst() async throws {
        let actions: (Rig) -> String = { r in
            #"[{"title":"Other","kind":"refactor","edit":\#(edit(r))},{"title":"Fix bad","kind":"quickfix","diagnostics":[\#(Self.diagRaw)],"edit":\#(edit(r, line: 1))}]"#
        }
        try await run(actions, diagnostic: true) { f in
            moveTo(f, line: 0)
            f.window.typeKey(FilePanelView.f8)
            #expect(f.state.primarySelection.range == 10..<13)
            f.window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            try await f.window.runUntil { f.r.exists(f.window, "code-action-menu") }
            #expect(f.view.overlayModel.actions.map(\.title) == ["Fix bad", "Other"])
        }
    }

    @Test func anActionWhoseCommandTheServerDidNotListIsAbsent() async throws {
        try await run({ r in
            #"[{"title":"Ghost","command":{"title":"Ghost","command":"not.listed"}},{"title":"Real","command":{"title":"Real","command":"do.it"}}]"#
        }) { f in
            moveTo(f, line: 0)
            f.window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            try await f.window.runUntil { f.r.exists(f.window, "code-action-menu") }
            #expect(f.view.overlayModel.actions.map(\.title) == ["Real"])
        }
    }

    @Test func theMenuItemOpensTheList() async throws {
        try await run({ r in #"[{"title":"Upper","edit":\#(edit(r))}]"# }) { f in
            moveTo(f, line: 0)
            try f.window.testApp.performMenuBarItem(accessibilityIdentifier: "menu-quick-fix")
            try await f.window.runUntil { f.r.exists(f.window, "code-action-menu") }
        }
    }

    @Test func noQuickFixesSaysSo() async throws {
        try await run({ _ in "[]" }) { f in
            moveTo(f, line: 0)
            f.window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            try await f.window.runUntil { f.view.definitionMessage == "No quick fixes here" }
            #expect(!f.r.exists(f.window, "code-action-menu"))
        }
    }

    @Test func noCapabilityNoSchedulerNoProbeNoMarker() async throws {
        try await IntelRig.run(script: IntelRig.script()) { r in
            try r.write("main.rs", Self.source)
            let window = try await r.open("main.rs")
            let doc = try #require(r.rig.workspace.document("main.rs"))
            let view = try #require(CodePanelStore.existingView(for: doc))
            let state = try #require(r.rig.workspace.selectionState(for: "main.rs", in: .chat))
            state.select(12..<12, reveal: false)
            await r.idle(window, 0.6)
            #expect(view.lightbulbLine == nil && r.count("textDocument/codeAction") == 0)
            window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            await r.idle(window, 0.2)
            #expect(!r.exists(window, "code-action-menu"))
        }
    }

    @Test func twoCaretsAndAReadOnlyViewProbeNothing() async throws {
        try await run({ r in #"[{"title":"Upper","edit":\#(edit(r))}]"# }) { f in
            let before = f.r.count("textDocument/codeAction")
            f.state.selections = [CodeSelection(caret: 1), CodeSelection(caret: 12)]
            await f.r.idle(f.window, 0.6)
            #expect(f.r.count("textDocument/codeAction") == before && f.view.lightbulbLine == nil)
            f.window.typeKey(KeyEquivalent("."), modifierFlags: .primary)
            await f.r.idle(f.window, 0.2)
            #expect(!f.r.exists(f.window, "code-action-menu"))
        }
    }

    @Test func closingTheViewRemovesTheMarker() async throws {
        try await run({ r in #"[{"title":"Upper","edit":\#(edit(r))}]"# }) { f in
            moveTo(f, line: 1)
            await f.r.idle(f.window, 0.6)
            #expect(f.view.lightbulbLine == 1)
            f.view.close()
            #expect(f.view.lightbulbLine == nil)
        }
    }
}
