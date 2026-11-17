import AlloyCore
import Foundation
import MetalUI

/// One terminal pane's stand-in until the real terminal view lands: a muted label, or the exited notice with Close and
/// Restart. The seam where `TerminalView` goes. It handles no keys: an exited pane never restarts on its own.
struct TerminalPlaceholderPane: Component, Equatable {
    let paneID: UUID
    let title: String
    var state: TerminalPaneState = .running
    var store: TerminalPanelStore?

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.paneID == b.paneID && a.title == b.title && a.state == b.state && a.store === b.store
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TerminalPlaceholderPane")
        let paneID = paneID, store = store
        VStack(spacing: 6) {
            switch state {
            case .running:
                Text(verbatim: title).font(size: 12).foregroundColor(.mutedInk)
            case .exited(let status):
                Text(verbatim: "[process exited \(status)]").font(size: 12).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("terminal-exited-text-\(paneID.uuidString)")
                HStack(spacing: 8) {
                    Button("Close") { store?.closePane(paneID) }.accessibilityIdentifier("terminal-exited-close")
                    Button("Restart") { store?.restart(paneID) }.accessibilityIdentifier("terminal-exited-restart")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { store?.focusPane(paneID) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-pane-\(paneID.uuidString)")
    }
}
