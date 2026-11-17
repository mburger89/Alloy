import AlloyCore
import Foundation
import MetalUI

let terminalTabStripHeight = Pixels(32)
let terminalRowHeight = Pixels(18)
/// The panel never shrinks below its tab strip plus four rows of text.
let terminalMinHeight = terminalTabStripHeight + terminalRowHeight * 4
/// 30 % of the default 800 pt window: a proportional ideal cannot be expressed through `.frame(idealHeight:)`.
let terminalIdealHeight = Pixels(240)

/// The bottom panel: the tab strip over the active tab's panes, laid out as the tab's split tree.
struct TerminalPanel: Component, Equatable {
    let store: TerminalPanelStore
    let workspace: Workspace
    let style: AppearanceStyle
    var themes: ThemeController?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.workspace === b.workspace && a.style == b.style && a.themes === b.themes
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TerminalPanel")
        let layout = workspace.terminalLayout
        let store = store
        // Read here, so a theme or terminal-settings change reruns the panel (and only the panes whose look changed).
        let appearance = store.appearance(themes: themes)
        VStack(spacing: 0) {
            TerminalTabStrip(store: store, tabs: store.tabSummaries, activeID: layout.activeTab, style: style).equatable()
            if let tab = layout.active {
                // Keyed by the tab so a tab switch rebuilds, while a split or close keeps the siblings' identity.
                TerminalSplitNodeView(node: tab.tree, store: store, appearance: appearance).id(tab.id.uuidString)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-terminal-panel")
    }
}

/// One node of a tab's tree: a split of two nodes (autosaved as `terminal-split-<id>`) or a pane.
struct TerminalSplitNodeView: Component {
    let node: TerminalSplitTree
    let store: TerminalPanelStore
    let appearance: TerminalAppearance

    var content: some ElementGroup {
        TerminalSplitNode.build(node, store: store, appearance: appearance)
    }
}

@MainActor
enum TerminalSplitNode {
    static let minPaneWidth = Pixels(120)
    static let minPaneHeight = terminalRowHeight * 4

    static func build(_ node: TerminalSplitTree, store: TerminalPanelStore, appearance: TerminalAppearance) -> AnyElement {
        switch node {
        case .pane(let id):
            return AnyElement(VStack(spacing: 0) {
                TerminalPaneView(paneID: id, title: store.title(of: id), state: store.paneState(id), notice: store.notice(of: id),
                                 appearance: appearance, store: store).equatable()
            })
        case .split(let id, let axis, let first, let second):
            let name = "terminal-split-\(id)"
            let a = build(first, store: store, appearance: appearance), b = build(second, store: store, appearance: appearance)
            switch axis {
            case .horizontal:
                return AnyElement(HSplitView {
                    a.frame(minWidth: minPaneWidth, maxWidth: .infinity)
                    b.frame(minWidth: minPaneWidth, maxWidth: .infinity)
                }
                .splitViewAutosaveName(name, store: store.splitStore)
                .splitViewDividerIdentifier(name)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(name))
            case .vertical:
                return AnyElement(VSplitView {
                    a.frame(minHeight: minPaneHeight, maxHeight: .infinity)
                    b.frame(minHeight: minPaneHeight, maxHeight: .infinity)
                }
                .splitViewAutosaveName(name, store: store.splitStore)
                .splitViewDividerIdentifier(name)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(name))
            }
        }
    }
}
