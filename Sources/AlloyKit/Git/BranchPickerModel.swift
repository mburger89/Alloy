import AlloyCore
import Foundation
import Observation

/// The branch picker and the new-branch field: one model, shown by the same host that shows Quick Open. It ranks local
/// branch names with `FuzzyMatch`; Return switches to the top or selected row. In create mode the field takes a name and
/// Return creates and switches. Git's own refusal shows in `error`.
@MainActor @Observable
final class BranchPickerModel: RowSource {
    nonisolated static let recentLimit = 8
    nonisolated static let rowLimit = 50

    enum Mode { case switchTo, create }

    private(set) var isShowing = false
    private(set) var mode: Mode = .switchTo
    var query = ""
    private(set) var rows: [String] = []
    var selected = 0
    var error: String?
    /// The branches the menu offers (most recent first, not the current one); read when the menu opens.
    private(set) var recent: [String] = []
    /// Whether the title menu is open (its binding).
    var menuOpen = false
    @ObservationIgnored var loadingMenu = false
    /// Every local branch, most recent first.
    @ObservationIgnored private(set) var all: [String] = []
    @ObservationIgnored var onSwitch: ((String) -> Void)?
    @ObservationIgnored var onCreate: ((String) -> Void)?

    var placeholder: String { mode == .create ? "New branch name" : "Switch to branch" }
    var fieldID: String { mode == .create ? "git-branch-name" : "git-branch-picker-field" }
    var rowPrefix: String { "branch-row" }
    var panelID: String { "git-branch-panel" }
    var listID: String { "git-branch-list" }
    var errorID: String { "git-branch-error" }

    func setBranches(_ branches: [GitBranch]) {
        all = branches.map(\.name)
        recent = Array(branches.filter { !$0.isCurrent }.prefix(Self.recentLimit).map(\.name))
        if isShowing, mode == .switchTo { rank() }
    }

    func showPicker() {
        mode = .switchTo
        open()
    }

    func showNewBranch() {
        mode = .create
        open()
    }

    /// An error with no field to type in (a refused switch from the menu) opens the panel in switch mode to show it.
    func showError(_ message: String) {
        if !isShowing { showPicker() }
        error = message
    }

    private func open() {
        isShowing = true
        query = ""
        selected = 0
        error = nil
        rank()
    }

    func hide() {
        guard isShowing || error != nil else { return }
        isShowing = false
        error = nil
        rows = []
    }

    func setQuery(_ new: String) {
        guard new != query else { return }
        query = new
        error = nil
        rank()
    }

    func move(_ step: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + step, 0), rows.count - 1)
    }

    func submit() {
        switch mode {
        case .create: onCreate?(query.trimmingCharacters(in: .whitespaces))
        case .switchTo: pick(selected)
        }
    }

    func pick(_ index: Int) {
        guard mode == .switchTo, rows.indices.contains(index) else { return }
        onSwitch?(rows[index])
    }

    private func rank() {
        guard mode == .switchTo else { rows = []; return }
        let q = query.trimmingCharacters(in: .whitespaces)
        rows = q.isEmpty ? Array(all.prefix(Self.rowLimit)) : FuzzyMatch.top(q, in: all, limit: Self.rowLimit)
        selected = 0
    }
}
