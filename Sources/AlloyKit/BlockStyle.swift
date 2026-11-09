import MetalUI

/// What a transcript block is, for colour and icon. One entry per row kind of the chat.
enum BlockKind: CaseIterable {
    case thinking, read, search, shell, edit, write, web, subagent, todo, question, plan, mcp, other
    case error, overlap, notice, command, user
}

/// The tint behind a block, the ink its header icon draws in, and its SF Symbol name.
struct BlockStyle {
    var tint: Color
    var ink: Color
    var icon: String

    // `checklist`, `questionmark.bubble`, `list.bullet.clipboard`, `puzzlepiece.extension` and `info.circle`
    // are outside MetalUI's bundled icon set: they draw on macOS only (docs/metalui-gaps.md, G3).
    static func style(_ kind: BlockKind) -> BlockStyle {
        switch kind {
        case .thinking: BlockStyle(tint: .thinkingTint, ink: .thinkingInk, icon: "brain.head.profile")
        case .read: BlockStyle(tint: .readTint, ink: .readInk, icon: "doc.text")
        case .search: BlockStyle(tint: .readTint, ink: .readInk, icon: "magnifyingglass")
        case .shell: BlockStyle(tint: .shellTint, ink: .shellInk, icon: "terminal")
        case .edit: BlockStyle(tint: .editAddTint, ink: .editInk, icon: "pencil")
        case .write: BlockStyle(tint: .editAddTint, ink: .editInk, icon: "doc.badge.plus")
        case .web: BlockStyle(tint: .webTint, ink: .webInk, icon: "globe")
        case .subagent: BlockStyle(tint: .panelFill, ink: .planInk, icon: "cpu")
        case .todo: BlockStyle(tint: .panelFill, ink: .editInk, icon: "checklist")
        case .question: BlockStyle(tint: .questionTint, ink: .questionInk, icon: "questionmark.bubble")
        case .plan: BlockStyle(tint: .planTint, ink: .planInk, icon: "list.bullet.clipboard")
        case .mcp: BlockStyle(tint: .panelFill, ink: .readInk, icon: "puzzlepiece.extension")
        case .other: BlockStyle(tint: .panelFill, ink: .mutedInk, icon: "sparkles")
        case .error: BlockStyle(tint: .errorTint, ink: .errorInk, icon: "xmark.circle")
        case .overlap: BlockStyle(tint: .warningTint, ink: .warningInk, icon: "exclamationmark.triangle")
        case .notice: BlockStyle(tint: .panelFill, ink: .mutedInk, icon: "info.circle")
        case .command: BlockStyle(tint: .commandTint, ink: .mutedInk, icon: "chevron.right")
        case .user: BlockStyle(tint: .sidebarFill, ink: .mutedInk, icon: "person")
        }
    }

    init(tint: Color, ink: Color, icon: String) { self.tint = tint; self.ink = ink; self.icon = icon }
}
