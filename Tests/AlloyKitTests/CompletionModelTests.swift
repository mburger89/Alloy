import AlloyCore
import AlloyLSP
@testable import AlloyKit
import Foundation
import MetalUI
import MetalUICodeBuffer
import Testing

@MainActor
struct CompletionFilterTests {
    @Test func fuzzyScoreThenSortTextThenLabel() {
        let items = [
            CompletionItem(label: "foobar"), CompletionItem(label: "fb", sortText: "1"), CompletionItem(label: "fb", sortText: "0"),
            CompletionItem(label: "zzz"),
        ]
        let top = CompletionFilter.top(items, query: "fb")
        // "fb" scores best (a contiguous match of its whole text); both of them tie, so sortText "0" goes first.
        #expect(top.prefix(2).map { items[$0].sortText } == ["0", "1"])
        #expect(!top.contains(3))
    }

    @Test func emptyQueryKeepsSortTextOrder() {
        let items = [CompletionItem(label: "b", sortText: "2"), CompletionItem(label: "a", sortText: "3"), CompletionItem(label: "c", sortText: "1"),
                     CompletionItem(label: "d")]
        // "d" has no sortText: its label is the key.
        #expect(CompletionFilter.top(items, query: "") == [2, 0, 1, 3])
    }

    @Test func filterTextIsWhatMatches() {
        let items = [CompletionItem(label: "Display Name", filterText: "name"), CompletionItem(label: "other")]
        #expect(CompletionFilter.top(items, query: "nam") == [0])
    }

    @Test func fiveThousandItemsAreCutToFifty() {
        let items = (0..<5_000).map { CompletionItem(label: "item\($0)", sortText: String(format: "%05d", $0)) }
        let top = CompletionFilter.top(items, query: "item")
        #expect(top.count == 50)
        #expect(top == Array(0..<50))
    }
}

@MainActor
struct CompletionApplyTests {
    private func snap(_ text: String) -> CodeSnapshot { CodeBuffer(text).snapshot() }

    @Test func plainLabelReplacesTheWord() throws {
        let s = snap("x fo")
        let plan = try #require(CompletionApply.plan(item: CompletionItem(label: "foobar"), requestSnapshot: s, current: s, requestCaret: 4,
                                                     caret: 4, wordStart: 2))
        #expect(plan.edits == [ByteEdit(range: 2..<4, text: "foobar")])
        #expect(plan.caret == 8)
    }

    @Test func insertTextBeatsLabel() throws {
        let s = snap("x fo")
        let plan = try #require(CompletionApply.plan(item: CompletionItem(label: "foobar()", insertText: "foobar"), requestSnapshot: s, current: s,
                                                     requestCaret: 4, caret: 4, wordStart: 2))
        #expect(plan.edits[0].text == "foobar")
    }

    @Test func textEditUsesItsInsertRange() throws {
        let s = snap("x.fo")
        let item = CompletionItem(label: "foo", edit: CompletionEdit(insert: 2..<4, newText: "foo!"))
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: s, current: s, requestCaret: 4, caret: 4, wordStart: 2))
        #expect(plan.edits == [ByteEdit(range: 2..<4, text: "foo!")])
    }

    @Test func insertReplaceUsesTheInsertRange() throws {
        let s = snap("fo|bar")
        let item = CompletionItem(label: "foo", edit: CompletionEdit(insert: 0..<2, replace: 0..<6, newText: "foo"))
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: s, current: s, requestCaret: 2, caret: 2, wordStart: 0))
        #expect(plan.edits[0].range == 0..<2)
    }

    @Test func aRangeOffTheCaretLineFallsBackToTheWord() throws {
        let s = snap("a\nx fo")
        let item = CompletionItem(label: "foobar", edit: CompletionEdit(insert: 0..<1, newText: "WRONG"))
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: s, current: s, requestCaret: 6, caret: 6, wordStart: 4))
        #expect(plan.edits == [ByteEdit(range: 4..<6, text: "foobar")])
    }

    @Test func aRangeNotContainingTheCaretFallsBackToTheWord() throws {
        let s = snap("x fo")
        let item = CompletionItem(label: "foobar", edit: CompletionEdit(insert: 0..<1, newText: "WRONG"))
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: s, current: s, requestCaret: 4, caret: 4, wordStart: 2))
        #expect(plan.edits[0] == ByteEdit(range: 2..<4, text: "foobar"))
    }

    @Test func lettersTypedAfterTheRequestAreReplacedToo() throws {
        let request = snap("x fo")
        let now = snap("x foba")
        let item = CompletionItem(label: "foobar", edit: CompletionEdit(insert: 2..<4, newText: "foobar"))
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: request, current: now, requestCaret: 4, caret: 6, wordStart: 2))
        #expect(plan.edits == [ByteEdit(range: 2..<6, text: "foobar")])
        let fallback = try #require(CompletionApply.plan(item: CompletionItem(label: "foobar"), requestSnapshot: request, current: now,
                                                         requestCaret: 4, caret: 6, wordStart: 2))
        #expect(fallback.edits == [ByteEdit(range: 2..<6, text: "foobar")])
    }

    @Test func anAutoImportAboveIsAppliedOnceAndMovesTheCaret() throws {
        let request = snap("use a;\nx fo")
        let now = snap("use a;\nx fob")
        let item = CompletionItem(label: "foobar", additionalEdits: [ByteEdit(range: 6..<6, text: "use b;\n")])
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: request, current: now, requestCaret: 11, caret: 12, wordStart: 9))
        #expect(plan.edits == [ByteEdit(range: 9..<12, text: "foobar"), ByteEdit(range: 6..<6, text: "use b;\n")])
        // The caret ends after "foobar", seven bytes further for the import above it.
        #expect(plan.caret == 9 + 6 + 7)
    }

    @Test func anAdditionalEditOverlappingTheWordIsDropped() throws {
        let s = snap("x fo")
        let item = CompletionItem(label: "foobar", additionalEdits: [ByteEdit(range: 1..<3, text: "!!"), ByteEdit(range: 4..<4, text: ";")])
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: s, current: s, requestCaret: 4, caret: 4, wordStart: 2))
        #expect(plan.edits == [ByteEdit(range: 2..<4, text: "foobar")])
    }

    @Test func anAdditionalEditBelowMovesWithWhatWasTyped() throws {
        let request = snap("x fo\nend")
        let now = snap("x foo\nend")
        let item = CompletionItem(label: "foobar", additionalEdits: [ByteEdit(range: 5..<8, text: "fin")])
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: request, current: now, requestCaret: 4, caret: 5, wordStart: 2))
        #expect(plan.edits == [ByteEdit(range: 2..<5, text: "foobar"), ByteEdit(range: 6..<9, text: "fin")])
    }

    @Test func aSnippetIsPlainTextWithTheCaretAtTheEndStop() throws {
        let s = snap("x fo")
        let item = CompletionItem(label: "foo", insertText: "foo($1)$0", isSnippet: true)
        let plan = try #require(CompletionApply.plan(item: item, requestSnapshot: s, current: s, requestCaret: 4, caret: 4, wordStart: 2))
        #expect(plan.edits[0].text == "foo()")
        #expect(plan.caret == 2 + 5)
        let inside = try #require(CompletionApply.plan(item: CompletionItem(label: "f", insertText: "f(${1:a})", isSnippet: true),
                                                       requestSnapshot: s, current: s, requestCaret: 4, caret: 4, wordStart: 2))
        #expect(inside.edits[0].text == "f(a)")
        #expect(inside.caret == 2 + 4)   // no `$0`: the end
    }

    @Test func aNonAsciiWordBeforeTheCaret() throws {
        let s = snap("x é")   // é is two bytes
        let plan = try #require(CompletionApply.plan(item: CompletionItem(label: "école"), requestSnapshot: s, current: s, requestCaret: 4,
                                                     caret: 4, wordStart: 2))
        #expect(plan.edits == [ByteEdit(range: 2..<4, text: "école")])
        #expect(plan.caret == 2 + "école".utf8.count)
    }

    @Test func nonsenseInputsGiveNoPlan() {
        let s = snap("ab")
        #expect(CompletionApply.plan(item: CompletionItem(label: "x"), requestSnapshot: s, current: s, requestCaret: 2, caret: 9, wordStart: 0) == nil)
        #expect(CompletionApply.plan(item: CompletionItem(label: "x"), requestSnapshot: s, current: s, requestCaret: 2, caret: 1, wordStart: 2) == nil)
    }
}

/// Suspends sleepers until the test lets them go.
actor GateClock {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var pending: Int { waiters.count }

    func sleep() async throws {
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

@MainActor
final class FakeHost: IntelligenceHost {
    let buffer: CodeBuffer
    var selectionState: CodeSelectionState { buffer.selectionState }
    var features: FeatureSet
    var isActive = true
    var requests: [(offset: Int, trigger: CompletionTrigger)] = []
    var resolves = 0
    var reply: LSPOutcome<CompletionList> = .answered(CompletionList(items: []))
    var resolveReply: LSPOutcome<CompletionItem> = .unavailable
    private let cursor: CodeEditCursor

    init(_ text: String, features: FeatureSet = FeatureSet(completion: true, completionTriggers: ["."], completionCommitCharacters: [";"])) {
        buffer = CodeBuffer(text)
        self.features = features
        cursor = buffer.makeEditCursor()
        buffer.selectionState.select(text.utf8.count..<text.utf8.count, reveal: false)
    }

    func flushEdits() {}

    func requestCompletion(offset: Int, snapshot: CodeSnapshot, trigger: CompletionTrigger) async -> LSPOutcome<CompletionList> {
        requests.append((offset, trigger))
        return reply
    }

    func requestResolve(item: CompletionItem, snapshot: CodeSnapshot) async -> LSPOutcome<CompletionItem> {
        resolves += 1
        return resolveReply
    }

    /// Edits as the document services would hand them to the scheduler.
    func drained() -> ([CodeEdit], CodeSnapshot)? {
        guard case .edits(let edits) = cursor.drain(), !edits.isEmpty else { return nil }
        return (edits, buffer.snapshot())
    }
}

@MainActor
struct IntelligenceSchedulerTests {
    private let clock = GateClock()

    private func make(_ text: String = "let x = ", features: FeatureSet? = nil) -> (FakeHost, IntelligenceScheduler) {
        let host = features.map { FakeHost(text, features: $0) } ?? FakeHost(text)
        let clock = clock
        let scheduler = IntelligenceScheduler(host: host, model: IntelligenceOverlayModel(), sleep: { _ in try await clock.sleep() })
        return (host, scheduler)
    }

    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func type(_ text: String, _ host: FakeHost, _ scheduler: IntelligenceScheduler, origin: CodeEditOrigin = .typing) {
        _ = host.selectionState.replaceSelections(with: text, origin: origin)
        if let (edits, snapshot) = host.drained() { scheduler.edited(edits, snapshot: snapshot) }
    }

    @Test func anIdentifierCharacterSchedulesOneRequestAfterTheDebounce() async {
        let (host, scheduler) = make()
        type("f", host, scheduler)
        await settle()
        #expect(host.requests.isEmpty)
        #expect(await clock.pending == 1)
        await clock.fire()
        await settle()
        #expect(host.requests.count == 1)
        #expect(host.requests[0].offset == 9)
    }

    @Test func aSecondKeystrokeWithinTheDebounceReplacesTheTask() async {
        let (host, scheduler) = make()
        type("f", host, scheduler)
        await settle()
        type("o", host, scheduler)
        await settle()
        #expect(await clock.pending == 1)
        await clock.fire()
        await settle()
        #expect(host.requests.count == 1)
        #expect(host.requests[0].offset == 10)
    }

    @Test func aTriggerCharacterAsksAtOnce() async {
        let (host, scheduler) = make("x")
        type(".", host, scheduler)
        await settle()
        #expect(host.requests.count == 1)
        guard case .character(let c) = host.requests[0].trigger else { Issue.record("not a trigger request"); return }
        #expect(c == ".")
        #expect(await clock.pending == 0)
    }

    @Test func nothingElseSchedulesAnything() async {
        let (host, scheduler) = make("abc def")
        type(" ", host, scheduler)                        // whitespace
        type("(", host, scheduler)                        // punctuation that is no trigger
        type("pasted", host, scheduler, origin: .paste)   // a paste
        _ = host.selectionState.replaceSelections(with: "q", origin: .programmatic)
        if let (edits, snapshot) = host.drained() { scheduler.edited(edits, snapshot: snapshot) }
        host.selectionState.undo()                         // undo
        if let (edits, snapshot) = host.drained() { scheduler.edited(edits, snapshot: snapshot) }
        await settle()
        #expect(await clock.pending == 0)
        await clock.fire()
        await settle()
        #expect(host.requests.isEmpty)
    }

    @Test func aNonEmptySelectionOrTwoCaretsScheduleNothing() async {
        let (host, scheduler) = make("abc def")
        host.selectionState.setSelections([CodeSelection(anchor: 0, head: 3), CodeSelection(caret: 7)], primary: 1)
        _ = host.selectionState.replaceSelections(with: "x", origin: .typing)
        if let (edits, snapshot) = host.drained() { scheduler.edited(edits, snapshot: snapshot) }
        host.selectionState.select(0..<2, reveal: false)
        if let (edits, snapshot) = host.drained() { scheduler.edited(edits, snapshot: snapshot) }
        await settle()
        #expect(await clock.pending == 0)
        #expect(host.requests.isEmpty)
    }

    @Test func aViewThatIsNotActiveSchedulesNothing() async {
        let (host, scheduler) = make()
        host.isActive = false
        type("f", host, scheduler)
        await settle()
        #expect(await clock.pending == 0)
        #expect(host.requests.isEmpty)
    }

    @Test func anAnswerShowsRowsAndTypingInsideTheWordOnlyRefilters() async {
        let (host, scheduler) = make("let x = ")
        host.reply = .answered(CompletionList(items: [CompletionItem(label: "foo"), CompletionItem(label: "fob"), CompletionItem(label: "bar")]))
        type("f", host, scheduler)
        await settle()
        await clock.fire()
        await settle()
        #expect(scheduler.model.rows.map(\.label) == ["fob", "foo"])
        type("b", host, scheduler)
        await settle()
        #expect(await clock.pending == 0)
        #expect(host.requests.count == 1)
        #expect(scheduler.model.rows.map(\.label) == ["fob"])
    }

    @Test func aStaleAnswerAfterTheWordMovedIsDropped() async {
        let (host, scheduler) = make("let x = ")
        host.reply = .answered(CompletionList(items: [CompletionItem(label: "foo")]))
        type("f", host, scheduler)
        await settle()
        await clock.fire()
        // The answer is in flight when the user types a space and moves to a new word.
        type(" ", host, scheduler)
        type("z", host, scheduler)
        await settle()
        #expect(scheduler.model.rows.isEmpty)
    }

    @Test func acceptingReplacesTheWordInOneUndoStep() async {
        let (host, scheduler) = make("let x = ")
        host.reply = .answered(CompletionList(items: [CompletionItem(label: "foobar")]))
        type("f", host, scheduler)
        await settle()
        await clock.fire()
        await settle()
        type("o", host, scheduler)
        await settle()
        #expect(scheduler.accept(item: scheduler.model.selectedItem ?? -1))
        #expect(host.buffer.snapshot().text == "let x = foobar")
        #expect(host.selectionState.primarySelection.head == 14)
        #expect(scheduler.model.rows.isEmpty)
        host.selectionState.undo()
        #expect(host.buffer.snapshot().text == "let x = fo")
    }

    @Test func aServerThatSendsNothingClosesThePopup() async {
        let (host, scheduler) = make("let x = ")
        host.reply = .answered(CompletionList(items: [CompletionItem(label: "foo")]))
        type("f", host, scheduler)
        await settle(); await clock.fire(); await settle()
        #expect(scheduler.model.isPresented)
        host.reply = .answered(CompletionList(items: []))
        type(".", host, scheduler)
        await settle()
        #expect(!scheduler.model.isPresented)
        host.reply = .failed("boom")
        type(".", host, scheduler)
        await settle()
        #expect(!scheduler.model.isPresented)
    }

    @Test func theDocPaneIsCutToTwelveLines() {
        let long = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let cut = IntelligenceOverlayModel.cut(long)
        #expect(cut.split(separator: "\n").count == IntelligenceOverlayModel.docLines)
        #expect(cut.hasSuffix("line 12"))
        let short = "a\nb"
        #expect(IntelligenceOverlayModel.cut(short) == short)
    }
}
