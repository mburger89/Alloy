import AlloyCore
import Foundation
import MetalUI

/// Sessions list, New session button, changed files and any workspace errors.
struct SidebarView: Component {
    let workspace: Workspace
    @Binding var showSettings: Bool

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SectionHeader(title: "Sessions")
                Spacer()
                Button {
                    let n = workspace.sessions.count + 1
                    Task { await workspace.newSession(name: "Session \(n)") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13)).padding(Pixels(4))
                }
                .buttonStyle(.plain)
                .help("New session")
                .accessibilityLabel("New session")
                .keyboardShortcut("n")
                .accessibilityIdentifier("new-session")
                .padding(inset(6, 0))
            }
            ScrollView {
                List(workspace.sessions, selection: selection, rowHeight: Pixels(62)) { session in
                    // The List's tint is the selection fill; controls inside the row (the rename field) keep the accent.
                    Column { SessionRow(workspace: workspace, session: session) }.tint(Color(ColorToken.accent))
                }
                .tint(.sessionSelection)   // MetalUI fills the selected row in the tint, else the accent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            KnowledgeStats(workspace: workspace)
            SettingsButton(workspace: workspace, showSettings: $showSettings)
            Divider()
            ChangedFilesSection(workspace: workspace)
            if !workspace.errors.isEmpty {
                ErrorList(errors: workspace.errors)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.sidebarFill)
    }

    private var selection: Binding<Session.ID?> {
        let workspace = workspace
        return Binding(get: { workspace.selectedSessionID }, set: { workspace.selectedSessionID = $0 })
    }
}

struct SectionHeader: Component {
    let title: String
    var content: some ElementGroup {
        Text(title.uppercased()).font(size: 10).foregroundColor(.mutedInk)
            .accessibilityIdentifier("section-header-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            .padding(inset(10, 6))
    }
}

/// The word shown for a session's status.
func statusWord(_ status: SessionStatus) -> String {
    switch status {
    case .dormant: "Paused"
    case .starting: "Starting"
    case .idle: "Idle"
    case .working: "Working"
    case .awaitingPermission: "Needs approval"
    case .exited: "Exited"
    case .failedToLaunch: "Can't start"
    }
}

/// "Opus" for "claude-opus-5-5"; the raw name when no known family is in it.
func modelShortName(_ model: String) -> String {
    let lower = model.lowercased()
    for family in ["opus", "sonnet", "haiku"] where lower.contains(family) { return family.capitalized }
    return model
}

/// "850 tok" below a thousand, "12.3k tok" from there.
func tokenText(_ count: Int) -> String {
    count < 1000 ? "\(count) tok" : String(format: "%.1fk tok", Double(count) / 1000)
}

/// The mode's display name, or nil for the default mode (and for modes this build does not know).
func modeBadge(_ mode: String?) -> String? {
    guard let mode, let m = PermissionMode(rawValue: mode), m != .default_ else { return nil }
    return m.displayName
}

struct SessionRow: Component {
    let workspace: Workspace
    let session: Session
    @State var renaming = false
    @State var draft = ""
    @FocusState var renameFocused: Bool

    var content: some ElementGroup {
        let id = session.id
        HStack(spacing: Pixels(8)) {
            Circle().fill(Color.sessionColor(session.colorIndex)).frame(width: Pixels(10), height: Pixels(10))
            VStack(alignment: .leading, spacing: Pixels(1)) {
                if renaming {
                    TextField("Name", text: $draft)
                        .onSubmit { commit() }
                        .focused($renameFocused)
                        .onAppear { renameFocused = true }
                        .onChange(of: renameFocused) { old, new in if old && !new { commit() } }
                        .onKeyPress(.escape) { renaming = false; return .handled }
                        .accessibilityIdentifier("rename-\(id.uuidString)")
                } else {
                    Text(session.name).font(size: 13)
                        .onTapGesture(count: 2) { draft = session.name; renaming = true }
                        .accessibilityIdentifier("session-name-\(id.uuidString)")
                }
                HStack(spacing: Pixels(6)) {
                    Text(statusWord(session.status)).font(size: 11).foregroundColor(.mutedInk)
                    Text(String(format: "$%.2f", session.costUSD)).font(size: 11).foregroundColor(.mutedInk)
                    Text(tokenText(session.totalTokens)).font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("session-tokens-\(id.uuidString)")
                }
                HStack(spacing: Pixels(6)) {
                    if let model = session.model {
                        Text(modelShortName(model)).font(size: 11).foregroundColor(.mutedInk)
                            .accessibilityIdentifier("session-model-\(id.uuidString)")
                    }
                    if session.redundantReads > 0, workspace.settings.shareKnowledge {
                        Text("\(session.redundantReads) re-reads").font(size: 11).foregroundColor(.mutedInk)
                            .accessibilityIdentifier("session-rereads-\(id.uuidString)")
                    }
                    if let badge = modeBadge(session.permissionMode) {
                        Text(badge).font(size: 10).foregroundColor(.mutedInk)
                            .padding(inset(5, 1))
                            .background(Color.sessionColor(session.colorIndex).opacity(0.15))
                            .accessibilityIdentifier("session-mode-\(id.uuidString)")
                    }
                }
            }
            Spacer()
            // Menu items cannot carry identifiers or tooltips (G24): tests choose them by title, and the reason
            // Fork is unavailable is a disabled item of its own.
            Menu {
                Button("Fork") { Task { await workspace.fork(id, name: nil) } }
                    .disabled(!session.hasConversation)
                if !session.hasConversation { Text("Nothing to fork yet") }
                Button("Rename") { draft = session.name; renaming = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12)).foregroundColor(.mutedInk)
            }
            .accessibilityLabel("Session menu")
            .accessibilityIdentifier("session-menu-\(id.uuidString)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(10, 4))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session-row-\(id.uuidString)")
        .accessibilityLabel(session.name)
    }

    private func commit() {
        guard renaming else { return }
        workspace.rename(session.id, to: draft)
        renaming = false
    }
}

/// The shared-knowledge totals since Alloy started (they are not saved, so a restart begins again at zero), quiet:
/// how many times the notes gave an answer, and how many reads repeated what a session or a note already held.
/// Shown only while sharing is on; with it off nothing is collected that the user could act on.
struct KnowledgeStats: Component {
    let workspace: Workspace

    var content: some ElementGroup {
        if workspace.settings.shareKnowledge {
            Text("Notes used \(workspace.notesServed)\u{00D7} \u{00B7} \(workspace.redundantReads) repeat reads")
                .font(size: 11).foregroundColor(.mutedInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(inset(10, 2))
                .accessibilityIdentifier("knowledge-stats")
        }
    }
}

struct ChangedFilesSection: Component {
    let workspace: Workspace

    var content: some ElementGroup {
        let files = workspace.changedFiles
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Changed files")
            if files.isEmpty {
                Text("No changes yet").font(size: 12).foregroundColor(.mutedInk).padding(inset(10, 4))
            }
            ForEach(files, id: \.path) { file in
                ChangedFileRow(workspace: workspace, file: file)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Edges(top: 0, right: 0, bottom: Pixels(8), left: 0))
    }
}

struct ChangedFileRow: Component {
    let workspace: Workspace
    let file: ChangedFile

    var content: some ElementGroup {
        HStack(spacing: Pixels(4)) {
            ForEach(Array(file.authors.enumerated()), id: \.offset) { index, author in
                Circle().fill(color(for: author)).frame(width: Pixels(8), height: Pixels(8))
                    .accessibilityIdentifier("author-dot-\(index)")
            }
            Text(file.path).font(size: 12)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(10, 3))
        .background(workspace.activeTab == file.path ? Color.sessionColor(0).opacity(0.12) : Color.clear)
        .onTapGesture { workspace.requestOpen(file.path) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("changed-file-\(file.path)")
    }

    private func color(for author: Author) -> Color { authorColor(author, sessions: workspace.sessions) }
}

/// The colour that marks an author: the session's hue, or a fixed one for the user and for outside edits.
@MainActor func authorColor(_ author: Author, sessions: [Session]) -> Color {
    switch author {
    case .session(let id): Color.sessionColor(sessions.first { $0.id == id }?.colorIndex ?? 0)
    case .user: .userAuthor
    case .outside: .outsideAuthor
    }
}

struct ErrorList: Component {
    let errors: [String]

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Pixels(4)) {
            ForEach(Array(errors.enumerated()), id: \.offset) { _, message in
                Text(message).font(size: 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(inset(8, 4))
                    .background(.warningTint)
            }
        }
        .padding(inset(8, 8))
        .accessibilityIdentifier("workspace-errors")
    }
}
