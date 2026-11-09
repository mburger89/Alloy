import AlloyCore
import Foundation
import MetalUI

/// How a warning is coloured. Overlap and tug use the warning tokens; red (the error tokens) is reserved for a tug whose
/// stop message was ignored, the one case that needs the user.
enum CoordinationStyle {
    static func isRed(_ warning: CoordinationWarning) -> Bool { warning.escalated }

    static func colors(for warning: CoordinationWarning) -> (ink: Color, tint: Color) {
        isRed(warning) ? (.errorInk, .errorTint) : (.warningInk, .warningTint)
    }

    /// The warning a marker stands for: an escalated one if there is one, else the newest.
    static func headline(_ warnings: [CoordinationWarning]) -> CoordinationWarning? {
        warnings.last(where: \.escalated) ?? warnings.last
    }
}

/// The ⚠ marker. Small enough for a session row beside its menu button; the hover help is the warning in one line.
struct WarningMark: Component {
    let warning: CoordinationWarning
    let identifier: String

    var content: some ElementGroup {
        let colors = CoordinationStyle.colors(for: warning)
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(colors.ink)
            .padding(Pixels(3))
            .background(colors.tint)
            .help(warning.summary)
            .accessibilityLabel("Warning")
            .accessibilityIdentifier(identifier)
    }
}

/// A one-line strip above the chat when a warning involves a session the user is not looking at. Clicking it goes to
/// that session; the x hides it (the markers stay).
struct CoordinationNotice: Component {
    let workspace: Workspace

    var content: some ElementGroup {
        let workspace = workspace
        if let warning = workspace.noticeWarning(selected: workspace.selectedSessionID) {
            let colors = CoordinationStyle.colors(for: warning)
            HStack(spacing: Pixels(4)) {
                Button {
                    if let other = warning.sessions.first(where: { $0 != workspace.selectedSessionID }) {
                        workspace.selectedSessionID = other
                    }
                    workspace.dismissWarning(warning)
                } label: {
                    HStack(spacing: Pixels(6)) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundColor(colors.ink)
                        Text(verbatim: warning.summary).font(size: 12).foregroundColor(.textPrimary).lineLimit(1)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("coordination-notice")
                Button {
                    workspace.dismissWarning(warning)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.textPrimary).padding(Pixels(4))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("coordination-notice-dismiss")
            }
            .padding(inset(10, 4))
            .frame(maxWidth: .infinity)
            .background(colors.tint)
        }
    }
}
