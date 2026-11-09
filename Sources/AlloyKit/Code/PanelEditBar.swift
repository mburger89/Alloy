import AlloyCore
import Foundation
import MetalUI

/// The strip under the code that acts on the edit whose gutter bar was clicked: who made it and when, then Keep,
/// Revert and Show in chat.
struct PanelEditBar: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let record: EditRecord

    var content: some ElementGroup {
        let workspace = workspace, store = store, record = record
        let id = record.id, path = record.path
        HStack(spacing: Pixels(8)) {
            Circle().fill(authorColor(record.author, sessions: workspace.sessions))
                .frame(width: Pixels(8), height: Pixels(8))
            Text(verbatim: "\(Self.name(of: record.author, in: workspace)) \u{00B7} \(record.date.formatted(date: .omitted, time: .shortened))")
                .font(size: 11).foregroundColor(.mutedInk)
            Spacer()
            Button("Keep") { workspace.keep(edit: id, path: path) }
                .accessibilityIdentifier("panel-keep-\(id.uuidString)")
            Button("Revert") { Task { _ = await workspace.revertInEditor(edit: id, path: path) } }
                .accessibilityIdentifier("panel-revert-\(id.uuidString)")
            Button("Show in chat") { showInChat(record, workspace: workspace, store: store) }
                .accessibilityIdentifier("panel-show-in-chat-\(id.uuidString)")
        }
        .padding(inset(12, 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel-edit-bar")
        if let conflict = workspace.revertConflicts[id] {
            Text(verbatim: conflict).font(size: 11)
                .padding(inset(12, 4))
                .background(.warningTint)
                .accessibilityIdentifier("panel-edit-conflict")
        }
    }

    static func name(of author: Author, in workspace: Workspace) -> String {
        switch author {
        case .session(let id): workspace.sessions.first { $0.id == id }?.name ?? "Session"
        case .user: "You"
        case .outside: "Outside Alloy"
        }
    }
}

/// Selects the session that made `record` and asks its transcript to scroll to the block that shows it. (The chat
/// has no scroll-to mechanism of its own, so the target is held on the session's UI store entry, which
/// `TranscriptView` consumes once the block exists.) Edits by the user or by outside tools have no chat block.
@MainActor
func showInChat(_ record: EditRecord, workspace: Workspace, store: SessionUIStore) {
    guard case .session(let id) = record.author, let session = workspace.sessions.first(where: { $0.id == id }) else { return }
    if let tool = record.toolUseID {
        store.entry(for: session, workspace: workspace).scrollTarget =
            topLevelBlockID(forToolUse: tool, edit: record.id, in: session.transcript.blocks)
    }
    workspace.selectedSessionID = id
}

/// The id of the top-level block to scroll to for an edit made by tool call `toolUseID`: that call's own block, or
/// (for a call nested in a subagent, which has no block of its own) the block that holds the edit.
func topLevelBlockID(forToolUse toolUseID: String, edit: UUID, in blocks: [ChatBlock]) -> String {
    if blocks.contains(where: { $0.id == toolUseID }) { return toolUseID }
    for case .tool(let tool) in blocks where tool.editIDs.contains(edit) { return tool.toolUseID }
    return toolUseID
}
