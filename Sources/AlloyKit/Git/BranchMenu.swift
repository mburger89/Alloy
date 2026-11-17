import AlloyCore
import Foundation
import MetalUI

/// The title island's branch indicator when a git coordinator exists: a menu of the recent local branches, Switch to
/// branch... and New branch.... The branch list is read when the menu opens, never on a frame.
struct BranchMenu: Component, Equatable {
    let coordinator: GitCoordinator
    let branch: String

    nonisolated static func == (a: Self, b: Self) -> Bool { a.coordinator === b.coordinator && a.branch == b.branch }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("BranchMenu")
        let coordinator = coordinator, branch = branch
        let picker = coordinator.branchPicker
        let recent = picker.recent
        let open = Binding<Bool>(get: { picker.menuOpen }, set: { coordinator.menuPresented($0) })
        Menu(isPresented: open, content: {
            for name in recent {
                Button(name) { coordinator.switchBranch(name) }
                    .accessibilityIdentifier("git-branch-item-\(name)")
            }
            if !recent.isEmpty { Divider() }
            Button("Switch to branch\u{2026}") { coordinator.showBranchPicker() }
                .accessibilityIdentifier("git-branch-picker")
            Button("New branch\u{2026}") { coordinator.showNewBranch() }
                .accessibilityIdentifier("git-branch-new")
        }, label: {
            Text("\u{2387} \(branch)").font(size: 11).foregroundColor(.mutedInk)
        })
        .accessibilityIdentifier("title-branch")
    }
}
