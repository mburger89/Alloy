import AlloyCore
import AlloyLSP
import Foundation
import MetalUICodeBuffer

/// The identifier run touching a caret, for a server that offers rename without `prepareRename`.
enum RenameWord {
    private static func isIdentifier(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x5F || b >= 0x80
    }

    /// The identifier bytes touching `offset`, preferring the word that ends at the caret; nil when there is none.
    static func range(in snapshot: CodeSnapshot, at offset: Int) -> Range<Int>? {
        let count = snapshot.utf8Count
        let at = min(max(0, offset), count)
        var start = at
        while start > 0, isIdentifier(snapshot.byte(at: start - 1)) { start -= 1 }
        var end = at
        while end < count, isIdentifier(snapshot.byte(at: end)) { end += 1 }
        return start < end ? start..<end : nil
    }
}

/// The symbol a rename will change.
struct RenameTarget: Equatable {
    var range: Range<Int>
    var oldName: String
    var snapshotVersion: UInt64
    var offset: Int
}

enum RenamePrepared: Equatable {
    case target(RenameTarget)
    case refused(String)
}

struct RenameRow: Equatable {
    var path: String
    var edits: Int
}

struct RenameResult: Equatable {
    var group: UUID
    var rows: [RenameRow]
    var message: String?
}

/// Rename Symbol: asks the server what can be renamed (`prepareRename`), then for the edit, and applies it all or
/// nothing through the ``WorkspaceEditApplier``. Nothing here runs until a caller asks, so an idle editor pays nothing.
@MainActor
final class RenameService {
    private let workspace: Workspace
    private let coordinator: LSPCoordinator
    private let applier: WorkspaceEditApplier
    var timeout: Duration

    static let staleMessage = "File changed, rename not applied"

    init(workspace: Workspace, coordinator: LSPCoordinator, applier: WorkspaceEditApplier, timeout: Duration = .seconds(10)) {
        self.workspace = workspace
        self.coordinator = coordinator
        self.applier = applier
        self.timeout = timeout
    }

    private func eligible(_ view: OpenDocumentView) -> Bool {
        !view.closed && view.document.state == .editable && view.services.lspOpen && view.features.rename
            && workspace.presentation(of: view.document.path, in: view.pane) != .sideBySide
    }

    // MARK: Prepare

    func prepare(view: OpenDocumentView) async -> RenamePrepared {
        guard eligible(view) else { return .refused("Rename is not available here") }
        view.services.drainEdits()
        let snapshot = view.document.buffer.snapshot()
        let path = view.document.path
        let offset = min(view.selection(in: workspace).primarySelection.head, snapshot.utf8Count)
        var range: Range<Int>?
        if view.features.renamePrepare {
            let outcome = await bounded { [coordinator] in
                await coordinator.prepareRename(path: path, utf8Offset: offset, snapshot: snapshot)
            }
            guard !view.closed, view.document.buffer.version == snapshot.version,
                  workspace.activeTab(in: view.pane) == path else { return .refused(Self.staleMessage) }
            switch outcome {
            case .answered(let info?):
                if let r = info.range { range = min(r.lowerBound, snapshot.utf8Count)..<min(r.upperBound, snapshot.utf8Count) }
            case .answered(nil): return .refused("Cannot rename this symbol")
            case .failed(let message): return .refused(message.isEmpty ? "Cannot rename this symbol" : message)
            case .timedOut: return .refused("Rename timed out")
            case .stale: return .refused("Server busy, try again")
            case .unavailable: return .refused("Rename is not available here")
            }
        }
        guard let found = range ?? RenameWord.range(in: snapshot, at: offset) else { return .refused("No symbol at the caret") }
        let name = String(decoding: snapshot.utf8(in: found), as: UTF8.self)
        return .target(RenameTarget(range: found, oldName: name, snapshotVersion: snapshot.version, offset: offset))
    }

    // MARK: Commit

    func commit(_ target: RenameTarget, newName: String, view: OpenDocumentView) async -> RenameResult {
        let group = UUID()
        func fail(_ message: String) -> RenameResult { RenameResult(group: group, rows: [], message: message) }
        guard eligible(view) else { return fail("Rename is not available here") }
        let path = view.document.path
        view.services.drainEdits()
        guard view.document.buffer.version == target.snapshotVersion else { return fail(Self.staleMessage) }
        let snapshot = view.document.buffer.snapshot()
        let offset = min(target.offset, snapshot.utf8Count)
        let outcome = await bounded { [coordinator] in
            await coordinator.rename(path: path, utf8Offset: offset, newName: newName, snapshot: snapshot)
        }
        guard !view.closed, view.document.buffer.version == snapshot.version,
              workspace.activeTab(in: view.pane) == path else { return fail(Self.staleMessage) }
        let answer: RenameAnswer
        switch outcome {
        case .answered(let a?): answer = a
        case .answered(nil): return fail("Nothing to rename")
        case .stale: return fail(Self.staleMessage)
        case .timedOut: return fail("Rename timed out")
        case .failed(let message): return fail(message)
        case .unavailable: return fail("Rename is not available here")
        }
        let files: [FileEdits]
        do {
            files = try WorkspaceEditParsing.normalize(answer.edit, root: workspace.projectRoot, encoding: answer.encoding) { [workspace] p in
                if let doc = workspace.document(p) { return doc.buffer.snapshot() }
                guard let data = try? Data(contentsOf: workspace.projectRoot.appendingPathComponent(p)) else { return nil }
                return CodeBuffer(utf8: [UInt8](data)).snapshot()
            }
        } catch {
            return fail(error.message)
        }
        var bases: [String: UInt64] = [path: snapshot.version]
        for file in files where bases[file.path] == nil {
            if let doc = workspace.document(file.path) { bases[file.path] = doc.buffer.version }
        }
        let applied = await applier.apply(files, baseVersions: bases, label: "rename", saveOpenFiles: true)
        // The partial-failure message starts a sentence.
        let message = applied.failed.isEmpty ? applied.message : applied.message.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return RenameResult(group: applied.group, rows: rows(files, applied: applied), message: message)
    }

    private func rows(_ files: [FileEdits], applied: WorkspaceEditApplier.ApplyOutcome) -> [RenameRow] {
        files.compactMap { file in
            guard applied.applied.contains(file.path), workspace.hasEdit(group: applied.group, path: file.path) else { return nil }
            return RenameRow(path: file.path, edits: file.edits.count)
        }
    }

    // MARK: Timeout

    private final class Flag { var value = false }

    /// Runs `work` and abandons it (cancelling the request on the server) after `timeout`.
    private func bounded<T: Sendable>(_ work: @escaping @MainActor () async -> LSPOutcome<T>) async -> LSPOutcome<T> {
        let task = Task { @MainActor in await work() }
        let fired = Flag()
        let timer = Task { @MainActor [timeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            fired.value = true
            task.cancel()
        }
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        timer.cancel()
        if fired.value, case .unavailable = outcome { return .timedOut }
        return outcome
    }
}
