import AlloyCore
import Foundation
import MetalUI

/// The middle pane: the selected session's transcript above its composer, or a hint when none is selected.
struct ChatView: Component {
    let workspace: Workspace
    let store: SessionUIStore

    var content: some ElementGroup {
        let _ = BodyProbe.hit("ChatView")
        if let session = workspace.sessions.first(where: { $0.id == workspace.selectedSessionID }) {
            ChatColumn(workspace: workspace, session: session, ui: store.entry(for: session, workspace: workspace))
                .equatable()
                .id(session.id.uuidString)
        } else {
            Text("Start a session with ⌘N").foregroundColor(.mutedInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.chatFill)
        }
    }
}

/// One session's chat: a 4 px stripe in the session colour, then transcript and composer.
struct ChatColumn: Component {
    let workspace: Workspace
    let session: Session
    let ui: SessionUIStore.Entry

    var content: some ElementGroup {
        let _ = BodyProbe.hit("ChatColumn")
        HStack(spacing: 0) {
            Rectangle().fill(Color.sessionColor(session.colorIndex))
                .frame(width: Pixels(4))
                .frame(maxHeight: .infinity)
            VStack(spacing: 0) {
                TranscriptView(workspace: workspace, session: session, ui: ui)
                Divider()
                ComposerView(workspace: workspace, session: session, model: ui.composer)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.chatFill)
    }
}

struct ScrollRequest: Equatable { var target: String?; var blockCount: Int }

/// The scrolling block list, pinned to the bottom with `defaultScrollAnchor(.bottom)` (MetalUI G6). A block's
/// collapse is kept in the session's UI entry by block id, so it survives re-render and a session switch; blocks the user has not toggled use
/// `ChatBlockView.defaultCollapsed`.
struct TranscriptView: Component {
    let workspace: Workspace
    let session: Session
    /// Collapse overrides, unsent card drafts (held here, not in the lazy rows, because a row's own `@State` is dropped
    /// after it stays off screen long enough: MetalUI LazyStack / StateTable) and the parsed Markdown. They live in the
    /// session's ``SessionUIStore`` entry, which outlives this column.
    let ui: SessionUIStore.Entry

    var content: some ElementGroup {
        let blocks = session.transcript.blocks
        let defaults = Self.defaults(blocks)
        let ui = ui
        let overrides = Binding(get: { ui.overrides }, set: { ui.overrides = $0 })
        let codeState = CodeBlockState(expanded: Binding(get: { ui.codeExpanded }, set: { ui.codeExpanded = $0 }), store: ui.codeBlocks)
        let drafts = Binding(get: { ui.drafts }, set: { ui.drafts = $0 })
        let cache = ui.markdownCache
        let _ = ui.codeBlocks.prune(keepingBlockIDs: Set(blocks.map(\.id)))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Pixels(10)) {
                    ForEach(blocks, id: \.id) { block in
                        ChatBlockView(workspace: workspace, session: session, block: block,
                                      collapsed: Self.binding(for: block.id, default: defaults[block.id], overrides: overrides),
                                      draft: Self.draftBinding(for: block, drafts: drafts), cache: cache,
                                      codeState: codeState,
                                      sharedExpanded: Self.sharedBinding(for: block, overrides: overrides))
                    }
                }
                .padding(inset(16, 12))
            }
            .defaultScrollAnchor(.bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: ScrollRequest(target: ui.scrollTarget, blockCount: blocks.count), initial: true) {
                switch Self.scrollDecision(target: ui.scrollTarget, blocks: blocks,
                                           historyPending: workspace.isHistoryPending(session.id)) {
                case .scroll(let id): ui.scrollTarget = nil; proxy.scrollTo(id, anchor: .center)
                case .drop: ui.scrollTarget = nil
                case .keep: break
                }
            }
        }
    }

    enum ScrollDecision: Equatable { case scroll(String), keep, drop }

    /// What to do with a "Show in chat" target: scroll once its block exists, keep it while the session's earlier
    /// conversation is still loading (the block may arrive), else drop it.
    static func scrollDecision(target: String?, blocks: [ChatBlock], historyPending: Bool) -> ScrollDecision {
        guard let target else { return .drop }
        if blocks.contains(where: { $0.id == target }) { return .scroll(target) }
        return historyPending ? .keep : .drop
    }

    /// The draft binding of a question or plan block (nil for other blocks). It writes only the drafted key; drafts of
    /// cards that are no longer pending stay behind, which is fine: they are tiny and request ids are never reused.
    static func draftBinding(for block: ChatBlock, drafts: Binding<[String: CardDraft]>) -> Binding<CardDraft>? {
        switch block {
        case .question(let q): draftBinding(requestID: q.requestID, drafts: drafts)
        case .plan(let p): draftBinding(requestID: p.requestID, drafts: drafts)
        default: nil
        }
    }

    static func draftBinding(requestID: String, drafts: Binding<[String: CardDraft]>) -> Binding<CardDraft> {
        Binding(get: { drafts.wrappedValue[requestID] ?? CardDraft() }, set: { drafts.wrappedValue[requestID] = $0 })
    }

    /// Each collapsible block's default collapse; a thinking block collapses once assistant text follows it.
    static func defaults(_ blocks: [ChatBlock]) -> [String: Bool] {
        var out: [String: Bool] = [:]
        var textFollows = false
        for block in blocks.reversed() {
            if let d = ChatBlockView.defaultCollapsed(block, textFollows: textFollows) { out[block.id] = d }
            if case .assistantText = block { textFollows = true }
        }
        return out
    }

    /// The expand state of a user bubble's "shared" chip, kept beside the collapse overrides under `shared-<id>`.
    static func sharedBinding(for block: ChatBlock, overrides: Binding<[String: Bool]>) -> Binding<Bool>? {
        guard case .user = block else { return nil }
        let key = "shared-\(block.id)"
        return Binding(get: { overrides.wrappedValue[key] ?? false }, set: { overrides.wrappedValue[key] = $0 })
    }

    private static func binding(for id: String, default value: Bool?, overrides: Binding<[String: Bool]>) -> Binding<Bool>? {
        guard let value else { return nil }
        return Binding(get: { overrides.wrappedValue[id] ?? value }, set: { overrides.wrappedValue[id] = $0 })
    }
}
