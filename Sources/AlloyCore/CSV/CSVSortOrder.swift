import Foundation

/// One row as the table identifies it: its file ordinal (the header row is ordinal 0 when there is one).
public struct CSVRowRef: Identifiable, Hashable, Sendable {
    public let id: Int
    public init(id: Int) { self.id = id }
}

/// The comparator a column header carries. MetalUI's Table only records which column was clicked and in which
/// direction; it never sorts, so `compare` says nothing. The model sorts.
public struct CSVColumnComparator: SortComparator, Hashable, Sendable {
    public typealias Compared = CSVRowRef
    public var column: Int
    public var order: SortOrder

    public init(column: Int, order: SortOrder = .forward) {
        self.column = column
        self.order = order
    }

    public func compare(_ lhs: CSVRowRef, _ rhs: CSVRowRef) -> ComparisonResult { .orderedSame }
}

/// A view-only display order: which file row sits at each display position. Never written to the file.
/// The permutation always covers the ordinals `firstOrdinal..<firstOrdinal + permutation.count` exactly once.
public struct CSVSortOrder: Equatable, Sendable {
    public var column: Int
    public var ascending: Bool
    /// Display position to file ordinal.
    public private(set) var permutation: [UInt32]
    /// The ordinal of the first data row (1 when the header row is not a data row).
    public let firstOrdinal: Int
    /// The buffer version of the text that was sorted.
    public var sortedAtVersion: UInt64

    public init(column: Int, ascending: Bool, permutation: [UInt32], firstOrdinal: Int, sortedAtVersion: UInt64) {
        self.column = column
        self.ascending = ascending
        self.permutation = permutation
        self.firstOrdinal = firstOrdinal
        self.sortedAtVersion = sortedAtVersion
    }

    /// Display position of every ordinal (index: ordinal minus `firstOrdinal`).
    public func inverse() -> [UInt32] {
        var inv = [UInt32](repeating: 0, count: permutation.count)
        for (position, ordinal) in permutation.enumerated() {
            let i = Int(ordinal) - firstOrdinal
            if i >= 0, i < inv.count { inv[i] = UInt32(position) }
        }
        return inv
    }

    /// Follows an edit that replaced old rows `first..<first + removed` with `inserted` rows. Frozen order: rows that
    /// still exist stay where they are, rows an edit added go to the end, rows that vanished drop out.
    public mutating func apply(first: Int, removed: Int, inserted: Int) {
        let kept = min(removed, inserted)
        let shift = inserted - removed
        var next: [UInt32] = []
        next.reserveCapacity(permutation.count + max(0, shift))
        for o in permutation {
            let e = Int(o)
            if e < first { next.append(o) }
            else if e < first + removed { if e - first < kept { next.append(o) } }
            else { next.append(UInt32(e + shift)) }
        }
        let added = max(first + kept, firstOrdinal)
        if added < first + inserted { for e in added..<(first + inserted) { next.append(UInt32(e)) } }
        permutation = next
    }

    /// After a rebuild no row mapping is known: entries past the new end drop out and rows no entry names go last.
    public mutating func resize(toRowCount count: Int) {
        let end = firstOrdinal + count
        var seen = [Bool](repeating: false, count: max(0, count))
        var next: [UInt32] = []
        next.reserveCapacity(count)
        for o in permutation where Int(o) < end && Int(o) >= firstOrdinal && !seen[Int(o) - firstOrdinal] {
            seen[Int(o) - firstOrdinal] = true
            next.append(o)
        }
        for (i, was) in seen.enumerated() where !was { next.append(UInt32(firstOrdinal + i)) }
        permutation = next
    }
}

public enum CSVSorter {
    /// The display order of `rowCount` rows by the column's values: Finder-style (numeric-aware, case and diacritics
    /// ignored), stable, ties by row index in both directions. Returns row indexes `0..<rowCount`.
    /// The one O(rows) pass: it builds a temporary array of the column's values and frees it on return.
    public static func sort(column: Int, ascending: Bool, rowCount: Int, value: (Int) -> String) -> [UInt32] {
        let options: String.CompareOptions = [.numeric, .caseInsensitive, .diacriticInsensitive]
        let values = (0..<rowCount).map(value)
        var order = (0..<rowCount).map { UInt32($0) }
        order.sort { a, b in
            let r = values[Int(a)].compare(values[Int(b)], options: options)
            if r == .orderedSame { return a < b }
            return ascending ? r == .orderedAscending : r == .orderedDescending
        }
        return order
    }
}
