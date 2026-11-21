import AlloyCore
import MetalUI

/// The strip above the table: the header-row toggle, why the file is read-only, and a label while the index builds.
struct CSVTableHeaderBar: Component {
    let model: CSVTableModel
    let groupID: String
    let workspace: Workspace
    let pane: PaneID

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CSVTableHeaderBar")
        let model = model
        let header = Binding<Bool>(get: { model.hasHeader }, set: { model.hasHeader = $0 })
        HStack(spacing: Pixels(12)) {
            Toggle(isOn: header) { Text("First row is header").font(size: 12) }
                .accessibilityIdentifier("csv-header-toggle-\(groupID)")
            if model.isBuilding {
                Text("Building index\u{2026}").font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("csv-building-\(groupID)")
            }
            if model.sort != nil {
                Button("File order") { model.clearSort() }
                    .accessibilityIdentifier("csv-file-order-\(groupID)")
                if model.sortIsStale {
                    Text("Sorted before changes. Click to re-sort").font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("csv-sort-stale-\(groupID)")
                }
            }
            let noChanges = model.changedCells().isEmpty
            Button("Previous change") { model.stepChange(forward: false) }
                .disabled(noChanges)
                .accessibilityIdentifier("csv-prev-change-\(groupID)")
            Button("Next change") { model.stepChange(forward: true) }
                .disabled(noChanges)
                .accessibilityIdentifier("csv-next-change-\(groupID)")
            if model.rowsHaveChange(model.selectedRows) {
                let editable = model.readOnlyReason == nil
                Button("Keep") { Self.keep(model, workspace) }
                    .disabled(!editable)
                    .accessibilityIdentifier("csv-keep-\(groupID)")
                Button("Revert") { Self.revert(model, workspace, pane) }
                    .disabled(!editable)
                    .accessibilityIdentifier("csv-revert-\(groupID)")
            }
            Spacer()
            if let reason = model.readOnlyReason {
                Text(verbatim: "Read-only \u{2014} \(reason)").font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                    .accessibilityIdentifier("csv-read-only-\(groupID)")
            }
        }
        .padding(inset(12, 6))
    }
}

extension CSVTableHeaderBar {
    /// Keeps the active changed cell, else the changes of the selected rows (ledger only).
    @MainActor static func keep(_ model: CSVTableModel, _ workspace: Workspace) {
        workspace.keepRanges(path: model.document.path, targets: model.actionTargets())
    }

    /// Restores the previous bytes of the active changed cell, else of the selected rows, in one undoable edit.
    @MainActor static func revert(_ model: CSVTableModel, _ workspace: Workspace, _ pane: PaneID) {
        workspace.revertRanges(path: model.document.path, targets: model.actionTargets(), in: pane)
    }
}
