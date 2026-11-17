import AlloyCore
import Foundation
import MetalUI

let gitTabFontSize: Double = 12
let gitTabSmallFontSize: Double = 11

/// The four lists of the Git tab, in the order they show.
enum GitSection: String, Equatable {
    case conflicts, staged, changes, untracked

    var title: String {
        switch self {
        case .conflicts: "Conflicts"
        case .staged: "Staged"
        case .changes: "Changes"
        case .untracked: "Untracked"
        }
    }
}

/// One line of the lazy list: a section header or a file.
struct GitListItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case header(GitSection, Int)
        case file(GitFileStatus, GitSection)
    }

    var id: String
    var kind: Kind

    static func items(conflicts: [GitFileStatus], staged: [GitFileStatus], changes: [GitFileStatus],
                      untracked: [GitFileStatus]) -> [GitListItem] {
        var out: [GitListItem] = []
        for (section, files) in [(GitSection.conflicts, conflicts), (.staged, staged), (.changes, changes), (.untracked, untracked)]
        where !files.isEmpty {
            out.append(GitListItem(id: "h-\(section.rawValue)", kind: .header(section, files.count)))
            for file in files { out.append(GitListItem(id: "\(section.rawValue):\(file.path)", kind: .file(file, section))) }
        }
        return out
    }
}

/// The Git sidebar tab: branch header, banners, the lazy file lists and the commit box. It exists only while the Git
/// tab shows, so a project on the Files tab pays nothing for it.
struct GitTab: Component, Equatable {
    let coordinator: GitCoordinator

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitTab")
        let panel = coordinator.panel
        VStack(alignment: .leading, spacing: 0) {
            switch panel.state {
            case .ready:
                GitReadyTab(coordinator: coordinator).equatable()
            case .unknown:
                GitNote(text: "Looking for the repository\u{2026}", id: "git-checking").equatable()
            case .notARepo:
                GitNote(text: "This folder is not a git repository.", id: "git-not-a-repo").equatable()
            case .noGit(let reason):
                GitNote(text: "Git is not available: \(reason).", id: "git-unavailable").equatable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-tab")
    }
}

struct GitNote: Component, Equatable {
    let text: String
    let id: String

    var content: some ElementGroup {
        Text(verbatim: text).font(size: gitTabFontSize).foregroundColor(.mutedInk)
            .padding(inset(12, 10))
            .accessibilityIdentifier(id)
    }
}

/// The tab of a usable repository.
struct GitReadyTab: Component, Equatable {
    let coordinator: GitCoordinator

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitReadyTab")
        let panel = coordinator.panel
        let items = GitListItem.items(conflicts: panel.conflicts, staged: panel.staged, changes: panel.changes,
                                      untracked: panel.untracked)
        VStack(alignment: .leading, spacing: 0) {
            GitHeader(coordinator: coordinator).equatable()
            GitBanners(panel: panel).equatable()
            GitDiscardConfirm(coordinator: coordinator).equatable()
            if items.isEmpty {
                GitNote(text: "No changes", id: "git-clean").equatable()
                Spacer()
            } else {
                ProposalScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.id) { item in
                            GitListRow(coordinator: coordinator, item: item).equatable()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            GitCommitBox(coordinator: coordinator).equatable()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Branch name, ahead and behind (only with an upstream), and the refresh button.
struct GitHeader: Component, Equatable {
    let coordinator: GitCoordinator

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitHeader")
        let panel = coordinator.panel
        HStack(spacing: Pixels(8)) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundColor(.mutedInk)
            Text(verbatim: panel.branch ?? "Detached HEAD").font(size: gitTabFontSize).lineLimit(1)
                .accessibilityIdentifier("git-branch")
            if panel.hasUpstream {
                Text(verbatim: "\u{2191}\(panel.ahead) \u{2193}\(panel.behind)").font(size: gitTabSmallFontSize).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("git-ahead-behind")
            }
            Spacer()
            Button { coordinator.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11)).foregroundColor(.mutedInk).padding(Pixels(3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
            .accessibilityIdentifier("git-refresh")
        }
        .padding(inset(12, 6))
    }
}

/// The operation banner and the "Status timed out" line, each read from its own panel field.
struct GitBanners: Component, Equatable {
    let panel: GitPanelModel

    nonisolated static func == (a: Self, b: Self) -> Bool { a.panel === b.panel }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitBanners")
        VStack(alignment: .leading, spacing: Pixels(2)) {
            if let operation = panel.operation {
                Text(verbatim: Self.title(operation)).font(size: gitTabSmallFontSize).foregroundColor(.warningInk)
                    .accessibilityIdentifier("git-operation-banner")
            }
            if panel.statusTimedOut {
                Text(verbatim: "Status timed out. Press refresh to try again.").font(size: gitTabSmallFontSize).foregroundColor(.warningInk)
                    .accessibilityIdentifier("git-status-timeout")
            }
        }
        .padding(inset(12, 0))
    }

    static func title(_ operation: GitOperation) -> String {
        switch operation {
        case .merge: "Merge in progress"
        case .rebase: "Rebase in progress"
        case .cherryPick: "Cherry-pick in progress"
        }
    }
}

/// The question a Discard asked, above the list.
struct GitDiscardConfirm: Component, Equatable {
    let coordinator: GitCoordinator

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitDiscardConfirm")
        if let pending = coordinator.sidebar.pendingDiscard {
            VStack(alignment: .leading, spacing: Pixels(4)) {
                Text(verbatim: Self.question(pending)).font(size: gitTabSmallFontSize)
                    .accessibilityIdentifier("git-discard-question")
                HStack(spacing: Pixels(8)) {
                    Button(pending.untracked ? "Delete" : "Discard") { coordinator.confirmDiscard() }
                        .accessibilityIdentifier("git-discard-confirm")
                    Button("Cancel") { coordinator.cancelDiscard() }
                        .accessibilityIdentifier("git-discard-cancel")
                }
            }
            .padding(inset(12, 6))
        }
    }

    static func question(_ pending: GitPendingDiscard) -> String {
        pending.untracked
            ? "Delete \(pending.path)? It is not tracked by git and cannot be restored."
            : "Discard the changes to \(pending.path)? They cannot be restored."
    }
}

/// A header or a file row. Equatable, so a refresh that leaves a row alone leaves it alone.
struct GitListRow: Component, Equatable {
    let coordinator: GitCoordinator
    let item: GitListItem

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator && a.item == b.item }

    @ElementBuilder var content: some ElementGroup {
        switch item.kind {
        case .header(let section, let count):
            Text(verbatim: "\(section.title) \(count)").font(size: gitTabSmallFontSize).foregroundColor(.mutedInk)
                .padding(inset(12, 4))
                .accessibilityIdentifier("git-section-\(section.rawValue)")
        case .file(let entry, let section):
            GitFileRow(coordinator: coordinator, entry: entry, section: section).equatable()
        }
    }
}

/// One file: its name (a click opens it), and the buttons of its section.
struct GitFileRow: Component, Equatable {
    let coordinator: GitCoordinator
    let entry: GitFileStatus
    let section: GitSection

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.coordinator === b.coordinator && a.entry == b.entry && a.section == b.section
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitFileRow", tag: entry.path)
        let entry = entry, coordinator = coordinator
        HStack(spacing: Pixels(4)) {
            Button { coordinator.openRow(entry) } label: {
                HStack(spacing: Pixels(6)) {
                    Text(verbatim: Self.title(entry)).font(size: gitTabFontSize).lineLimit(1)
                        .foregroundColor(FileTreeLabel.gitColor(section == .staged ? .added : entry.display))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.title(entry))
            .accessibilityIdentifier("git-open-\(entry.path)")
            if section == .staged {
                iconButton("minus", label: "Unstage", id: "git-unstage-\(entry.path)") { coordinator.unstage(entry) }
            } else {
                if section != .conflicts && !entry.isSubmodule {
                    iconButton("arrow.uturn.backward", label: "Discard", id: "git-discard-\(entry.path)") { coordinator.requestDiscard(entry) }
                }
                iconButton("plus", label: "Stage", id: "git-stage-\(entry.path)") { coordinator.stage(entry) }
            }
        }
        .padding(inset(12, 2))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git-row-\(entry.path)")
    }

    private func iconButton(_ symbol: String, label: String, id: String, action: @escaping @MainActor () -> Void) -> some ElementGroup {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundColor(.mutedInk).padding(Pixels(3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    static func title(_ entry: GitFileStatus) -> String {
        entry.origPath.map { "\($0) \u{2192} \(entry.path)" } ?? entry.path
    }
}

/// The message editor, Commit and Amend, and the last error. Typing re-runs this component and the editor in it, and
/// nothing above.
struct GitCommitBox: Component, Equatable {
    let coordinator: GitCoordinator
    @FocusState var messageFocused: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitCommitBox")
        let sidebar = coordinator.sidebar, panel = coordinator.panel, coordinator = coordinator
        let message = sidebar.message
        let commitBlock = GitCommitRules.blocker(panel: panel, message: message, amend: false)
        let amendBlock = GitCommitRules.blocker(panel: panel, message: message, amend: true)
        let binding = Binding(get: { coordinator.sidebar.message }, set: { coordinator.sidebar.message = $0 })
        VStack(alignment: .leading, spacing: Pixels(6)) {
            GitErrorLine(coordinator: coordinator).equatable()
            TextEditor("Commit message", text: binding)
                .frame(maxWidth: .infinity, minHeight: Pixels(56), maxHeight: Pixels(120))
                .focused($messageFocused)
                .onChange(of: sidebar.focusRequest) { _, _ in messageFocused = true }
                .accessibilityIdentifier("git-commit-message")
            if let hint = commitBlock, panel.operation == .rebase || !message.isEmpty || !panel.staged.isEmpty {
                Text(verbatim: hint).font(size: gitTabSmallFontSize).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("git-commit-hint")
            }
            HStack(spacing: Pixels(8)) {
                Button("Commit") { coordinator.commit(amend: false) }
                    .disabled(commitBlock != nil || sidebar.busy)
                    .accessibilityIdentifier("git-commit")
                Button("Amend") { coordinator.commit(amend: true) }
                    .disabled(amendBlock != nil || sidebar.busy)
                    .accessibilityIdentifier("git-commit-amend")
                Spacer()
            }
        }
        .padding(inset(12, 8))
    }
}

/// git's own message after a failed command, and the stale-lock offer.
struct GitErrorLine: Component, Equatable {
    let coordinator: GitCoordinator

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GitErrorLine")
        let sidebar = coordinator.sidebar
        if let error = coordinator.panel.lastError {
            VStack(alignment: .leading, spacing: Pixels(4)) {
                Text(verbatim: error).font(size: gitTabSmallFontSize).foregroundColor(.errorInk)
                    .accessibilityIdentifier("git-commit-error")
                if sidebar.staleLock {
                    if sidebar.confirmingLock {
                        Text(verbatim: "Remove .git/index.lock? No git command is running in it.").font(size: gitTabSmallFontSize)
                        HStack(spacing: Pixels(8)) {
                            Button("Remove") { coordinator.confirmLockRemoval() }
                                .accessibilityIdentifier("git-remove-lock-confirm")
                            Button("Cancel") { coordinator.cancelLockRemoval() }
                                .accessibilityIdentifier("git-remove-lock-cancel")
                        }
                    } else {
                        Button("Remove stale lock") { coordinator.requestLockRemoval() }
                            .accessibilityIdentifier("git-remove-lock")
                    }
                }
            }
        }
    }
}
