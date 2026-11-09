import AlloyCore
import AlloyHighlight
import Foundation
import MetalUI

/// The read-only left pane of the side-by-side diff: a buffer of the ledger's old text, its decorations and its
/// own highlighter. A new pane is made whenever the ledger changes; the old one is closed.
@MainActor
final class LeftPane {
    let bytes: [UInt8]
    let buffer: CodeBuffer
    let decorations: CodeDecorations
    private(set) var highlighter: CodeViewHighlighter?
    private let engine: HighlightEngine
    private let id = UUID()
    private var opening: Task<Void, Never>?
    private var closed = false
    /// Texts up to this many bytes are turned into a `String` inline; larger ones are built off the main actor.
    nonisolated static let inlineTextLimit = 64 * 1024
    /// Whether the engine's copy of the text was built off the main actor (nil until the pane is opened).
    private(set) var textBuiltOffMain: Bool?

    init(bytes: [UInt8], path: String, engine: HighlightEngine) {
        self.bytes = bytes
        buffer = CodeBuffer(utf8: bytes)
        buffer.isReadOnly = true
        decorations = CodeDecorations(buffer: buffer)
        decorations.theme = .alloy
        self.engine = engine
        let snapshot = buffer.snapshot()
        guard let language = Language.detect(path: path, firstLine: snapshot.lineCount > 0 ? snapshot.line(0) : nil) else { return }
        // The engine holds the text (at the buffer's version) before the first request is made.
        let id = id
        let offMain = bytes.count > Self.inlineTextLimit
        opening = Task { [weak self] in
            // The buffer is read-only, so the snapshot's version is the pane's only version: no later check is needed.
            let text = offMain ? await Task.detached { snapshot.text }.value : snapshot.text
            self?.textBuiltOffMain = offMain
            await engine.open(id: id, language: language, text: text, version: snapshot.version)
            guard let self, !closed else { return }
            highlighter = CodeViewHighlighter(engine: engine, documentID: id, decorations: decorations)
            decorations.invalidateHighlights(in: 0..<buffer.utf8Count)
        }
    }

    func close() {
        closed = true
        let engine = engine, id = id, opening = opening
        Task { await opening?.value; await engine.close(id: id) }
    }
}

/// Old text on the left, the live document on the right, with blank filler rows keeping the lines level and the two
/// scroll positions locked together. MetalUI does not report an assigned `CodeScrollState.position` through
/// `onScroll`, so assigning the other pane's position from `onScroll` cannot feed back.
struct SideBySideView: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let document: EditorDocument
    let view: OpenDocumentView
    /// The panel's one focus source: the right pane is the focus target, as the inline view is.
    let focused: FocusState<Bool>.Binding

    var content: some ElementGroup {
        let workspace = workspace, store = store, document = document, view = view
        let editable = document.state == .editable
        HStack(spacing: 0) {
            if let left = view.left {
                CodeView(buffer: left.buffer, decorations: left.decorations)
                    .font(family: "Menlo", size: 12)
                    .codeViewEditable(false)
                    .scrollState(view.leftScroll)
                    .onScroll { position in view.scroll.position = CodeScrollPosition(row: position.row, x: view.scroll.position.x) }
                    .onGutterBarClick { hit in view.selectedEdit = hit.tag.flatMap { view.leftTags[$0] } }
                    .gutterBarContextMenu { hit in
                        if let edit = hit.tag.flatMap({ view.leftTags[$0] }) {
                            editMenu(edit: edit, workspace: workspace, store: store, document: document)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("sbs-left")
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            CodeView(buffer: document.buffer, decorations: view.decorations)
                .font(family: "Menlo", size: 12)
                .codeViewEditable(editable)
                .scrollState(view.scroll)
                .onScroll { position in view.leftScroll.position = CodeScrollPosition(row: position.row, x: view.leftScroll.position.x) }
                .onGutterBarClick { hit in view.selectedEdit = hit.tag.flatMap { view.tags[$0] } }
                .gutterBarContextMenu { hit in
                    if let edit = hit.tag.flatMap({ view.tags[$0] }) {
                        editMenu(edit: edit, workspace: workspace, store: store, document: document)
                    }
                }
                .focused(focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("sbs-right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
