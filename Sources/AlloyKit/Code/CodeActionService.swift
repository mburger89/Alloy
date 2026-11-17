import AlloyCore
import AlloyLSP
import Foundation
import MetalUICodeBuffer

/// What choosing a code action did.
enum CodeActionResult: Equatable {
    case applied
    case failed(String)
    case cancelled
}

/// Asks the language servers for code actions, resolves, applies and runs them. Edits go through the
/// ``WorkspaceEditApplier`` (one undo step per open file, one ledger group). Nothing here runs until a caller asks, so an
/// idle editor pays nothing.
@MainActor
final class CodeActionService {
    private let workspace: Workspace
    private let coordinator: LSPCoordinator
    private let applier: WorkspaceEditApplier
    /// The view of a path's document (focused pane first), for its text services and messages.
    var viewFor: (@MainActor (String) -> OpenDocumentView?)?
    static let staleMessage = "File changed, quick fix not applied"
    private static let messageSeconds = 3.0

    init(workspace: Workspace, coordinator: LSPCoordinator, applier: WorkspaceEditApplier) {
        self.workspace = workspace
        self.coordinator = coordinator
        self.applier = applier
    }

    // MARK: Request

    /// The actions for `range` of `view`'s document (empty when nothing applies, the server is busy or the view is not
    /// eligible). Remembers the buffer version they were computed for, which ``choose(_:in:)`` checks.
    func actions(for view: OpenDocumentView, range: Range<Int>, automatic: Bool) async -> [CodeActionItem] {
        guard view.document.state == .editable, view.services.lspOpen, !view.closed, view.features.codeAction else { return [] }
        view.services.drainEdits()
        let snapshot = view.document.buffer.snapshot()
        let path = view.document.path
        let range = min(range.lowerBound, snapshot.utf8Count)..<min(range.upperBound, snapshot.utf8Count)
        guard case .answered(let items) = await coordinator.codeActions(path: path, range: range, snapshot: snapshot,
                                                                         automatic: automatic) else { return [] }
        guard !Task.isCancelled, !view.closed, view.document.buffer.version == snapshot.version else { return [] }
        return items.map { var item = $0; item.requestVersion = snapshot.version; return item }
    }

    // MARK: Choose

    /// Applies `item` for `view`: resolves it when its edit is missing, applies the edit, then runs its command. A buffer
    /// that changed since the actions were requested applies nothing.
    func choose(_ item: CodeActionItem, in view: OpenDocumentView) async -> CodeActionResult {
        if let reason = item.disabledReason { return fail("\(item.title): \(reason)", view) }
        guard !view.closed, view.document.state == .editable else { return fail("This file is read-only", view) }
        let path = view.document.path
        let base = item.requestVersion ?? view.document.buffer.version
        guard view.document.buffer.version == base else { return fail(Self.staleMessage, view) }
        var item = item
        if item.edit == nil, item.data != nil {
            view.services.drainEdits()
            let outcome = await coordinator.resolveCodeAction(path: path, item: item, snapshot: view.document.buffer.snapshot())
            if Task.isCancelled { return .cancelled }
            guard !view.closed, view.document.buffer.version == base else { return fail(Self.staleMessage, view) }
            guard case .answered(let resolved) = outcome else {
                if case .stale = outcome { return fail(Self.staleMessage, view) }
                return fail("\(item.title) could not be resolved", view)
            }
            item = resolved
        }
        guard item.edit != nil || item.command != nil else { return fail("\(item.title) has no effect", view) }
        if let edit = item.edit {
            let encoding = await coordinator.positionEncoding(path: path, serverID: item.serverID)
            if Task.isCancelled { return .cancelled }
            guard !view.closed, view.document.buffer.version == base else { return fail(Self.staleMessage, view) }
            if let message = await applyWorkspaceEdit(edit, encoding: encoding, pinned: [path: base]) { return fail(message, view) }
        }
        if let command = item.command {
            view.services.drainEdits()
            let outcome = await coordinator.executeCommand(path: path, serverID: item.serverID, command: command,
                                                           snapshot: view.document.buffer.snapshot())
            switch outcome {
            case .answered: break
            case .stale: return fail(Self.staleMessage, view)
            case .timedOut: return fail("\(item.title) timed out", view)
            case .failed(let message): return fail("\(item.title) failed: \(message)", view)
            case .unavailable: return Task.isCancelled ? .cancelled : fail("The server cannot run \(item.title)", view)
            }
        }
        return .applied
    }

    // MARK: Server-initiated edits

    /// Applies a `workspace/applyEdit` a server sent (usually while running a command) and answers it. Buffers that differ
    /// from their state at receipt, a path with no open editor, and any rejected edit answer `applied: false`.
    func handleServerEdit(path: String, serverID: String, label: String?, edit: JSONValue, reply: ApplyEditReply) {
        guard let view = viewFor?(path), !view.closed else {
            reply.answer(applied: false, failureReason: "no editor is open for that file")
            return
        }
        let receipt = view.document.buffer.version
        Task { @MainActor [self] in
            let encoding = await coordinator.positionEncoding(path: path, serverID: serverID)
            // The command's own file is pinned to its version at receipt; other open files are pinned when the edit is read.
            if let message = await applyWorkspaceEdit(edit, encoding: encoding, pinned: [path: receipt]) {
                if !view.closed { view.intelMessage(message, seconds: Self.messageSeconds) }
                reply.answer(applied: false, failureReason: message)
            } else {
                reply.answer(applied: true, failureReason: nil)
            }
        }
    }

    // MARK: Apply

    /// Reads and applies `edit`; nil on success, else the message. `pinned` holds the buffer versions the edit's
    /// computation was for; every other open file it touches is pinned to its version right now.
    private func applyWorkspaceEdit(_ edit: JSONValue, encoding: PositionEncoding, pinned: [String: UInt64]) async -> String? {
        let files: [FileEdits]
        do {
            files = try WorkspaceEditParsing.normalize(edit, root: workspace.projectRoot, encoding: encoding) { [workspace] path in
                if let doc = workspace.document(path) { return doc.buffer.snapshot() }
                guard let data = try? Data(contentsOf: workspace.projectRoot.appendingPathComponent(path)) else { return nil }
                return CodeBuffer(utf8: [UInt8](data)).snapshot()
            }
        } catch {
            return error.message
        }
        var bases = pinned
        for file in files where bases[file.path] == nil {
            if let doc = workspace.document(file.path) { bases[file.path] = doc.buffer.version }
        }
        let outcome = await applier.apply(files, baseVersions: bases, label: "quick fix")
        return outcome.message
    }

    private func fail(_ message: String, _ view: OpenDocumentView) -> CodeActionResult {
        if !view.closed { view.intelMessage(message, seconds: Self.messageSeconds) }
        return .failed(message)
    }
}
