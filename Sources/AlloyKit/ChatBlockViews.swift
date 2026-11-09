import AlloyCore
import AlloyHighlight
import Foundation
import MetalUI

/// Dispatches one block to its view, identified `block-<id>`. `collapsed` drives the chrome of the collapsible
/// kinds (thinking and tool blocks).
struct ChatBlockView: Component {
    let workspace: Workspace
    let session: Session
    let block: ChatBlock
    var collapsed: Binding<Bool>?
    var draft: Binding<CardDraft>?
    /// The transcript's parsed Markdown, shared by the rows.
    let cache: MarkdownCache
    /// The transcript's code-block state.
    var codeState: CodeBlockState = .detached()
    /// Whether the user bubble's "shared" chip is expanded.
    var sharedExpanded: Binding<Bool>?

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: 0) {
            switch block {
            case .user(let id, let text, let images, let state): UserBubble(blockID: id.uuidString, text: text, imageCount: images, state: state,
                                                                  shared: workspace.sharedFiles[id] ?? [], sharedExpanded: sharedExpanded)
            case .assistantText(let id, let text): AssistantText(blockID: id, text: text, cache: cache)
            case .thinking(let id, let text, let tokens): ThinkingRow(id: id, text: text, tokens: tokens, collapsed: collapsed)
            case .tool(let tool): ToolBlockView(workspace: workspace, tool: tool, collapsed: collapsed, codeState: codeState)
            case .permission(let p): PermissionCard(workspace: workspace, sessionID: session.id, block: p)
            case .question(let q): QuestionCard(workspace: workspace, sessionID: session.id, block: q, draft: draft ?? .constant(CardDraft()))
            case .plan(let p): PlanCard(workspace: workspace, sessionID: session.id, block: p, draft: draft ?? .constant(CardDraft()), cache: cache)
            case .notice(_, let kind, let text): NoticeRow(id: block.id, kind: kind, text: text, cache: cache)
            case .sessionMessage(_, let direction, let peer, let peerID, let text):
                SessionMessageRow(blockID: block.id, direction: direction, peer: peer, text: text,
                                  colorIndex: SessionMessageRow.colorIndex(direction, peer: peer, peerID: peerID, sessions: workspace.sessions))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("block-\(block.id)")
    }

    /// Whether a block starts collapsed: thinking once text follows it in the transcript; read, search, web, todo
    /// and mcp tool blocks always. Edit, write, shell and the rest start expanded. `nil` for blocks with no chrome toggle.
    static func defaultCollapsed(_ block: ChatBlock, textFollows: Bool) -> Bool? {
        switch block {
        case .thinking: return textFollows
        case .tool(let t):
            switch t.kind {
            case .read, .search, .web, .todo, .mcp: return true
            default: return false
            }
        default: return nil
        }
    }
}

struct UserBubble: Component {
    let blockID: String
    let text: String
    var imageCount = 0
    var state: UserState = .sent
    /// What Alloy added to the message about files other sessions already read.
    var shared: [SharedFile] = []
    var sharedExpanded: Binding<Bool>?

    /// "shared: 3 files"; nil without any.
    static func sharedCaption(_ count: Int) -> String? {
        count > 0 ? "shared: \(count) \(count == 1 ? "file" : "files")" : nil
    }

    /// "1 image", "3 images"; nil without images, so an image-only message is not an empty bubble.
    static func imageCaption(_ count: Int) -> String? {
        count > 0 ? (count == 1 ? "1 image" : "\(count) images") : nil
    }

    /// What a message still waiting behind a running turn says: a `later` one is "Queued", a `next` one "Steering".
    static func stateLabel(_ state: UserState) -> String? {
        switch state {
        case .sent: nil
        case .queued(.later): "Queued"
        case .queued(.next): "Steering"
        case .queued: nil
        }
    }

    var content: some ElementGroup {
        HStack(spacing: 0) {
            Spacer(minLength: Pixels(60))
            VStack(alignment: .leading, spacing: Pixels(4)) {
                if !text.isEmpty { Text(text).font(size: 13) }
                if let caption = Self.imageCaption(imageCount) {
                    Text(caption).font(size: 12).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("user-images-\(blockID)")
                }
                if let caption = Self.sharedCaption(shared.count) {
                    // A real button: keyboard and VoiceOver reach it.
                    Button { sharedExpanded?.wrappedValue.toggle() } label: {
                        Text(caption).font(size: 11).foregroundColor(.mutedInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("user-shared-\(blockID)")
                    if sharedExpanded?.wrappedValue == true {
                        Text(verbatim: AlreadyRead.text(lines: shared.map(\.line))).font(size: 11).foregroundColor(.mutedInk)
                            .accessibilityIdentifier("user-shared-detail-\(blockID)")
                    }
                }
                if let label = Self.stateLabel(state) {
                    Text(label).font(size: 11).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("user-state-\(blockID)")
                }
            }
            .padding(inset(12, 8))
            .background(.sidebarFill)
            .cornerRadius(Pixels(10))
        }
    }
}

struct AssistantText: Component {
    let blockID: String
    let text: String
    let cache: MarkdownCache
    var content: some ElementGroup {
        MarkdownText(blockID: blockID, text: text, cache: cache)
    }
}

struct ThinkingRow: Component {
    let id: String
    let text: String
    let tokens: Int
    let collapsed: Binding<Bool>?
    var content: some ElementGroup {
        BlockChrome(kind: .thinking, title: "Thinking", summary: "\(tokens) tokens", collapsed: collapsed, id: id) {
            if !text.isEmpty {
                Text(verbatim: text).font(size: 12).italic().foregroundColor(.mutedInk)
            }
        }
    }
}

/// A message between sessions: "From <name>" in the receiver's chat, "To <name>" in the sender's. A stripe in the
/// other session's colour marks who it is; Alloy's own messages and unknown senders get a neutral stripe.
struct SessionMessageRow: Component {
    let blockID: String
    let direction: SessionMessageDirection
    let peer: String
    let text: String
    var colorIndex: Int?

    /// The other session's colour: by id, else by name (history knows only the name). Alloy's own rows get none.
    static func colorIndex(_ direction: SessionMessageDirection, peer: String, peerID: UUID?, sessions: [Session]) -> Int? {
        guard direction != .system else { return nil }
        return (sessions.first { $0.id == peerID } ?? sessions.first { $0.name == peer })?.colorIndex
    }

    static func title(_ direction: SessionMessageDirection, peer: String) -> String {
        (direction == .to ? "To " : "From ") + peer
    }

    var content: some ElementGroup {
        let style = BlockStyle.style(.sessionMessage)
        HStack(spacing: 0) {
            Rectangle().fill(colorIndex.map { Color.sessionColor($0) } ?? style.ink)
                .frame(width: Pixels(4))
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("session-message-stripe-\(blockID)")
            VStack(alignment: .leading, spacing: Pixels(4)) {
                HStack(spacing: Pixels(6)) {
                    Image(systemName: style.icon).font(.system(size: 12)).foregroundColor(style.ink).accessibilityHidden(true)
                    Text(verbatim: Self.title(direction, peer: peer)).font(size: 12).foregroundColor(.mutedInk)
                        .accessibilityIdentifier("session-message-title-\(blockID)")
                }
                Text(verbatim: text).font(size: 13)
                    .accessibilityIdentifier("session-message-text-\(blockID)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(inset(10, 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tint)
        .cornerRadius(Pixels(8))
    }
}

struct NoticeRow: Component {
    let id: String
    let kind: NoticeKind
    let text: String
    let cache: MarkdownCache
    var content: some ElementGroup {
        let blockKind: BlockKind = switch kind {
        case .exited, .error: .error
        case .warning: .overlap
        case .commandOutput: .command
        default: .notice
        }
        if kind == .commandOutput {
            BlockChrome(kind: blockKind, title: "Command output", id: id) {
                MarkdownText(blockID: id, text: text, cache: cache)
            }
        } else {
            BlockChrome(kind: blockKind, title: text, id: id) { Spacer(minLength: 0).frame(height: 0) }
        }
    }
}

struct PermissionCard: Component {
    let workspace: Workspace
    let sessionID: Session.ID
    let block: PermissionBlock

    var content: some ElementGroup {
        let workspace = workspace, sessionID = sessionID, requestID = block.requestID
        BlockChrome(kind: .overlap, title: "Claude wants to use \(block.toolName)", id: "perm-\(requestID)") {
            Text(verbatim: block.summary).font(family: "Menlo", size: 12)
            switch block.state {
            case .pending:
                HStack(spacing: Pixels(8)) {
                    Button("Approve") {
                        Task { await workspace.answerPermission(session: sessionID, requestID: requestID, allow: true) }
                    }
                    .accessibilityIdentifier("approve-\(requestID)")
                    Button("Deny") {
                        Task { await workspace.answerPermission(session: sessionID, requestID: requestID, allow: false) }
                    }
                    .accessibilityIdentifier("deny-\(requestID)")
                }
            case .allowed: Text("Allowed").font(size: 12).foregroundColor(.mutedInk)
            case .denied: Text("Denied").font(size: 12).foregroundColor(.mutedInk)
            case .cancelled: Text("Cancelled").font(size: 12).foregroundColor(.mutedInk)
            }
        }
    }
}

/// The chrome title for a tool block: the kind's label and the call's summary.
func kindLabel(_ tool: ToolBlock) -> String {
    switch tool.kind {
    case .read: "Read"
    case .search: "Search"
    case .shell: "Shell"
    case .edit: "Edit"
    case .write: "Write"
    case .web: "Web"
    case .subagent: "Agent"
    case .todo: "Todo"
    case .question: "Ask"
    case .plan: "Plan"
    case .mcp, .other: tool.name
    }
}

func blockKind(_ kind: ToolKind) -> BlockKind {
    switch kind {
    case .read: .read
    case .search: .search
    case .shell: .shell
    case .edit: .edit
    case .write: .write
    case .web: .web
    case .subagent: .subagent
    case .todo: .todo
    case .question: .question
    case .plan: .plan
    case .mcp: .mcp
    case .other: .other
    }
}

func toolStatusWord(_ status: ToolBlock.Status) -> String {
    switch status {
    case .running: "Running"
    case .succeeded: "Done"
    case .failed: "Failed"
    case .denied: "Denied"
    case .interrupted: "Interrupted"
    }
}

struct ToolBlockView: Component {
    let workspace: Workspace
    let tool: ToolBlock
    var collapsed: Binding<Bool>?
    var codeState: CodeBlockState = .detached()
    @State var showPrompt = false

    /// The project-relative file a read, edit or write block names (its title then opens the file).
    static func openablePath(_ tool: ToolBlock, root: URL) -> String? {
        guard tool.kind == .read || tool.kind == .edit || tool.kind == .write,
              let file = tool.input["file_path"]?.stringValue, !file.isEmpty else { return nil }
        // Only files inside the project open: a path outside would leave a junk tab with an error message.
        let standardRoot = root.standardizedFileURL.path
        let url = URL(fileURLWithPath: file).standardizedFileURL
        guard url.path.hasPrefix(standardRoot.hasSuffix("/") ? standardRoot : standardRoot + "/") else { return nil }
        return ToolSummary.relativePath(file, root: root)
    }

    /// Where a read starts, when the call said so; an edit's line comes from its first edit instead.
    static func firstLine(_ tool: ToolBlock) -> Int? {
        tool.kind == .read ? tool.input["offset"]?.intValue : nil
    }

    var content: some ElementGroup {
        let workspace = workspace, tool = tool
        let openFile: ((Int?) -> Void)? = Self.openablePath(tool, root: workspace.projectRoot).map { path in
            { line in workspace.requestOpen(path, line: line) }
        }
        BlockChrome(kind: ToolBodies.chromeKind(tool), title: ToolBodies.title(tool), trailing: ToolBodies.trailing(for: tool),
                    collapsed: collapsed, id: tool.toolUseID,
                    openPath: Self.openablePath(tool, root: workspace.projectRoot).map { path in
                        { workspace.requestOpen(path, edit: tool.editIDs.first, line: Self.firstLine(tool)) }
                    }) {
            if tool.status != .failed && (tool.kind == .edit || tool.kind == .write) {
                DiffSection(workspace: workspace, tool: tool, codeState: codeState, openFile: openFile)
            } else {
                ToolBody(tool: tool, root: workspace.projectRoot, codeState: codeState, openFile: openFile, showPrompt: $showPrompt)
            }
        }
    }
}

/// The block's diff lines (read from the model's per-edit slices) and the Keep / Revert controls per edit.
struct DiffSection: Component {
    let workspace: Workspace
    let tool: ToolBlock
    let codeState: CodeBlockState
    var openFile: ((Int?) -> Void)?

    var content: some ElementGroup {
        let ids = Array(tool.editIDs.enumerated())
        VStack(alignment: .leading, spacing: Pixels(4)) {
            ForEach(ids, id: \.element) { index, id in
                EditDiff(workspace: workspace, editID: id, blockID: tool.toolUseID,
                         part: Self.part(tool, index: index), codeState: codeState,
                         openFile: tool.kind == .write ? openFile : nil)
            }
        }
    }

    /// `diff` for an edit, `content` for a write; the second and later edits of one block count on (`diff2`, ...).
    static func part(_ tool: ToolBlock, index: Int) -> String {
        let base = tool.kind == .write ? "content" : "diff"
        return index == 0 ? base : "\(base)\(index + 1)"
    }
}

/// One edit's diff lines and actions.
struct EditDiff: Component {
    let workspace: Workspace
    let editID: UUID
    let blockID: String
    let part: String
    let codeState: CodeBlockState
    var openFile: ((Int?) -> Void)?

    var content: some ElementGroup {
        let diff = workspace.editDiffs[editID] ?? []
        let language = workspace.editRecord(id: editID).flatMap { Language.detect(path: $0.path) }
        let id = "\(blockID)-\(part)"
        VStack(alignment: .leading, spacing: Pixels(4)) {
            if !diff.isEmpty {
                ChatCodeBlock(blockID: blockID, part: part, expanded: codeState.binding(id),
                              item: codeState.store.item(id: id, fingerprint: Self.fingerprint(diff, language)) {
                                  (Self.codeLines(diff), language.map { [OutputSection(lines: 0..<diff.count, language: $0)] } ?? [])
                              },
                              overflow: openFile.map(CodeOverflow.openFile) ?? .count)
            }
            if let record = workspace.editRecord(id: editID) {
                EditActions(workspace: workspace, record: record, conflict: workspace.revertConflicts[editID])
            }
        }
    }

    static func fingerprint(_ diff: [DiffLine], _ language: Language?) -> Int {
        var h = Hasher()
        h.combine(language)
        for line in diff {
            switch line {
            case .context(let t, let n): h.combine(0); h.combine(t); h.combine(n)
            case .added(let t, let n, _, _): h.combine(1); h.combine(t); h.combine(n)
            case .removed(let t, _): h.combine(2); h.combine(t)
            }
        }
        return h.finalize()
    }

    /// Diff lines as code lines: context and added lines carry their file line number, added and removed ones their tint.
    static func codeLines(_ diff: [DiffLine]) -> [CodeLine] {
        diff.map { line in
            switch line {
            case .context(let text, let n): CodeLine(text: text, number: n, mark: " ", tint: nil)
            case .added(let text, let n, _, _): CodeLine(text: text, number: n, mark: "+", tint: .editAddTint)
            case .removed(let text, _): CodeLine(text: text, number: nil, mark: "-", tint: .editRemoveTint)
            }
        }
    }
}

struct EditActions: Component {
    let workspace: Workspace
    let record: EditRecord
    let conflict: String?

    var content: some ElementGroup {
        let workspace = workspace, id = record.id, path = record.path
        HStack(spacing: Pixels(8)) {
            Text(verbatim: record.path).font(size: 11).foregroundColor(.mutedInk)
            Spacer()
            switch record.state {
            case .live:
                Button("Keep") { workspace.keep(edit: id, path: path) }
                    .accessibilityIdentifier("keep-\(id.uuidString)")
                Button("Revert") { Task { _ = await workspace.revertInEditor(edit: id, path: path) } }
                    .accessibilityIdentifier("revert-\(id.uuidString)")
                OpenActions(workspace: workspace, id: id, path: path)
            case .kept:
                Text("Kept").font(size: 11).foregroundColor(.mutedInk)
                OpenActions(workspace: workspace, id: id, path: path)
            case .reverted: Text("Reverted").font(size: 11).foregroundColor(.mutedInk)
            }
        }
        if let conflict {
            Text(verbatim: conflict).font(size: 11)
                .padding(inset(8, 4))
                .background(.warningTint)
                .cornerRadius(Pixels(6))
        }
    }
}

/// "Open in file" and "Side by side" for one edit: open its file at the edit's first line, inline or side by side.
struct OpenActions: Component {
    let workspace: Workspace
    let id: UUID
    let path: String

    var content: some ElementGroup {
        let workspace = workspace, id = id, path = path
        Button("Open in file") { workspace.requestOpen(path, edit: id) }
            .accessibilityIdentifier("open-in-file-\(id.uuidString)")
        Button("Side by side") { workspace.requestOpen(path, edit: id, mode: .sideBySide) }
            .accessibilityIdentifier("side-by-side-\(id.uuidString)")
    }
}
