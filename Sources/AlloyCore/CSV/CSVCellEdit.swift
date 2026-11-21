import Foundation
import MetalUICodeBuffer

/// A cell edit in flight: where the field was and what it said when the edit began.
public struct CSVCellEditToken: Equatable, Sendable {
    public var fileRow: Int
    public var column: Int
    /// The field's byte range (quotes included) at `version`; nil for a cell missing from a ragged row.
    public var range: Range<Int>?
    public var rowRange: Range<Int>
    public var version: UInt64
    public var wasQuoted: Bool
    /// The unquoted value, full text including newlines.
    public var initialValue: String
    /// The bytes that must be unchanged for the commit to apply: the field, or the row body of a missing cell.
    var guardRange: Range<Int>
    var guardBytes: [UInt8]
    /// Delimiters a missing cell needs before its field.
    var missingDelimiters: Int
    var delimiter: UInt8
}

public enum CSVCellEditOutcome: Equatable, Sendable {
    case applied, unchanged, refusedChanged, refusedReadOnly, refusedFlagged, refusedNoRow

    public var notice: String? {
        self == .refusedChanged ? "This cell changed while you were editing. Your value was not applied." : nil
    }
}

extension CSVTableModel {
    /// Whether `column` of `fileRow` can be edited now (the `isEditable` answer): an existing data row, not flagged,
    /// a writable document, a column inside the table.
    public func canEdit(fileRow: Int, column: Int) -> Bool {
        guard document.state == .editable, readOnlyReason == nil, !isBuilding, column >= 0,
              let i = dataRow(forFileRow: fileRow), fileRow >= 0 else { return false }
        let row = cells(forDataRow: i)
        return !row.flagged && column < max(columnCount, row.fieldRanges.count)
    }

    /// Snapshots the cell: its range, the buffer version, quoting and unquoted value. Nil when it cannot be edited.
    public func beginCellEdit(fileRow: Int, column: Int) -> CSVCellEditToken? {
        sync()
        guard canEdit(fileRow: fileRow, column: column), let i = dataRow(forFileRow: fileRow) else { return nil }
        let row = cells(forDataRow: i)
        let snap = cellEditSnapshot
        let delimiter = cellEditDelimiter
        if column < row.fieldRanges.count {
            let r = row.fieldRanges[column]
            let bytes = snap.utf8(in: r)
            let p = CSVParser.parseRow(snap.utf8(in: row.byteRange), dialect: CSVDialect(delimiter: delimiter))
            let quoted = column < p.quoted.count ? p.quoted[column] : false
            return CSVCellEditToken(fileRow: fileRow, column: column, range: r, rowRange: row.byteRange,
                                    version: snap.version, wasQuoted: quoted,
                                    initialValue: CSVParser.value(of: bytes[...], quoted: quoted),
                                    guardRange: r, guardBytes: bytes, missingDelimiters: 0, delimiter: delimiter)
        }
        // Missing cell of a ragged row: the insertion point is the end of the row body, before the terminator.
        let p = CSVParser.parseRow(snap.utf8(in: row.byteRange), dialect: CSVDialect(delimiter: delimiter))
        let end = row.byteRange.upperBound - p.terminatorLength
        let body = row.byteRange.lowerBound..<end
        return CSVCellEditToken(fileRow: fileRow, column: column, range: nil, rowRange: row.byteRange,
                                version: snap.version, wasQuoted: false, initialValue: "",
                                guardRange: body, guardBytes: snap.utf8(in: body),
                                missingDelimiters: column - row.fieldRanges.count + 1, delimiter: delimiter)
    }

    /// Applies `text` to the cell the token describes, in one `.programmatic` transaction touching only that field.
    public func commitCellEdit(_ token: CSVCellEditToken, text: String) -> CSVCellEditOutcome {
        guard document.state == .editable, readOnlyReason == nil else { return .refusedReadOnly }
        let buffer = document.buffer
        // Where the guarded bytes are now. The bounds widen at their edges, so an edit touching the field refuses.
        guard let lo = buffer.map(token.guardRange.lowerBound, from: token.version, bias: .before),
              let hi = buffer.map(token.guardRange.upperBound, from: token.version, bias: .after) else {
            return .refusedChanged
        }
        let snap = buffer.snapshot()
        guard lo <= hi, hi <= snap.utf8Count else { return .refusedNoRow }
        guard hi - lo == token.guardBytes.count, snap.utf8(in: lo..<hi) == token.guardBytes else { return .refusedChanged }
        if token.range != nil, text == token.initialValue { return .unchanged }
        if token.range == nil, text.isEmpty { return .unchanged }
        let field = CSVEncoder.encode(text, delimiter: token.delimiter, wasQuoted: token.wasQuoted)
        var bytes = field
        let target: Range<Int>
        if token.range != nil {
            target = lo..<hi
        } else {
            bytes = Array(repeating: token.delimiter, count: token.missingDelimiters) + field
            target = hi..<hi
        }
        let replacement = String(decoding: bytes, as: UTF8.self)
        buffer.transaction { $0.replace(target, with: replacement, origin: .programmatic) }
        sync()
        return .applied
    }
}

// MARK: - Editing state for the table's inline editor

extension CSVTableModel {
    /// The editor's text for a cell: the unquoted value from a fresh snapshot, or the open edit's own. MetalUI asks
    /// for it before it writes the `editing` binding on a key start and after it on a caller start, so this keeps the
    /// token and `setEditingCell` agrees with it.
    public func editorText(fileRow: Int, column: Int) -> String {
        let cell = ActiveCell(row: fileRow, column: column)
        if editingCell == cell, let t = pendingEditToken { return t.initialValue }
        pendingEditToken = beginCellEdit(fileRow: fileRow, column: column)
        return pendingEditToken?.initialValue ?? ""
    }

    /// The `editing` binding's setter: a cell opens (or confirms) an edit and nil ends it without a commit.
    public func setEditingCell(_ cell: ActiveCell?) {
        guard let cell else { editingCell = nil; pendingEditToken = nil; return }
        if editingCell == cell { return }
        if let t = pendingEditToken, t.fileRow == cell.row, t.column == cell.column {
            editingCell = cell
        } else if let t = beginCellEdit(fileRow: cell.row, column: cell.column) {
            pendingEditToken = t
            editingCell = cell
        } else {
            editingCell = nil
        }
    }

    /// Commits the open edit once and clears it. Returns the outcome and the typed text so a refusal can keep it.
    public func finishCellEdit(text: String) -> CSVCellEditOutcome? {
        guard let token = pendingEditToken else { return nil }
        pendingEditToken = nil
        editingCell = nil
        return commitCellEdit(token, text: text)
    }
}

extension Workspace {
    /// Commits the table's open cell edit for `path`; a refusal posts its notice. Returns the outcome.
    @discardableResult
    public func commitTableCell(_ model: CSVTableModel, text: String) -> CSVCellEditOutcome? {
        let outcome = model.finishCellEdit(text: text)
        if let outcome, let message = outcome.notice { notify(path: model.document.path, kind: .warning, text: message) }
        return outcome
    }
}
