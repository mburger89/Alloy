import AlloyCore
import AlloyHighlight
import Foundation
import MetalUI
import AlloyLSP
import Observation

/// What a decoration build is for: the ledger's version and the buffer version it was saved as.
struct BuildKey: Equatable { var ledger: Int; var saved: UInt64; var mode: DiffMode }

/// What the panel keeps for one open document: its `CodeDecorations` and highlighter, the selected edit, the
/// find state and the scroll position. Kept by path in ``CodePanelStore`` so a tab switch loses none of it.
@MainActor @Observable
final class OpenDocumentView {
    private enum Feed: Sendable {
        case open(CodeSnapshot)
        case edits([CodeEdit], CodeSnapshot)
    }

    @ObservationIgnored let document: EditorDocument
    @ObservationIgnored let decorations: CodeDecorations
    @ObservationIgnored let scroll = CodeScrollState()
    /// The left pane's scroll position in side-by-side mode; it outlives the pane, which is rebuilt with the ledger.
    @ObservationIgnored let leftScroll = CodeScrollState()
    @ObservationIgnored private(set) var highlighter: CodeViewHighlighter?
    /// Server-driven colours for a file with no grammar; present only while the document is reported to a server.
    @ObservationIgnored private(set) var semantic: SemanticHighlighter?
    @ObservationIgnored private var hasGrammar = true
    @ObservationIgnored private var feed: AsyncStream<Feed>.Continuation?
    @ObservationIgnored private var cursor: CodeEditCursor
    @ObservationIgnored private let engine: HighlightEngine
    @ObservationIgnored private(set) var closed = false
    /// The language-server bridge, and whether this document is currently reported open to it.
    @ObservationIgnored private let lsp: LSPCoordinator?
    @ObservationIgnored private var lspOpen = false
    /// Whether a server handles this file (decided at open and on settings changes, so typing does no lookup).
    @ObservationIgnored private var lspWanted = false
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
    /// The row changes since the view opened, to carry the diff to the current version by hand (see ``RowDeltaLog``).
    @ObservationIgnored private var rowLog: RowDeltaLog
    @ObservationIgnored private var appliedDiff: AppliedDiff?
    @ObservationIgnored private var builtKey: BuildKey?
    @ObservationIgnored private var building: BuildKey?
    /// Decoration tag to edit, for the click and menu closures.
    @ObservationIgnored private(set) var tags: [UInt64: UUID] = [:]
    /// Decoration tag to edit for the left pane's bars (side by side).
    @ObservationIgnored private(set) var leftTags: [UInt64: UUID] = [:]
    @ObservationIgnored private var searchGeneration = 0

    /// The old-text pane of the side-by-side diff; nil in inline mode and until the first build.
    private(set) var left: LeftPane?
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

    init(document: EditorDocument, engine: HighlightEngine, lsp: LSPCoordinator? = nil) {
        self.document = document
        self.engine = engine
        self.lsp = lsp
        self.decorations = CodeDecorations(buffer: document.buffer)
        self.decorations.theme = .alloy
        self.cursor = document.buffer.makeEditCursor()
        self.rowLog = RowDeltaLog(base: document.buffer.version)
        startHighlighting()
    }

    /// Stops feeding the engine and forgets the document there.
    func close() {
        closed = true
        messageTask?.cancel()
        if lspOpen { lsp?.closed(path: document.path); lspOpen = false }
        stopSemantic()
        left?.close()
        left = nil
        feed?.finish()
        feed = nil
    }

    // MARK: Highlighting

    /// Opens the document in the engine, then watches the buffer and passes every drained edit batch on. The
    /// highlighter exists only once the engine holds the text (`HighlightEngine.open` has returned), and every
    /// engine call is made in order from one task, so the engine's version never runs ahead of a request's.
    private func startHighlighting() {
        cursor = document.buffer.makeEditCursor()
        defer { observeBuffer() }
        let first = document.buffer.snapshot()
        let detected = Language.detect(path: document.path, firstLine: first.lineCount > 0 ? first.line(0) : nil)
        hasGrammar = detected != nil
        reportOpenToLSP(first)
        guard let language = detected else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Feed.self)
        feed = continuation
        let engine = engine, id = document.id
        continuation.yield(.open(first))
        Task.detached { [weak self] in
            for await item in stream {
                switch item {
                case .open(let snapshot):
                    await engine.open(id: id, language: language, snapshot: snapshot, version: snapshot.version)
                    await self?.engineOpened()
                case .edits(let edits, let snapshot):
                    await engine.edit(id: id, edits: edits, snapshot: snapshot, version: snapshot.version)
                }
            }
            await engine.close(id: id)
        }
    }

    private func engineOpened() {
        guard !closed, highlighter == nil else { return }
        highlighter = CodeViewHighlighter(engine: engine, documentID: document.id, decorations: decorations)
        decorations.invalidateHighlights(in: 0..<document.buffer.utf8Count)
    }

    private func observeBuffer() {
        guard !closed else { return }
        withObservationTracking {
            _ = document.buffer.version
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.drain()
                self.observeBuffer()
            }
        }
    }

    private func drain() {
        // Matches follow edits but a new one is not found by that, so an open find searches again (off main).
        if findVisible, !findQuery.isEmpty { search() }
        drainEdits()
    }

    /// Passes the buffer's pending edits to the highlight engine and the language server.
    private func drainEdits() {
        let batch = cursor.drain()
        switch batch {
        case .edits(let edits):
            guard !edits.isEmpty else { return }
            let after = document.buffer.snapshot()
            for edit in edits { rowLog.record(edit) }
            feed?.yield(.edits(edits, after))
            forwardToLSP(.edits(edits, after: after), snapshot: after)
            semantic?.documentChanged()
        case .resync(let snapshot):
            rowLog.reset(at: snapshot.version)
            feed?.yield(.open(snapshot))
            forwardToLSP(.resync(snapshot), snapshot: snapshot)
            semantic?.documentChanged()
        }
    }

    /// A file over the server size cap is never reported: one that grows past it is closed, one that shrinks below it
    /// is opened then.
    private func forwardToLSP(_ change: DocumentChange, snapshot: CodeSnapshot) {
        guard lspWanted, let lsp else { return }
        let fits = snapshot.utf8Count <= DocumentSync.maxFileBytes
        if lspOpen {
            if fits {
                lsp.changed(path: document.path, change: change)
            } else {
                lsp.closed(path: document.path)
                lspOpen = false
                stopSemantic()
            }
        } else if fits {
            reportOpenToLSP(snapshot)
        }
    }

    // MARK: Language server

    /// Tells the language server about this document when one handles its file. Read-only documents (truncated or
    /// not valid UTF-8) never reach a server: their text is not the file's.
    private func reportOpenToLSP(_ snapshot: CodeSnapshot) {
        guard let lsp, document.state == .editable, lsp.wants(document.path) else { return }
        lspWanted = true
        guard snapshot.utf8Count <= DocumentSync.maxFileBytes else { return }
        lspOpen = true
        probedVersion = snapshot.version
        lsp.opened(path: document.path, snapshot: snapshot)
        // A file with no grammar takes its colours from the server's semantic tokens, if it offers them: the first
        // request finds out (once the server is ready), and only then is a highlighter made.
        if !hasGrammar { lsp.requestSemanticTokens(path: document.path, probe: true) }
    }

    /// The buffer version of the text the opening probe asked about.
    @ObservationIgnored private var probedVersion: UInt64?

    /// The server answered whether it offers semantic tokens for this file.
    func semanticSupport(_ supported: Bool) {
        guard let lsp, !closed, lspOpen, !hasGrammar else { return }
        guard supported else { stopSemantic(); return }
        guard semantic == nil else { return }
        semantic = SemanticHighlighter(path: document.path, decorations: decorations) { [weak lsp] path in
            lsp?.requestSemanticTokens(path: path)
        }
        // An edit between the probe and now cancelled the probe's answer in the manager, and the edit's own request was
        // dropped because there was no highlighter: ask for the current text.
        if probedVersion != document.buffer.version { semantic?.documentChanged() }
    }

    private func stopSemantic() {
        semantic?.stop()
        semantic = nil
    }

    /// After a save: sends the edits not yet passed on, so the server sees `didSave` after the text it saved.
    func lspSaved() {
        guard lspOpen, !closed else { return }
        drainEdits()
        lsp?.flushedSaved(path: document.path)
    }

    /// After the server settings changed: reports the document if a server now handles it, and forgets it if none does.
    func lspSettingsChanged() {
        guard let lsp, !closed else { return }
        if lsp.wants(document.path) {
            if !lspOpen { drainEdits(); lspWanted = false; reportOpenToLSP(document.buffer.snapshot()) }
        } else {
            lspOpen = false
            lspWanted = false
            stopSemantic()
        }
    }

    // MARK: Diff decorations

    /// Builds the diff decorations (and, side by side, the left pane) when the ledger, the saved text or the mode
    /// moved since the last build (never on typing). The diff and the models are made off the main actor and applied
    /// only if nothing moved meanwhile, and only when the buffer's saved text is the ledger's text (a session edit
    /// reaches the ledger before the buffer). The right pane's rows are those of the saved version, which MetalUI
    /// maps forward through unsaved typing.
    func rebuildIfNeeded(workspace: Workspace) {
        let path = document.path
        guard let file = workspace.ledger.files[path] else { return }
        let key = buildTrigger(workspace: workspace)
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
                  sameText, document.diffMode == key.mode else { return }
            tags = model.tags
            appliedDiff = AppliedDiff(model: model, sessions: workspace.sessions, version: key.saved,
                                      byteCount: saved.utf8Count, fillers: sbs?.rightFillers, rowCount: saved.lineCount)
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
        guard let lsp, lspOpen, !closed else {
            showDefinitionMessage("No definition found", seconds: Self.noDefinitionSeconds)
            return nil
        }
        drainEdits()
        let snapshot = document.buffer.snapshot()
        let offset = document.buffer.primarySelection.head
        let path = document.path
        return Task { @MainActor [weak self] in
            let outcome = await lsp.definition(path: path, utf8Offset: offset, snapshot: snapshot)
            guard !Task.isCancelled, let self, !self.closed, workspace.activeTab == path,
                  self.document.buffer.version == snapshot.version, self.document.buffer.primarySelection.head == offset else { return }
            switch outcome {
            case .stale: return
            case .unavailable: self.showDefinitionMessage("No definition found", seconds: Self.noDefinitionSeconds)
            case .answered(let result):
                guard let first = result.targets.first else {
                    self.showDefinitionMessage("No definition found", seconds: Self.noDefinitionSeconds)
                    return
                }
                await self.go(to: first, encoding: result.encoding, workspace: workspace)
            }
        }
    }

    private func go(to target: DefinitionTarget, encoding: PositionEncoding, workspace: Workspace) async {
        switch target {
        case .inWorkspace(let path, let range):
            await workspace.open(path, selecting: { Positions.utf8Range(of: range, in: $0, encoding: encoding) })
        case .external(let url, let range):
            // Alloy has no read-only view for files outside the project (`Workspace.open` refuses them): say where it is.
            showDefinitionMessage("Definition: \(url.path):\(range.start.line + 1):\(range.start.character + 1)",
                                  seconds: Self.externalSeconds)
        }
    }

    private func showDefinitionMessage(_ text: String, seconds: Double) {
        definitionMessage = text
        messageTask?.cancel()
        messageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.definitionMessage = nil
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
    private func applyLineLayers() {
        drainEdits()   // the row log must hold every edit MetalUI has seen
        var layout = DiagnosticDecorations.currentLayout(lsp?.diagnostics.entry(for: document.path), in: document.buffer)
        let sideBySide = document.diffMode == .sideBySide
        if sideBySide { layout.rows = [] }   // only the right pane could show them, which would unlevel the panes
        if let diff = appliedDiff {
            let ok = DiffDecorations.apply(diff.model, to: decorations, sessions: diff.sessions, version: diff.version,
                                           byteCount: diff.byteCount, fillers: diff.fillers,
                                           diagnostics: layout, rowLog: rowLog, savedRowCount: diff.rowCount,
                                           includeAnnotations: !diff.annotated)
            if ok, !diff.annotated {
                appliedDiff?.annotated = true
                annotationApplyCount += 1
            }
            if !ok {
                // The diff cannot be carried forward any more: forget it and have it built again.
                appliedDiff = nil
                builtKey = nil
            }
        } else if lsp != nil {
            DiffDecorations.applyDiagnostics(layout, to: decorations)
        }
    }

    /// Selects the next (`+1`) or previous (`-1`) problem from the caret, wrapping.
    func stepProblem(_ direction: Int) {
        let items = DiagnosticDecorations.current(lsp?.diagnostics.entry(for: document.path), in: document.buffer)
        let selection = document.buffer.primarySelection.range
        guard let range = DiagnosticDecorations.nextProblem(items, selection: selection, direction: direction) else { return }
        document.buffer.select(range, reveal: true)
    }

    /// The value `onChange` watches to start a rebuild.
    func buildTrigger(workspace: Workspace) -> BuildKey {
        BuildKey(ledger: workspace.ledger.files[document.path]?.version ?? -1, saved: document.savedVersion, mode: document.diffMode)
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
        let caret = document.buffer.primarySelection
        let next: Int
        if let current = decorations.currentMatch {
            next = (current + direction + matches.count) % matches.count
        } else if direction > 0 {
            next = matches.firstIndex { $0.lowerBound >= caret.range.upperBound } ?? 0
        } else {
            next = matches.lastIndex { $0.lowerBound < caret.range.lowerBound } ?? matches.count - 1
        }
        decorations.currentMatch = next
        document.buffer.select(matches[next], reveal: true)
    }
}

/// The panel's per-document state and the one highlight engine, owned above the panel (by `AlloyScreen`) so they
/// outlive re-renders.
@MainActor @Observable
final class CodePanelStore {
    @ObservationIgnored private let engine = HighlightEngine()
    private final class Weak { weak var store: CodePanelStore?; init(_ s: CodePanelStore) { store = s } }
    private static var registry: [Weak] = []

    /// The state of `document` in whichever store made it, so a test can reach the panel's per-document state.
    package static func existingView(for document: EditorDocument) -> OpenDocumentView? {
        registry.removeAll { $0.store == nil }
        return registry.lazy.compactMap { $0.store?.view(for: document) }.first
    }
    private var views: [String: OpenDocumentView] = [:]
    private var lsp: LSPCoordinator?

    /// Connects the store to the workspace's language-server coordinator, if one is installed. Idempotent.
    func attach(workspace: Workspace) {
        guard let coordinator = workspace.languageServices as? LSPCoordinator, coordinator !== lsp else { return }
        lsp = coordinator
        coordinator.savedHandler = { [weak self] path in self?.views[path]?.lspSaved() }
        coordinator.diagnosticsHandler = { [weak self] path in self?.views[path]?.paintDiagnostics() }
        coordinator.semanticSupportHandler = { [weak self] path, supported in self?.views[path]?.semanticSupport(supported) }
        coordinator.semanticHandler = { [weak self] path, version, runs in self?.views[path]?.semantic?.apply(runs, version: version) }
        workspace.goToDefinition = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.goToDefinition(workspace: workspace)
        }
        coordinator.reloadHandler = { [weak self] in self?.views.values.forEach { $0.lspSettingsChanged() } }
    }

    /// The one go-to-definition in flight, for whichever view asked last.
    private var definitionTask: Task<Void, Never>?

    /// Go to Definition at the active tab's caret; replaces (cancels) any request still in flight.
    func goToDefinition(workspace: Workspace) {
        cancelDefinition()
        guard let path = workspace.activeTab, let document = workspace.document(path), let view = view(for: document) else { return }
        definitionTask = view.startDefinition(workspace: workspace)
    }

    /// Abandons the request in flight (a tab switch, a closed view).
    func cancelDefinition() {
        definitionTask?.cancel()
        definitionTask = nil
    }

    /// Makes (or replaces, when the path was reopened) the state of `document`. Called outside rendering.
    func ensureView(for document: EditorDocument) {
        if !Self.registry.contains(where: { $0.store === self }) { Self.registry.append(Weak(self)) }
        if let existing = views[document.path], existing.document === document { return }
        if views[document.path] != nil { cancelDefinition() }
        views[document.path]?.close()
        views[document.path] = OpenDocumentView(document: document, engine: engine, lsp: lsp)
    }

    /// The state of `document`, once ``ensureView(for:)`` has made it.
    func view(for document: EditorDocument) -> OpenDocumentView? {
        guard let view = views[document.path], view.document === document else { return nil }
        return view
    }

    /// Closes the view of every tab whose document was replaced (a read-only file made editable again installs a
    /// new document), active or not, and makes the new document's view for a tab that had one. A tab that never
    /// had a view gets one when it is first shown.
    func refreshReplaced(workspace: Workspace) {
        for (path, view) in views where workspace.document(path) !== view.document {
            cancelDefinition()
            view.close()
            views[path] = nil
            if let document = workspace.document(path) { ensureView(for: document) }
        }
    }

    /// Drops the state of documents that are no longer open.
    func prune(keeping paths: [String]) {
        for (path, view) in views where !paths.contains(path) {
            cancelDefinition()
            view.close()
            views[path] = nil
        }
    }

}

/// The code view of one document with its find bar and edit bar.
struct CodePanel: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let document: EditorDocument
    let view: OpenDocumentView
    @FocusState var codeFocused: Bool

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CodePanel")
        let workspace = workspace, document = document, view = view, path = document.path
        let editable = document.state == .editable
        VStack(alignment: .leading, spacing: 0) {
            if view.findVisible { FindBar(view: view, onClose: { codeFocused = true }) }
            if document.diffMode == .sideBySide {
                SideBySideView(workspace: workspace, store: store, document: document, view: view, focused: $codeFocused)
            } else {
                CodeView(buffer: document.buffer, decorations: view.decorations)
                    .font(family: "Menlo", size: 12)
                    .codeViewEditable(editable)
                    .scrollState(view.scroll)
                    .onGutterBarClick { hit in view.selectedEdit = hit.tag.flatMap { view.tags[$0] } }
                    .gutterBarContextMenu { hit in
                        if let edit = hit.tag.flatMap({ view.tags[$0] }) {
                            editMenu(edit: edit, workspace: workspace, store: store, document: document)
                        }
                    }
                    .focused($codeFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("code-view")
            }
            if let edit = view.selectedEdit, let record = workspace.editRecord(id: edit), record.state == .live {
                PanelEditBar(workspace: workspace, store: store, record: record)
            }
        }
        .onChange(of: view.buildTrigger(workspace: workspace), initial: true) {
            view.rebuildIfNeeded(workspace: workspace)
        }
        .onChange(of: codeFocused) { old, new in
            workspace.codePanelFocused = new
            if old && !new { Task { await workspace.focusLeft(path) } }
        }
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
func editMenu(edit: UUID, workspace: Workspace, store: SessionUIStore, document: EditorDocument) -> some MenuContent {
    let path = document.path
    Button("Keep") { workspace.keep(edit: edit, path: path) }
        .accessibilityIdentifier("keep-\(edit.uuidString)")
    Button("Revert") { Task { _ = await workspace.revertInEditor(edit: edit, path: path) } }
        .accessibilityIdentifier("revert-\(edit.uuidString)")
    Button("Show in chat") {
        if let record = workspace.editRecord(id: edit) { showInChat(record, workspace: workspace, store: store) }
    }
    .accessibilityIdentifier("show-in-chat-\(edit.uuidString)")
    Button(document.diffMode == .inline ? "Side by side" : "Inline") {
        document.diffMode = document.diffMode == .inline ? .sideBySide : .inline
    }
    .accessibilityIdentifier("\(document.diffMode == .inline ? "side-by-side" : "inline")-\(edit.uuidString)")
}
