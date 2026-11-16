import AlloyCore
import Foundation
import MetalUI

/// The collapsed strip's width, in gutters.
let codeChatStripGutters = 4
/// The dot's diameter.
let codeStatusDotSize = Pixels(8)
/// The session header's gap between its items, the session name's and the icon's font size, the collapse button's
/// padding and the header's inset (x, y).
let codeSessionHeaderSpacing = Pixels(8)
let codeSessionHeaderFontSize: Double = 13
let codeSessionHeaderButtonPadding = Pixels(4)
let codeSessionHeaderInset = (x: Float(10), y: Float(6))

/// The strip's width: a fixed multiple of the island gutter.
func codeChatStripWidth(_ style: AppearanceStyle) -> Double { style.gutter * Double(codeChatStripGutters) }

/// A session's status as a theme colour (read from `status` alone: the transcript changes on every streamed chunk): needs approval warns, work runs in the accent, a dead process errs, the rest is quiet.
@MainActor func statusDotColor(_ session: Session) -> Color {
    switch session.status {
    case .awaitingPermission: return .warningInk
    case .working, .starting: return Color(ColorToken.accent)
    case .exited, .failedToLaunch: return .errorInk
    case .idle, .dormant: return .mutedInk
    }
}

/// Code mode's chat column: the session menu over the shared chat body (theme bar, coordination warnings, chat, composer).
struct CodeChatColumn: Component, Equatable {
    let workspace: Workspace
    let store: SessionUIStore
    var themes: ThemeController?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.store === b.store && a.themes === b.themes }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CodeChatColumn")
        VStack(spacing: 0) {
            SessionMenuHeader(workspace: workspace).equatable()
            ChatIslandBody(workspace: workspace, store: store, themes: themes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The column's top row: the current session's dot, the session menu and the collapse button.
struct SessionMenuHeader: Component, Equatable {
    let workspace: Workspace

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("SessionMenuHeader")
        let workspace = workspace
        let current = workspace.sessions.first { $0.id == workspace.selectedSessionID }
        HStack(spacing: codeSessionHeaderSpacing) {
            if let current {
                Circle().fill(statusDotColor(current)).frame(width: codeStatusDotSize, height: codeStatusDotSize)
                    .accessibilityLabel(statusWord(current.status))
                    .accessibilityIdentifier("code-session-status")
            }
            // Menu items cannot carry an image yet, so each shows its status word.
            Menu {
                for session in workspace.sessions {
                    Button("\(session.name) \u{2014} \(statusWord(session.status))") { workspace.selectedSessionID = session.id }
                        .accessibilityIdentifier("code-session-\(session.id.uuidString)")
                }
                Divider()
                Button("New Session") { workspace.startNewSession() }
                    .accessibilityIdentifier("code-session-new")
            } label: {
                Text(verbatim: current?.name ?? "Sessions").font(size: codeSessionHeaderFontSize).lineLimit(1)
            }
            .accessibilityIdentifier("code-session-menu")
            Spacer()
            Button {
                workspace.codeLayout.chatCollapsed = true
            } label: {
                Image(systemName: "sidebar.right").font(.system(size: codeSessionHeaderFontSize)).foregroundColor(.mutedInk).padding(codeSessionHeaderButtonPadding)
            }
            .buttonStyle(.plain)
            .help("Collapse chat")
            .accessibilityLabel("Collapse chat")
            .accessibilityIdentifier("code-chat-collapse")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(inset(codeSessionHeaderInset.x, codeSessionHeaderInset.y))
    }
}

/// The folded chat column: a thin strip at the window edge with the current session's dot. The whole strip expands the
/// column; it never opens itself.
struct CollapsedChatStrip: Component, Equatable {
    let workspace: Workspace
    let style: AppearanceStyle

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace && a.style == b.style }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CollapsedChatStrip")
        let workspace = workspace
        let current = workspace.sessions.first { $0.id == workspace.selectedSessionID }
        // One element: the status is in the button's label and the dot is decoration.
        Button {
            workspace.codeLayout.chatCollapsed = false
        } label: {
            VStack(spacing: 0) {
                if let current {
                    Circle().fill(statusDotColor(current)).frame(width: codeStatusDotSize, height: codeStatusDotSize)
                        .padding(Pixels(Float(style.gutter)))
                        .accessibilityHidden(true)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .help("Expand chat")
        .accessibilityLabel(current.map { "Expand chat, \(statusWord($0.status))" } ?? "Expand chat")
        .accessibilityIdentifier("code-chat-expand")
        .island(style: style, identifier: "island-code-chat-strip")
        .frame(width: Pixels(Float(codeChatStripWidth(style))))
    }
}
