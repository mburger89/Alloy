import AlloyCore
import AlloyTerminal
import Foundation
import MetalUI
import MetalUITerminal
import MetalUITerminalUI

/// One terminal pane: MetalUI's `TerminalView` over the pane's snapshot source, or, for an exited pane or one without a
/// session, the notice overlay (exit status, Close and Restart). A notice (spawn failure, cwd fallback) is one muted line
/// above either. It handles no keys yet: input arrives with MetalUI 5.4.
struct TerminalPaneView: Component, Equatable {
    let paneID: UUID
    let title: String
    var state: TerminalPaneState = .running
    var notice: String?
    var appearance: TerminalAppearance
    var store: TerminalPanelStore?
    /// True while any focusable descendant (the `TerminalView`) holds focus (MetalUI focus-within on a plain container).
    @FocusState private var paneFocused: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.paneID == b.paneID && a.title == b.title && a.state == b.state && a.notice == b.notice
            && a.appearance == b.appearance && a.store === b.store
    }

    /// The source of a running pane; nil when the pane has exited or has no session (lazy restore, spawn failure).
    @MainActor private var source: TerminalSnapshotSource? {
        guard case .running = state else { return nil }
        return store?.snapshotSource(of: paneID)
    }

    @MainActor private func terminal(_ source: TerminalSnapshotSource) -> some ElementGroup {
        let paneID = paneID, store = store
        return TerminalView(
            snapshotSource: source, theme: appearance.palette, keyCaptureExceptions: [],
            optionAsMeta: appearance.optionAsMeta, cursorBlink: appearance.cursorBlink, blinkStopsAfterIdle: true,
            boldIsBright: false,
            onInput: { _ in },  // MetalUI 5.4: onInput plugs in here (single call site)
            onResize: { size in store?.resizePane(paneID, cols: size.cols, rows: size.rows) },
            onLink: { _ in nil })  // MetalUI 5.5: onLink plugs in here (single call site)
            .font(appearance.font)
            // A restart builds a new session with a new source: a new identity, so the view is rebuilt, never rebound.
            .id(ObjectIdentifier(source).hashValue.description)
    }

    private func overlay() -> some ElementGroup {
        let paneID = paneID, store = store
        return VStack(spacing: 6) {
            if case .exited(let status) = state {
                Text(verbatim: "[process exited \(status)]").font(size: 12).foregroundColor(.mutedInk)
                    .accessibilityIdentifier("terminal-exited-text-\(paneID.uuidString)")
            }
            HStack(spacing: 8) {
                Button("Close") { store?.closePane(paneID) }.accessibilityIdentifier("terminal-exited-close")
                if case .exited = state {
                    Button("Restart") { store?.restart(paneID) }.accessibilityIdentifier("terminal-exited-restart")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TerminalPaneView")
        let paneID = paneID, store = store
        VStack(spacing: 0) {
            if let notice {
                Text(verbatim: notice).font(size: 11).foregroundColor(.mutedInk).lineLimit(2)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("terminal-notice-\(paneID.uuidString)")
            }
            if let source {
                terminal(source)
            } else {
                overlay()
            }
        }
        .focused($paneFocused)
        .onChange(of: paneFocused) { _, now in store?.paneDidChangeFocus(paneID, focused: now) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-pane-\(paneID.uuidString)")
    }
}
