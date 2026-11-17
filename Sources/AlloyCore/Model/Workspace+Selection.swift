import Foundation
import MetalUICodeBuffer

/// Per-pane carets and selections. A pane holding a file owns a `CodeSelectionState` over the file's buffer, so two
/// views of one file each keep their own caret. A state lives while its pane's tab list holds the path.
extension Workspace {
    /// The selection state `pane` uses for `path`; nil when the pane does not hold the path or it has no document.
    /// Created on a pane's first hold (and here, if the document arrived after the tab).
    public func selectionState(for path: String, in pane: PaneID) -> CodeSelectionState? {
        guard let doc = documents[path], tabs(in: pane).contains(path) else { return nil }
        if let existing = paneSelections[pane]?[path], existing.buffer === doc.buffer { return existing }
        return makeSelectionState(for: doc, in: pane, copying: nil)
    }

    /// Panes from most to least recently focused: the pane showing now, then earlier focus moves.
    private func panesByRecency() -> [PaneID] {
        var order = [defaultPane]
        for pane in paneFocusLog where !order.contains(pane) { order.append(pane) }
        return order
    }

    /// Creates `pane`'s state for `doc`, selecting `copying` or, when nil, what the most recently focused other pane
    /// selects, or else the buffer's default state.
    @discardableResult
    func makeSelectionState(for doc: EditorDocument, in pane: PaneID, copying: [CodeSelection]?) -> CodeSelectionState {
        var seed = copying
        if seed == nil {
            for other in panesByRecency() where other != pane {
                if let s = paneSelections[other]?[doc.path], s.buffer === doc.buffer { seed = s.selections; break }
            }
        }
        let state = CodeSelectionState(buffer: doc.buffer, selections: seed ?? doc.buffer.selectionState.selections)
        paneSelections[pane, default: [:]][doc.path] = state
        paneFolds[pane, default: [:]][doc.path] = CodeFoldState(selectionState: state)
        applyPendingFolds(path: doc.path, in: pane)
        return state
    }

    /// Gives `pane` a state for `path` when it holds the path and the document exists.
    func ensureSelectionState(_ path: String, in pane: PaneID) {
        _ = selectionState(for: path, in: pane)
    }

    /// The document `path` just arrived: every pane holding it gets a state.
    func ensureSelectionStates(forInstalled path: String) {
        if tabs.contains(path) { ensureSelectionState(path, in: .chat) }
        for id in codeLayout.groups.keys where codeLayout.groups[id]?.tabs.contains(path) == true {
            ensureSelectionState(path, in: .group(id))
        }
    }

    func dropSelectionState(_ path: String, from pane: PaneID) {
        paneFolds[pane]?.removeValue(forKey: path)
        if pendingFolds[pane]?.removeValue(forKey: path) != nil, pendingFolds[pane]?.isEmpty == true {
            pendingFolds.removeValue(forKey: pane)
        }
        if paneSelections[pane]?[path] != nil { paneSelections[pane]?.removeValue(forKey: path); selectionRevision += 1 }
    }

    func dropSelectionStates(of pane: PaneID) {
        paneFolds.removeValue(forKey: pane)
        pendingFolds.removeValue(forKey: pane)
        if paneSelections.removeValue(forKey: pane) != nil { selectionRevision += 1 }
        paneFocusLog.removeAll { $0 == pane }
    }

    /// Records that `pane` took focus (a group focus move, a Chat code view gaining focus, a mode switch).
    func noteFocus(_ pane: PaneID) {
        guard paneFocusLog.first != pane else { return }
        paneFocusLog.removeAll { $0 == pane }
        paneFocusLog.insert(pane, at: 0)
    }
}
