import AlloyCore
import AlloyLSP
import Foundation
import MetalUICodeBuffer
import MetalUI
import Observation

/// The state of quick-open (⌘P): whether it shows, the query, the ranked rows and the selected row. Owned by the
/// window's root so the global keys and the file panel share it.
@MainActor @Observable
final class QuickOpenModel {
    nonisolated static let rowLimit = 50

    /// What the palette lists: file paths, or the rows of a symbols / references ``ListPaletteModel``.
    enum Mode {
        case files
        case list(ListPaletteModel)
    }

    /// The document a symbol jump belongs to, captured when the palette opens.
    struct Target: Equatable {
        var path: String
        var pane: PaneID
    }

    private(set) var isShowing = false
    private(set) var mode = Mode.files
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
    /// The panel store that answers symbol requests (set by the root).
    @ObservationIgnored weak var panel: CodePanelStore?
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var symbols: [DocSymbol] = []
    @ObservationIgnored private var symbolVersion: UInt64 = 0

    /// Shows the palette. The cached index ranks at once; a rescan then refreshes it off the main actor.
    func show(workspace: Workspace) {
        leaveList()
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
        leaveList()
        isShowing = false
        generation += 1
        pendingSubmit = false
        rankedQuery = nil
        rows = []
    }

    func setQuery(_ new: String, workspace: Workspace) {
        guard new != query else { return }
        switch mode {
        case .files:
            query = new
            pendingSubmit = false
            if new.hasPrefix("@") {
                // `@` first: the symbols of the focused document, the rest of the text filters them.
                generation += 1
                rows = []
                rankedQuery = nil
                enterSymbols(workspace: workspace)
                if case .list(let list) = mode { list.setQuery(String(new.dropFirst())) }
            } else {
                rank(workspace: workspace)
            }
        case .list(let list):
            query = new
            if list.kind == .symbols {
                if new.hasPrefix("@") {
                    list.setQuery(String(new.dropFirst()))
                } else {
                    // The `@` was deleted: back to files.
                    leaveList()
                    pendingSubmit = false
                    rank(workspace: workspace)
                }
            } else {
                list.setQuery(new)
            }
        }
    }

    // MARK: Lists

    /// Opens the palette in symbols mode (⇧⌘O) for the focused pane's active document.
    func showSymbols(workspace: Workspace) {
        leaveList()
        isShowing = true
        query = "@"
        selected = 0
        rows = []
        rankedQuery = nil
        pendingSubmit = false
        generation += 1
        enterSymbols(workspace: workspace)
    }

    /// Opens a references palette (the store built `model`); Esc or `hide()` closes it.
    func showReferences(model: ListPaletteModel) {
        leaveList()
        isShowing = true
        query = ""
        selected = 0
        rows = []
        generation += 1
        pendingSubmit = false
        mode = .list(model)
    }

    private func enterSymbols(workspace: Workspace) {
        let pane = workspace.defaultPane
        let captured = workspace.activeTab(in: pane).map { Target(path: $0, pane: pane) }
        target = captured
        symbols = []
        let palette = ListPaletteModel(kind: .symbols, items: [], loading: true) { [weak self, weak workspace] item in
            guard let self, let workspace else { return }
            self.jump(toSymbol: item.tag, workspace: workspace)
        }
        mode = .list(palette)
        guard let captured, let panel else {
            palette.setItems([])
            return
        }
        panel.loadSymbols(workspace: workspace, quickOpen: self, palette: palette, target: captured)
    }

    /// The outline arrived for `palette` (still the open one).
    func provideSymbols(_ list: [DocSymbol], version: UInt64, for palette: ListPaletteModel) {
        guard case .list(let current) = mode, current === palette, isShowing else { return }
        symbols = list
        symbolVersion = version
        palette.setItems(list.enumerated().map { i, symbol in
            ListPaletteModel.Item(title: symbol.name, detail: symbol.detail ?? "", depth: symbol.depth,
                                  glyph: Self.glyph(kind: symbol.kind), tag: i)
        })
    }

    /// Selects symbol `index` of the outline in the captured document: its range is mapped through the edits made since the
    /// request, and dropped when it cannot be.
    private func jump(toSymbol index: Int, workspace: Workspace) {
        guard symbols.indices.contains(index), let target, let document = workspace.document(target.path) else { return }
        let range = symbols[index].range, version = symbolVersion
        hide()
        Task { @MainActor in
            await workspace.open(target.path, selecting: { _ in
                guard let lower = document.buffer.map(range.lowerBound, from: version, bias: .after),
                      let upper = document.buffer.map(range.upperBound, from: version, bias: .before) else { return 0..<0 }
                return lower..<max(lower, upper)
            }, in: target.pane)
        }
    }

    private func leaveList() {
        if case .list(let list) = mode { list.cancel() }
        mode = .files
        target = nil
        symbols = []
    }

    /// A short mark for an LSP `SymbolKind`.
    nonisolated static func glyph(kind: Int) -> String {
        switch kind {
        case 2, 3, 4: "M"      // module, namespace, package
        case 5: "C"            // class
        case 6, 9: "m"         // method, constructor
        case 7, 8: "p"         // property, field
        case 10: "E"           // enum
        case 11: "I"           // interface
        case 12: "f"           // function
        case 13, 14: "v"       // variable, constant
        case 22, 23: "S"       // enum member, struct
        case 26: "T"           // type parameter
        default: "·"
        }
    }

    /// The references palette for `result`: rows "path:line  preview", picking one opens it in `pane`.
    static func referencesPalette(_ result: ReferenceResult, snapshot: CodeSnapshot, path: String, pane: PaneID,
                                  workspace: Workspace, quickOpen: QuickOpenModel?) -> ListPaletteModel {
        let hits = result.hits
        let items = hits.enumerated().map { i, hit in
            ListPaletteModel.Item(title: "\(hit.path):\(hit.line + 1)", detail: hit.preview, group: hit.path, tag: i)
        }
        var notes: [String] = []
        if result.truncated { notes.append("first \(ReferenceParsing.hitLimit) shown") }
        if result.outsideRoot > 0 { notes.append("\(result.outsideRoot) more outside the project") }
        let encoding = result.encoding
        return ListPaletteModel(kind: .references, items: items, note: notes.isEmpty ? nil : notes.joined(separator: ", ")) {
            [weak workspace, weak quickOpen] item in
            guard let workspace, hits.indices.contains(item.tag) else { return }
            let hit = hits[item.tag]
            quickOpen?.hide()
            Task { @MainActor in
                if hit.path == path, let document = workspace.document(path) {
                    // The answer is for `snapshot`; the text may have moved on while the palette was open.
                    let range = Positions.utf8Range(of: hit.range, in: snapshot, encoding: encoding)
                    await workspace.open(path, selecting: { _ in
                        guard let lower = document.buffer.map(range.lowerBound, from: snapshot.version, bias: .after),
                              let upper = document.buffer.map(range.upperBound, from: snapshot.version, bias: .before) else { return 0..<0 }
                        return lower..<max(lower, upper)
                    }, in: pane)
                } else {
                    await workspace.open(hit.path, selecting: { Positions.utf8Range(of: hit.range, in: $0, encoding: encoding) }, in: pane)
                }
            }
        }
    }

    /// Return: opens the selected row, or, while the rows are for an older query, waits for the current query's ranking
    /// and then opens its top row.
    func submit(workspace: Workspace) {
        if case .list(let list) = mode { list.submit(); return }
        if rankedQuery == query { open(workspace: workspace) } else { pendingSubmit = true }
    }

    /// Ranks again for the same query (the index was rescanned).
    func refresh(workspace: Workspace) { rank(workspace: workspace) }

    func move(_ step: Int) {
        if case .list(let list) = mode { list.move(step); return }
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

/// What the suggestion field and its row list need from a model: quick-open's paths or the branch picker's names.
/// The identifiers are parameters, so each source keeps its own.
@MainActor
protocol RowSource {
    var query: String { get }
    var rows: [String] { get }
    var selected: Int { get }
    var isShowing: Bool { get }
    /// A symbols / references list the field shows in place of `rows`; nil for the plain rows.
    var listModel: ListPaletteModel? { get }
    /// A message shown under the field (git's refusal); nil for none.
    var error: String? { get }
    var placeholder: String { get }
    var fieldID: String { get }
    var rowPrefix: String { get }
    var panelID: String { get }
    var listID: String { get }
    var errorID: String { get }
    func setQuery(_ new: String)
    func submit()
    func move(_ step: Int)
    func hide()
    func pick(_ index: Int)
}

extension RowSource { var listModel: ListPaletteModel? { nil } }

/// Quick-open's model with the workspace it opens files in, as a row source.
struct QuickOpenSource: RowSource {
    let workspace: Workspace
    let model: QuickOpenModel
    var query: String { model.query }
    var rows: [String] { model.rows }
    var selected: Int { model.selected }
    var isShowing: Bool { model.isShowing }
    var listModel: ListPaletteModel? { if case .list(let list) = model.mode { list } else { nil } }
    var error: String? { nil }
    var placeholder: String { listModel?.kind.placeholder ?? "Open file by name" }
    var fieldID: String { "quick-open-field" }
    var rowPrefix: String { "quick-open-row" }
    var panelID: String { "quick-open" }
    var listID: String { "quick-open-list" }
    var errorID: String { "quick-open-error" }
    func setQuery(_ new: String) { model.setQuery(new, workspace: workspace) }
    func submit() { model.submit(workspace: workspace) }
    func move(_ step: Int) { model.move(step) }
    func hide() { model.hide() }
    func pick(_ index: Int) { model.open(index, workspace: workspace) }
}

/// The path field of quick-open, at the top of the file panel; its rows hang below it in a suggestion overlay, so
/// the field keeps the caret and the keys. ↑ ↓ move, Return opens, Esc closes. The branch picker uses the same field.
struct QuickOpenField<Source: RowSource>: Component {
    let source: Source
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let source = source
        let query = Binding<String>(get: { source.query }, set: { source.setQuery($0) })
        let listModel = source.listModel
        let showRows = Binding<Bool>(get: { source.isShowing && (listModel != nil || !source.rows.isEmpty) }, set: { _ in })
        VStack(alignment: .leading, spacing: Pixels(4)) {
            HStack(spacing: Pixels(8)) {
                TextField(source.placeholder, text: query)
                    .onSubmit { source.submit() }
                    .focused($focused)
                    .onAppear { focused = true }
                    .onChange(of: focused) { old, new in if old && !new { source.hide() } }
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        guard press.modifiers.isEmpty else { return .ignored }
                        switch press.key {
                        case .downArrow: source.move(1); return .handled
                        case .upArrow: source.move(-1); return .handled
                        case .escape: source.hide(); return .handled
                        default: return .ignored
                        }
                    }
                    .accessibilityIdentifier(source.fieldID)
            }
            if let error = source.error {
                Text(verbatim: error).font(size: 11).foregroundColor(.mutedInk)
                    .accessibilityIdentifier(source.errorID)
            }
        }
        .padding(inset(12, 6))
        .background(.panelFill)
        .suggestionOverlay(isPresented: showRows, edge: .bottom, alignment: .leading) {
            if let listModel {
                ListPaletteList(model: listModel) { listModel.pick($0) }
            } else {
                QuickOpenList(rows: source.rows, selected: source.selected, rowPrefix: source.rowPrefix, listID: source.listID) { source.pick($0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(source.panelID)
    }
}

extension QuickOpenField where Source == QuickOpenSource {
    init(workspace: Workspace, model: QuickOpenModel) { self.init(source: QuickOpenSource(workspace: workspace, model: model)) }
}

/// Up to 50 path rows, the selected one highlighted: `quick-open-row-<i>`. It draws its own background.
struct QuickOpenList: Component {
    let rows: [String]
    let selected: Int
    var rowPrefix = "quick-open-row"
    var listID = "quick-open-list"
    let onPick: (Int) -> Void

    var content: some ElementGroup {
        let rows = rows, selected = selected, onPick = onPick, rowPrefix = rowPrefix, listID = listID
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
                    .accessibilityIdentifier("\(rowPrefix)-\(i)")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(listID)
        }
        .frame(width: Pixels(420))
        .frame(maxHeight: Pixels(320))
        .background(Color.panelFill)
        .cornerRadius(Pixels(8))
    }
}
