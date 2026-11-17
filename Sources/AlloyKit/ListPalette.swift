import AlloyCore
import Foundation
import MetalUI
import Observation

/// The rows of a go-to-symbol or find-references palette, filtered by what is typed after the palette opened. Filtering
/// runs off the main actor, and only the newest result is used (like ``QuickOpenModel``'s ranking).
@MainActor @Observable
final class ListPaletteModel {
    enum Kind {
        case symbols, references

        /// The accessibility id prefix: container `<prefix>-palette`, rows `<prefix>-row-<i>`.
        var prefix: String { self == .symbols ? "symbols" : "references" }
        var placeholder: String { self == .symbols ? "Go to symbol in file" : "Filter references" }
        var emptyText: String { self == .symbols ? "No symbols for this file" : "No references found" }
        var loadingText: String { self == .symbols ? "Loading symbols" : "Finding references" }
    }

    /// One thing to pick. `tag` is the caller's own handle (an index into its data).
    struct Item: Sendable, Equatable {
        var title: String
        var detail: String
        var depth: Int
        var glyph: String
        var group: String?
        var tag: Int

        init(title: String, detail: String = "", depth: Int = 0, glyph: String = "", group: String? = nil, tag: Int = 0) {
            self.title = title
            self.detail = detail
            self.depth = depth
            self.glyph = glyph
            self.group = group
            self.tag = tag
        }
    }

    struct Row: Identifiable, Equatable {
        var id: Int
        var title: String
        var detail: String
        var depth: Int
        var glyph: String
        var group: String?
        /// A message, not a choice: never picked.
        var inert: Bool
    }

    let kind: Kind
    private(set) var rows: [Row] = []
    var query = ""
    var selected = 0
    /// How many matches are not shown (beyond ``QuickOpenModel/rowLimit``).
    private(set) var hiddenCount = 0
    /// True until the items are known: the palette shows a waiting row instead of the empty message.
    private(set) var isLoading: Bool
    /// A line the owner adds to the footer (references outside the project, hits past the cap).
    private(set) var note: String?
    @ObservationIgnored private var items: [Item]
    @ObservationIgnored private var itemIndexByRow: [Int] = []
    @ObservationIgnored private let onPick: @MainActor (Item) -> Void
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rankedQuery: String?
    @ObservationIgnored private var pendingSubmit = false
    /// Test hooks: filterings that landed, and a gate every filtering waits at (with its query) before it computes.
    @ObservationIgnored private(set) var landedCount = 0
    @ObservationIgnored var rankGate: (@Sendable (String) async -> Void)?

    init(kind: Kind, items: [Item], loading: Bool = false, note: String? = nil, onPick: @escaping @MainActor (Item) -> Void) {
        self.kind = kind
        self.items = items
        self.isLoading = loading
        self.note = note
        self.onPick = onPick
        show(Self.filter("", items: items))
        rankedQuery = ""
    }

    /// The footer text: what is not shown, and the owner's note.
    var footer: String? {
        var parts: [String] = []
        if hiddenCount > 0 { parts.append("\(hiddenCount) more") }
        if let note { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// Replaces the items (the answer arrived) and filters them by the current query.
    func setItems(_ new: [Item], note: String? = nil) {
        items = new
        self.note = note
        isLoading = false
        filter()
    }

    func setQuery(_ new: String) {
        guard new != query else { return }
        query = new
        pendingSubmit = false
        filter()
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + step, 0), rows.count - 1)
    }

    /// Return: picks the selected row, or, while the rows are for an older query, the top row of the current one once it lands.
    func submit() {
        if rankedQuery == query { pick(selected) } else { pendingSubmit = true }
    }

    /// Picks the row at `index`; an inert row does nothing.
    func pick(_ index: Int) {
        guard rows.indices.contains(index), !rows[index].inert, itemIndexByRow.indices.contains(index) else { return }
        onPick(items[itemIndexByRow[index]])
    }

    /// Stops any filtering in flight (the palette closed).
    func cancel() {
        generation += 1
        pendingSubmit = false
    }

    private func filter() {
        generation += 1
        let ticket = generation
        let query = query, items = items, gate = rankGate
        if query.isEmpty {
            apply(Self.filter("", items: items), query: query)
            return
        }
        Task { [weak self] in
            let result = await Task.detached { () -> Filtered in
                await gate?(query)
                return Self.filter(query, items: items)
            }.value
            guard let self, ticket == generation else { return }
            apply(result, query: query)
            landedCount += 1
        }
    }

    private func apply(_ result: Filtered, query: String) {
        show(result)
        rankedQuery = query
        selected = 0
        if pendingSubmit {
            pendingSubmit = false
            pick(0)
        }
    }

    struct Filtered: Sendable {
        var indices: [Int]
        var hidden: Int
    }

    private func show(_ result: Filtered) {
        hiddenCount = result.hidden
        if result.indices.isEmpty {
            itemIndexByRow = []
            rows = [Row(id: 0, title: isLoading ? kind.loadingText : kind.emptyText, detail: "", depth: 0, glyph: "", group: nil, inert: true)]
            return
        }
        itemIndexByRow = result.indices
        rows = result.indices.enumerated().map { row, index in
            let item = items[index]
            return Row(id: row, title: item.title, detail: item.detail, depth: item.depth, glyph: item.glyph, group: item.group, inert: false)
        }
    }

    /// At most ``QuickOpenModel/rowLimit`` item indices. An empty query keeps the source order; any other is a fuzzy match
    /// over title and detail, best first, ties in source order.
    nonisolated static func filter(_ query: String, items: [Item]) -> Filtered {
        let limit = QuickOpenModel.rowLimit
        if query.isEmpty {
            return Filtered(indices: Array(items.indices.prefix(limit)), hidden: max(items.count - limit, 0))
        }
        var scored: [(score: Int, index: Int)] = []
        for (i, item) in items.enumerated() {
            if i & 1023 == 0, Task.isCancelled { return Filtered(indices: [], hidden: 0) }
            let text = item.detail.isEmpty ? item.title : item.title + " " + item.detail
            if let s = FuzzyMatch.score(query, text) { scored.append((s, i)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Filtered(indices: scored.prefix(limit).map(\.index), hidden: max(scored.count - limit, 0))
    }
}

/// Up to 50 rows of a ``ListPaletteModel`` with its footer, the selected row highlighted: `<prefix>-row-<i>`. It draws its
/// own background.
struct ListPaletteList: Component {
    let model: ListPaletteModel
    let onPick: (Int) -> Void

    var content: some ElementGroup {
        let rows = model.rows, selected = model.selected, footer = model.footer, prefix = model.kind.prefix, onPick = onPick
        ScrollView {
            VStack(alignment: .leading, spacing: Pixels(0)) {
                ForEach(rows) { row in
                    HStack(spacing: Pixels(8)) {
                        if !row.glyph.isEmpty { Text(verbatim: row.glyph).font(size: 11).foregroundColor(.mutedInk) }
                        Text(verbatim: row.title).font(size: 12)
                        if !row.detail.isEmpty {
                            Text(verbatim: row.detail).font(size: 11).foregroundColor(.mutedInk).lineLimit(1)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Edges(top: Pixels(5), right: Pixels(10), bottom: Pixels(5), left: Pixels(10 + 12 * Float(min(row.depth, 8)))))
                    .background(row.id == selected && !row.inert ? Color.commandTint : Color.clear)
                    .onTapGesture { onPick(row.id) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(prefix)-row-\(row.id)")
                }
                if let footer {
                    Text(verbatim: footer).font(size: 11).foregroundColor(.mutedInk)
                        .padding(inset(10, 5))
                        .accessibilityIdentifier("\(prefix)-footer")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(prefix)-palette")
        }
        .frame(width: Pixels(420))
        .frame(maxHeight: Pixels(320))
        .background(Color.panelFill)
        .cornerRadius(Pixels(8))
    }
}
