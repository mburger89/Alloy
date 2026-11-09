import AlloyCore
import Foundation
import MetalUI
import Observation

/// The state of quick-open (⌘P): whether it shows, the query, the ranked rows and the selected row. Owned by the
/// window's root so the global keys and the file panel share it.
@MainActor @Observable
final class QuickOpenModel {
    nonisolated static let rowLimit = 50

    private(set) var isShowing = false
    var query = ""
    private(set) var rows: [String] = []
    var selected = 0
    @ObservationIgnored private var generation = 0
    /// The query whose ranking `rows` holds; it lags `query` while a ranking is in flight.
    @ObservationIgnored private var rankedQuery: String?
    /// Return was pressed while `rows` was for an older query: open the top row once the right ranking lands.
    @ObservationIgnored private var pendingSubmit = false
    /// Test hooks: rankings that landed, and a gate every ranking waits at (with its query) before it computes.
    @ObservationIgnored private(set) var landedCount = 0
    @ObservationIgnored var rankGate: (@Sendable (String) async -> Void)?

    /// Shows the palette. The cached index ranks at once; a rescan then refreshes it off the main actor.
    func show(workspace: Workspace) {
        isShowing = true
        query = ""
        selected = 0
        rankedQuery = nil
        pendingSubmit = false
        rank(workspace: workspace)
        let index = workspace.fileIndex
        Task { [weak self] in
            await index.refresh()
            guard let self, isShowing else { return }
            rank(workspace: workspace)
        }
    }

    func hide() {
        isShowing = false
        generation += 1
        pendingSubmit = false
        rankedQuery = nil
        rows = []
    }

    func setQuery(_ new: String, workspace: Workspace) {
        guard new != query else { return }
        query = new
        pendingSubmit = false
        rank(workspace: workspace)
    }

    /// Return: opens the selected row, or, while the rows are for an older query, waits for the current query's ranking
    /// and then opens its top row.
    func submit(workspace: Workspace) {
        if rankedQuery == query { open(workspace: workspace) } else { pendingSubmit = true }
    }

    /// Ranks again for the same query (the index was rescanned).
    func refresh(workspace: Workspace) { rank(workspace: workspace) }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + step, 0), rows.count - 1)
    }

    /// Opens the row at `index` (the selected one by default) and closes the palette.
    func open(_ index: Int? = nil, workspace: Workspace) {
        let i = index ?? selected
        guard rows.indices.contains(i) else { return }
        workspace.requestOpen(rows[i])
        hide()
    }

    /// Ranks off the main actor (the index can hold 100,000 paths); only the newest result is used.
    private func rank(workspace: Workspace) {
        generation += 1
        let ticket = generation
        let query = query
        let changed = workspace.changedFiles.map(\.path)
        let index = workspace.fileIndex
        let gate = rankGate
        Task { [weak self] in
            let all = await index.paths()
            let ranked = await Task.detached { () -> [String] in
                await gate?(query)
                return Self.rank(query, paths: all, changed: changed)
            }.value
            guard let self, ticket == generation, isShowing else { return }
            // The same query keeps the user's choice (by path, else the same index); a new query starts at the top.
            if rankedQuery == query, rows.indices.contains(selected) {
                let chosen = rows[selected]
                selected = ranked.firstIndex(of: chosen) ?? min(selected, max(ranked.count - 1, 0))
            } else {
                selected = 0
            }
            rows = ranked
            rankedQuery = query
            landedCount += 1
            if pendingSubmit {
                pendingSubmit = false
                open(0, workspace: workspace)
            }
        }
    }

    /// At most ``rowLimit`` paths. An empty query lists the changed files first and then the index in its order; any
    /// other query is a fuzzy match over the index and the changed files (a new file may not be indexed yet).
    nonisolated static func rank(_ query: String, paths: [String], changed: [String]) -> [String] {
        if query.isEmpty {
            let changedSet = Set(changed)
            return Array((changed + paths.filter { !changedSet.contains($0) }).prefix(rowLimit))
        }
        let known = Set(paths)
        return FuzzyMatch.top(query, in: paths + changed.filter { !known.contains($0) }, limit: rowLimit)
    }
}

/// The path field of quick-open, at the top of the file panel; its rows hang below it in a suggestion overlay, so
/// the field keeps the caret and the keys. ↑ ↓ move, Return opens, Esc closes.
struct QuickOpenField: Component {
    let workspace: Workspace
    let model: QuickOpenModel
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let workspace = workspace, model = model
        let query = Binding<String>(get: { model.query }, set: { model.setQuery($0, workspace: workspace) })
        let showRows = Binding<Bool>(get: { model.isShowing && !model.rows.isEmpty }, set: { _ in })
        HStack(spacing: Pixels(8)) {
            TextField("Open file by name", text: query)
                .onSubmit { model.submit(workspace: workspace) }
                .focused($focused)
                .onAppear { focused = true }
                .onChange(of: focused) { old, new in if old && !new { model.hide() } }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
                    switch press.key {
                    case .downArrow: model.move(1); return .handled
                    case .upArrow: model.move(-1); return .handled
                    case .escape: model.hide(); return .handled
                    default: return .ignored
                    }
                }
                .accessibilityIdentifier("quick-open-field")
        }
        .padding(inset(12, 6))
        .background(.panelFill)
        .suggestionOverlay(isPresented: showRows, edge: .bottom, alignment: .leading) {
            QuickOpenList(rows: model.rows, selected: model.selected) { model.open($0, workspace: workspace) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quick-open")
    }
}

/// Up to 50 path rows, the selected one highlighted: `quick-open-row-<i>`. It draws its own background.
struct QuickOpenList: Component {
    let rows: [String]
    let selected: Int
    let onPick: (Int) -> Void

    var content: some ElementGroup {
        let rows = rows, selected = selected, onPick = onPick
        ScrollView {
            VStack(alignment: .leading, spacing: Pixels(0)) {
                ForEach(Array(rows.enumerated()), id: \.element) { i, path in
                    HStack(spacing: Pixels(10)) {
                        Text(verbatim: path).font(size: 12)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(inset(10, 5))
                    .background(i == selected ? Color.commandTint : Color.clear)
                    .onTapGesture { onPick(i) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("quick-open-row-\(i)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("quick-open-list")
        }
        .frame(width: Pixels(420))
        .frame(maxHeight: Pixels(320))
        .background(Color.panelFill)
        .cornerRadius(Pixels(8))
    }
}
