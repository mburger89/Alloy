import Foundation
import MetalUICodeBuffer

/// Per-pane fold state. A pane holding a file owns a `CodeFoldState` next to its `CodeSelectionState`, made and
/// dropped with it (see Workspace+Selection.swift). The workspace is the strong owner; MetalUI holds them weakly.
extension Workspace {
    /// The fold state `pane` uses for `path`; nil exactly when `selectionState(for:in:)` is nil.
    public func foldState(for path: String, in pane: PaneID) -> CodeFoldState? {
        guard let selection = selectionState(for: path, in: pane) else { return nil }
        if let existing = paneFolds[pane]?[path], existing.selectionState === selection { return existing }
        let state = CodeFoldState(selectionState: selection)
        paneFolds[pane, default: [:]][path] = state
        return state
    }

    /// Every pane's fold state for `path`.
    func foldStates(for path: String) -> [(pane: PaneID, state: CodeFoldState)] {
        paneFolds.compactMap { pane, byPath in byPath[path].map { (pane, $0) } }
    }

    /// Folds changed in a way the views do not report: the next write snapshots them.
    public func noteFoldsChanged() { scheduleUIStateWrite() }
}

// MARK: Ranges, source switch, saved folds

extension Workspace {
    /// The most folds kept per (pane, path), in memory and on disk.
    static let foldCap = 2000

    static func paneKey(_ pane: PaneID) -> String {
        switch pane {
        case .chat: return "chat"
        case .group(let id): return id.uuidString
        }
    }

    /// Hands `choice`, computed against buffer version `version`, to every pane's fold state for `path`.
    public func applyFoldRanges(path: String, choice: FoldChoice, version: UInt64) {
        let previous = latestFold[path]?.choice.source
        let ranges = choice.ranges.map { $0.startLine..<($0.endLine + 1) }
        let switched = previous != nil && previous != choice.source
        let states = foldStates(for: path)
        var accepted = states.isEmpty
        for (_, state) in states {
            // A refused call (the edit log no longer reaches `version`) leaves that state unchanged.
            guard state.setFoldableRanges(ranges, asOf: version) else { continue }
            accepted = true
            if switched { rewriteFolds(of: state, to: choice.ranges) }
        }
        if accepted { latestFold[path] = (choice, version) }
        for pane in paneFolds.keys { applyPendingFolds(path: path, in: pane) }
    }

    /// A source switch keeps a fold only where a new range starts on the same line; its end becomes that range's end.
    private func rewriteFolds(of state: CodeFoldState, to ranges: [FoldRange]) {
        let byStart = Dictionary(ranges.map { ($0.startLine, $0.endLine) }, uniquingKeysWith: max)
        let kept = state.folded.compactMap { fold in byStart[fold.lowerBound].map { fold.lowerBound..<($0 + 1) } }
        state.folded = kept
    }

    /// Applies the folds restored for (`pane`, `path`) once ranges for the buffer's current version exist.
    func applyPendingFolds(path: String, in pane: PaneID) {
        guard let saved = pendingFolds[pane]?[path], let latest = latestFold[path],
              let state = paneFolds[pane]?[path], let doc = documents[path],
              latest.version == doc.buffer.version else { return }
        let lineCount = doc.buffer.snapshot().lineCount
        let byStart = Dictionary(latest.choice.ranges.map { ($0.startLine, $0.endLine) }, uniquingKeysWith: max)
        let kept = saved.compactMap { fold -> Range<Int>? in
            guard fold.end < lineCount, let end = byStart[fold.start] else { return nil }
            return fold.start..<(end + 1)
        }
        // Merge into folds the user made meanwhile instead of overwriting them.
        var merged = state.folded
        for fold in kept where !merged.contains(fold) { merged.append(fold) }
        state.folded = merged
        pendingFolds[pane]?.removeValue(forKey: path)
        if pendingFolds[pane]?.isEmpty == true { pendingFolds.removeValue(forKey: pane) }
    }

    /// The folds to save, by pane key then path.
    func foldSnapshot() -> [String: [String: [FoldLines]]] {
        var out: [String: [String: [FoldLines]]] = [:]
        func put(_ pane: PaneID, _ path: String, _ folds: [FoldLines]) {
            guard !folds.isEmpty, untitledNumbers[path] == nil else { return }
            out[Self.paneKey(pane), default: [:]][path] = Array(folds.prefix(Self.foldCap))
        }
        for (pane, byPath) in paneFolds {
            for (path, state) in byPath {
                var lines = state.folded.map(FoldLines.init)
                for fold in pendingFolds[pane]?[path] ?? [] where !lines.contains(fold) { lines.append(fold) }
                put(pane, path, lines)
            }
        }
        for (pane, byPath) in pendingFolds {
            for (path, folds) in byPath where paneFolds[pane]?[path] == nil { put(pane, path, folds) }
        }
        return out
    }

    /// A save wrote `path`: folds sit in the saved state beside the text, so write it, but only when some fold exists.
    func noteFoldsSaved(path: String) {
        if foldStates(for: path).contains(where: { !$0.state.folded.isEmpty }) { scheduleUIStateWrite() }
    }

    /// Keeps the saved folds of panes and paths that still exist as pending until their ranges arrive.
    func restoreFolds(_ saved: [String: [String: [FoldLines]]]) {
        pendingFolds.removeAll()
        for (key, byPath) in saved {
            let pane: PaneID
            if key == "chat" { pane = .chat }
            else if let id = UUID(uuidString: key), codeLayout.groups[id] != nil { pane = .group(id) }
            else { continue }
            let held = Set(tabs(in: pane))
            for (path, folds) in byPath where held.contains(path) && !folds.isEmpty {
                pendingFolds[pane, default: [:]][path] = Array(folds.prefix(Self.foldCap))
            }
        }
        // A document already loaded has its ranges only if they were applied; try now for any that were.
        for (pane, byPath) in pendingFolds { for path in byPath.keys { applyPendingFolds(path: path, in: pane) } }
    }
}
