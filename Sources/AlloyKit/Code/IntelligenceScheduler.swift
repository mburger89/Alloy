import AlloyLSP
import Foundation
import MetalUI
import MetalUICodeBuffer
import Observation

/// What the scheduler needs of the editor view it works for; the view provides it, a test fakes it.
@MainActor
protocol IntelligenceHost: AnyObject {
    var buffer: CodeBuffer { get }
    var selectionState: CodeSelectionState { get }
    var features: FeatureSet { get }
    /// Whether this view may show anything now: the focused pane's view of its active tab, editable, open at a server, not
    /// closed, and not the side-by-side diff.
    var isActive: Bool { get }
    /// Sends the edits the buffer holds that the server has not been told about.
    func flushEdits()
    func requestCompletion(offset: Int, snapshot: CodeSnapshot, trigger: CompletionTrigger) async -> LSPOutcome<CompletionList>
    func requestResolve(item: CompletionItem, snapshot: CodeSnapshot) async -> LSPOutcome<CompletionItem>
    func requestSignature(offset: Int, snapshot: CodeSnapshot, trigger: SignatureTrigger) async -> LSPOutcome<SignatureInfo?>
    /// The lightbulb's line (nil when none is shown) and its writer; the marker is a line decoration of its own owner.
    var lightbulbLine: Int? { get }
    func setLightbulb(line: Int?)
    /// The code actions for a byte range of the document (empty when none, or the buffer moved while asking).
    func requestCodeActions(range: Range<Int>, automatic: Bool) async -> [CodeActionItem]
    func chooseCodeAction(_ item: CodeActionItem) async -> CodeActionResult
    func currentDiagnostics() -> [LSPDiagnostic]
    func showMessage(_ text: String)
}

extension IntelligenceHost {
    func requestSignature(offset: Int, snapshot: CodeSnapshot, trigger: SignatureTrigger) async -> LSPOutcome<SignatureInfo?> { .unavailable }
    var lightbulbLine: Int? { nil }
    func setLightbulb(line: Int?) {}
    func requestCodeActions(range: Range<Int>, automatic: Bool) async -> [CodeActionItem] { [] }
    func chooseCodeAction(_ item: CodeActionItem) async -> CodeActionResult { .cancelled }
    func currentDiagnostics() -> [LSPDiagnostic] { [] }
    func showMessage(_ text: String) {}
}

/// Completion as you type for one editor view. It exists only while the view's document is open at a server that offers
/// completion, signature help or code actions, so a view without one pays nothing per keystroke.
@MainActor
final class IntelligenceScheduler {
    nonisolated static let debounce: Duration = .milliseconds(60)
    nonisolated static let resolveSettle: Duration = .milliseconds(80)
    /// The longest word looked back over from the caret.
    nonisolated static let wordLookback = 256

    private let host: IntelligenceHost
    let model: IntelligenceOverlayModel
    private let sleep: @Sendable (Duration) async throws -> Void

    private let triggerBytes: Set<UInt8>
    private let triggerScalars: Set<Unicode.Scalar>
    private let commitScalars: Set<Unicode.Scalar>
    /// Bytes that continue a word: ASCII letters, digits, `_`, and every byte of a non-ASCII scalar.
    private let identifierBytes: [Bool]

    // The open list.
    private var items: [CompletionItem] = []
    private var isIncomplete = false
    private var requestSnapshot: CodeSnapshot?
    private var requestCaret = 0
    private var wordStart = 0
    private var resolved: Set<Int> = []
    /// Items whose resolve answer has been merged in.
    private var resolveAnswered: Set<Int> = []
    /// An accept waiting for its item's resolve answer (the longest it waits is `acceptResolveWait`).
    private var accepting = false
    nonisolated static let acceptResolveWait: Duration = .seconds(1)
    private var docs: [Int: String] = [:]

    // The open signature help.
    private let sigTriggers: Set<Unicode.Scalar>
    private let sigRetriggers: Set<Unicode.Scalar>
    private var sigInfo: SignatureInfo?
    private var sigIndex = 0
    /// Where the call's opening character is; kept in step with every edit.
    private var sigStart = 0
    private var sigGeneration = 0
    private var sigTask: Task<Void, Never>?
    private(set) var signatureRequestCount = 0

    // The lightbulb probe and the action list.
    nonisolated static let probeAfterMove: Duration = .milliseconds(250)
    nonisolated static let probeAfterTyping: Duration = .milliseconds(750)
    private var stopped = false
    private var probeTask: Task<Void, Never>?
    private var probeGeneration = 0
    /// The buffer version when the last probe was scheduled; a caret move at another version is typing.
    private var lastScheduledVersion: UInt64?
    /// Which lines have an answer at `probeCacheVersion`.
    private var probeCache: [Int: Bool] = [:]
    private var probeCacheVersion: UInt64?
    private(set) var probeRequestCount = 0
    private var actionItems: [CodeActionItem] = []
    private var actionTask: Task<Void, Never>?
    private var actionGeneration = 0

    /// Requests this scheduler has sent (test observability).
    private(set) var requestCount = 0
    private var generation = 0
    private var filterGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?

    /// Whether a list is held (the popup may still be hidden when nothing matches what is typed).
    var isOpen: Bool { !items.isEmpty }
    var isShowing: Bool { model.isPresented && model.content == .completion }

    init(host: IntelligenceHost, model: IntelligenceOverlayModel,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.host = host
        self.model = model
        self.sleep = sleep
        let features = host.features
        var bytes: Set<UInt8> = []
        var scalars: Set<Unicode.Scalar> = []
        for trigger in features.completionTriggers where trigger.unicodeScalars.count == 1 {
            let s = trigger.unicodeScalars.first!
            if s.isASCII { bytes.insert(UInt8(s.value)) } else { scalars.insert(s) }
        }
        triggerBytes = bytes
        triggerScalars = scalars
        commitScalars = Set(features.completionCommitCharacters.compactMap { $0.unicodeScalars.count == 1 ? $0.unicodeScalars.first : nil })
        func scalarSet(_ list: [String]) -> Set<Unicode.Scalar> {
            features.signatureHelp ? Set(list.compactMap { $0.unicodeScalars.count == 1 ? $0.unicodeScalars.first : nil }) : []
        }
        sigTriggers = scalarSet(features.signatureTriggers)
        sigRetriggers = scalarSet(features.signatureRetriggers)
        var mask = [Bool](repeating: false, count: 256)
        for b in 0..<256 {
            let c = UInt8(b)
            mask[b] = b >= 0x80 || c == UInt8(ascii: "_") || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
        }
        identifierBytes = mask
        if features.codeAction { armSelectionObservation() }
    }

    // MARK: Edits

    /// The buffer changed (called for every drained batch, on the main actor). Decides without allocating whether anything
    /// is to be done: a typed identifier character schedules one debounced request, a trigger character asks at once, a
    /// deletion only refilters an open popup, and anything else (whitespace, a paste, undo, another caret) closes it.
    func edited(_ edits: [CodeEdit], snapshot: CodeSnapshot) {
        guard let last = edits.last else { return }
        if isActionsOpen { closeActions() }
        if host.features.codeAction { scheduleProbe() }
        guard host.isActive else { if hasState || sigActive { close() }; return }
        let selections = host.selectionState.selections
        guard selections.count == 1, selections[0].isEmpty else { if hasState || sigActive { close() }; return }
        let caret = selections[0].head
        if sigActive || !sigTriggers.isEmpty { signatureEdited(edits, caret: caret) }
        switch last.origin {
        case .typing:
            guard let scalar = last.newText.unicodeScalars.last, last.range.lowerBound + last.newText.utf8.count == caret,
                  snapshot.version == last.version else { if hasState { closeCompletion() }; return }
            guard host.features.completion else { return }
            if isTrigger(scalar) {
                request(.character(String(scalar)))
            } else if scalar.isASCII ? identifierBytes[Int(scalar.value)] : true {
                typedInWord(snapshot: snapshot, caret: caret)
            } else if hasState {
                closeCompletion()
            }
        case .deletion:
            guard host.features.completion else { return }
            if isOpen { typedInWord(snapshot: snapshot, caret: caret, typed: false) } else if hasState { closeCompletion() }
        default:
            if hasState { closeCompletion() }
        }
    }

    private var sigActive: Bool { sigInfo != nil || sigTask != nil }

    private var hasState: Bool { isOpen || debounceTask != nil || requestTask != nil || model.content != .none }

    private func isTrigger(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII ? triggerBytes.contains(UInt8(scalar.value)) : triggerScalars.contains(scalar)
    }

    private func isIdentifierByte(_ b: UInt8) -> Bool { identifierBytes[Int(b)] }

    /// The start of the word ending at `caret`.
    func wordStart(in snapshot: CodeSnapshot, caret: Int) -> Int {
        var at = caret
        let floor = max(0, caret - Self.wordLookback)
        while at > floor, isIdentifierByte(snapshot.byte(at: at - 1)) { at -= 1 }
        return at
    }

    private func typedInWord(snapshot: CodeSnapshot, caret: Int, typed: Bool = true) {
        let start = wordStart(in: snapshot, caret: caret)
        if isOpen {
            guard start == wordStart, caret >= wordStart, snapshot.point(at: caret).row == requestSnapshot?.point(at: requestCaret).row else {
                closeCompletion()
                if typed { schedule() }
                return
            }
            refilter()
            if isIncomplete, typed { schedule() }
        } else if typed {
            schedule()
        } else {
            closeCompletion()
        }
    }

    // MARK: Requests

    /// Asks after the debounce, replacing a request still waiting or in flight.
    private func schedule() {
        debounceTask?.cancel()
        requestTask?.cancel()
        requestTask = nil
        generation += 1
        let sleep = sleep
        debounceTask = Task { [weak self] in
            do { try await sleep(Self.debounce) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.request(self.isOpen && self.isIncomplete ? .incomplete : .invoked)
        }
    }

    /// ⌃Space: asks now, whatever was typed.
    func invoke() {
        guard host.isActive else { return }
        host.flushEdits()
        request(.invoked)
    }

    private func request(_ trigger: CompletionTrigger) {
        debounceTask?.cancel()
        debounceTask = nil
        requestTask?.cancel()
        let selections = host.selectionState.selections
        guard host.isActive, host.features.completion, selections.count == 1, selections[0].isEmpty else { closeCompletion(); return }
        generation += 1
        requestCount += 1
        let gen = generation
        let snapshot = host.buffer.snapshot()
        let caret = min(selections[0].head, snapshot.utf8Count)
        let start = wordStart(in: snapshot, caret: caret)
        let host = host
        requestTask = Task { [weak self] in
            let outcome = await host.requestCompletion(offset: caret, snapshot: snapshot, trigger: trigger)
            guard !Task.isCancelled, let self, self.generation == gen else { return }
            self.requestTask = nil
            self.answered(outcome, snapshot: snapshot, caret: caret, wordStart: start)
        }
    }

    private func answered(_ outcome: LSPOutcome<CompletionList>, snapshot: CodeSnapshot, caret: Int, wordStart start: Int) {
        guard case .answered(let list) = outcome else { return }
        let selections = host.selectionState.selections
        guard host.isActive, selections.count == 1, selections[0].isEmpty else { closeCompletion(); return }
        // The answer is shown only when the caret is still on its line, in the same word, at or after where it asked.
        let now = host.buffer.snapshot()
        let current = selections[0].head
        guard current >= caret, current <= now.utf8Count, now.point(at: current).row == snapshot.point(at: caret).row,
              wordStart(in: now, caret: current) == start else { return }
        guard !list.items.isEmpty else { closeCompletion(); return }
        items = list.items
        isIncomplete = list.isIncomplete
        requestSnapshot = snapshot
        requestCaret = caret
        wordStart = start
        resolved = []
        resolveAnswered = []
        docs = [:]
        resolveTask?.cancel()
        refilter(keepSelection: false)
    }

    // MARK: Filter

    private func query() -> String? {
        let now = host.buffer.snapshot()
        let selections = host.selectionState.selections
        guard let head = selections.first?.head, head >= wordStart, head <= now.utf8Count else { return nil }
        return now.text(in: wordStart..<head)
    }

    private func refilter(keepSelection: Bool = true) {
        guard let query = query() else { closeCompletion(); return }
        filterGeneration += 1
        let gen = filterGeneration
        let keep = keepSelection ? model.selectedItem : nil
        filterTask?.cancel()
        let items = items
        if items.count <= 400 {
            present(CompletionFilter.top(items, query: query), keep: keep)
            return
        }
        filterTask = Task { [weak self] in
            let top = await Task.detached(priority: .userInitiated) { CompletionFilter.top(items, query: query) }.value
            guard !Task.isCancelled, let self, self.filterGeneration == gen else { return }
            self.present(top, keep: keep)
        }
    }

    private func present(_ top: [Int], keep: Int?) {
        let rows = top.prefix(IntelligenceOverlayModel.rowCap).map { i -> CompletionRow in
            let item = items[i]
            return CompletionRow(index: i, label: item.label, detail: item.detail, kindGlyph: CompletionRow.glyph(for: item.kind))
        }
        if rows.isEmpty {
            model.clear()
            return
        }
        model.show(.completion, rows: Array(rows), keepSelectionOn: keep)
        selectionSettled()
    }

    // MARK: Resolve and documentation

    /// The selection moved (or the rows changed): shows what is known of the item's documentation now and resolves it once.
    private func selectionSettled() {
        resolveTask?.cancel()
        resolveTask = nil
        guard let index = model.selectedItem, items.indices.contains(index) else { model.setDoc(nil); return }
        model.setDoc(docs[index] ?? items[index].documentation)
        guard host.features.completionResolve, !resolved.contains(index) else { return }
        let gen = generation, sleep = sleep
        let host = host
        resolveTask = Task { [weak self] in
            do { try await sleep(Self.resolveSettle) } catch { return }
            guard !Task.isCancelled, let self, self.generation == gen, self.items.indices.contains(index) else { return }
            self.resolved.insert(index)
            var item = self.items[index]
            let now = host.buffer.snapshot()
            // The item's ranges belong to the request's text; once the user typed on, only the server's `data` counts.
            if now.version != self.requestSnapshot?.version { item.edit = nil }
            let outcome = await host.requestResolve(item: item, snapshot: now)
            guard !Task.isCancelled, self.generation == gen, self.items.indices.contains(index), case .answered(let merged) = outcome else { return }
            self.merge(merged, into: index)
        }
    }

    /// Folds a resolve answer into the item at `index`.
    private func merge(_ merged: CompletionItem, into index: Int) {
        guard items.indices.contains(index) else { return }
        var updated = items[index]
        updated.detail = merged.detail ?? updated.detail
        updated.documentation = merged.documentation ?? updated.documentation
        if !merged.additionalEdits.isEmpty { updated.additionalEdits = merged.additionalEdits }
        items[index] = updated
        resolveAnswered.insert(index)
        if let doc = updated.documentation { docs[index] = doc }
        if model.selectedItem == index { model.setDoc(docs[index]) }
    }

    // MARK: Signature help

    private func signatureEdited(_ edits: [CodeEdit], caret: Int) {
        let wasOpen = sigInfo != nil
        if wasOpen {
            for edit in edits where edit.range.upperBound <= sigStart {
                sigStart += edit.newText.utf8.count - edit.range.count
            }
            if caret <= sigStart { closeSignature(); return }
        }
        guard let last = edits.last else { return }
        if last.origin == .typing, let scalar = last.newText.unicodeScalars.last, last.range.lowerBound + last.newText.utf8.count == caret {
            if sigTriggers.contains(scalar) {
                requestSignature(.character(String(scalar)), start: caret - last.newText.utf8.count, keepStart: false)
                return
            }
            if wasOpen {
                requestSignature(sigRetriggers.contains(scalar) ? .retrigger(String(scalar)) : .retrigger(nil), start: sigStart, keepStart: true)
                return
            }
        } else if wasOpen {
            requestSignature(.retrigger(nil), start: sigStart, keepStart: true)
            return
        }
        // Not open and nothing that opens it: an answer still in flight belongs to an older text.
        if sigTask != nil { sigGeneration += 1; sigTask?.cancel(); sigTask = nil }
    }

    /// ⌃⇧Space: asks now, whatever was typed.
    func invokeSignature() {
        guard host.isActive, host.features.signatureHelp else { return }
        host.flushEdits()
        let selections = host.selectionState.selections
        guard selections.count == 1, selections[0].isEmpty else { return }
        let snapshot = host.buffer.snapshot()
        let caret = min(selections[0].head, snapshot.utf8Count)
        requestSignature(.invoked, start: callStart(in: snapshot, caret: caret), keepStart: false)
    }

    /// The offset of the nearest unmatched "(" before `caret`; without one, the byte before the caret, so that typing at
    /// the caret does not count as leaving the call.
    private func callStart(in snapshot: CodeSnapshot, caret: Int) -> Int {
        var depth = 0
        var at = caret
        let floor = max(0, caret - 4096)
        while at > floor {
            at -= 1
            switch snapshot.byte(at: at) {
            case UInt8(ascii: ")"): depth += 1
            case UInt8(ascii: "("):
                if depth == 0 { return at }
                depth -= 1
            default: break
            }
        }
        return caret - 1
    }

    private func requestSignature(_ trigger: SignatureTrigger, start: Int, keepStart: Bool) {
        let selections = host.selectionState.selections
        guard host.isActive, host.features.signatureHelp, selections.count == 1, selections[0].isEmpty else { closeSignature(); return }
        sigTask?.cancel()
        sigGeneration += 1
        signatureRequestCount += 1
        let gen = sigGeneration
        let snapshot = host.buffer.snapshot()
        let caret = min(selections[0].head, snapshot.utf8Count)
        let host = host
        sigTask = Task { [weak self] in
            let outcome = await host.requestSignature(offset: caret, snapshot: snapshot, trigger: trigger)
            guard !Task.isCancelled, let self, self.sigGeneration == gen else { return }
            self.sigTask = nil
            self.signatureAnswered(outcome, snapshot: snapshot, start: start, keepStart: keepStart)
        }
    }

    private func signatureAnswered(_ outcome: LSPOutcome<SignatureInfo?>, snapshot: CodeSnapshot, start: Int, keepStart: Bool) {
        guard case .answered(let answer) = outcome else { return }
        let selections = host.selectionState.selections
        guard host.isActive, selections.count == 1, selections[0].isEmpty, host.buffer.snapshot().version == snapshot.version,
              let info = answer else { closeSignature(); return }
        if selections[0].head < start { closeSignature(); return }
        let opening = sigInfo == nil
        if !keepStart || opening { sigStart = start }
        sigInfo = info
        sigIndex = info.activeSignature
        showSignature()
    }

    private func showSignature() {
        guard let info = sigInfo, info.signatures.indices.contains(sigIndex) else { model.setSignature(nil); return }
        let signature = info.signatures[sigIndex]
        var active: Range<Int>?
        if let p = info.activeParameter, signature.parameters.indices.contains(p) {
            let r = signature.parameters[p]
            if r.end > r.start { active = r.start..<r.end }
        }
        model.setSignature(SignatureStrip(label: signature.label, activeParameter: active, index: sigIndex, count: info.signatures.count))
    }

    private func cycleSignature(_ step: Int) {
        guard let info = sigInfo, info.signatures.count > 1 else { return }
        sigIndex = (sigIndex + step + info.signatures.count) % info.signatures.count
        showSignature()
    }

    /// After a key that moves the caret: closes the strip once the caret is left of the call's opening character.
    private func checkSignatureCaret() {
        guard sigInfo != nil else { return }
        let selections = host.selectionState.selections
        guard selections.count == 1, selections[0].isEmpty, selections[0].head > sigStart else { closeSignature(); return }
    }

    func closeSignature() {
        sigGeneration += 1
        sigTask?.cancel(); sigTask = nil
        sigInfo = nil
        model.setSignature(nil)
    }

    // MARK: Keys

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if isActionsOpen { return handleActionKey(press) }
        guard host.isActive, isShowing || sigInfo != nil else { return .ignored }
        let plain = press.modifiers.isEmpty
        if press.modifiers == .option, sigInfo != nil, press.key == .upArrow || press.key == .downArrow {
            cycleSignature(press.key == .upArrow ? -1 : 1)
            return .handled
        }
        guard isShowing else {
            if press.key == .escape, plain { closeSignature(); return .handled }
            if sigInfo != nil, [.leftArrow, .rightArrow, .home, .end, .upArrow, .downArrow, .pageUp, .pageDown].contains(press.key) {
                Task { @MainActor [weak self] in await Task.yield(); self?.checkSignatureCaret() }
            }
            return .ignored
        }
        switch press.key {
        case .escape where plain:
            closeCompletion()
            return .handled
        case .upArrow where plain, .downArrow where plain:
            let rows = model.rows.count
            guard rows > 0 else { return .ignored }
            let step = press.key == .upArrow ? -1 : 1
            model.select((model.selected + step + rows) % rows)
            selectionSettled()
            return .handled
        case .return where plain, .tab where plain:
            guard let item = model.selectedItem else { return .ignored }
            if accepting { return .handled }
            return accept(item: item) ? .handled : .ignored
        case .leftArrow, .rightArrow, .home, .end, .pageUp, .pageDown, .upArrow, .downArrow:
            closeCompletion()
            if sigInfo != nil { Task { @MainActor [weak self] in await Task.yield(); self?.checkSignatureCaret() } }
            return .ignored
        default:
            break
        }
        // A typed commit character accepts the item and is then typed itself (the view inserts it).
        guard press.modifiers.isSubset(of: [.shift]), press.characters.unicodeScalars.count == 1,
              let scalar = press.characters.unicodeScalars.first, !(scalar.isASCII && identifierBytes[Int(scalar.value)]),
              let index = model.selectedItem, items.indices.contains(index) else { return .ignored }
        let item = items[index]
        let commit = item.commitCharacters.map { $0.contains(String(scalar)) } ?? commitScalars.contains(scalar)
        guard commit else { return .ignored }
        if accepting { return .handled }
        if needsResolve(index) {
            // The character is typed once the import has arrived, so the key is taken here.
            _ = accept(item: index, thenTyping: String(scalar))
            return .handled
        }
        _ = accept(item: index)
        return .ignored
    }

    // MARK: Accept

    private func needsResolve(_ index: Int) -> Bool {
        host.features.completionResolve && !resolveAnswered.contains(index)
    }

    /// Applies the item at `index` of the list. When its resolve answer (which may carry the auto-import) has not arrived,
    /// waits for it for at most `acceptResolveWait` first, then applies; `thenTyping` is inserted after the word either way.
    /// False (and the popup closes) when the caret is no longer in the word.
    @discardableResult
    func accept(item index: Int, thenTyping typed: String? = nil) -> Bool {
        guard needsResolve(index), items.indices.contains(index), host.isActive else { return applyAccept(index, thenTyping: typed) }
        guard !accepting else { return true }
        accepting = true
        resolveTask?.cancel(); resolveTask = nil
        let gen = generation, host = host, sleep = sleep
        var item = items[index]
        let now = host.buffer.snapshot()
        if now.version != requestSnapshot?.version { item.edit = nil }
        // The answer and the deadline race; whichever comes first finishes the accept, once.
        var finished = false
        var timer: Task<Void, Never>?
        var request: Task<Void, Never>?
        let finish: @MainActor (CompletionItem?) -> Void = { [weak self] merged in
            guard !finished else { return }
            finished = true
            timer?.cancel(); request?.cancel()
            guard let self, self.generation == gen else { return }
            self.accepting = false
            if let merged { self.merge(merged, into: index) }
            if !self.applyAccept(index, thenTyping: typed), let typed { self.type(typed) }
        }
        request = Task { @MainActor in
            let outcome = await host.requestResolve(item: item, snapshot: now)
            if case .answered(let merged) = outcome { finish(merged) } else { finish(nil) }
        }
        timer = Task { @MainActor in
            try? await sleep(Self.acceptResolveWait)
            finish(nil)
        }
        return true
    }

    private func type(_ text: String) {
        let state = host.selectionState
        guard state.selections.count == 1, state.selections[0].isEmpty else { return }
        let caret = state.selections[0].head
        _ = state.transaction { $0.replace(caret..<caret, with: text, origin: .programmatic) }
        state.select(caret + text.utf8.count..<caret + text.utf8.count, reveal: true)
    }

    private func applyAccept(_ index: Int, thenTyping typed: String?) -> Bool {
        let state = host.selectionState
        guard items.indices.contains(index), let snapshot = requestSnapshot, host.isActive,
              state.selections.count == 1, state.selections[0].isEmpty else { closeCompletion(); return false }
        let now = host.buffer.snapshot()
        let caret = state.selections[0].head
        guard caret >= wordStart, caret <= now.utf8Count, wordStart(in: now, caret: caret) == wordStart,
              let plan = CompletionApply.plan(item: items[index], requestSnapshot: snapshot, current: now, requestCaret: requestCaret,
                                              caret: caret, wordStart: wordStart) else { closeCompletion(); return false }
        closeCompletion()
        _ = state.transaction { buffer in
            for edit in plan.edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                buffer.replace(edit.range, with: edit.text, origin: .programmatic)
            }
        }
        state.select(plan.caret..<plan.caret, reveal: true)
        if let typed { type(typed) }
        return true
    }

    /// A tap on a row of the popup.
    func accept(row position: Int) {
        if isActionsOpen { chooseAction(at: position); return }
        guard model.rows.indices.contains(position) else { return }
        accept(item: model.rows[position].index)
    }

    // MARK: Close

    /// Closes everything the overlay shows.
    func close() {
        closeCompletion()
        closeSignature()
        closeActions()
    }

    /// The view is going away or this scheduler is being replaced: drops the lightbulb and every task.
    func stop() {
        stopped = true
        close()
        probeGeneration += 1
        probeTask?.cancel(); probeTask = nil
        actionTask?.cancel(); actionTask = nil
        if host.lightbulbLine != nil { host.setLightbulb(line: nil) }
    }

    func closeCompletion() {
        generation += 1
        filterGeneration += 1
        debounceTask?.cancel(); debounceTask = nil
        requestTask?.cancel(); requestTask = nil
        filterTask?.cancel(); filterTask = nil
        resolveTask?.cancel(); resolveTask = nil
        items = []
        isIncomplete = false
        requestSnapshot = nil
        resolved = []
        resolveAnswered = []
        accepting = false
        docs = [:]
        model.clear()
    }
}

// MARK: Lightbulb and the action list

extension IntelligenceScheduler {
    var isActionsOpen: Bool { model.content == .actions && !model.actions.isEmpty }

    /// Watches the caret: every change of the selections hops to the main actor, re-arms and schedules a probe. Armed once
    /// per change, never per frame.
    private func armSelectionObservation() {
        guard !stopped else { return }
        let state = host.selectionState
        withObservationTracking {
            _ = state.selections
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.armSelectionObservation()
                if self.isActionsOpen { self.closeActions() }
                self.scheduleProbe()
            }
        }
    }

    /// A caret move or an edit: decides whether the lightbulb for the caret's line is to be asked for, and when.
    func scheduleProbe() {
        guard !stopped, host.features.codeAction else { return }
        probeTask?.cancel(); probeTask = nil
        probeGeneration += 1
        let selections = host.selectionState.selections
        guard host.isActive, selections.count == 1, selections[0].isEmpty else {
            if host.lightbulbLine != nil { host.setLightbulb(line: nil) }
            return
        }
        let snapshot = host.buffer.snapshot()
        let caret = min(selections[0].head, snapshot.utf8Count)
        let line = snapshot.point(at: caret).row
        let typing = lastScheduledVersion != nil && snapshot.version != lastScheduledVersion
        lastScheduledVersion = snapshot.version
        if probeCacheVersion != snapshot.version { probeCache = [:]; probeCacheVersion = snapshot.version }
        if let known = probeCache[line] {
            // Moving within a line, or back to one already asked about at this text, asks nothing.
            if known, host.lightbulbLine != line { host.setLightbulb(line: line) }
            if !known, host.lightbulbLine != nil { host.setLightbulb(line: nil) }
            return
        }
        if let shown = host.lightbulbLine, shown != line { host.setLightbulb(line: nil) }
        let delay = typing ? Self.probeAfterTyping : Self.probeAfterMove
        let gen = probeGeneration, sleep = sleep
        probeTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.probeGeneration == gen else { return }
            self.probeTask = nil
            await self.probe(line: line, version: snapshot.version, generation: gen)
        }
    }

    private func probe(line: Int, version: UInt64, generation gen: Int) async {
        let selections = host.selectionState.selections
        guard !stopped, host.isActive, selections.count == 1, selections[0].isEmpty else { return }
        host.flushEdits()
        let snapshot = host.buffer.snapshot()
        guard snapshot.version == version, snapshot.point(at: min(selections[0].head, snapshot.utf8Count)).row == line else {
            scheduleProbe()
            return
        }
        probeRequestCount += 1
        let items = await host.requestCodeActions(range: snapshot.lineRange(line), automatic: true)
        guard !Task.isCancelled, !stopped, probeGeneration == gen, host.buffer.version == version else { return }
        let any = items.contains { $0.disabledReason == nil }
        probeCache[line] = any
        let now = host.selectionState.selections
        guard host.isActive, now.count == 1, now[0].isEmpty,
              host.buffer.snapshot().point(at: min(now[0].head, snapshot.utf8Count)).row == line else { return }
        if any { host.setLightbulb(line: line) } else if host.lightbulbLine != nil { host.setLightbulb(line: nil) }
    }

    /// The caret's pane took or lost the focus.
    func focusChanged(_ focused: Bool) {
        if focused { scheduleProbe() }
    }

    // MARK: Action list

    /// ⌘. and a click on the lightbulb: asks over the selection (the diagnostic's range when the caret is in one) and lists
    /// what comes back, the diagnostic's own fixes first.
    func showActions() {
        guard !stopped, host.isActive, host.features.codeAction else { return }
        let selections = host.selectionState.selections
        guard selections.count == 1 else { return }
        closeCompletion()
        closeActions()
        host.flushEdits()
        let snapshot = host.buffer.snapshot()
        let selection = min(selections[0].range.lowerBound, snapshot.utf8Count)..<min(selections[0].range.upperBound, snapshot.utf8Count)
        let diagnostic = host.currentDiagnostics().first { d in
            selection.isEmpty ? (d.range.contains(selection.lowerBound) || (d.range.isEmpty && d.range.lowerBound == selection.lowerBound))
                              : d.range.overlaps(selection)
        }
        let range = selection.isEmpty ? (diagnostic?.range ?? selection) : selection
        actionGeneration += 1
        let gen = actionGeneration, host = host
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            let items = await host.requestCodeActions(range: range, automatic: false)
            guard !Task.isCancelled, let self, self.actionGeneration == gen, !self.stopped, host.isActive,
                  host.buffer.version == snapshot.version else { return }
            self.actionTask = nil
            guard !items.isEmpty else { host.showMessage("No quick fixes here"); return }
            var ordered = items
            if let diagnostic {
                let own = items.filter { CodeActionMatching.matches($0, diagnostic: diagnostic) }
                ordered = own + items.filter { item in !own.contains { $0.rawAction == item.rawAction && $0.serverID == item.serverID } }
            }
            self.actionItems = ordered
            self.model.showActions(ordered.enumerated().map { i, item in
                ActionRow(index: i, title: item.displayTitle, disabledReason: item.disabledReason, isPreferred: item.isPreferred)
            })
        }
    }

    func closeActions() {
        actionGeneration += 1
        actionTask?.cancel(); actionTask = nil
        actionItems = []
        if model.content == .actions { model.clear() }
    }

    private func chooseAction(at position: Int) {
        guard model.actions.indices.contains(position) else { return }
        let index = model.actions[position].index
        guard actionItems.indices.contains(index) else { return }
        let item = actionItems[index]
        closeActions()
        actionTask = Task { [host] in
            _ = await host.chooseCodeAction(item)
        }
    }

    private func handleActionKey(_ press: KeyPress) -> KeyPress.Result {
        guard host.isActive else { closeActions(); return .ignored }
        guard press.modifiers.isEmpty else { return .ignored }
        let count = model.actions.count
        switch press.key {
        case .escape:
            closeActions()
            return .handled
        case .upArrow, .downArrow:
            model.select((model.selected + (press.key == .upArrow ? -1 : 1) + count) % count)
            return .handled
        case .return:
            chooseAction(at: model.selected)
            return .handled
        case .leftArrow, .rightArrow, .home, .end, .pageUp, .pageDown, .tab:
            closeActions()
            return .ignored
        default:
            if press.characters.isEmpty == false { closeActions() }
            return .ignored
        }
    }
}

/// The editor view as the scheduler's host.
@MainActor
final class ViewIntelHost: IntelligenceHost {
    private weak var view: OpenDocumentView?
    let buffer: CodeBuffer

    init(view: OpenDocumentView) {
        self.view = view
        buffer = view.document.buffer
    }

    var selectionState: CodeSelectionState { view?.selection() ?? buffer.selectionState }
    var features: FeatureSet { view?.features ?? FeatureSet() }

    var isActive: Bool {
        guard let view, !view.closed, view.document.state == .editable, view.services.lspOpen, let workspace = view.workspace else { return false }
        let pane = view.pane, path = view.document.path
        return workspace.defaultPane == pane && workspace.activeTab(in: pane) == path && workspace.presentation(of: path, in: pane) != .sideBySide
    }

    func flushEdits() { view?.services.drainEdits() }

    var lightbulbLine: Int? { view?.lightbulbLine }
    func setLightbulb(line: Int?) { view?.setLightbulb(line: line) }

    func requestCodeActions(range: Range<Int>, automatic: Bool) async -> [CodeActionItem] {
        guard let view, let service = view.actionService else { return [] }
        return await service.actions(for: view, range: range, automatic: automatic)
    }

    func chooseCodeAction(_ item: CodeActionItem) async -> CodeActionResult {
        guard let view, let service = view.actionService else { return .cancelled }
        return await service.choose(item, in: view)
    }

    func currentDiagnostics() -> [LSPDiagnostic] {
        guard let view else { return [] }
        return DiagnosticDecorations.current(view.lsp?.diagnostics.entry(for: view.document.path), in: view.document.buffer)
    }

    func showMessage(_ text: String) { view?.intelMessage(text, seconds: 3) }

    func requestCompletion(offset: Int, snapshot: CodeSnapshot, trigger: CompletionTrigger) async -> LSPOutcome<CompletionList> {
        guard let view, let lsp = view.lsp else { return .unavailable }
        return await lsp.completion(path: view.document.path, utf8Offset: offset, snapshot: snapshot, trigger: trigger)
    }

    func requestSignature(offset: Int, snapshot: CodeSnapshot, trigger: SignatureTrigger) async -> LSPOutcome<SignatureInfo?> {
        guard let view, let lsp = view.lsp else { return .unavailable }
        return await lsp.signatureHelp(path: view.document.path, utf8Offset: offset, snapshot: snapshot, trigger: trigger)
    }

    func requestResolve(item: CompletionItem, snapshot: CodeSnapshot) async -> LSPOutcome<CompletionItem> {
        guard let view, let lsp = view.lsp else { return .unavailable }
        return await lsp.resolveCompletion(path: view.document.path, item: item, snapshot: snapshot)
    }
}
