import AlloyCore
import Foundation
import MetalUI

let codeSidebarTabIconSize: Double = 13
let codeSidebarTabPadding = Pixels(6)
let codeSidebarTabRowInset = (x: Float(6), y: Float(4))

/// Code mode's sidebar: a tab row with the Files tab over the file tree.
struct CodeSidebarView: Component, Equatable {
    let workspace: Workspace

    nonisolated static func == (a: Self, b: Self) -> Bool { a.workspace === b.workspace }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("CodeSidebarView")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Image(systemName: "folder").font(.system(size: codeSidebarTabIconSize)).padding(codeSidebarTabPadding)
                    .accessibilityLabel("Files")
                    .accessibilityIdentifier("code-sidebar-tab-files")
                Spacer()
            }
            .padding(inset(codeSidebarTabRowInset.x, codeSidebarTabRowInset.y))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("code-sidebar-tabs")
            FileTreeView(workspace: workspace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
