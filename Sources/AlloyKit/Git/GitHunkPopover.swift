import AlloyCore
import Foundation
import MetalUI
import Observation

/// One open hunk popover: which hunk, where it points, and what its buttons have said so far. A new one per click, so
/// its state never outlives the popover.
@MainActor @Observable
final class GitHunkSelection: Identifiable {
    @ObservationIgnored let id = UUID()
    @ObservationIgnored let hunk: GitHunk
    /// The byte range of the hunk's first row in the buffer at `version`, which the popover points at.
    @ObservationIgnored let anchor: Range<Int>
    @ObservationIgnored let version: UInt64
    /// Set after Revert found a pending Claude edit in the same rows.
    var confirmRevert = false
    var busy = false
    var message: String?

    init(hunk: GitHunk, anchor: Range<Int>, version: UInt64) {
        self.hunk = hunk; self.anchor = anchor; self.version = version
    }
}

/// The popover of one hunk: the lines HEAD had, and Stage, Unstage and Revert.
struct GitHunkPopover: Component {
    let view: OpenDocumentView
    let selection: GitHunkSelection

    static let previewLimit = 8

    var content: some ElementGroup {
        let view = view, selection = selection, hunk = selection.hunk
        let shown = Array(hunk.oldLines.prefix(Self.previewLimit).enumerated().map { PreviewLine(id: $0.offset, text: $0.element) })
        VStack(alignment: .leading, spacing: Pixels(6)) {
            Text(verbatim: Self.title(hunk)).font(size: 11).foregroundColor(.mutedInk)
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: Pixels(0)) {
                    ForEach(shown, id: \.id) { line in
                        Text(verbatim: line.text.isEmpty ? " " : line.text).font(family: "Menlo", size: 11).lineLimit(1)
                            .padding(inset(4, 0))
                            .background(.removedRowTint)
                    }
                    if hunk.oldLines.count > Self.previewLimit {
                        Text(verbatim: "\u{2026} \(hunk.oldLines.count - Self.previewLimit) more").font(size: 11).foregroundColor(.mutedInk)
                    }
                }
                .accessibilityIdentifier("git-hunk-old-lines")
            }
            HStack(spacing: Pixels(8)) {
                Button("Stage") { Self.run(selection, view) { await $0.stage(selection.hunk) } }
                    .accessibilityIdentifier("git-hunk-stage")
                Button("Unstage") { Self.run(selection, view) { await $0.unstage(selection.hunk) } }
                    .accessibilityIdentifier("git-hunk-unstage")
                Button("Revert") { Self.revert(selection, view, confirmed: false) }
                    .accessibilityIdentifier("git-hunk-revert")
            }
            if selection.confirmRevert {
                Text(verbatim: "This also reverts Claude\u{2019}s unreviewed change").font(size: 11)
                    .accessibilityIdentifier("git-hunk-revert-warning")
                HStack(spacing: Pixels(8)) {
                    Button("Revert anyway") { Self.revert(selection, view, confirmed: true) }
                        .accessibilityIdentifier("git-hunk-revert-confirm")
                    Button("Cancel") { selection.confirmRevert = false }
                        .accessibilityIdentifier("git-hunk-revert-cancel")
                }
            }
            if let message = selection.message {
                Text(verbatim: message).font(size: 11).foregroundColor(.errorInk)
                    .accessibilityIdentifier("git-hunk-message")
            }
        }
        .padding(inset(10, 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-git-hunk-popover")
    }

    struct PreviewLine: Hashable { var id: Int; var text: String }

    static func title(_ hunk: GitHunk) -> String {
        switch hunk.kind {
        case .added: hunk.newCount == 1 ? "Added line \(hunk.newStart)" : "Added lines \(hunk.newStart)\u{2013}\(hunk.newStart + hunk.newCount - 1)"
        case .deleted: hunk.oldCount == 1 ? "Removed 1 line after line \(hunk.newStart)" : "Removed \(hunk.oldCount) lines after line \(hunk.newStart)"
        case .modified: hunk.newCount == 1 ? "Changed line \(hunk.newStart)" : "Changed lines \(hunk.newStart)\u{2013}\(hunk.newStart + hunk.newCount - 1)"
        }
    }

    /// Stage or unstage: shows a failure inline, closes the popover on success.
    @MainActor
    private static func run(_ selection: GitHunkSelection, _ view: OpenDocumentView,
                            _ action: @escaping @MainActor (GitDocumentMarks) async -> GitCommandResult) {
        guard !selection.busy, let marks = view.gitMarks else { return }
        selection.busy = true; selection.message = nil
        Task { @MainActor in
            let result = await action(marks)
            selection.busy = false
            if result.ok { view.selectedGitHunk = nil } else { selection.message = result.stderr.isEmpty ? "git failed" : result.stderr }
        }
    }

    @MainActor
    private static func revert(_ selection: GitHunkSelection, _ view: OpenDocumentView, confirmed: Bool) {
        guard !selection.busy, let marks = view.gitMarks else { return }
        selection.busy = true; selection.message = nil
        Task { @MainActor in
            let outcome = await marks.revert(selection.hunk, confirmed: confirmed)
            selection.busy = false
            switch outcome {
            case .reverted: view.selectedGitHunk = nil
            case .needsConfirmation: selection.confirmRevert = true
            case .stale: selection.confirmRevert = false; selection.message = "This change moved. Try again."
            }
        }
    }
}

extension OpenDocumentView {
    /// A press on a git bar or wedge: opens that hunk's popover, pointing at the row the press hit now.
    func openGitHunk(_ hit: CodeGutterHit) {
        guard let tag = hit.tag, let hunk = gitMarks?.tags[tag] else { return }
        let snapshot = document.buffer.snapshot()
        let row = max(0, min(hit.lines.lowerBound, snapshot.lineCount - 1))
        selectedGitHunk = GitHunkSelection(hunk: hunk, anchor: snapshot.lineRange(row), version: snapshot.version)
    }
}
