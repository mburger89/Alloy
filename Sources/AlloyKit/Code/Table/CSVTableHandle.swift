import AlloyCore
import Observation

/// A table model and its feed: a one-shot observation of the buffer's version that drains the model's edit cursor.
/// No timer and no per-frame polling; it fires only when the buffer changes.
@MainActor
final class CSVTableHandle {
    let model: CSVTableModel
    private var closed = false

    private weak var workspace: Workspace?

    private let pane: PaneID

    init(document: EditorDocument, workspace: Workspace, pane: PaneID) {
        model = CSVTableModel(document: document)
        self.workspace = workspace
        self.pane = pane
        let path = document.path
        model.ledgerProvider = { [weak workspace] in (workspace?.ledger.files[path], workspace?.sessions ?? []) }
        model.ownTintEnabled = workspace.settings.ownEditTint.enabled
        model.ledgerChanged()
        observe()
        observeSaved()
        observeOwnTint()
        observeLedger()
        takeReveal()
        observeReveal()
    }

    /// Takes a reveal this pane asked for: the model selects and scrolls to its row, waiting for the index if building.
    private func takeReveal() {
        guard let workspace, let reveal = workspace.tableReveal[model.document.path], reveal.pane == pane else { return }
        workspace.tableReveal[model.document.path] = nil
        model.reveal(byteOffset: reveal.offset, column: reveal.column)
    }

    private func observeReveal() {
        guard !closed, let workspace else { return }
        let path = model.document.path
        withObservationTracking {
            _ = workspace.tableReveal[path]
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.takeReveal()
                self.observeReveal()
            }
        }
    }

    /// One-shot observation of this file's ledger version: when a session, an outside change or Keep changes it, the
    /// model rebuilds who-changed-what off the main actor. Nothing runs while the ledger is still.
    private func observeLedger() {
        guard !closed, let workspace else { return }
        let path = model.document.path
        withObservationTracking {
            _ = workspace.ledger.files[path]?.version
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.model.ledgerChanged()
                self.observeLedger()
            }
        }
    }

    /// A save or a refresh from disk moved the saved text: the own-edit tint clears or diffs again.
    private func observeSaved() {
        guard !closed else { return }
        let document = model.document
        withObservationTracking {
            _ = document.savedVersion
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.model.savedTextChanged()
                self.observeSaved()
            }
        }
    }

    /// The setting: the toggle starts or stops the tint; a colour change redraws the table.
    private func observeOwnTint() {
        guard !closed, let workspace else { return }
        withObservationTracking {
            _ = workspace.settings.ownEditTint
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed, let workspace = self.workspace else { return }
                let tint = workspace.settings.ownEditTint
                if self.model.ownTintEnabled != tint.enabled { self.model.ownTintEnabled = tint.enabled } else if tint.enabled { self.model.redraw() }
                self.observeOwnTint()
            }
        }
    }

    private func observe() {
        guard !closed else { return }
        let document = model.document
        withObservationTracking {
            _ = document.buffer.version
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.model.sync()
                self.observe()
            }
        }
    }

    func close() {
        closed = true
        model.close()
    }
}
