import AlloyCore
import Foundation
import MetalUI

/// The smallest a group may be dragged to inside a split.
let codeGroupMinWidth = Pixels(160)
let codeGroupMinHeight = Pixels(120)

/// What every node of the editor area needs.
struct EditorAreaEnv {
    let workspace: Workspace
    let store: SessionUIStore
    let panel: CodePanelStore
    let quickOpen: QuickOpenModel
    let splitStore: UIStateSplitStore
    var themes: ThemeController?
    let style: AppearanceStyle
}

/// The editor island's content: the split tree of editor groups. 
struct EditorAreaView: Component {
    let workspace: Workspace
    let store: SessionUIStore
    let panel: CodePanelStore
    let quickOpen: QuickOpenModel
    let splitStore: UIStateSplitStore
    var themes: ThemeController?
    let style: AppearanceStyle

    var content: some ElementGroup {
        let _ = BodyProbe.hit("EditorAreaView")
        let workspace = workspace, panel = panel
        let env = EditorAreaEnv(workspace: workspace, store: store, panel: panel, quickOpen: quickOpen,
                                splitStore: splitStore, themes: themes, style: style)
        let tree = workspace.codeLayout.tree
        VStack(spacing: 0) {
            SplitNodeView(node: tree, env: env)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-editor-area")
    }
}

/// One node of the tree: a split of two nodes (an autosaved, draggable divider between them) or a group.
@MainActor
func SplitNodeView(node: SplitTree, env: EditorAreaEnv) -> AnyElement {
    switch node {
    case .group(let id):
        return AnyElement(VStack(spacing: 0) {
            EditorGroupView(workspace: env.workspace, store: env.store, panel: env.panel, quickOpen: env.quickOpen,
                            groupID: id, themes: env.themes, style: env.style).equatable()
        })
    case .split(let id, let axis, let first, let second):
        let name = "code-split-\(id)"
        let a = SplitNodeView(node: first, env: env), b = SplitNodeView(node: second, env: env)
        switch axis {
        case .horizontal:
            return AnyElement(HSplitView {
                a.frame(minWidth: codeGroupMinWidth, maxWidth: .infinity)
                b.frame(minWidth: codeGroupMinWidth, maxWidth: .infinity)
            }
            .splitViewAutosaveName(name, store: env.splitStore)
            .splitViewDividerIdentifier(name)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(name))
        case .vertical:
            return AnyElement(VSplitView {
                a.frame(minHeight: codeGroupMinHeight, maxHeight: .infinity)
                b.frame(minHeight: codeGroupMinHeight, maxHeight: .infinity)
            }
            .splitViewAutosaveName(name, store: env.splitStore)
            .splitViewDividerIdentifier(name)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(name))
        }
    }
}

extension EditorAreaView: Equatable {
    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.store === b.store && a.panel === b.panel && a.quickOpen === b.quickOpen
            && a.splitStore === b.splitStore && a.themes === b.themes && a.style == b.style
    }
}
