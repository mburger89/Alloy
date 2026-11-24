/// What happened to an open document, as the workspace reports it (`Workspace.onDocumentEvent`). `version` is the buffer
/// version after the open or the save; paths are project-relative.
public enum DocumentEvent: Sendable, Equatable {
    case opened(path: String, version: Int)
    case saved(path: String, version: Int)
    case closed(path: String)
}
