import AlloyCore
import AlloyPlugins
import Foundation

/// Plugin decorations: the host hands over each plugin's newest set per document, the store keeps it and the open views paint it.
extension PluginCoordinator {
    /// Listens for the workspace's document events: a closed document loses its plugin decorations.
    func installDocumentEvents(on workspace: Workspace) {
        workspace.onDocumentEvent = { [weak self] event in
            guard let self else { return }
            if case .closed(let path) = event {
                self.decorations.remove(path: path)
                if let uri = self.documentURI(path) { self.forgetDecorations(uri: uri) }
            }
            self.forwardDocumentEvent(event)
        }
    }

    /// The project-relative path a file URI names, or nil for a URI outside the project.
    func relativePath(forURI uri: String) -> String? {
        guard let root = workspace?.projectRoot, let url = URL(string: uri), url.isFileURL else { return nil }
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    /// A `decorations/set` of a running plugin. A URI that is not an open document is dropped, never buffered.
    func applyDecorations(id: String, uri: String, set: PluginDecorationSet) {
        guard isActive(id) else { return }
        guard let workspace, let path = relativePath(forURI: uri), workspace.document(path) != nil else {
            forgetDecorations(plugin: id, uri: uri)   // what the host remembered of it would grow without bound
            return
        }
        decorations.set(id, path: path, set)
    }
}
