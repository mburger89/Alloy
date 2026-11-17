import AlloyCore
import MetalUI

/// What the Git commands (registered in `BuiltinCommands`) do and when they are available. The registry entries call
/// these and nothing else, so they hold no logic of their own.
extension GitCoordinator {
    /// The active document of the focused Code group and its view, when Code mode shows one.
    var activeEditorView: OpenDocumentView? {
        guard let host, host.mode == .code else { return nil }
        let pane = host.defaultPane
        guard let path = host.activeTab(in: pane), let document = host.document(path) else { return nil }
        return CodePanelStore.existingView(for: document, in: pane)
    }

    private var activePath: String? {
        guard let host, host.mode == .code else { return nil }
        return host.activeTab(in: host.defaultPane)
    }

    /// Git works here: a repository was found and the git executable is usable.
    var repoReady: Bool { panel.state == .ready }
    /// An editor item is available: a repository, Code mode and an open file.
    var editorItemsReady: Bool { repoReady && activePath != nil }

    func compareActiveWithHead() {
        guard let host, let path = activePath else { return }
        openCompare(path: path, against: .head, in: host.defaultPane)
    }

    func stageActiveFile() {
        guard let path = activePath else { return }
        let entry = (panel.changes + panel.untracked + panel.conflicts).first { $0.path == path }
        if let entry { stage(entry) }
    }

    func unstageActiveFile() {
        guard let path = activePath, let entry = panel.staged.first(where: { $0.path == path }) else { return }
        unstage(entry)
    }

    /// Git > Commit…: shows the Git tab and puts the caret in the message.
    func showCommit() {
        sidebar.tab = .git
        sidebar.focusRequest += 1
    }

    func blameActiveLine() {
        if let view = activeEditorView { blameLine(in: view) }
    }

    func toggleActiveFileBlame() {
        if let view = activeEditorView { toggleFileBlame(in: view) }
    }

    func stepActiveChange(_ direction: Int) {
        if let view = activeEditorView { nextChange(in: view, direction: direction) }
    }
}
