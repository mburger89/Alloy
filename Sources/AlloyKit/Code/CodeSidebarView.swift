import AlloyCore
import Foundation
import MetalUI

let codeSidebarTabIconSize: Double = 13
let codeSidebarTabPadding = Pixels(6)
let codeSidebarTabRowInset = (x: Float(6), y: Float(4))

/// Code mode's sidebar: a tab row (Files, Search) over the file tree or the project search. The body reads only the
/// selected tab, so it re-runs when the tab changes and never on editor keystrokes.
struct CodeSidebarView: Component, Equatable {
    let workspace: Workspace

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }

    /// The icon colour of a tab: the selected one is `.primary` (the ink), the other `.mutedInk`.
    static func tabInk(selected: Bool) -> Color { selected ? .primary : .mutedInk }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CodeSidebarView")
        let workspace = workspace
        let selected = workspace.codeLayout.sidebarTab
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                tabButton(.files, symbol: "folder", label: "Files", selected: selected)
                tabButton(.search, symbol: "magnifyingglass", label: "Search", selected: selected)
                Spacer()
            }
            .padding(inset(codeSidebarTabRowInset.x, codeSidebarTabRowInset.y))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("code-sidebar-tabs")
            if selected == .search {
                SearchView(workspace: workspace)
            } else {
                FileTreeView(workspace: workspace)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ElementBuilder private func tabButton(_ tab: SidebarTab, symbol: String, label: String, selected: SidebarTab) -> some ElementGroup {
        let workspace = workspace
        Button {
            workspace.codeLayout.sidebarTab = tab
        } label: {
            Image(systemName: symbol).font(.system(size: codeSidebarTabIconSize)).padding(codeSidebarTabPadding)
                .foregroundColor(Self.tabInk(selected: selected == tab))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected == tab ? .isSelected : [])
        .accessibilityIdentifier("code-sidebar-tab-\(tab.rawValue)")
    }
}
