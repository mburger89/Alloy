import AlloyCore
import Foundation
import MetalUI

let codeSidebarWidths = (min: Pixels(180), ideal: Pixels(240), max: Pixels(420))
let codeChatWidths = (min: Pixels(280), ideal: Pixels(340), max: Pixels(560))
let codeEditorMinWidth = Pixels(320)
/// The reserved bottom panel: no view and no space until a later feature turns it on.
let codeBottomPanelVisible = false

/// Code mode's island row: sidebar | editor area | chat column, with resizable gutters.
struct CodeIslandRow: Component, Equatable {
    let workspace: Workspace
    let store: SessionUIStore
    let panel: CodePanelStore
    let quickOpen: QuickOpenModel
    let splitStore: UIStateSplitStore
    var themes: ThemeController?
    let style: AppearanceStyle

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.store === b.store && a.panel === b.panel && a.quickOpen === b.quickOpen
            && a.splitStore === b.splitStore && a.themes === b.themes && a.style == b.style
    }

    private func sidebarIsland() -> some ElementGroup {
        CodeSidebarView(workspace: workspace).equatable()
            .island(style: style, identifier: "island-code-sidebar")
            .frame(minWidth: codeSidebarWidths.min, idealWidth: codeSidebarWidths.ideal, maxWidth: codeSidebarWidths.max)
    }

    private func editorIsland() -> some ElementGroup {
        VStack(spacing: 0) {
            EditorAreaView(workspace: workspace, store: store, panel: panel, quickOpen: quickOpen, splitStore: splitStore,
                           themes: themes, style: style).equatable()
            if codeBottomPanelVisible { Color.clear.accessibilityIdentifier("code-bottom-panel") }
        }
        .island(style: style, identifier: "island-code-editor")
        .frame(minWidth: codeEditorMinWidth, maxWidth: .infinity)
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CodeIslandRow")
        let gutter = Pixels(Float(style.gutter))
        let workspace = workspace, store = store, themes = themes
        if workspace.uiStateRestored {
            let collapsed = workspace.codeLayout.chatCollapsed
            HStack(spacing: gutter) {
                if collapsed {
                    HSplitView { sidebarIsland(); editorIsland() }
                        .splitViewAutosaveName("code-main-collapsed", store: splitStore)
                        .splitViewDivider(.hidden, thickness: CGFloat(style.gutter))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    CollapsedChatStrip(workspace: workspace, style: style).equatable()
                } else {
                    HSplitView {
                        sidebarIsland()
                        editorIsland()
                        CodeChatColumn(workspace: workspace, store: store, themes: themes).equatable()
                            .island(style: style, identifier: "island-code-chat")
                            .frame(minWidth: codeChatWidths.min, idealWidth: codeChatWidths.ideal, maxWidth: codeChatWidths.max)
                    }
                    .splitViewAutosaveName("code-main", store: splitStore)
                    .splitViewDivider(.hidden, thickness: CGFloat(style.gutter))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(Edges(top: Pixels(0), right: gutter, bottom: gutter, left: gutter))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("code-screen")
        } else {
            // The split reads its saved sizes when first built, so it waits for the restore: an empty island until then.
            VStack(spacing: 0) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .island(style: style, identifier: "island-code-restoring")
            }
                .padding(Edges(top: Pixels(0), right: gutter, bottom: gutter, left: gutter))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("code-screen")
        }
    }
}
