import AlloyCore
import AlloyHighlight
import AlloyLSP
import Foundation
import MetalUI
import Observation

/// What one open document keeps once, however many views show it: the highlight-engine feed, the edit cursor, the
/// language-server open/change/close and the semantic tokens. Each ``OpenDocumentView`` of the document attaches to it;
/// every drained edit batch reaches all of them (they keep their own row logs, highlighters and decorations).
@MainActor
final class DocumentServices {
    private enum Feed: Sendable {
        case open(CodeSnapshot)
        case edits([CodeEdit], CodeSnapshot)
    }

    private struct WeakView { weak var view: OpenDocumentView? }

    let document: EditorDocument
    private let engine: HighlightEngine
    /// The language-server bridge, and whether this document is currently reported open to it.
    private let lsp: LSPCoordinator?
    /// The fold-range builder; set by the store right after the services are made.
    private(set) weak var folds: FoldCoordinator?
    private(set) var lspOpen = false
    /// Whether any attached view has a completion scheduler (so a drain looks at the views only then).
    private var hasSchedulers = false
    /// Whether a server handles this file (decided at open and on settings changes, so typing does no lookup).
    private var lspWanted = false
    private(set) var closed = false
    /// True once the engine holds the text: views make their highlighters then.
    private(set) var engineIsOpen = false
    /// Server-driven colours for a file with no grammar; present only while the document is reported to a server.
    private(set) var semantic: SemanticHighlighter?
    private var hasGrammar = true
    private var feed: AsyncStream<Feed>.Continuation?
    private var cursor: CodeEditCursor
    private var views: [WeakView] = []
    /// The row changes since the services started, shared by every view (see ``RowDeltaLog``).
    private(set) var rowLog: RowDeltaLog
    /// Edit batches recorded in the log (test observability).
    private(set) var recordedBatches = 0
    /// The buffer version of the text the opening probe asked about.
    private var probedVersion: UInt64?

    init(document: EditorDocument, engine: HighlightEngine, lsp: LSPCoordinator? = nil) {
        self.document = document
        self.engine = engine
        self.lsp = lsp
        self.cursor = document.buffer.makeEditCursor()
        self.rowLog = RowDeltaLog(base: document.buffer.version)
        startHighlighting()
    }

    /// Lets the fold coordinator follow this document: now when the engine already holds it (or there is no grammar to
    /// wait for), else when the engine opens it.
    func attachFolds(_ coordinator: FoldCoordinator?) {
        folds = coordinator
        if !closed, engineIsOpen || !hasGrammar { folds?.opened(self) }
    }

    /// The views attached now.
    var attachedViews: [OpenDocumentView] { views.compactMap(\.view) }

    /// Starts feeding `view`: it gets the edits from now on, the semantic colours, and a highlighter once the engine holds
    /// the text. Edits not yet drained go to the views already attached first, so the new view's log starts level.
    func attach(_ view: OpenDocumentView) {
        guard !closed, !views.contains(where: { $0.view === view }) else { return }
        drainEdits()
        views.removeAll { $0.view == nil }
        views.append(WeakView(view: view))
        noteSchedulers()
        semantic?.attach(view.decorations)
        if engineIsOpen { view.engineReady() }
    }

    /// A view's scheduler appeared or went.
    func noteSchedulers() { hasSchedulers = views.contains { $0.view?.scheduler != nil } }

    func detach(_ view: OpenDocumentView) {
        views.removeAll { $0.view == nil || $0.view === view }
        noteSchedulers()
        semantic?.detach(view.decorations)
    }

    /// Stops feeding the engine, closes the document at the server and forgets it there.
    func close() {
        closed = true
        folds?.closed(path: document.path)
        if lspOpen { lsp?.closed(path: document.path); lspOpen = false }
        stopSemantic()
        feed?.finish()
        feed = nil
        views.removeAll()
    }

    // MARK: Highlighting

    /// Opens the document in the engine, then watches the buffer and passes every drained edit batch on. The
    /// highlighters exist only once the engine holds the text (`HighlightEngine.open` has returned), and every
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
        guard !closed, !engineIsOpen else { return }
        engineIsOpen = true
        folds?.opened(self)
        for view in attachedViews { view.engineReady() }
    }

    private func observeBuffer() {
        guard !closed else { return }
        withObservationTracking {
            _ = document.buffer.version
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.bufferChanged()
                self.observeBuffer()
            }
        }
    }

    private func bufferChanged() {
        // Matches follow edits but a new one is not found by that, so an open find searches again (off main).
        for entry in views { entry.view?.searchAgainIfOpen(); entry.view?.gitMarks?.typed(); entry.view?.renameBufferChanged() }
        drainEdits()
    }

    /// Passes the buffer's pending edits to the highlight engine, the language server and every attached view.
    func drainEdits() {
        guard !closed else { return }
        let batch = cursor.drain()
        switch batch {
        case .edits(let edits):
            guard !edits.isEmpty else { return }
            let after = document.buffer.snapshot()
            recordedBatches += 1
            for edit in edits { rowLog.record(edit) }
            feed?.yield(.edits(edits, after))
            folds?.edited(path: document.path, edits: edits)
            forwardToLSP(.edits(edits, after: after), snapshot: after)
            semantic?.documentChanged()
            if hasSchedulers { for entry in views { entry.view?.intelEdited(edits, snapshot: after) } }
        case .resync(let snapshot):
            rowLog.reset(at: snapshot.version)
            feed?.yield(.open(snapshot))
            folds?.resynced(path: document.path, snapshot: snapshot)
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

    /// The server answered whether it offers semantic tokens for this file.
    func semanticSupport(_ supported: Bool) {
        guard let lsp, !closed, lspOpen, !hasGrammar else { return }
        guard supported else { stopSemantic(); return }
        guard semantic == nil else { return }
        let highlighter = SemanticHighlighter(path: document.path) { [weak lsp] path in
            lsp?.requestSemanticTokens(path: path)
        }
        for view in attachedViews { highlighter.attach(view.decorations) }
        semantic = highlighter
        // An edit between the probe and now cancelled the probe's answer in the manager, and the edit's own request was
        // dropped because there was no highlighter: ask for the current text.
        if probedVersion != document.buffer.version { highlighter.documentChanged() }
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
        for view in attachedViews { view.rebuildScheduler() }
    }
}
