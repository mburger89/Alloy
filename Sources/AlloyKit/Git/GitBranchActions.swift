import AlloyCore
import Foundation

/// What the branch menu and picker do. A switch saves the dirty documents first (the same path as ⌘S), then runs
/// `git switch`; git's refusal is shown and nothing else changes. Nothing is stashed or forced.
extension GitCoordinator {
    /// The menu's open binding was written. A click (true) reads the branch list first and opens the menu once it is
    /// in, so the items are the ones just read; a dismissal (false) closes it.
    func menuPresented(_ open: Bool) {
        guard open else { branchPicker.menuOpen = false; branchPicker.loadingMenu = false; return }
        guard !branchPicker.menuOpen, !branchPicker.loadingMenu else { return }
        branchPicker.loadingMenu = true
        let service = service
        Task { @MainActor in
            let branches = await service.branches()
            guard self.branchPicker.loadingMenu else { return }
            self.branchPicker.loadingMenu = false
            self.branchPicker.setBranches(branches)
            self.branchPicker.menuOpen = true
        }
    }

    func showBranchPicker() {
        wireBranchPicker()
        branchPicker.showPicker()
        let service = service
        Task { @MainActor in
            self.branchPicker.setBranches(await service.branches())
        }
    }

    func showNewBranch() {
        wireBranchPicker()
        branchPicker.showNewBranch()
    }

    func switchBranch(_ name: String) {
        perform { await $0.switchBranch(name) }
    }

    func createBranch(_ name: String) {
        perform { await $0.createBranch(name) }
    }

    private func perform(_ command: @escaping @Sendable (GitService) async -> GitCommandResult) {
        guard let host else { return }
        let service = service
        Task { @MainActor in
            await host.saveAll()
            let result = await command(service)
            if result.ok {
                self.branchPicker.hide()
                // The service reads the new HEAD at once; the workspace's own branch name follows the HEAD event.
                await service.requestRefresh()
            } else {
                self.branchPicker.showError(result.stderr.isEmpty ? "git failed" : result.stderr)
            }
        }
    }

    func wireBranchPicker() {
        branchPicker.onSwitch = { [weak self] in self?.switchBranch($0) }
        branchPicker.onCreate = { [weak self] in self?.createBranch($0) }
    }
}
