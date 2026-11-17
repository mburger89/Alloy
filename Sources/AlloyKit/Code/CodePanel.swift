import AlloyCore
import AlloyHighlight
import Foundation
import MetalUI
import AlloyLSP
import Observation

/// What a decoration build is for: the ledger's version and the buffer version it was saved as.
struct BuildKey: Equatable { var ledger: Int; var saved: UInt64; var mode: Presentation }

/// What the panel keeps for one view of an open document: its `CodeDecorations` and highlighter, the selected edit, the
/// find state, the scroll position and the diff build for its presentation. Kept by (pane, path) in ``CodePanelStore``
/// so a tab switch loses none of it; the highlight feed, the language-server sync and the semantic tokens are the
/// document's, in ``DocumentServices``, shared by every view of the file.
@MainActor @Observable
final class OpenDocumentView {
    @ObservationIgnored let document: EditorDocument
    @ObservationIgnored let pane: PaneID
    @ObservationIgnored let services: DocumentServices
    @ObservationIgnored let decorations: CodeDecorations
    @ObservationIgnored let scroll = CodeScrollState()
    /// The left pane's scroll position in side-by-side mode; it outlives the pane, which is rebuilt with the ledger.
    @ObservationIgnored let leftScroll = CodeScrollState()
    @ObservationIgnored private(set) var highlighter: CodeViewHighlighter?
    @ObservationIgnored private let engine: HighlightEngine
    @ObservationIgnored private(set) var closed = false
    /// The language-server bridge (for the diagnostics and the definition request).
    @ObservationIgnored private let lsp: LSPCoordinator?
    /// What the last diff build applied, kept so a diagnostics change can set the diff and the diagnostics together.
    private struct AppliedDiff {
        var model: DiffDecorationModel
        var sessions: [Session]
        var version: UInt64
        var byteCount: Int
        var fillers: [SideBySideModel.Filler]?
        var rowCount: Int
        /// Whether the author-run layer of this diff is set (it is set once; diagnostics repaints leave it).
        var annotated = false
    }
    @ObservationIgnored private var annotationsSet = false
    @ObservationIgnored private var appliedDiff: AppliedDiff?
    /// The presentation the applied diff was built for (line layers follow it).
    @ObservationIgnored private var appliedPresentation: Presentation = .inline
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var builtKey: BuildKey?
    @ObservationIgnored private var building: BuildKey?
    /// Decoration tag to edit, for the click and menu closures.
    @ObservationIgnored private(set) var tags: [UInt64: UUID] = [:]
    /// Decoration tag to edit for the left pane's bars (side by side).
    @ObservationIgnored private(set) var leftTags: [UInt64: UUID] = [:]
    @ObservationIgnored private var searchGeneration = 0

    /// The old-text pane of the side-by-side diff; nil in inline mode and until the first build.
    private(set) var left: LeftPane?
    /// Which language features the servers of this file offer (written only when they change; the hover is attached by it).
    private(set) var features = FeatureSet()
    /// The hover popover's slot: the view's one text-anchored presentation.
    @ObservationIgnored let popoverSlot = PopoverSlotModel()
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var hoverGeneration = 0
    var selectedEdit: UUID?
    var findVisible = false
    var findQuery = ""
    var findCount = 0
    var findTruncated = false
    /// Test hook: runs inside a decoration build before it reads the ledger.
    @ObservationIgnored var buildGate: (@Sendable () async -> Void)?
    /// Test hook: runs inside the search before it reads.
    @ObservationIgnored var searchGate: (@Sendable () async -> Void)?
    /// Test hook: the buffer versions whose search matches were applied.
    @ObservationIgnored private(set) var appliedSearchVersions: [UInt64] = []

    init(document: EditorDocument, pane: PaneID, services: DocumentServices, engine: HighlightEngine,
         lsp: LSPCoordinator? = nil) {
        self.document = document
        self.pane = pane
        self.services = services
        self.engine = engine
        self.lsp = lsp
        self.decorations = CodeDecorations(buffer: document.buffer)
        self.decorations.theme = .alloy
        features = lsp?.features(for: document.path) ?? FeatureSet()
        services.attach(self)
    }

    /// This pane's caret and selections for the file: the workspace's state for (pane, path), else the buffer's default.
    func selection(in workspace: Workspace? = nil) -> CodeSelectionState {
        (workspace ?? self.workspace)?.selectionState(for: document.path, in: pane) ?? document.buffer.selectionState
    }

    /// Detaches from the document's services (which outlive the view) and drops what the view holds.
    func close() {
        closed = true
        messageTask?.cancel()
        dismissHover()
        services.detach(self)
        left?.close()
        left = nil
    }

    // MARK: Document services

    /// The engine holds the document's text: the view's highlighter can ask it for colours.
    func engineReady() {
        guard !closed, highlighter == nil else { return }
        highlighter = CodeViewHighlighter(engine: engine, documentID: document.id, decorations: decorations)
        decorations.invalidateHighlights(in: 0..<document.buffer.utf8Count)
    }

    /// The buffer changed: an open find searches again, since matches follow edits but a new one is not found by that.
    func searchAgainIfOpen() {
        if findVisible, !findQuery.isEmpty { search() }
    }

    /// Server-driven colours for a file with no grammar (the document's, shared by its views).
    var semantic: SemanticHighlighter? { services.semantic }

    func semanticSupport(_ supported: Bool) { services.semanticSupport(supported) }

    // MARK: Diff decorations

    /// Builds the diff decorations (and, side by side, the left pane) when the ledger, the saved text or the mode
    /// moved since the last build (never on typing). The diff and the models are made off the main actor and applied
    /// only if nothing moved meanwhile, and only when the buffer's saved text is the ledger's text (a session edit
    /// reaches the ledger before the buffer). The right pane's rows are those of the saved version, which MetalUI
    /// maps forward through unsaved typing.
    func rebuildIfNeeded(workspace: Workspace) {
        self.workspace = workspace
        let path = document.path
        let key = buildTrigger(workspace: workspace)
        if key.mode == .plain {
            guard key != builtKey else { return }
            clearDiff()
            builtKey = key
            return
        }
        guard let file = workspace.ledger.files[path] else { return }
        guard key != builtKey, key != building else { return }
        building = key
        let document = document
        let ending = document.buffer.lineEnding.text
        let saved = document.savedSnapshot
        let authors = Dictionary(file.edits.map { ($0.id, $0.author) }, uniquingKeysWith: { a, _ in a })
        let sideBySide = key.mode == .sideBySide
        let gate = buildGate
        Task { [weak self, weak workspace] in
            let (model, sbs, oldBytes, sameText) = await Task.detached { () -> (DiffDecorationModel, SideBySideModel?, [UInt8], Bool) in
                await gate?()
                let entries = file.diffEntries()
                let lines = entries.map(\.line), terminators = entries.map(\.terminator)
                let model = DiffDecorationModel.build(lines, terminators: terminators,
                                                      authorOf: { authors[$0] ?? .outside }, lineEnding: ending)
                let sbs = sideBySide ? SideBySideModel.build(lines, terminators: terminators,
                                                              authorOf: { authors[$0] ?? .outside }, lineEnding: ending) : nil
                return (model, sbs, sbs.map { Array($0.oldText.utf8) } ?? [],
                        saved.utf8(in: 0..<saved.utf8Count) == Array(file.text.text.utf8))
            }.value
            guard let self, let workspace else { return }
            if building == key { building = nil }
            guard !closed, workspace.ledger.files[path]?.version == key.ledger, document.savedVersion == key.saved,
                  sameText, workspace.presentation(of: path, in: pane) == key.mode else { return }
            tags = model.tags
            appliedDiff = AppliedDiff(model: model, sessions: workspace.sessions, version: key.saved,
                                      byteCount: saved.utf8Count, fillers: sbs?.rightFillers, rowCount: saved.lineCount)
            appliedPresentation = key.mode
            applyLineLayers()
            if let sbs {
                // The pane (buffer, engine document, highlights) changes only when the old text does.
                let pane: LeftPane
                if let existing = left, existing.bytes == oldBytes {
                    pane = existing
                } else {
                    left?.close()
                    pane = LeftPane(bytes: oldBytes, path: path, engine: engine)
                    left = pane
                }
                DiffDecorations.applyLeft(sbs, to: pane.decorations, sessions: workspace.sessions, version: pane.buffer.version)
                leftTags = sbs.tags
            } else {
                left?.close()
                left = nil
                leftTags = [:]
            }
            if sbs != nil { workspace.noteSideBySideBuild() }
            builtKey = key
            workspace.noteDecorationBuild()
        }
    }

    /// A plain presentation: forgets the diff and the left pane, clears the diff's layers and paints the diagnostics alone.
    private func clearDiff() {
        let hadDiff = appliedDiff != nil
        building = nil
        tags = [:]
        leftTags = [:]
        left?.close()
        left = nil
        appliedDiff = nil
        appliedPresentation = .plain
        if hadDiff || annotationsSet {
            annotationsSet = false
            decorations.setHighlights([], in: 0..<(1 << 40), layer: .annotations, asOf: document.buffer.version)
        }
        applyLineLayers(clearing: hadDiff)
    }

    // MARK: Hover

    /// Whether the hover is attached to the code view: the server offers it and the document is open at it, editable.
    func hoverAttached(editable: Bool) -> Bool { features.hover && editable && services.lspOpen && lsp != nil }

    /// Re-reads the features the document's servers offer; writes only a change, and drops an open hover when they go.
    func refreshFeatures() {
        let now = lsp?.features(for: document.path) ?? FeatureSet()
        guard now != features else { return }
        features = now
        if !now.hover { dismissHover() }
    }

    /// Asks for the hover at `offset` (the primary caret when nil) and opens the popover when something comes back. Each
    /// call supersedes the one before; the answer is dropped when the text, the tab or the request moved on.
    func showHover(at offset: Int?, workspace: Workspace) {
        hoverTask?.cancel()
        hoverGeneration += 1
        let generation = hoverGeneration
        guard let lsp, !closed, features.hover, document.state == .editable, services.lspOpen else { return }
        services.drainEdits()
        let snapshot = document.buffer.snapshot()
        let at = min(offset ?? selection(in: workspace).primarySelection.head, snapshot.utf8Count)
        let path = document.path, pane = pane
        hoverTask = Task { @MainActor [weak self] in
            let outcome = await lsp.hover(path: path, utf8Offset: at, snapshot: snapshot)
            guard !Task.isCancelled, let self, !self.closed, self.hoverGeneration == generation,
                  workspace.activeTab(in: pane) == path, self.document.buffer.version == snapshot.version else { return }
            var info: HoverInfo?
            switch outcome {
            case .stale: return
            case .answered(let answer): info = answer
            case .unavailable, .timedOut, .failed: break
            }
            let marks = DiagnosticDecorations.current(lsp.diagnostics.entry(for: path), in: self.document.buffer)
                .filter { $0.range.contains(at) || ($0.range.isEmpty && $0.range.lowerBound == at) }
            let markdown = info?.markdown ?? ""
            guard !markdown.isEmpty || !marks.isEmpty else {
                self.popoverSlot.hover = nil
                return
            }
            self.popoverSlot.hover = HoverPresentation(markdown: markdown, diagnostics: marks, range: info?.range ?? at..<at)
        }
    }

    /// Closes the popover and abandons a request in flight.
    func dismissHover() {
        hoverTask?.cancel()
        hoverTask = nil
        hoverGeneration += 1
        if popoverSlot.hover != nil { popoverSlot.hover = nil }
    }

    /// The pointer's rest on text: asks once per grapheme; the end of the hover closes the popover.
    func textHover(_ phase: CodeHoverPhase, workspace: Workspace) {
        switch phase {
        case .active(let hit), .moved(let hit): showHover(at: hit.character?.lowerBound ?? hit.offset, workspace: workspace)
        case .ended: dismissHover()
        }
    }

    // MARK: Go to definition

    /// A short message about the last go-to-definition ("No definition found", or where an outside file lies); the header shows it.
    var definitionMessage: String?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    /// How long ``definitionMessage`` stays, per kind.
    nonisolated static let noDefinitionSeconds = 2.0
    nonisolated static let externalSeconds = 6.0

    /// Starts a go-to-definition for the caret and returns its task (the store keeps one in flight and cancels it). The
    /// answer is dropped silently when the tab, the text or the caret changed since the request.
    func startDefinition(workspace: Workspace) -> Task<Void, Never>? {
        definitionMessage = nil
        messageTask?.cancel()
        guard let lsp, services.lspOpen, !closed else {
            flash("No definition found", seconds: Self.noDefinitionSeconds)
            return nil
        }
        services.drainEdits()
        let snapshot = document.buffer.snapshot()
        let selection = self.selection(in: workspace)
        let offset = selection.primarySelection.head
        let path = document.path
        return Task { @MainActor [weak self] in
            let outcome = await lsp.definition(path: path, utf8Offset: offset, snapshot: snapshot)
            guard !Task.isCancelled, let self, !self.closed, workspace.activeTab(in: pane) == path,
                  self.document.buffer.version == snapshot.version, selection.primarySelection.head == offset else { return }
            switch outcome {
            case .stale: return
            case .unavailable: self.flash("No definition found", seconds: Self.noDefinitionSeconds)
            case .answered(let result):
                guard let first = result.targets.first else {
                    self.flash("No definition found", seconds: Self.noDefinitionSeconds)
                    return
                }
                await self.go(to: first, encoding: result.encoding, workspace: workspace)
            }
        }
    }

    private func go(to target: DefinitionTarget, encoding: PositionEncoding, workspace: Workspace) async {
        let pane = pane
        switch target {
        case .inWorkspace(let path, let range):
            await workspace.open(path, selecting: { Positions.utf8Range(of: range, in: $0, encoding: encoding) }, in: pane)
        case .external(let url, let range):
            // Alloy has no read-only view for files outside the project (`Workspace.open` refuses them): say where it is.
            flash("Definition: \(url.path):\(range.start.line + 1):\(range.start.character + 1)",
                                  seconds: Self.externalSeconds)
        }
    }

    func flash(_ text: String, seconds: Double) {
        definitionMessage = text
        messageTask?.cancel()
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.definitionMessage = nil
        }
    }

    // MARK: Symbols and references

    /// How long the busy / timeout / empty messages of symbols and references stay.
    nonisolated static let messageSeconds = 2.0

    /// Whether the document can be asked for its outline now (the server offers it, the document is open at it, editable).
    func symbolsAttached(editable: Bool) -> Bool { features.documentSymbol && editable && services.lspOpen && lsp != nil }

    /// Whether the document can be asked for the uses of the symbol at the caret now.
    func referencesAttached(editable: Bool) -> Bool { features.references && editable && services.lspOpen && lsp != nil }

    /// Asks for the outline and hands it to `quickOpen` for `palette`. After a silent retry on a stale answer it says the
    /// server is busy; whatever goes wrong, the palette ends up showing its empty row. The answer is kept across edits (it is
    /// mapped through them when picked) but dropped when the tab changed.
    func startSymbols(workspace: Workspace, quickOpen: QuickOpenModel, palette: ListPaletteModel) -> Task<Void, Never>? {
        guard let lsp, symbolsAttached(editable: document.state == .editable), !closed else {
            palette.setItems([])
            return nil
        }
        let path = document.path, pane = pane
        return Task { @MainActor [weak self, weak quickOpen] in
            for attempt in 0..<2 {
                guard let self, !self.closed else { return }
                self.services.drainEdits()
                let snapshot = self.document.buffer.snapshot()
                let outcome = await lsp.documentSymbols(path: path, snapshot: snapshot)
                guard !Task.isCancelled, !self.closed, workspace.activeTab(in: pane) == path else { return }
                switch outcome {
                case .answered(let symbols):
                    quickOpen?.provideSymbols(symbols, version: snapshot.version, for: palette)
                    return
                case .stale where attempt == 0: continue
                case .stale:
                    self.flash("Server busy, try again", seconds: Self.messageSeconds)
                case .timedOut:
                    self.flash("Symbols timed out", seconds: Self.messageSeconds)
                case .unavailable, .failed: break
                }
                palette.setItems([])
                return
            }
        }
    }

    /// Asks for the uses of the symbol at the caret and opens the references palette with them. The answer is dropped
    /// silently when the tab, the text or the caret changed since the request.
    func startReferences(workspace: Workspace, quickOpen: QuickOpenModel) -> Task<Void, Never>? {
        definitionMessage = nil
        messageTask?.cancel()
        guard let lsp, referencesAttached(editable: document.state == .editable), !closed else { return nil }
        let path = document.path, pane = pane
        let selection = self.selection(in: workspace)
        let offset = selection.primarySelection.head
        return Task { @MainActor [weak self, weak quickOpen] in
            for attempt in 0..<2 {
                guard let self, !self.closed else { return }
                self.services.drainEdits()
                let snapshot = self.document.buffer.snapshot()
                let outcome = await lsp.references(path: path, utf8Offset: min(offset, snapshot.utf8Count), snapshot: snapshot)
                guard !Task.isCancelled, !self.closed, workspace.activeTab(in: pane) == path,
                      self.document.buffer.version == snapshot.version, selection.primarySelection.head == offset else { return }
                switch outcome {
                case .answered(let result):
                    guard !result.hits.isEmpty || result.outsideRoot > 0 else {
                        self.flash("No references found", seconds: Self.messageSeconds)
                        return
                    }
                    quickOpen?.showReferences(model: QuickOpenModel.referencesPalette(
                        result, snapshot: snapshot, path: path, pane: pane, workspace: workspace, quickOpen: quickOpen))
                    return
                case .stale where attempt == 0: continue
                case .stale: self.flash("Server busy, try again", seconds: Self.messageSeconds)
                case .timedOut: self.flash("References timed out", seconds: Self.messageSeconds)
                case .unavailable, .failed: self.flash("No references found", seconds: Self.messageSeconds)
                }
                return
            }
        }
    }

    // MARK: Diagnostics

    /// The diagnostics of this document changed: paints the tint, and the rows together with the diff's.
    ///
    /// A burst of publishes costs one paint per main-actor turn: the first paints at once, the others in the same turn
    /// only mark that one more paint is due, which runs at the start of the next turn.
    func paintDiagnostics() {
        guard !closed else { return }
        if paintGate { paintQueued = true; return }
        paintGate = true
        paintDiagnosticsNow()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.paintGate = false
            if self.paintQueued {
                self.paintQueued = false
                self.paintDiagnostics()
            }
        }
    }

    @ObservationIgnored private var paintGate = false
    @ObservationIgnored private var paintQueued = false
    /// Paints of the diagnostics so far, and how many of them set the diff's author-run layer (test observability).
    @ObservationIgnored private(set) var diagnosticsPaintCount = 0
    @ObservationIgnored private(set) var annotationApplyCount = 0

    private func paintDiagnosticsNow() {
        diagnosticsPaintCount += 1
        DiagnosticDecorations.applyTint(lsp?.diagnostics.entry(for: document.path), to: decorations)
        applyLineLayers()
    }

    /// Sets the line decorations and virtual rows: the diff's, if built, and the diagnostics'.
    private func applyLineLayers(clearing: Bool = false) {
        services.drainEdits()   // the row log must hold every edit MetalUI has seen
        var layout = DiagnosticDecorations.currentLayout(lsp?.diagnostics.entry(for: document.path), in: document.buffer)
        // Without a built diff, the pane's own presentation decides (a file that never builds still hides message rows).
        let shown = appliedDiff == nil ? (workspace?.presentation(of: document.path, in: pane) ?? appliedPresentation) : appliedPresentation
        let sideBySide = shown == .sideBySide
        if sideBySide { layout.rows = [] }   // only the right pane could show them, which would unlevel the panes
        if let diff = appliedDiff {
            let ok = DiffDecorations.apply(diff.model, to: decorations, sessions: diff.sessions, version: diff.version,
                                           byteCount: diff.byteCount, fillers: diff.fillers,
                                           diagnostics: layout, rowLog: services.rowLog, savedRowCount: diff.rowCount,
                                           includeAnnotations: !diff.annotated)
            if ok, !diff.annotated {
                appliedDiff?.annotated = true
                annotationsSet = true
                annotationApplyCount += 1
            }
            if !ok {
                // The diff cannot be carried forward any more: forget it and have it built again.
                appliedDiff = nil
                builtKey = nil
            }
        } else if lsp != nil || clearing {
            DiffDecorations.applyDiagnostics(layout, to: decorations)
        }
    }

    /// Selects the next (`+1`) or previous (`-1`) problem from the caret, wrapping.
    func stepProblem(_ direction: Int) {
        let items = DiagnosticDecorations.current(lsp?.diagnostics.entry(for: document.path), in: document.buffer)
        let selection = self.selection().primarySelection.range
        guard let range = DiagnosticDecorations.nextProblem(items, selection: selection, direction: direction) else { return }
        self.selection().select(range, reveal: true)
    }

    /// The value `onChange` watches to start a rebuild.
    func buildTrigger(workspace: Workspace) -> BuildKey {
        let mode = workspace.presentation(of: document.path, in: pane)
        // A plain view builds no diff: the ledger and the saved text do not matter to it.
        if mode == .plain { return BuildKey(ledger: 0, saved: 0, mode: .plain) }
        return BuildKey(ledger: workspace.ledger.files[document.path]?.version ?? -1, saved: document.savedVersion, mode: mode)
    }

    // MARK: Find

    /// The most matches kept; a query with more shows "10,000+".
    nonisolated static let findLimit = 10_000

    func showFind() {
        findVisible = true
        search()
    }

    func closeFind() {
        findVisible = false
        searchGeneration += 1
        decorations.findMatches = []
        decorations.currentMatch = nil
        findCount = 0
        findTruncated = false
    }

    func setQuery(_ query: String) {
        guard query != findQuery else { return }
        findQuery = query
        search()
    }

    /// Finds the query off the main actor; the matches are used only if the buffer is still at the searched version.
    func search() {
        searchGeneration += 1
        let generation = searchGeneration
        let query = findQuery
        guard !query.isEmpty else {
            decorations.findMatches = []
            decorations.currentMatch = nil
            findCount = 0; findTruncated = false
            return
        }
        let snapshot = document.buffer.snapshot()
        let gate = searchGate
        Task { [weak self] in
            let found = await Task.detached { () -> [Range<Int>] in
                await gate?()
                return snapshot.ranges(of: query, limit: Self.findLimit + 1)
            }.value
            guard let self, !closed, generation == searchGeneration else { return }
            if snapshot.version == document.buffer.version {
                findTruncated = found.count > Self.findLimit
                let ranges = findTruncated ? Array(found.prefix(Self.findLimit)) : found
                decorations.findMatches = ranges
                decorations.currentMatch = nil
                findCount = ranges.count
                appliedSearchVersions.append(snapshot.version)
            } else {
                search()
            }
        }
    }

    /// Selects the next (`+1`) or previous (`-1`) match after the caret, wrapping.
    func step(_ direction: Int) {
        let matches = decorations.findMatches
        guard !matches.isEmpty else { return }
        let selection = self.selection()
        let caret = selection.primarySelection
        let next: Int
        if let current = decorations.currentMatch {
            next = (current + direction + matches.count) % matches.count
        } else if direction > 0 {
            next = matches.firstIndex { $0.lowerBound >= caret.range.upperBound } ?? 0
        } else {
            next = matches.lastIndex { $0.lowerBound < caret.range.lowerBound } ?? matches.count - 1
        }
        decorations.currentMatch = next
        selection.select(matches[next], reveal: true)
    }
}

/// The key of one view: the pane showing the file, and the file.
struct ViewKey: Hashable { let pane: PaneID; let path: String }

/// The panel's per-document services and per-view state and the one highlight engine, owned above the panel (by
/// `AlloyScreen`) so they outlive re-renders.
@MainActor @Observable
final class CodePanelStore {
    @ObservationIgnored let engine = HighlightEngine()
    private final class Weak { weak var store: CodePanelStore?; init(_ s: CodePanelStore) { store = s } }
    private static var registry: [Weak] = []

    /// The Chat view of `document` in whichever store made it, so a test can reach the panel's per-document state.
    package static func existingView(for document: EditorDocument) -> OpenDocumentView? {
        existingView(for: document, in: .chat)
    }

    /// The view of `document` in `pane`, in whichever store made it.
    package static func existingView(for document: EditorDocument, in pane: PaneID) -> OpenDocumentView? {
        registry.removeAll { $0.store == nil }
        return registry.lazy.compactMap { $0.store?.view(for: document, in: pane) }.first
    }
    /// The format service of whichever store made the Chat view of `document`, so a test can shorten its timeouts.
    package static func existingFormatService(for document: EditorDocument) -> FormatService? {
        registry.removeAll { $0.store == nil }
        return registry.lazy.compactMap { entry -> FormatService? in
            guard let store = entry.store, store.view(for: document, in: .chat) != nil else { return nil }
            return store.formatService
        }.first
    }
    private var views: [ViewKey: OpenDocumentView] = [:]
    private var servicesByPath: [String: DocumentServices] = [:]
    private var lsp: LSPCoordinator?

    /// The services of the document at `path` (one per open document), once a view of it was made.
    func services(for path: String) -> DocumentServices? { servicesByPath[path] }

    /// Connects the store to the workspace's language-server coordinator, if one is installed. Idempotent.
    func attach(workspace: Workspace) {
        installIntelHooks(workspace: workspace)
        guard let coordinator = workspace.languageServices as? LSPCoordinator, coordinator !== lsp else { return }
        lsp = coordinator
        installFormat(workspace: workspace, coordinator: coordinator)
        coordinator.savedHandler = { [weak self] path in self?.servicesByPath[path]?.lspSaved() }
        coordinator.diagnosticsHandler = { [weak self] path in
            guard let self else { return }
            for (key, view) in views where key.path == path { view.paintDiagnostics() }
        }
        coordinator.semanticSupportHandler = { [weak self] path, supported in self?.servicesByPath[path]?.semanticSupport(supported) }
        coordinator.semanticHandler = { [weak self] path, version, runs in self?.servicesByPath[path]?.semantic?.apply(runs, version: version) }
        workspace.goToDefinition = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.goToDefinition(workspace: workspace, pane: workspace.defaultPane)
        }
        coordinator.reloadHandler = { [weak self] in self?.servicesByPath.values.forEach { $0.lspSettingsChanged() } }
        coordinator.featuresHandler = { [weak self] path in
            guard let self else { return }
            for (key, view) in views where key.path == path { view.refreshFeatures() }
        }
    }

    /// Installs the code-intelligence commands the menus and keys run. Idempotent; `quickOpen` is read when a command runs.
    func installIntelHooks(workspace: Workspace) {
        workspace.intelHooks.run[.showHover] = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.focusedView(workspace: workspace)?.showHover(at: nil, workspace: workspace)
        }
        workspace.intelHooks.run[.goToSymbol] = { [weak self, weak workspace] in
            guard let self, let workspace, let quickOpen = self.quickOpen, self.focusedView(workspace: workspace) != nil else { return }
            self.goToSymbol(workspace: workspace, quickOpen: quickOpen)
        }
        workspace.intelHooks.run[.findReferences] = { [weak self, weak workspace] in
            guard let self, let workspace, let quickOpen = self.quickOpen else { return }
            self.findReferences(workspace: workspace, quickOpen: quickOpen, pane: workspace.defaultPane)
        }
        workspace.intelHooks.run[.formatDocument] = { [weak self, weak workspace] in
            guard let self, let workspace, let service = self.formatService, let view = self.focusedView(workspace: workspace) else { return }
            self.formatTask = Task { @MainActor in await service.formatDocument(view: view) }
        }
        workspace.intelHooks.run[.formatSelection] = { [weak self, weak workspace] in
            guard let self, let workspace, let service = self.formatService, let view = self.focusedView(workspace: workspace) else { return }
            self.formatTask = Task { @MainActor in await service.formatSelection(view: view) }
        }
        workspace.intelHooks.isEnabled = { [weak self, weak workspace] command in
            guard let self, let workspace, let view = self.focusedView(workspace: workspace) else { return false }
            let editable = view.document.state == .editable
            switch command {
            case .showHover: return view.hoverAttached(editable: editable)
            case .goToSymbol: return view.symbolsAttached(editable: editable)
            case .findReferences: return view.referencesAttached(editable: editable)
            case .formatDocument: return editable && view.services.lspOpen && view.features.formatting && formatService != nil
            case .formatSelection:
                return editable && view.services.lspOpen && view.features.rangeFormatting && formatService != nil
                    && !view.selection(in: workspace).primarySelection.range.isEmpty
            }
        }
    }

    /// Format document, selection and on save; made once a coordinator is attached.
    private(set) var formatService: FormatService?
    private var formatTask: Task<Void, Never>?

    private func installFormat(workspace: Workspace, coordinator: LSPCoordinator) {
        let service = FormatService(workspace: workspace, coordinator: coordinator,
                                    applier: WorkspaceEditApplier(workspace: workspace, coordinator: coordinator))
        service.viewFor = { [weak self, weak workspace] path in
            guard let self, let workspace else { return nil }
            let focused = workspace.defaultPane
            if workspace.activeTab(in: focused) == path, let document = workspace.document(path),
               let view = self.view(for: document, in: focused) { return view }
            return self.views.first { $0.key.path == path && !$0.value.closed }?.value
        }
        formatService = service
        workspace.formatBeforeSave = { [weak service] doc in await service?.formatForSave(doc) }
    }

    /// The view of the focused pane's active tab.
    func focusedView(workspace: Workspace) -> OpenDocumentView? {
        let pane = workspace.defaultPane
        guard let path = workspace.activeTab(in: pane), let document = workspace.document(path) else { return nil }
        return view(for: document, in: pane)
    }

    /// Quick-open (⌘P), set by the root: the palette the symbols and references answers go to.
    @ObservationIgnored weak var quickOpen: QuickOpenModel?
    /// The one outline or references request in flight.
    private var intelTask: Task<Void, Never>?

    /// Opens the symbols palette on the focused editor (⇧⌘O).
    func goToSymbol(workspace: Workspace, quickOpen: QuickOpenModel) { quickOpen.showSymbols(workspace: workspace) }

    /// Loads the outline of `target` into `palette`; replaces any intel request in flight.
    func loadSymbols(workspace: Workspace, quickOpen: QuickOpenModel, palette: ListPaletteModel, target: QuickOpenModel.Target) {
        cancelIntel()
        guard let document = workspace.document(target.path), let view = view(for: document, in: target.pane) else {
            palette.setItems([])
            return
        }
        intelTask = view.startSymbols(workspace: workspace, quickOpen: quickOpen, palette: palette)
    }

    /// Find References at `pane`'s active tab's caret; replaces any intel request in flight.
    func findReferences(workspace: Workspace, quickOpen: QuickOpenModel, pane: PaneID) {
        cancelIntel()
        guard let path = workspace.activeTab(in: pane), let document = workspace.document(path),
              let view = view(for: document, in: pane) else { return }
        intelTask = view.startReferences(workspace: workspace, quickOpen: quickOpen)
    }

    func cancelIntel() {
        intelTask?.cancel()
        intelTask = nil
    }

    /// The one go-to-definition in flight, for whichever view asked last.
    private var definitionTask: Task<Void, Never>?

    /// Go to Definition at `pane`'s active tab's caret; replaces (cancels) any request still in flight.
    func goToDefinition(workspace: Workspace, pane: PaneID) {
        cancelDefinition()
        guard let path = workspace.activeTab(in: pane), let document = workspace.document(path),
              let view = view(for: document, in: pane) else { return }
        definitionTask = view.startDefinition(workspace: workspace)
    }

    /// Abandons the request in flight (a tab switch, a closed view).
    func cancelDefinition() {
        cancelIntel()
        definitionTask?.cancel()
        definitionTask = nil
    }

    /// Makes (or replaces, when the path was reopened) the view of `document` in `pane`, and the document's services
    /// when it has none. Called outside rendering.
    func ensureView(for document: EditorDocument, in pane: PaneID) {
        if !Self.registry.contains(where: { $0.store === self }) { Self.registry.append(Weak(self)) }
        let path = document.path
        if let services = servicesByPath[path], services.document !== document { dropDocument(path) }
        let key = ViewKey(pane: pane, path: path)
        if let existing = views[key], existing.document === document { return }
        let services: DocumentServices
        if let existing = servicesByPath[path] {
            services = existing
        } else {
            services = DocumentServices(document: document, engine: engine, lsp: lsp)
            servicesByPath[path] = services
        }
        views[key] = OpenDocumentView(document: document, pane: pane, services: services, engine: engine, lsp: lsp)
    }

    /// The view of `document` in `pane`, once ``ensureView(for:in:)`` has made it.
    func view(for document: EditorDocument, in pane: PaneID) -> OpenDocumentView? {
        guard let view = views[ViewKey(pane: pane, path: document.path)], view.document === document else { return nil }
        return view
    }

    /// Closes every view of `path` and its services (the document was replaced or is gone).
    private func dropDocument(_ path: String) {
        cancelDefinition()
        for key in views.keys where key.path == path {
            views[key]?.close()
            views[key] = nil
        }
        servicesByPath[path]?.close()
        servicesByPath[path] = nil
    }

    /// Closes the view of every tab whose document was replaced (a read-only file made editable again installs a
    /// new document), active or not, and makes the new document's view in each pane that had one. A tab that never
    /// had a view gets one when it is first shown.
    func refreshReplaced(workspace: Workspace) {
        for (path, services) in servicesByPath where workspace.document(path) !== services.document {
            let panes = views.keys.filter { $0.path == path }.map(\.pane)
            dropDocument(path)
            if let document = workspace.document(path) {
                for pane in panes { ensureView(for: document, in: pane) }
            }
        }
    }

    /// Drops the views of `pane` whose tab is gone. The documents' services stay until ``pruneServices(workspace:)``.
    func prune(pane: PaneID, keeping paths: [String]) {
        for (key, view) in views where key.pane == pane && !paths.contains(key.path) {
            cancelDefinition()
            view.close()
            views[key] = nil
        }
    }

    /// Chat's tab list changed: drops the views of its closed tabs, then the services of documents nobody holds.
    func chatTabsChanged(workspace: Workspace) {
        prune(pane: .chat, keeping: workspace.tabs)
        pruneServices(workspace: workspace)
    }

    /// A group's tab list changed or a group closed: drops the views of every group tab that is gone, then the services.
    func groupsChanged(workspace: Workspace) {
        for pane in Set(views.keys.map(\.pane)) where pane != .chat { prune(pane: pane, keeping: workspace.tabs(in: pane)) }
        pruneServices(workspace: workspace)
    }

    /// Drops the views of every closed tab in every pane (Chat's and the groups'), then the services of documents nobody
    /// holds. Runs whichever mode is shown, so a close that finishes in the other mode leaves nothing behind.
    func reconcile(workspace: Workspace) {
        for pane in Set(views.keys.map(\.pane)) { prune(pane: pane, keeping: workspace.tabs(in: pane)) }
        pruneServices(workspace: workspace)
    }

    /// Closes the services of every document that left the workspace (no tab list holds it, or it was replaced), once.
    func pruneServices(workspace: Workspace) {
        for path in Array(servicesByPath.keys) where !workspace.holds(path) { dropDocument(path) }
        refreshReplaced(workspace: workspace)
    }
}

/// The code view of one document with its find bar and edit bar.
struct CodePanel: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let document: EditorDocument
    let view: OpenDocumentView
    /// The pane's selection state the code view runs on; the equatable panel compares it, so a replaced state rewires the view.
    let selection: CodeSelectionState
    /// The glass bar floating over the panel's top (its height with the gutter below it): the code scrolls under it, so
    /// the code's top margin is this; the find bar, which is not scrolled, sits below the glass bar instead.
    var topClear: Double = 0
    /// The accessibility id of the code view: `code-view` in Chat, `code-view-<groupID>` in a group.
    var codeViewIdentifier: String = "code-view"
    /// Called when the code view gains focus (a group takes the editor focus then).
    var onFocus: (() -> Void)?
    @FocusState var codeFocused: Bool

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CodePanel")
        let workspace = workspace, document = document, view = view, path = document.path
        let editable = document.state == .editable
        VStack(alignment: .leading, spacing: 0) {
            if view.findVisible {
                VStack(spacing: 0) { FindBar(view: view, onClose: { codeFocused = true }) }
                    .padding(Edges(top: Pixels(Float(topClear)), right: Pixels(0), bottom: Pixels(0), left: Pixels(0)))
            }
            if workspace.presentation(of: path, in: view.pane) == .sideBySide {
                SideBySideView(workspace: workspace, store: store, document: document, view: view, focused: $codeFocused,
                               idSuffix: Self.sideBySideSuffix(view.pane))
            } else if view.hoverAttached(editable: editable) {
                // The server offers hover: the view carries the text hover and its one text-anchored popover (slot B).
                let slot = view.popoverSlot
                CodeView(buffer: document.buffer, decorations: view.decorations)
                    .selectionState(selection)
                    .font(family: "Menlo", size: 12)
                    .codeViewEditable(editable)
                    .scrollState(view.scroll)
                    .onGutterBarClick { hit in view.selectedEdit = hit.tag.flatMap { view.tags[$0] } }
                    .gutterBarContextMenu { hit in
                        if let edit = hit.tag.flatMap({ view.tags[$0] }) {
                            editMenu(edit: edit, workspace: workspace, store: store, document: document, pane: view.pane)
                        }
                    }
                    .focused($codeFocused)
                    .onTextHover(delay: .milliseconds(500)) { phase in view.textHover(phase, workspace: workspace) }
                    .popover(item: Binding(get: { slot.hover }, set: { slot.hover = $0 }),
                             attachmentAnchor: .range(slot.hover?.range ?? 0..<0), arrowEdge: .bottom) { presentation in
                        HoverView(presentation: presentation, cache: slot.markdownCache)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(codeViewIdentifier)
            } else {
                CodeView(buffer: document.buffer, decorations: view.decorations)
                    .selectionState(selection)
                    .font(family: "Menlo", size: 12)
                    .codeViewEditable(editable)
                    .scrollState(view.scroll)
                    .onGutterBarClick { hit in view.selectedEdit = hit.tag.flatMap { view.tags[$0] } }
                    .gutterBarContextMenu { hit in
                        if let edit = hit.tag.flatMap({ view.tags[$0] }) {
                            editMenu(edit: edit, workspace: workspace, store: store, document: document, pane: view.pane)
                        }
                    }
                    .focused($codeFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(codeViewIdentifier)
            }
            if let edit = view.selectedEdit, let record = workspace.editRecord(id: edit), record.state == .live {
                PanelEditBar(workspace: workspace, store: store, record: record)
            }
        }
        .contentMargins(.top, Pixels(Float(view.findVisible ? 0 : topClear)), for: .scrollContent)
        .onChange(of: view.buildTrigger(workspace: workspace), initial: true) {
            view.rebuildIfNeeded(workspace: workspace)
        }
        .onChange(of: codeFocused) { old, new in
            workspace.codeFocusChanged(new, pane: view.pane)
            if new { onFocus?() }
            // Switching to Code mode drops the view's focus; a mode switch never saves.
            if old && !new && workspace.mode == .chat { Task { await workspace.focusLeft(path) } }
        }
    }
}

extension CodePanel {
    /// Side-by-side ids carry the group's id inside a group; Chat keeps `sbs-left` / `sbs-right`.
    static func sideBySideSuffix(_ pane: PaneID) -> String {
        if case .group(let id) = pane { return "-\(id)" }
        return ""
    }
}

struct FindBar: Component {
    let view: OpenDocumentView
    /// Called after Esc closed the bar, to put focus back in the code view.
    let onClose: () -> Void
    @FocusState var fieldFocused: Bool

    var content: some ElementGroup {
        let view = view
        HStack(spacing: Pixels(8)) {
            TextField("Find", text: Binding(get: { view.findQuery }, set: { view.setQuery($0) }))
                .onSubmit { view.step(1) }
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onKeyPress(.escape) { view.closeFind(); onClose(); return .handled }
                .accessibilityIdentifier("find-field")
            Text(verbatim: Self.countText(count: view.findCount, index: view.decorations.currentMatch, truncated: view.findTruncated, query: view.findQuery))
                .font(size: 11).foregroundColor(.mutedInk)
                .accessibilityIdentifier("find-count")
            Button("\u{2191}") { view.step(-1) }.accessibilityIdentifier("find-prev")
            Button("\u{2193}") { view.step(1) }.accessibilityIdentifier("find-next")
        }
        .padding(inset(12, 6))
        .background(.panelFill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("find-bar")
    }

    static func countText(count: Int, index: Int?, truncated: Bool, query: String) -> String {
        if query.isEmpty { return "" }
        if count == 0 { return "No matches" }
        let total = truncated ? "10,000+" : String(count)
        if let index { return "\(index + 1) of \(total)" }
        return truncated ? total : (count == 1 ? "1 match" : "\(count) matches")
    }
}

/// The gutter-bar menu of one edit, in either diff mode.
@MainActor @MenuContentBuilder
func editMenu(edit: UUID, workspace: Workspace, store: SessionUIStore, document: EditorDocument, pane: PaneID) -> some MenuContent {
    let path = document.path
    Button("Keep") { workspace.keep(edit: edit, path: path) }
        .accessibilityIdentifier("keep-\(edit.uuidString)")
    Button("Revert") { Task { _ = await workspace.revertInEditor(edit: edit, path: path) } }
        .accessibilityIdentifier("revert-\(edit.uuidString)")
    Button("Show in chat") {
        if let record = workspace.editRecord(id: edit) { showInChat(record, workspace: workspace, store: store) }
    }
    .accessibilityIdentifier("show-in-chat-\(edit.uuidString)")
    let inline = workspace.presentation(of: path, in: pane) == .inline
    Button(inline ? "Side by side" : "Inline") {
        workspace.setPresentation(inline ? .sideBySide : .inline, of: path, in: pane)
    }
    .accessibilityIdentifier("\(inline ? "side-by-side" : "inline")-\(edit.uuidString)")
}
