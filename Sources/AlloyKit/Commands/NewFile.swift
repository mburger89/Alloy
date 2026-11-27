import AlloyCore
import Foundation

extension CommandCenter {
    /// The first save of an Untitled tab: asks where (the project folder, named "Untitled"), writes the text, and turns the
    /// tab into that file in place (see `Workspace.saveUntitled`). A file outside the project opens the way Open… does.
    /// Returns false when the dialog was cancelled or the write failed (the tab is untouched), true once it is saved.
    @discardableResult
    func saveUntitledTab(_ key: String, in workspace: Workspace) async -> Bool {
        guard workspace.isUntitled(key), let pane = workspace.paneHolding(key) else { return false }
        guard let target = await chooseSaveURL("Untitled", workspace.projectRoot) else { return false }
        // The dialog is async: the tab may have gone meanwhile (closed, or dropped by another answer).
        guard workspace.isUntitled(key), let pane = workspace.paneHolding(key) ?? Optional(pane) else { return false }
        do {
            if let outside = try await workspace.saveUntitled(key, to: target, in: pane) { openOutsideProject(outside) }
            return true
        } catch {
            return false
        }
    }

    /// ⌘N: a new Untitled tab in the focused code group; Chat mode switches to the code view first, as Open… does.
    func newFile(in workspace: Workspace) {
        if workspace.mode != .code { workspace.setMode(.code) }
        workspace.newUntitled(in: workspace.defaultPane)
    }
}
