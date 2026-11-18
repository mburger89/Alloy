import AlloyCore
import Foundation
import MetalUI

/// The find bar above a terminal pane. Mounted only while `store.findPane` is this pane; Return finds the next match,
/// Shift-Return the previous (both wrap), Escape closes the bar and returns focus to the terminal.
struct TerminalFindBar: Component, Equatable {
    let paneID: UUID
    var store: TerminalPanelStore
    @FocusState private var fieldFocused: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { a.paneID == b.paneID && a.store === b.store }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TerminalFindBar")
        let store = store
        HStack(spacing: Pixels(8)) {
            TextField("Find", text: Binding(get: { store.findQuery }, set: { store.setFindQuery($0) }))
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onChange(of: store.findFocusToken) { _, _ in fieldFocused = true }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    switch press.key {
                    case .escape: store.closeFind(); return .handled
                    case .return:
                        store.find(next: !press.modifiers.contains(.shift)); return .handled
                    default: return .ignored
                    }
                }
                .accessibilityIdentifier("terminal-find-field")
            Text(verbatim: store.findStatus == .notFound ? "No matches" : "")
                .font(size: 11).foregroundColor(.mutedInk)
                .accessibilityIdentifier("terminal-find-status")
            Button("\u{2191}") { store.find(next: false) }.accessibilityIdentifier("terminal-find-prev")
            Button("\u{2193}") { store.find(next: true) }.accessibilityIdentifier("terminal-find-next")
            Button("\u{2715}") { store.closeFind() }.accessibilityIdentifier("terminal-find-close")
        }
        .padding(inset(12, 6))
        .background(.panelFill)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-find-bar")
    }
}
