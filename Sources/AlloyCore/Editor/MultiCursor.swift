import Foundation
import MetalUICodeBuffer
import Observation

/// A multi-cursor command. MetalUI's `CodeSelectionState` helpers do the work; Alloy only picks the focused view's
/// state and reports the cursor cap.
public enum MultiCursorCommand: Sendable {
    case addNextOccurrence, selectAllOccurrences, skipToNextOccurrence, addCaretAbove, addCaretBelow
}

extension Workspace {
    static let capNoticeText = "Stopped at 10,000 cursors"

    /// The focused pane's selection state when it has an active tab with an open document.
    private func multiCursorState() -> (path: String, pane: PaneID, state: CodeSelectionState)? {
        let pane = defaultPane
        guard let path = activeTab(in: pane), document(path) != nil,
              let state = selectionState(for: path, in: pane) else { return nil }
        return (path, pane, state)
    }

    /// Whether the multi-cursor commands apply: the focused pane shows a document as code. Read-only documents
    /// count, since carets and selections do not edit. An action's predicate: never call it from a view body.
    public func canRunMultiCursor() -> Bool { multiCursorState() != nil }

    /// Runs `command` on the focused view's selections. False when disabled. Past `limit` selections the first
    /// `limit` are kept and a warning notice shows in that pane's group until its selection changes.
    @discardableResult
    public func runMultiCursor(_ command: MultiCursorCommand, limit: Int = CodeSelectionState.selectionLimit) -> Bool {
        guard let (path, pane, state) = multiCursorState() else { return false }
        clearCapNotice(in: pane)
        let ok: Bool
        switch command {
        case .addNextOccurrence: ok = state.addNextOccurrence(limit: limit)
        case .selectAllOccurrences: ok = state.selectAllOccurrences(limit: limit)
        case .skipToNextOccurrence: ok = state.skipToNextOccurrence()
        case .addCaretAbove: ok = state.addCaret(lineDelta: -1, limit: limit)
        case .addCaretBelow: ok = state.addCaret(lineDelta: 1, limit: limit)
        }
        if !ok { postCapNotice(path: path, pane: pane, state: state) }
        return true
    }

    private func clearCapNotice(in pane: PaneID) {
        guard let entry = capNotices.removeValue(forKey: pane) else { return }
        dismiss(entry.notice)
    }

    /// Posts the notice, then watches the state once: its next selection change removes the notice. Armed only
    /// after the write that hit the cap, so that write does not clear it, and only when the cap was hit.
    private func postCapNotice(path: String, pane: PaneID, state: CodeSelectionState) {
        let notice = Notice(path: path, kind: .warning, text: Self.capNoticeText)
        notify(path: path, kind: .warning, text: Self.capNoticeText)
        let token = UUID()
        capNotices[pane] = (token, notice)
        withObservationTracking {
            _ = state.selections
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.capNotices[pane]?.token == token else { return }
                self.clearCapNotice(in: pane)
            }
        }
    }
}
