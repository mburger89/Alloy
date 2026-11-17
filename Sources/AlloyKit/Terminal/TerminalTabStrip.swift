import AlloyCore
import Foundation
import MetalUI

/// The panel's tab row: the tabs (`terminal-tab-<n>`, close `terminal-tab-close-<n>`), then new, split and close buttons.
/// Equatable over the summaries, the active id and the style, so a repeated title or an editor keystroke replays it.
struct TerminalTabStrip: Component, Equatable {
    let store: TerminalPanelStore
    let tabs: [TerminalTabSummary]
    let activeID: UUID?
    let style: AppearanceStyle

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.store === b.store && a.tabs == b.tabs && a.activeID == b.activeID && a.style == b.style
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TerminalTabStrip")
        let store = store, tabs = tabs, activeID = activeID
        let items = tabs.enumerated().map { index, tab in
            TabStripItem(id: tab.id, title: tab.exited ? "\(tab.title) (exited)" : tab.title,
                         icon: Image(systemName: "terminal"),
                         accessibilityIdentifier: "terminal-tab-\(index + 1)",
                         closeAccessibilityIdentifier: "terminal-tab-close-\(index + 1)")
        }
        let selection = Binding<UUID>(get: { activeID ?? tabs.first?.id ?? UUID() }, set: { store.selectTab($0) })
        HStack(spacing: 0) {
            TabStrip(selection: selection, tabs: items)
                .selectedTabShape(style.tabSelectionShape)
                .stripBackground(.clear)
                .onCloseTab { store.closeTab($0) }
                .frame(maxWidth: .infinity)
            HStack(spacing: 2) {
                barButton("plus", help: "New terminal", id: "terminal-new") { store.newTab() }
                barButton("rectangle.split.2x1", help: "Split terminal", id: "terminal-split") { store.splitActive(axis: .horizontal) }
                barButton("xmark", help: "Close terminal", id: "terminal-close") {
                    if let id = activeID { store.closeTab(id) }
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: terminalTabStripHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-tab-strip")
    }

    @MainActor
    private func barButton(_ symbol: String, help: String, id: String, action: @escaping @MainActor () -> Void) -> some ElementGroup {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundColor(.mutedInk).padding(5)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(id)
    }
}
