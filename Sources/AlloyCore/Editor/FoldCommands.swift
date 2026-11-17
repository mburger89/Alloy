import Foundation
import MetalUICodeBuffer

/// A fold command: Fold, Unfold, Fold All, Unfold All. MetalUI's `CodeFoldState` does the work; Alloy picks the
/// focused view's state and the caret lines.
public enum FoldCommand: Sendable {
    case fold, unfold, foldAll, unfoldAll
}

extension Workspace {
    /// The focused pane's fold state when it has an active tab with an open document.
    private func foldCommandState() -> (state: CodeFoldState, selection: CodeSelectionState)? {
        let pane = defaultPane
        guard let path = activeTab(in: pane), document(path) != nil,
              let selection = selectionState(for: path, in: pane),
              let state = foldState(for: path, in: pane) else { return nil }
        return (state, selection)
    }

    /// Whether the fold commands apply: the focused pane shows a document as code. An action's predicate: never
    /// call it from a view body.
    public func canRunFold() -> Bool { foldCommandState() != nil }

    /// Runs `command` on the focused view's folds. False when disabled; true otherwise, even when nothing changed.
    @discardableResult
    public func runFold(_ command: FoldCommand) -> Bool {
        guard let (state, selection) = foldCommandState() else { return false }
        let before = state.folded
        switch command {
        case .fold:
            let lines = caretLines(selection)
            let ranges = state.foldableRanges
            // Every caret picks against the same snapshot, so two carets in one range fold only that range.
            let folded = state.folded
            var targets: [Range<Int>] = []
            for line in lines {
                let target = ranges.filter { $0.contains(line) && !folded.contains($0) }.max { $0.lowerBound < $1.lowerBound }
                if let target, !targets.contains(target) { targets.append(target) }
            }
            for target in targets { state.fold(target) }
        case .unfold:
            for line in caretLines(selection) {
                let starting = state.folded.filter { $0.lowerBound == line }
                if let outer = starting.max(by: { $0.count < $1.count }) { state.unfold(outer) }
                else { state.unfold(containing: line) }
            }
        case .foldAll:
            state.folded = state.foldableRanges
        case .unfoldAll:
            state.unfoldAll()
        }
        if state.folded != before { noteFoldsChanged() }
        return true
    }

    /// The distinct lines the carets (heads) sit on, ascending.
    private func caretLines(_ selection: CodeSelectionState) -> [Int] {
        let snapshot = selection.buffer.snapshot()
        return Array(Set(selection.selections.map { snapshot.point(at: $0.head).row })).sorted()
    }
}
