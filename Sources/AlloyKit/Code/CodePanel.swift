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
    /// The two compare panes' geometries: the scroll lock converts by line through them, so it stays right when the rows
    /// and the lines of the two panes differ.
    @ObservationIgnored let leftGeometry = CodeViewGeometry()
    @ObservationIgnored let rightGeometry = CodeViewGeometry()
    @ObservationIgnored private(set) var highlighter: CodeViewHighlighter?
    @ObservationIgnored private let engine: HighlightEngine
    @ObservationIgnored private(set) var closed = false
    /// The language-server bridge (for the diagnostics and the definition request).
    @ObservationIgnored let lsp: LSPCoordinator?
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
    @ObservationIgnored private(set) weak var workspace: Workspace?
    @ObservationIgnored private var builtKey: BuildKey?
    @ObservationIgnored private var building: BuildKey?
    /// Decoration tag to edit, for the click and menu closures.
    @ObservationIgnored private(set) var tags: [UInt64: UUID] = [:]
    /// Decoration tag to edit for the left pane's bars (side by side).
    @ObservationIgnored private(set) var leftTags: [UInt64: UUID] = [:]
    @ObservationIgnored private var searchGeneration = 0
    /// The git coordinator's marks for this view (it owns them); nil without a repository or coordinator.
    @ObservationIgnored weak var gitMarks: GitDocumentMarks?
    /// Whether the code view reserves the change lane (git marks can show for this document). Set by
    /// `GitDocumentMarks.laneReserved`; read in the panel body, changes only when a recompute finishes.
    var gitLaneReserved = false
    /// The hunk whose popover is open.
    var selectedGitHunk: GitHunkSelection?
    /// On-demand blame: the file-blame switch, its runs and the open blame popover. Nothing here is read per frame
    /// except `blame.fileOn` in the panel body.
    @ObservationIgnored let blame = GitBlameState()
    /// How often the gutter hover text was asked for (a test seam: it must stay 0 without a hover).
    @ObservationIgnored var gutterHelpCalls = 0
    /// The git compare this view shows (`.compareHead` / `.compareIndex`), or nil while it loads or when there is none.
    private(set) var compare: GitCompare?
    /// Why a compare has nothing to show (an untracked file, no repository).
    private(set) var compareUnavailable: String?
    /// Decoration tag to the index of the compare hunk it belongs to.
    @ObservationIgnored private(set) var compareTags: [UInt64: Int] = [:]
    /// The hunk the compare bar acts on.
    var compareFocus = 0
    var compareMessage: String?
    var compareConfirmRevert = false
    var compareBusy = false
    /// Bumped when the base moved (index or HEAD changed, an action ran): the next build reads the base again.
    private(set) var compareEpoch = 0
    @ObservationIgnored private var compareApplied = false

    /// The old-text pane of the side-by-side diff; nil in inline mode and until the first build.
    private(set) var left: LeftPane?
    /// Which language features the servers of this file offer (written only when they change; the hover is attached by it).
    private(set) var features = FeatureSet()
    /// The hover popover's slot: the view's one text-anchored presentation.
    @ObservationIgnored let popoverSlot = PopoverSlotModel()
    /// Completion as you type; exists only while the document is open at a server offering completion, signature help or
    /// code actions, so a view without one does nothing per keystroke.
    private(set) var scheduler: IntelligenceScheduler?
    /// What the view's one suggestion overlay shows (read only by the overlay itself).
    @ObservationIgnored let overlayModel = IntelligenceOverlayModel()
    @ObservationIgnored private var schedulerFeatures = FeatureSet()
    /// The store's code action service, for the lightbulb probe and the action list.
    @ObservationIgnored weak var actionService: CodeActionService?
    /// The line the lightbulb is on (set only when it changes).
    @ObservationIgnored private(set) var lightbulbLine: Int?
    /// The tag of the lightbulb's gutter marker, told apart from every diff tag.
    nonisolated static let lightbulbTag: UInt64 = .max
    private static let lightbulbOwner = CodeDecorationOwner("lightbulb", priority: 1)
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
        rebuildScheduler()
    }

    /// This pane's caret and selections for the file: the workspace's state for (pane, path), else the buffer's default.
    func selection(in workspace: Workspace? = nil) -> CodeSelectionState {
        (workspace ?? self.workspace)?.selectionState(for: document.path, in: pane) ?? document.buffer.selectionState
    }

    /// Detaches from the document's services (which outlive the view) and drops what the view holds.
    func close() {
        closed = true
        messageTask?.cancel()
        gitMarks?.coordinator?.detach(self)
        dismissHover()
        scheduler?.stop()
        scheduler = nil
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
        attachGit(workspace: workspace)
        let key = buildTrigger(workspace: workspace)
        if key.mode == .plain {
            guard key != builtKey else { return }
            clearDiff()
            builtKey = key
            return
        }
        if key.mode.isCompare { rebuildCompare(workspace: workspace, key: key); return }
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
            dropCompare()
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

    /// Builds a git compare: the base text from the coordinator (cached by blob id), the hunks off the main actor, and
    /// both panes' decorations. The right pane's rows are those of the buffer when the build began.
    private func rebuildCompare(workspace: Workspace, key: BuildKey) {
        guard key != builtKey, key != building else { return }
        building = key
        let path = document.path
        let against: GitCompare.Base = key.mode == .compareHead ? .head : .index
        let snapshot = document.buffer.snapshot()
        let coordinator = workspace.gitServices as? GitCoordinator
        Task { [weak self, weak workspace] in
            let baseText = await coordinator?.compareBase(path: path, against: against)
            let built: GitCompare? = if let baseText {
                await Task.detached { GitCompare.build(base: against, baseText: baseText, snapshot: snapshot) }.value
            } else { nil }
            guard let self, let workspace else { return }
            if building == key { building = nil }
            guard !closed, workspace.presentation(of: path, in: pane) == key.mode, buildTrigger(workspace: workspace) == key else { return }
            applyCompare(built, against: against, snapshot: snapshot, path: path, workspace: workspace)
            builtKey = key
            workspace.noteDecorationBuild()
        }
    }

    private func applyCompare(_ built: GitCompare?, against: GitCompare.Base, snapshot: CodeSnapshot, path: String, workspace: Workspace) {
        appliedDiff = nil
        tags = [:]; leftTags = [:]
        if annotationsSet {
            annotationsSet = false
            decorations.setHighlights([], in: 0..<(1 << 40), layer: .annotations, asOf: document.buffer.version)
        }
        compareApplied = true
        compare = built
        compareUnavailable = built == nil ? (against == .head ? "No HEAD copy of this file to compare with" : "No index copy of this file to compare with") : nil
        compareFocus = min(compareFocus, max(0, (built?.hunks.count ?? 1) - 1))
        guard let built else {
            left?.close(); left = nil
            compareTags = [:]
            decorations.setLineDecorations([], asOf: document.buffer.version)
            decorations.setVirtualRows([], asOf: document.buffer.version)
            return
        }
        let oldBytes = Array(built.baseText.utf8)
        let pane: LeftPane
        if let existing = left, existing.bytes == oldBytes {
            pane = existing
        } else {
            left?.close()
            pane = LeftPane(bytes: oldBytes, path: path, engine: engine)
            left = pane
        }
        let decorated = GitCompareDecorations.build(built, leftRowCount: pane.buffer.snapshot().lineCount, rightRowCount: snapshot.lineCount)
        compareTags = built.tags
        DiffDecorations.applyGit(decorated, right: decorations, rightVersion: snapshot.version,
                                 left: pane.decorations, leftVersion: pane.buffer.version)
        workspace.noteSideBySideBuild()
    }

    /// Forgets a compare (another presentation took over); the next line-layer paint replaces its decorations.
    private func dropCompare() {
        guard compareApplied || compare != nil else { return }
        compareApplied = false
        compare = nil; compareUnavailable = nil; compareTags = [:]
        compareConfirmRevert = false; compareMessage = nil
    }

    /// The base moved (the index or HEAD changed, or an action ran): the compare is built again.
    func compareBaseChanged() {
        if currentPresentation.isCompare { compareEpoch += 1 }
    }

    /// Compares against the other base (HEAD or the index).
    func toggleCompareBase() {
        guard let workspace else { return }
        let next: Presentation = currentPresentation == .compareHead ? .compareIndex : .compareHead
        workspace.setPresentation(next, of: document.path, in: pane)
    }

    /// The source the right pane is compared with, if any.
    func compareSource(workspace: Workspace) -> CompareSource? {
        if currentPresentation.isCompare { return compare.map { .git($0) } }
        if let edit = selectedEdit, let record = workspace.editRecord(id: edit), record.state == .live { return .ledger(record) }
        return nil
    }

    /// This view's presentation as the workspace has it.
    var currentPresentation: Presentation { workspace?.presentation(of: document.path, in: pane) ?? .inline }

    /// Registers with the git coordinator (once) and tells its marks the presentation: they show in a plain view only.
    private func attachGit(workspace: Workspace) {
        if gitMarks == nil, let coordinator = workspace.gitServices as? GitCoordinator { coordinator.attach(self) }
        gitMarks?.presentationSeen(workspace.presentation(of: document.path, in: pane))
    }

    /// A plain presentation: forgets the diff and the left pane, clears the diff's layers and paints the diagnostics alone.
    private func clearDiff() {
        let hadDiff = appliedDiff != nil || compareApplied
        dropCompare()
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
        rebuildScheduler()
    }

    /// Makes the scheduler when the document is open at a server offering one of its features, drops it otherwise. Writes
    /// the observed property only when it appears or goes.
    func rebuildScheduler() {
        let wanted = lsp != nil && !closed && document.state == .editable && services.lspOpen
            && (features.completion || features.signatureHelp || features.codeAction)
        if wanted {
            guard scheduler == nil || schedulerFeatures != features else { return }
            scheduler?.stop()
            schedulerFeatures = features
            scheduler = IntelligenceScheduler(host: ViewIntelHost(view: self), model: overlayModel)
        } else if scheduler != nil {
            scheduler?.stop()
            scheduler = nil
        }
        services.noteSchedulers()
    }

    /// Puts the lightbulb on `line` (0-based), or removes it. Writes the decoration only for a change or a new line.
    func setLightbulb(line: Int?) {
        if line == nil, lightbulbLine == nil { return }
        lightbulbLine = line
        let marks = line.map { [CodeLineDecoration(lines: $0..<($0 + 1), gutterMarker: CodeGutterMarker("\u{1F4A1}"), tag: Self.lightbulbTag)] } ?? []
        decorations.setLineDecorations(marks, asOf: document.buffer.version, owner: Self.lightbulbOwner)
    }

    /// Edits the document's drain passed on; only a view with a scheduler looks at them.
    func intelEdited(_ edits: [CodeEdit], snapshot: CodeSnapshot) {
        scheduler?.edited(edits, snapshot: snapshot)
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

    /// Shows `text` in the header for `seconds` (the result of a quick fix or an edit a server asked for).
    func intelMessage(_ text: String, seconds: Double) { flash(text, seconds: seconds) }

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
        if compareApplied { return }   // a git compare owns the line layers; it shows no diagnostics
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
        if mode.isCompare { return BuildKey(ledger: compareEpoch, saved: document.savedVersion, mode: mode) }
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
    /// The code action service of whichever store made the Chat view of `document`.
    package static func existingCodeActionService(for document: EditorDocument) -> CodeActionService? {
        registry.removeAll { $0.store == nil }
        return registry.lazy.compactMap { entry -> CodeActionService? in
            guard let store = entry.store, store.view(for: document, in: .chat) != nil else { return nil }
            return store.codeActionService
        }.first
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
    /// Builds the fold ranges of every open document and gives them to the workspace.
    private(set) var foldCoordinator: FoldCoordinator?

    /// The services of the document at `path` (one per open document), once a view of it was made.
    func services(for path: String) -> DocumentServices? { servicesByPath[path] }

    /// Connects the store to the workspace's language-server coordinator, if one is installed. Idempotent.
    func attach(workspace: Workspace) {
        installIntelHooks(workspace: workspace)
        if foldCoordinator == nil {
            let engine = engine
            let folds = FoldCoordinator(sources: .production(engine: engine, lsp: { [weak self] in self?.lsp }))
            folds.attach(workspace: workspace)
            foldCoordinator = folds
            for services in servicesByPath.values { services.attachFolds(folds) }
        }
        guard let coordinator = workspace.languageServices as? LSPCoordinator, coordinator !== lsp else { return }
        lsp = coordinator
        installFormat(workspace: workspace, coordinator: coordinator)
        installCodeActions(workspace: workspace, coordinator: coordinator)
        coordinator.savedHandler = { [weak self] path in
            self?.servicesByPath[path]?.lspSaved()
            self?.foldCoordinator?.settled(path: path)
        }
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
        coordinator.reloadHandler = { [weak self] in
            guard let self else { return }
            servicesByPath.values.forEach { $0.lspSettingsChanged() }
            for path in servicesByPath.keys { foldCoordinator?.settled(path: path) }
        }
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
        workspace.intelHooks.run[.triggerCompletion] = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.focusedView(workspace: workspace)?.scheduler?.invoke()
        }
        workspace.intelHooks.run[.triggerSignature] = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.focusedView(workspace: workspace)?.scheduler?.invokeSignature()
        }
        workspace.intelHooks.run[.quickFix] = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.focusedView(workspace: workspace)?.scheduler?.showActions()
        }
        workspace.intelHooks.isEnabled = { [weak self, weak workspace] command in
            guard let self, let workspace, let view = self.focusedView(workspace: workspace) else { return false }
            let editable = view.document.state == .editable
            switch command {
            case .showHover: return view.hoverAttached(editable: editable)
            case .goToSymbol: return view.symbolsAttached(editable: editable)
            case .findReferences: return view.referencesAttached(editable: editable)
            case .triggerCompletion:
                let selections = view.selection(in: workspace).selections
                return view.scheduler != nil && view.features.completion && selections.count == 1 && selections[0].isEmpty
                    && workspace.presentation(of: view.document.path, in: view.pane) != .sideBySide
            case .triggerSignature:
                let selections = view.selection(in: workspace).selections
                return view.scheduler != nil && view.features.signatureHelp && selections.count == 1 && selections[0].isEmpty
                    && workspace.presentation(of: view.document.path, in: view.pane) != .sideBySide
            case .quickFix:
                let selections = view.selection(in: workspace).selections
                return view.scheduler != nil && view.features.codeAction && selections.count == 1
                    && workspace.presentation(of: view.document.path, in: view.pane) != .sideBySide
            case .formatDocument: return editable && view.services.lspOpen && view.features.formatting && formatService != nil
            case .formatSelection:
                let selections = view.selection(in: workspace).selections
                return editable && view.services.lspOpen && view.features.rangeFormatting && formatService != nil
                    && selections.count == 1 && !selections[0].isEmpty
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

    /// Quick fixes and server-initiated edits; made once a coordinator is attached.
    private(set) var codeActionService: CodeActionService?

    private func installCodeActions(workspace: Workspace, coordinator: LSPCoordinator) {
        let service = CodeActionService(workspace: workspace, coordinator: coordinator,
                                        applier: WorkspaceEditApplier(workspace: workspace, coordinator: coordinator))
        service.viewFor = { [weak self, weak workspace] path in
            guard let self, let workspace else { return nil }
            let focused = workspace.defaultPane
            if workspace.activeTab(in: focused) == path, let document = workspace.document(path),
               let view = self.view(for: document, in: focused) { return view }
            return self.views.first { $0.key.path == path && !$0.value.closed }?.value
        }
        codeActionService = service
        for view in views.values { view.actionService = service }
        coordinator.applyEditHandler = { [weak service] path, serverID, label, edit, reply in
            guard let service else { reply.answer(applied: false, failureReason: "the editor is closing"); return }
            service.handleServerEdit(path: path, serverID: serverID, label: label, edit: edit, reply: reply)
        }
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
            services.attachFolds(foldCoordinator)
        }
        let view = OpenDocumentView(document: document, pane: pane, services: services, engine: engine, lsp: lsp)
        view.actionService = codeActionService
        views[key] = view
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
    /// The pane's fold state for the file (nil without one); compared by identity like the selection state. Attached only to
    /// the plain and inline views: the side-by-side and compare branches never call `codeView(editable:)`.
    var fold: CodeFoldState?
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
            let presentation = workspace.presentation(of: path, in: view.pane)
            if presentation == .sideBySide || presentation.isCompare {
                SideBySideView(workspace: workspace, store: store, document: document, view: view, focused: $codeFocused,
                               idSuffix: Self.sideBySideSuffix(view.pane))
            } else if let scheduler = view.scheduler {
                // Completion (and later signature help and code actions) share the one suggestion overlay, chained after the
                // hover popover (slot B) when the server offers hover.
                let model = view.overlayModel
                if view.hoverAttached(editable: editable) {
                    let slot = view.popoverSlot
                    codeView(editable: editable)
                        .onTextHover(delay: .milliseconds(500)) { phase in view.textHover(phase, workspace: workspace) }
                        .gitPopovers(view: view)
                        .popover(item: Binding(get: { slot.hover }, set: { slot.hover = $0 }),
                                 attachmentAnchor: .range(slot.hover?.range ?? 0..<0), arrowEdge: .bottom) { presentation in
                            HoverView(presentation: presentation, cache: slot.markdownCache)
                        }
                        .intelligenceOverlay(scheduler: scheduler, model: model, identifier: codeViewIdentifier)
                } else {
                    codeView(editable: editable)
                        .gitPopovers(view: view)
                        .intelligenceOverlay(scheduler: scheduler, model: model, identifier: codeViewIdentifier)
                }
            } else if view.hoverAttached(editable: editable) {
                // The server offers hover: the view carries the text hover and its one text-anchored popover (slot B).
                let slot = view.popoverSlot
                codeView(editable: editable)
                    .onTextHover(delay: .milliseconds(500)) { phase in view.textHover(phase, workspace: workspace) }
                    .gitPopovers(view: view)
                    .popover(item: Binding(get: { slot.hover }, set: { slot.hover = $0 }),
                             attachmentAnchor: .range(slot.hover?.range ?? 0..<0), arrowEdge: .bottom) { presentation in
                        HoverView(presentation: presentation, cache: slot.markdownCache)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(codeViewIdentifier)
            } else {
                codeView(editable: editable)
                    .gitPopovers(view: view)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier(codeViewIdentifier)
            }
            if presentation.isCompare {
                GitHunkBar(view: view, workspace: workspace)
            } else if case .ledger(let record)? = view.compareSource(workspace: workspace) {
                PanelEditBar(workspace: workspace, store: store, record: record)
            }
        }
        .contentMargins(.top, Pixels(Float(view.findVisible ? 0 : topClear)), for: .scrollContent)
        .onChange(of: view.buildTrigger(workspace: workspace), initial: true) {
            view.rebuildIfNeeded(workspace: workspace)
        }
        .onChange(of: view.blame.popover == nil) { old, new in
            if !old && new { codeFocused = true }
        }
        .onChange(of: view.selectedGitHunk == nil) { old, new in
            // The code view is rebuilt as the popover opens and closes; it takes the keys back.
            if !old && new { codeFocused = true }
        }
        .onChange(of: codeFocused) { old, new in
            workspace.codeFocusChanged(new, pane: view.pane)
            if !new { view.scheduler?.close() }
            if new { view.scheduler?.focusChanged(true) }
            if new { onFocus?() }
            // Switching to Code mode drops the view's focus; a mode switch never saves.
            if old && !new && workspace.mode == .chat { Task { await workspace.focusLeft(path) } }
        }
    }
}

extension _CodeTextAnchoring {
    /// The git hunk and blame popovers, always attached: a closed popover costs nothing per frame, and attaching only
    /// while one is open would change the code view's structure on every open and close.
    @MainActor func gitPopovers(view: OpenDocumentView) -> some _CodeTextAnchoring & ElementGroup {
        self.popover(item: Binding(get: { view.selectedGitHunk }, set: { view.selectedGitHunk = $0 }),
                     attachmentAnchor: .range(view.selectedGitHunk?.anchor ?? 0..<0, asOf: view.selectedGitHunk?.version)) { selection in
            GitHunkPopover(view: view, selection: selection)
        }
        .popover(item: Binding(get: { view.blame.popover }, set: { view.blame.popover = $0 }),
                 attachmentAnchor: .range(view.blame.popover?.anchor ?? 0..<0, asOf: view.blame.popover?.version)) { selection in
            GitBlamePopover(selection: selection)
        }
    }
}

extension CodePanel {
    /// The code view every branch of the panel starts from.
    @MainActor
    func codeView(editable: Bool) -> CodeView {
        let workspace = workspace, store = store, document = document, view = view
        var base = CodeView(buffer: document.buffer, decorations: view.decorations)
            .selectionState(selection)
            .font(family: "Menlo", size: 12)
            .codeViewEditable(editable)
            .scrollState(view.scroll)
        // A code action server reserves the marker lane from the first frame, so the lightbulb never moves the text.
        // File blame widens the lane to initials and age for as long as it is on: one deliberate shift per toggle.
        if view.blame.fileOn {
            base = base.gutterMarkerLane(width: GitBlameMarks.laneWidth)
        } else if view.scheduler != nil && view.features.codeAction {
            base = base.gutterMarkerLane(true)
        }
        // Git marks live in the change lane, reserved from the first frame of a tracked file so the first hunk never
        // shifts the text. Untracked files, chat panels and the diff presentations reserve nothing.
        if view.gitLaneReserved { base = base.changeLane(true) }
        if let fold {
            base = base.foldState(fold).foldGutter(showsOnHover: true, onToggle: { [weak workspace] _ in workspace?.noteFoldsChanged() })
        }
        return base
            .onGutterBarClick { hit in
                switch hit.source {
                case .changeBar where hit.owner == GitGutterMarks.owner:
                    view.openGitHunk(hit)
                case .gutterMarker where hit.tag == OpenDocumentView.lightbulbTag:
                    view.scheduler?.showActions()
                default:
                    if hit.owner == GitBlameMarks.owner { view.openBlameRun(hit) }
                    else { view.selectedEdit = hit.tag.flatMap { view.tags[$0] } }
                }
            }
            .gutterBarContextMenu { hit in
                // Git's change bars and blame runs have their own tag spaces; only author bars name an edit.
                if hit.source != .changeBar, hit.owner != GitBlameMarks.owner, hit.owner != GitGutterMarks.owner,
                   let edit = hit.tag.flatMap({ view.tags[$0] }) {
                    editMenu(edit: edit, workspace: workspace, store: store, document: document, pane: view.pane)
                }
            }
            .gutterHelp { hit in view.gutterHelpText(for: hit) }
            .focused($codeFocused)
    }

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

extension _CodeTextAnchoring where Self: ElementGroup {
    /// The suggestion overlay, its keys, its teardown and the frame every branch of the panel ends with.
    @MainActor
    func intelligenceOverlay(scheduler: IntelligenceScheduler, model: IntelligenceOverlayModel, identifier: String) -> some ElementGroup {
        let open = Binding(get: { model.isPresented }, set: { _ in })
        return suggestionOverlay(isPresented: open, attachmentAnchor: .caret) {
            IntelligenceOverlayView(model: model, onPick: { scheduler.accept(row: $0) })
        }
        // Keys and teardown go after the frame: ahead of it they fold into one more element request per frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
        .onKeyPress(phases: [.down, .repeat]) { press in scheduler.handleKey(press) }
        .onDisappear { scheduler.close() }
    }
}
