import Foundation
import AlloyCore
import MetalUI

/// A CSV or TSV document as a read-only table (Phase 2): a frozen row-number column, the header row's titles and
/// one column per field. Rows are virtualised by MetalUI's `Table`; cells come from the model's bounded window cache.
/// The only observed state is `model.revision`, so an idle table asks for nothing.
struct TablePanel: Component {
    let workspace: Workspace
    let model: CSVTableModel
    let groupID: UUID
    let style: AppearanceStyle
    let topClear: Double
    @Environment(\.clipboard) var clipboard

    static let rowNumberWidth = 64.0

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TablePanel")
        let model = model
        let _ = model.revision
        let _ = model.selectionRevision
        let titles = model.headerTitles()
        let widths = model.columnWidths()
        let offset = model.hasHeader ? 1 : 0
        let end = model.endDeletionMarker
        let sorted = model.sort != nil
        let rows = CSVRowList(count: model.rowCount + (end == nil ? 0 : 1), offset: offset, permutation: model.sort?.permutation)
        let order = Binding<[CSVColumnComparator]>(
            get: { model.sortComparators },
            set: { if let first = $0.first { model.sort(column: first.column, ascending: first.order == .forward) } })
        let selection = Binding<Set<Int>>(get: { model.selectedRows }, set: { model.setSelection($0) })
        let active = Binding<TableCell<Int>?>(
            get: { model.activeCell.map { TableCell(row: $0.row, column: model.tableColumn(forDataColumn: $0.column)) } },
            set: { cell in
                guard let cell else { model.setActiveCell(nil); return }
                if let c = model.dataColumn(forTableColumn: cell.column) {
                    model.setActiveCell(CSVTableModel.ActiveCell(row: cell.row, column: c))
                } else {
                    model.setActiveCell(nil)
                    model.setSelection([cell.row])
                }
            })
        let editing = Binding<TableCell<Int>?>(
            get: { model.editingCell.map { TableCell(row: $0.row, column: model.tableColumn(forDataColumn: $0.column)) } },
            set: { cell in
                guard let cell, let c = model.dataColumn(forTableColumn: cell.column) else { model.setEditingCell(nil); return }
                model.setEditingCell(CSVTableModel.ActiveCell(row: cell.row, column: c))
            })
        let workspace = workspace, clipboard = clipboard
        let dataRows = model.rowCount
        let gid = groupID.uuidString
        let top = Edges<Pixels>(top: Pixels(Float(topClear)), right: Pixels(0), bottom: Pixels(0), left: Pixels(0))
        VStack(alignment: .leading, spacing: 0) {
            CSVTableHeaderBar(model: model, groupID: gid, workspace: workspace, pane: .group(groupID))
            ScrollViewReader { proxy in
            let _ = Self.register(proxy, on: model)
            Table(rows, selection: selection, sortOrder: order) {
                TableColumn(model.headerHasRemovedColumn ? "# \u{00D7}" : "#") { row in
                    let trailing = row.id - offset >= dataRows
                    let cells = model.cells(forDataRow: row.id - offset)
                    CSVRowNumber(number: row.id + 1, flagged: !trailing && cells.flagged,
                                 identifier: "csv-row-\(gid)-\(row.id)",
                                 marker: (trailing ? end : model.deletionMarker(beforeFileRow: row.id))?.help,
                                 trailing: trailing).equatable()
                }
                .width(Pixels(Float(Self.rowNumberWidth)))
                TableColumnForEach(0..<titles.count) { column in
                    TableColumn(titles[column], sortUsing: CSVColumnComparator(column: column)) { row in
                        let values = model.cells(forDataRow: row.id - offset).values
                        CSVCell(text: column < values.count ? values[column] : "",
                                identifier: "csv-cell-\(gid)-\(row.id)-\(column)",
                                tint: model.tint(forFileRow: row.id, column: column),
                                who: model.changeDescription(forFileRow: row.id, column: column)).equatable()
                    }
                    // Resizable (MetalUI Table column resize): starts at the measured width, user-draggable within bounds.
                    .width(min: Pixels(40), ideal: Pixels(Float(widths[column])), max: Pixels(1200))
                }
            }
            .tableActiveCell(active)
            .tableCellEditing(editing,
                text: { cell in model.dataColumn(forTableColumn: cell.column).map { model.editorText(fileRow: cell.row, column: $0) } ?? "" },
                isEditable: { cell in model.dataColumn(forTableColumn: cell.column).map { model.canEdit(fileRow: cell.row, column: $0) } ?? false },
                onCommit: { _, text in
                    if workspace.commitTableCell(model, text: text) == .refusedChanged { clipboard.write(text) }
                })
            .tableCellBackground { cell in
                model.dataColumn(forTableColumn: cell.column).flatMap { model.tint(forFileRow: cell.row, column: $0) }
                    .map(CSVCell.fill)
            }
            .tableFrozenColumns(1)
            .tableRowIndex { id in
                if sorted { return model.displayPosition(ofFileRow: id) }
                let i = id - offset
                return i >= 0 && i < rows.count ? i : nil
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("csv-table-\(gid)")
    }
}

extension TablePanel {
    /// Hands the model the reader's proxy so Previous/Next change and reveal can scroll to a cell.
    @MainActor static func register(_ proxy: ScrollViewProxy, on model: CSVTableModel) {
        model.scroller = { [weak model] cell in
            guard let model else { return }
            proxy.scrollTo(TableCell(row: cell.row, column: model.tableColumn(forDataColumn: cell.column)))
        }
        if model.hasPendingScroll { Task { @MainActor in model.flushPendingScroll() } }
    }
}

extension TablePanel: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.model === b.model && a.groupID == b.groupID && a.style == b.style
            && a.topClear == b.topClear
    }
}
