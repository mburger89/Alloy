import AlloyCore
import AlloyHighlight
import Foundation
import MetalUI
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
    @ObservationIgnored private var feed: AsyncStream<Feed>.Continuation?
    @ObservationIgnored private var cursor: CodeEditCursor
    @ObservationIgnored private let engine: HighlightEngine
    @ObservationIgnored private(set) var closed = false
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

    init(document: EditorDocument, engine: HighlightEngine) {
        self.document = document
        self.engine = engine
        self.decorations = CodeDecorations(buffer: document.buffer)
        self.decorations.theme = .alloy
        self.cursor = document.buffer.makeEditCursor()
        startHighlighting()
    }

    /// Stops feeding the engine and forgets the document there.
    func close() {
        closed = true
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
        guard let language = Language.detect(path: document.path, firstLine: first.lineCount > 0 ? first.line(0) : nil) else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Feed.self)
        feed = continuation
        let engine = engine, id = document.id
        continuation.yield(.open(first))
        Task.detached { [weak self] in
            for await item in stream {
                switch item {
                case .open(let snapshot):
                    await engine.open(id: id, language: language, text: snapshot.text, version: snapshot.version)
                    await self?.engineOpened()
                case .edits(let edits, let snapshot):
                    await engine.edit(id: id, edits: edits, newText: snapshot.text, version: snapshot.version)
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
        let batch = cursor.drain()
        switch batch {
        case .edits(let edits):
            guard !edits.isEmpty else { return }
            feed?.yield(.edits(edits, document.buffer.snapshot()))
        case .resync(let snapshot):
            feed?.yield(.open(snapshot))
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
            DiffDecorations.apply(model, to: decorations, sessions: workspace.sessions, version: key.saved,
                                  byteCount: saved.utf8Count, fillers: sbs?.rightFillers)
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

    /// Makes (or replaces, when the path was reopened) the state of `document`. Called outside rendering.
    func ensureView(for document: EditorDocument) {
        if !Self.registry.contains(where: { $0.store === self }) { Self.registry.append(Weak(self)) }
        if let existing = views[document.path], existing.document === document { return }
        views[document.path]?.close()
        views[document.path] = OpenDocumentView(document: document, engine: engine)
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
            view.close()
            views[path] = nil
            if let document = workspace.document(path) { ensureView(for: document) }
        }
    }

    /// Drops the state of documents that are no longer open.
    func prune(keeping paths: [String]) {
        for (path, view) in views where !paths.contains(path) {
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
    Button("Revert") { Task { _ = await workspace.revertInEditor(edit: edit, path: path) } }
    Button("Show in chat") {
        if let record = workspace.editRecord(id: edit) { showInChat(record, workspace: workspace, store: store) }
    }
    Button(document.diffMode == .inline ? "Side by side" : "Inline") {
        document.diffMode = document.diffMode == .inline ? .sideBySide : .inline
    }
}
