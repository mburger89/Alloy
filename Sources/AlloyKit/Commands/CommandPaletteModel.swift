import AlloyCore
import Foundation
import Observation

/// One line of the palette.
struct PaletteRow: Equatable {
    let id: String
    /// "View: Split Right".
    let displayTitle: String
    /// UTF-8 byte ranges of `displayTitle` the query matched.
    let matched: [Range<Int>]
    /// The command's chord as text, once MetalUI can show one (see `CommandPaletteModel.shortcutText`).
    let shortcutText: String?
    let isEnabled: Bool
    let isRecent: Bool
}

/// A command as it was when the palette opened: the registry is read once per show, never per keystroke.
private struct PaletteEntry {
    let id: String
    let displayTitle: String
    let category: String
    let title: String
    let shortcutText: String?
    let isEnabled: Bool
    let isRecent: Bool
}

/// The state of the command palette (⇧⌘P): whether it shows, the query, the ranked rows and the selected row. Owned by
/// the `CommandCenter`. Only `isShowing` is read by the screen; the rows and query are read by the palette view alone.
@MainActor @Observable
final class CommandPaletteModel {
    nonisolated static let rowLimit = 50
    nonisolated static let recentLimit = 5

    private(set) var isShowing = false
    private(set) var query = ""
    private(set) var rows: [PaletteRow] = []
    var selected = 0
    /// With an empty query, the first `recentCount` rows are the recently used ones, under one heading.
    private(set) var recentCount = 0

    @ObservationIgnored private var entries: [PaletteEntry] = []
    @ObservationIgnored private var titles: [String] = []
    /// The recents as they were at show, newest first: every empty-query rank uses this order.
    @ObservationIgnored private var storedRecents: [String] = []
    @ObservationIgnored private weak var registry: CommandRegistry?

    /// The one call that turns a chord into text for the shortcut column. MetalUI has no shortcut display text yet
    /// (gap G1), so there is no column and no substitute formatter: when MetalUI ships one, this is the only line to change.
    nonisolated static func shortcutText(for chord: KeyChord) -> String? { nil }

    func toggle(registry: CommandRegistry, workspace: Workspace) {
        if isShowing { hide() } else { show(registry: registry, workspace: workspace) }
    }

    /// Opens the palette on a snapshot of the registry (enabled flags evaluated now).
    func show(registry: CommandRegistry, workspace: Workspace) {
        self.registry = registry
        let recents = workspace.recentCommands
        let recentSet = Set(recents)
        storedRecents = recents
        let showsDisabled = workspace.settings.paletteShowsDisabled
        entries = registry.commands.compactMap { command in
            let enabled = command.isEnabled()
            if !enabled && !showsDisabled { return nil }
            let d = command.descriptor
            return PaletteEntry(id: d.id, displayTitle: d.displayTitle, category: d.category.name, title: d.title,
                                shortcutText: registry.keymap.chord(for: d.id).flatMap(Self.shortcutText(for:)),
                                isEnabled: enabled, isRecent: recentSet.contains(d.id))
        }
        titles = entries.map(\.displayTitle)
        query = ""
        selected = 0
        isShowing = true
        rank()
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        query = ""
        rows = []
        entries = []
        titles = []
        storedRecents = []
        recentCount = 0
        selected = 0
    }

    func setQuery(_ new: String) {
        guard isShowing, new != query else { return }
        query = new
        selected = 0
        rank()
    }

    /// Moves over every row, disabled ones included; stops at both ends.
    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + step, 0), rows.count - 1)
    }

    /// Return: runs the selected row.
    func submit() {
        guard rows.indices.contains(selected) else { hide(); return }
        run(row: selected)
    }

    /// Closes the palette, then runs the row's command through the registry, which looks the id up again and re-checks
    /// that it is still there and enabled (a stale row just closes the palette).
    func run(row index: Int) {
        guard rows.indices.contains(index) else { hide(); return }
        let id = rows[index].id
        let registry = registry
        hide()
        registry?.run(id: id)
    }

    private func rank() {
        if query.isEmpty {
            rankEmpty(recents: storedRecents)
            return
        }
        recentCount = 0
        let entries = entries
        let hits = FuzzyMatch.topIndices(query: query, in: titles, limit: Self.rowLimit) { entries[$0].isRecent ? FuzzyMatch.recentBonus : 0 }
        rows = hits.map { row(entries[$0.index], matched: $0.matched) }
    }

    /// Up to five recents (newest first, unknown ids skipped), then everything else by category and title.
    private func rankEmpty(recents: [String]) {
        var byID: [String: PaletteEntry] = [:]
        for e in entries { byID[e.id] = e }
        var lead: [PaletteEntry] = []
        var seen = Set<String>()
        for id in recents where lead.count < Self.recentLimit {
            if let e = byID[id], seen.insert(id).inserted { lead.append(e) }
        }
        let rest = entries.filter { !seen.contains($0.id) }.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.title < $1.title
        }
        recentCount = lead.count
        rows = Array((lead + rest).prefix(Self.rowLimit)).map { row($0, matched: []) }
    }

    private func row(_ e: PaletteEntry, matched: [Range<Int>]) -> PaletteRow {
        PaletteRow(id: e.id, displayTitle: e.displayTitle, matched: matched, shortcutText: e.shortcutText,
                   isEnabled: e.isEnabled, isRecent: e.isRecent)
    }
}
