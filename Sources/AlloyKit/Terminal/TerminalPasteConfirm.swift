import AlloyCore
import Foundation
import MetalUI

/// The multi-line paste confirm bar at the top of a terminal pane. Mounted only while that pane's `store.pendingPaste` is non-nil;
/// Paste sends the text, Cancel and Escape send nothing, and both return focus to the terminal.
struct TerminalPasteConfirm: Component, Equatable {
    let paneID: UUID
    var store: TerminalPanelStore
    @State private var dontAsk = false
    @FocusState private var pasteFocused: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool { a.paneID == b.paneID && a.store === b.store }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TerminalPasteConfirm")
        let store = store
        let lines = store.pendingPaste?.lines ?? 0
        VStack(spacing: 10) {
            Text(verbatim: "Paste \(lines) lines? They may run as commands").font(size: 13)
                .accessibilityIdentifier("terminal-paste-confirm-text")
            Toggle(isOn: $dontAsk) { Text("Don't ask again").font(size: 12) }
                .accessibilityIdentifier("terminal-paste-confirm-dont-ask")
            HStack(spacing: 8) {
                Button("Cancel") { store.cancelPaste() }.accessibilityIdentifier("terminal-paste-confirm-cancel")
                Button("Paste") { store.confirmPaste(dontAskAgain: dontAsk) }
                    .focused($pasteFocused)
                    .onAppear { pasteFocused = true }
                    .accessibilityIdentifier("terminal-paste-confirm-paste")
            }
        }
        .padding(inset(16, 12))
        .background(.panelFill)
        .onKeyPress(phases: [.down, .repeat]) { press in
            guard press.key == .escape else { return .ignored }
            store.cancelPaste()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-paste-confirm")
    }
}
