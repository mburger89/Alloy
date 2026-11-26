import AlloyCore
import MetalUI

/// The rows of a table as cheap handles over the model's row count: O(1) `count` and subscript, nothing stored per row.
struct CSVRowList: RandomAccessCollection {
    let count: Int
    /// 1 when the header row is not a data row, so data row `i` has file ordinal `i + offset`.
    let offset: Int
    /// A view-only sort's display order (file ordinals); nil in file order. Shared with the model, never copied.
    var permutation: [UInt32]? = nil
    var startIndex: Int { 0 }
    var endIndex: Int { count }
    subscript(position: Int) -> CSVRowRef {
        if let p = permutation, position < p.count { return CSVRowRef(id: Int(p[position])) }
        return CSVRowRef(id: position + offset)
    }
}

/// A data cell: the first line of the field (the model's display form). A cell a session or an outside change
/// touched is filled with that author's colour by the table's `tableCellBackground` (the whole cell box); the cell
/// itself carries only the accessibility token.
struct CSVCell: Component {
    let text: String
    let identifier: String
    let tint: CSVTint?
    var who: String? = nil

    static func fill(_ tint: CSVTint, own: Color = .userAuthor) -> Color {
        switch tint {
        case .own: own.opacity(0.3)
        case .session(let slot): Color.sessionColor(slot).opacity(0.3)
        case .outside: Color.outsideAuthor.opacity(0.3)
        }
    }

    /// What the accessibility value says about the fill (tests read it).
    static func token(_ tint: CSVTint) -> String {
        switch tint {
        case .own: "tint-own"
        case .session(let slot): "tint-session\(((slot % 12) + 12) % 12)"
        case .outside: "tint-outside"
        }
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CSVCell")
        if let tint {
            Text(verbatim: text).font(size: 12).lineLimit(1)
                .padding(inset(8, 0))
                .accessibilityValue(Self.token(tint))
                .accessibilityHint(who ?? "")
                .accessibilityIdentifier(identifier)
        } else {
            Text(verbatim: text).font(size: 12).lineLimit(1)
                .padding(inset(8, 0))
                .accessibilityIdentifier(identifier)
        }
    }
}

extension CSVCell: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.text == b.text && a.identifier == b.identifier && a.tint == b.tint && a.who == b.who
    }
}

/// The frozen first column: the spreadsheet row number, with a warning glyph when the row's quoting is broken.
struct CSVRowNumber: Component {
    let number: Int
    let flagged: Bool
    let identifier: String
    /// The hover text of a deletion marker on this row (the removed rows), when a session removed rows just before it.
    var marker: String? = nil
    /// The row after the last one, which only carries a marker.
    var trailing = false

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CSVRowNumber")
        HStack(spacing: Pixels(4)) {
            if let marker {
                Image(systemName: "minus.circle").font(.system(size: 11)).foregroundColor(.mutedInk)
                    .accessibilityHint(marker)
                    .accessibilityIdentifier("\(identifier)-marker")
            }
            if flagged {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundColor(.warningInk)
                    .help("This row's quoting is broken")
                    .accessibilityIdentifier("\(identifier)-flag")
            }
            Text(verbatim: trailing ? "" : String(number)).font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                .accessibilityIdentifier(identifier)
        }
        .padding(inset(8, 0))
    }
}

extension CSVRowNumber: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.number == b.number && a.flagged == b.flagged && a.identifier == b.identifier && a.marker == b.marker
            && a.trailing == b.trailing
    }
}
