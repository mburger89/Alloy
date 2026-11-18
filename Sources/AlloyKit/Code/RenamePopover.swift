import AlloyCore
import Foundation
import MetalUI

/// The content of the code view's popover slot: the hover, or the rename field.
@MainActor
struct SlotContent: Component {
    let presentation: SlotPresentation
    let slot: PopoverSlotModel
    let workspace: Workspace
    let onRename: (String) -> Void
    let onDone: () -> Void

    var content: some ElementGroup {
        switch presentation {
        case .hover(let p): HoverView(presentation: p, cache: slot.markdownCache)
        case .rename(let s): RenameFieldView(state: s, onSubmit: onRename)
        case .summary(let s): RenameSummaryView(state: s, workspace: workspace, onDone: onDone)
        }
    }
}

/// The new-name field of Rename Symbol: prefilled and selected with the old name; Return submits, Esc (the popover's own
/// key stage) only dismisses.
@MainActor
struct RenameFieldView: Component {
    let state: RenameFieldState
    let onSubmit: (String) -> Void
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let state = state, onSubmit = onSubmit
        VStack(alignment: .leading, spacing: Pixels(4)) {
            TextField("New name", text: Binding(get: { state.name }, set: { state.name = $0 }),
                      selectedOffsets: Binding(get: { state.selection }, set: { state.selection = $0 }))
                .onSubmit { onSubmit(state.name) }
                .focused($focused)
                .onAppear { focused = true }
                .accessibilityIdentifier("rename-field")
                .frame(width: Pixels(240), height: Pixels(24))
            if let error = state.error {
                Text(verbatim: error).font(size: 11).foregroundColor(.diagnosticError)
                    .frame(maxWidth: Pixels(240), alignment: .leading)
                    .accessibilityIdentifier("rename-error")
            }
        }
        .padding(inset(8, 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rename-popover")
    }
}

/// The summary after a rename: one line, one row per file with its outcome, and Keep All / Revert All / Done.
@MainActor
struct RenameSummaryView: Component {
    let state: RenameSummaryState
    let workspace: Workspace
    let onDone: () -> Void

    var content: some ElementGroup {
        let state = state, workspace = workspace, onDone = onDone
        VStack(alignment: .leading, spacing: Pixels(4)) {
            Text(verbatim: state.summary).font(size: 12).accessibilityIdentifier("rename-summary-text")
            VStack(alignment: .leading, spacing: Pixels(2)) {
                ForEach(Array(state.rows.enumerated()), id: \.element.path) { position, row in
                    HStack(spacing: Pixels(6)) {
                        Text(verbatim: row.name).font(size: 11).lineLimit(1)
                        Text(verbatim: row.folder).font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                        Spacer()
                        Text(verbatim: row.outcome).font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("rename-summary-file-\(position)")
                }
            }
            HStack(spacing: Pixels(6)) {
                Button("Keep All") { state.keepAll(workspace: workspace) }
                    .disabled(!state.isOpen)
                    .accessibilityIdentifier("rename-keep-all")
                Button("Revert All") { state.revertAll(workspace: workspace) }
                    .disabled(!state.isOpen)
                    .accessibilityIdentifier("rename-revert-all")
                Button("Done") { onDone() }
                    .accessibilityIdentifier("rename-done")
            }
        }
        .padding(inset(8, 6))
        .frame(minWidth: Pixels(300), alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rename-summary")
    }
}
