import AlloyCore
import AlloyLSP
import Foundation
import MetalUICodeBuffer

/// Format document, format selection and format on save: asks the server that formats a file (see `FormatterChoice`)
/// and applies its edits through the ``WorkspaceEditApplier``. Nothing here runs until a command or a deliberate save
/// asks, so an idle editor costs nothing.
@MainActor
package final class FormatService {
    private let workspace: Workspace
    private let coordinator: LSPCoordinator
    private let applier: WorkspaceEditApplier
    var saveTimeout: Duration
    var explicitTimeout: Duration
    /// The view of a path's document in the focused pane (or any pane), for its text services and messages.
    var viewFor: (@MainActor (String) -> OpenDocumentView?)?
    /// Paths whose "format on save skipped" message was shown this session.
    private var reported: Set<String> = []

    init(workspace: Workspace, coordinator: LSPCoordinator, applier: WorkspaceEditApplier,
         saveTimeout: Duration = .milliseconds(750), explicitTimeout: Duration = .seconds(10)) {
        self.workspace = workspace
        self.coordinator = coordinator
        self.applier = applier
        self.saveTimeout = saveTimeout
        self.explicitTimeout = explicitTimeout
    }

    private static let messageSeconds = 2.0

    // MARK: Commands

    func formatDocument(view: OpenDocumentView) async { await runExplicit(view: view, selectionOnly: false) }

    func formatSelection(view: OpenDocumentView) async { await runExplicit(view: view, selectionOnly: true) }

    private func runExplicit(view: OpenDocumentView, selectionOnly: Bool) async {
        let feature = selectionOnly ? view.features.rangeFormatting : view.features.formatting
        guard feature, view.document.state == .editable, view.services.lspOpen, !view.closed else { return }
        let path = view.document.path
        for attempt in 0..<2 {
            view.services.drainEdits()
            let snapshot = view.document.buffer.snapshot()
            var range: Range<Int>?
            if selectionOnly {
                // One selection only: formatting the primary of several would silently skip the rest.
                let selections = view.selection(in: workspace).selections
                guard selections.count == 1, !selections[0].isEmpty else { return }
                let primary = selections[0].range
                range = min(primary.lowerBound, snapshot.utf8Count)..<min(primary.upperBound, snapshot.utf8Count)
            }
            guard let choice = await coordinator.formatChoice(path: path, formatters: workspace.settings.formatters,
                                                              rangeOnly: selectionOnly) else { return }
            let outcome = await coordinator.format(path: path, snapshot: snapshot, range: range, serverID: choice.serverID,
                                                   timeout: explicitTimeout)
            guard !view.closed else { return }
            switch outcome {
            case .answered(let edits):
                await apply(edits, snapshot: snapshot, path: path, view: view)
                return
            case .stale where attempt == 0: continue
            case .stale: view.flash("Server busy, try again", seconds: Self.messageSeconds)
            case .timedOut: view.flash("Format timed out", seconds: Self.messageSeconds)
            case .failed(let message): view.flash("Format failed: \(message)", seconds: Self.messageSeconds)
            case .unavailable: break
            }
            return
        }
    }

    private func apply(_ edits: [ByteEdit], snapshot: CodeSnapshot, path: String, view: OpenDocumentView) async {
        guard !edits.isEmpty else {
            view.flash("Already formatted", seconds: Self.messageSeconds)
            return
        }
        let result = await applier.apply([FileEdits(path: path, version: nil, edits: edits)],
                                         baseVersions: [path: snapshot.version], label: "Format", saveOpenFiles: false)
        if let message = result.message { view.flash(message, seconds: Self.messageSeconds) }
    }

    // MARK: Format on save

    /// Runs before a deliberate save writes. Never throws and never blocks the save for longer than `saveTimeout`: on a
    /// timeout, a missing server, an error, or a buffer that moved while waiting, the file is saved as it is.
    func formatForSave(_ doc: EditorDocument) async {
        guard doc.state == .editable, let view = viewFor?(doc.path), !view.closed, view.features.formatting,
              view.services.lspOpen else { return }
        let path = doc.path
        view.services.drainEdits()
        let snapshot = doc.buffer.snapshot()
        guard let choice = await coordinator.formatChoice(path: path, formatters: workspace.settings.formatters, rangeOnly: false),
              workspace.settings.languageServers[choice.serverID]?.formatOnSave == true else { return }
        let outcome = await bounded { [coordinator, saveTimeout] in
            await coordinator.format(path: path, snapshot: snapshot, range: nil, serverID: choice.serverID, timeout: saveTimeout)
        }
        switch outcome {
        case .answered(let edits):
            guard !edits.isEmpty else { return }
            guard doc.buffer.version == snapshot.version else {
                skipped(path, "the file changed while formatting", view: view)
                return
            }
            let result = await applier.apply([FileEdits(path: path, version: nil, edits: edits)],
                                             baseVersions: [path: snapshot.version], label: "Format", saveOpenFiles: false)
            if result.message != nil { skipped(path, "the file changed while formatting", view: view) }
        case .timedOut: skipped(path, "the server took too long", view: view)
        case .stale: skipped(path, "the file changed while formatting", view: view)
        case .failed(let message): skipped(path, message, view: view)
        case .unavailable: skipped(path, "no answer from the server", view: view)
        }
    }

    /// Runs `work` and abandons it (cancelling the request on the server) after `saveTimeout`.
    private func bounded(_ work: @escaping @MainActor () async -> LSPOutcome<[ByteEdit]>) async -> LSPOutcome<[ByteEdit]> {
        let task = Task { @MainActor in await work() }
        let fired = Flag()
        let timer = Task { @MainActor [saveTimeout] in
            try? await Task.sleep(for: saveTimeout)
            guard !Task.isCancelled else { return }
            fired.value = true
            task.cancel()
        }
        let outcome = await task.value
        timer.cancel()
        if fired.value, case .unavailable = outcome { return .timedOut }
        return outcome
    }

    private final class Flag { var value = false }

    private func skipped(_ path: String, _ reason: String, view: OpenDocumentView) {
        guard reported.insert(path).inserted else { return }
        view.flash("Format on save skipped: \(reason)", seconds: Self.messageSeconds)
    }
}
