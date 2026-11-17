import AlloyCore
import Foundation
import MetalUI
import MetalUICodeBuffer

/// The footer of a git compare: which hunk is focused, next and previous, Stage, Unstage and Revert for it, and the
/// switch between comparing with HEAD and with the index. It replaces the ledger's edit bar for a git source.
struct GitHunkBar: Component {
    let view: OpenDocumentView
    let workspace: Workspace

    var content: some ElementGroup {
        let view = view
        let compare = view.compare
        let count = compare?.hunks.count ?? 0
        let against = view.currentPresentation == .compareIndex ? "Index" : "HEAD"
        VStack(alignment: .leading, spacing: Pixels(4)) {
            HStack(spacing: Pixels(8)) {
                Text(verbatim: Self.counter(focus: view.compareFocus, count: count)).font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("git-hunk-counter")
                Button("\u{2191}") { view.stepCompare(-1) }.accessibilityIdentifier("git-hunk-prev")
                Button("\u{2193}") { view.stepCompare(1) }.accessibilityIdentifier("git-hunk-next")
                Button("Stage") { view.compareStage() }.accessibilityIdentifier("git-hunk-stage")
                Button("Unstage") { view.compareUnstage() }.accessibilityIdentifier("git-hunk-unstage")
                Button("Revert") { view.compareRevert(confirmed: false) }.accessibilityIdentifier("git-hunk-revert")
                Spacer()
                Button("Against: \(against)") { view.toggleCompareBase() }.accessibilityIdentifier("git-compare-against")
            }
            if view.compareConfirmRevert {
                HStack(spacing: Pixels(8)) {
                    Text(verbatim: "This also reverts Claude\u{2019}s unreviewed change").font(size: 11)
                        .accessibilityIdentifier("git-hunk-revert-warning")
                    Button("Revert anyway") { view.compareRevert(confirmed: true) }.accessibilityIdentifier("git-hunk-revert-confirm")
                    Button("Cancel") { view.compareConfirmRevert = false }.accessibilityIdentifier("git-hunk-revert-cancel")
                }
            }
            if let message = view.compareMessage {
                Text(verbatim: message).font(size: 11).foregroundColor(.errorInk).accessibilityIdentifier("git-hunk-message")
            }
        }
        .padding(inset(12, 6))
        .background(.panelFill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-hunk-bar")
    }

    static func counter(focus: Int, count: Int) -> String {
        count == 0 ? "No changes" : "\(min(max(0, focus), count - 1) + 1) of \(count)"
    }
}

extension OpenDocumentView {
    /// The compare hunk the bar acts on, if there is one.
    private var focusedCompareIndex: Int? {
        guard let compare, !compare.hunks.isEmpty else { return nil }
        return min(max(0, compareFocus), compare.hunks.count - 1)
    }

    /// A press on a bar of either pane: focuses that hunk.
    func focusCompareHunk(tag: UInt64?) {
        guard let tag, let index = compareTags[tag] else { return }
        compareFocus = index
        compareMessage = nil; compareConfirmRevert = false
    }

    /// Focuses the next (`direction` > 0) or previous hunk, wrapping, and moves the caret to its first change.
    func stepCompare(_ direction: Int) {
        guard let compare, !compare.hunks.isEmpty, let current = focusedCompareIndex else { return }
        let count = compare.hunks.count
        compareFocus = ((current + (direction >= 0 ? 1 : -1)) % count + count) % count
        compareMessage = nil; compareConfirmRevert = false
        guard let part = compare.parts[compareFocus].first else { return }
        let snapshot = document.buffer.snapshot()
        let at = snapshot.lineRange(max(0, min(part.markRow, snapshot.lineCount - 1))).lowerBound
        selection().select(at..<at, reveal: true)
    }

    func compareStage() {
        runCompare { marks, compare, parts in
            await marks.stage(parts: parts, headBase: compare.base == .head ? compare.baseText : nil)
        }
    }

    func compareUnstage() {
        runCompare { marks, compare, parts in
            await marks.unstage(parts: parts, headBase: compare.base == .head ? compare.baseText : nil)
        }
    }

    /// Reverts the focused hunk to the compared text, after asking when Claude's unreviewed change is in it.
    func compareRevert(confirmed: Bool) {
        guard !compareBusy, let marks = gitMarks, let compare, let index = focusedCompareIndex else { return }
        compareBusy = true; compareMessage = nil
        let parts = compare.parts[index]
        Task { @MainActor in
            let outcome = await marks.revert(parts: parts, base: compare.baseText, confirmed: confirmed)
            compareBusy = false
            switch outcome {
            case .reverted: compareConfirmRevert = false; compareBaseChanged()
            case .needsConfirmation: compareConfirmRevert = true
            case .stale: compareConfirmRevert = false; compareMessage = "This change moved. Try again."
            }
        }
    }

    private func runCompare(_ action: @escaping @MainActor (GitDocumentMarks, GitCompare, [GitHunk]) async -> GitCommandResult) {
        guard !compareBusy, let marks = gitMarks, let compare, let index = focusedCompareIndex else { return }
        compareBusy = true; compareMessage = nil; compareConfirmRevert = false
        let parts = compare.parts[index]
        Task { @MainActor in
            let result = await action(marks, compare, parts)
            compareBusy = false
            if !result.ok { compareMessage = result.stderr.isEmpty ? "git failed" : result.stderr }
            compareBaseChanged()
        }
    }

}
