import AlloyCore
import Foundation
import MetalUI

/// The island across the top: room for the traffic lights, the project's folder name and branch, then the New Session,
/// Quick Open and Settings pills. Equatable on the workspace, the quick-open model and the style, so the bodies that
/// read them (the branch) are its only reasons to re-run. The spacer reserves the lights' cluster up front and grows
/// only for a wider reported one, so insets that arrive a frame late and fit the reserve move nothing.
struct TitleIsland: Component, Equatable {
    let workspace: Workspace
    let quickOpen: QuickOpenModel
    let style: AppearanceStyle
    @Environment(\.titleBarInsets) var titleBarInsets

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.workspace === b.workspace && a.quickOpen === b.quickOpen && a.style == b.style
    }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("TitleIsland")
        let workspace = workspace, quickOpen = quickOpen, style = style
        VStack(spacing: 0) {
        HStack(spacing: 0) {
            Spacer().frame(width: Pixels(Float(style.titleLightsSpacer(rightEdge: Double(titleBarInsets.left.value)))))
            Text(workspace.projectRoot.lastPathComponent).font(size: 13)
                .accessibilityIdentifier("title-project")
            if let branch = workspace.branchName {
                Text("\u{2387} \(branch)").font(size: 11).foregroundColor(.mutedInk)
                    .padding(Edges(top: Pixels(0), right: Pixels(0), bottom: Pixels(0), left: Pixels(10)))
                    .accessibilityIdentifier("title-branch")
            }
            Spacer()
            HStack(spacing: Pixels(6)) {
                pill(style, label: "New Session", id: "title-new-session") {
                    Text("New Session").font(size: 11)
                } action: {
                    let n = workspace.sessions.count + 1
                    Task { await workspace.newSessionFromUser(name: "Session \(n)") }
                }
                pill(style, label: "Quick Open", id: "title-quick-open") {
                    Text("Quick Open").font(size: 11)
                } action: {
                    if quickOpen.isShowing { quickOpen.hide() } else { quickOpen.show(workspace: workspace) }
                }
                pill(style, label: "Settings", id: "title-settings") {
                    Image(systemName: "gearshape").font(.system(size: 11))
                } action: {
                    workspace.openSettings?()
                }
            }
            .padding(Edges(top: Pixels(0), right: Pixels(10), bottom: Pixels(0), left: Pixels(0)))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Pixels(Float(style.titleIslandHeight)))
        .island(style: style, identifier: "island-title")
        }
        // One gutter around the island: with the island's height, the title-bar band the window reserves.
        .padding(style.gutterInsets)
    }

    private func pill<Label: ElementGroup>(_ style: AppearanceStyle, label name: String, id: String, @ElementBuilder label: () -> Label,
                                           action: @escaping @MainActor () -> Void) -> some ElementGroup {
        return Button(action: action) {
            HStack(spacing: 0) { label() }
        }
        .buttonStyle(PillButtonStyle(style: style))
        .accessibilityLabel(name)
        .accessibilityIdentifier(id)
    }
}
