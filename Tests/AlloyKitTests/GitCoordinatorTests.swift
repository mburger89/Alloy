@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import Testing

@MainActor
@Suite struct GitCoordinatorTests {
    /// A rig whose root is a committed repository with `login.swift` and `other.swift`.
    private func repoRig() throws -> Rig {
        let rig = Rig()
        try git(rig.root, "init", "-q", "-b", "main")
        try writeFile(rig.root, "login.swift", "let a = 1\n")
        try writeFile(rig.root, "other.swift", "let b = 2\n")
        try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init")
        return rig
    }

    /// Advances the manual clock and yields until `condition` holds.
    private func settle(_ rig: Rig, _ what: String, _ condition: () -> Bool) async {
        for _ in 0..<3000 where !condition() {
            rig.clock.advance(by: 0.6)
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        #expect(condition(), Comment(rawValue: "never became true: \(what)"))
    }

    @Test func installRefreshesAndFillsPanel() async throws {
        let rig = try repoRig()
        try writeFile(rig.root, "login.swift", "let a = 2\n")
        try writeFile(rig.root, "new.swift", "x\n")
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await settle(rig, "ready") { coordinator.panel.state == .ready }
        #expect(coordinator.panel.branch == "main")
        #expect(coordinator.panel.changes.map(\.path) == ["login.swift"])
        #expect(coordinator.panel.untracked.map(\.path) == ["new.swift"])
        #expect(coordinator.panel.staged.isEmpty)
        #expect(rig.workspace.gitServices === coordinator)
    }

    @Test func installChainsOnSavedAndOnStop() async throws {
        let rig = try repoRig()
        var saved: [String] = [], stopped = 0
        rig.workspace.onSaved = { saved.append($0) }
        rig.workspace.addStopHook { stopped += 1 }
        let coordinator = GitCoordinator.install(on: rig.workspace)
        rig.workspace.onSaved?("login.swift")
        #expect(saved == ["login.swift"])
        for hook in rig.workspace.onStopHooks { await hook() }
        #expect(stopped == 1)
        // The service stopped: nothing is spawned afterwards.
        let n = coordinator.spawnCount
        try writeFile(rig.root, "login.swift", "let a = 5\n")
        rig.workspace.onSaved?("login.swift")
        for _ in 0..<20 { rig.clock.advance(by: 1); try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(coordinator.spawnCount == n)
    }

    @Test func worktreeChangedFiresRefresh() async throws {
        let rig = try repoRig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await settle(rig, "ready") { coordinator.panel.state == .ready }
        rig.workspace.startWatching()
        try writeFile(rig.root, "other.swift", "let b = 3\n")
        rig.changes.send([rig.root.appendingPathComponent("other.swift").path])
        await settle(rig, "other.swift changed") { coordinator.panel.changes.map(\.path) == ["other.swift"] }
    }

    @Test func gitEventFiresRefresh() async throws {
        let rig = try repoRig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await settle(rig, "ready") { coordinator.panel.state == .ready }
        rig.workspace.startWatching()
        try git(rig.root, "switch", "-q", "-c", "topic")
        rig.changes.send([rig.root.appendingPathComponent(".git/HEAD").path])
        await settle(rig, "branch topic") { coordinator.panel.branch == "topic" }
    }

    @Test func onSavedRefreshes() async throws {
        let rig = try repoRig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await settle(rig, "ready") { coordinator.panel.state == .ready }
        try writeFile(rig.root, "login.swift", "let a = 9\n")
        rig.workspace.onSaved?("login.swift")
        await settle(rig, "saved change shown") { coordinator.panel.changes.map(\.path) == ["login.swift"] }
    }

    @Test func idleCoordinatorSpawnsNothingAndPanelStaysPut() async throws {
        let rig = try repoRig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await settle(rig, "ready") { coordinator.panel.state == .ready }
        let spawned = coordinator.spawnCount
        let snapshot = (coordinator.panel.staged, coordinator.panel.changes, coordinator.panel.untracked, coordinator.panel.branch)
        for _ in 0..<50 { rig.clock.advance(by: 1); await Task.yield() }
        for _ in 0..<1000 { await Task.yield() }
        #expect(coordinator.spawnCount == spawned)
        #expect(coordinator.panel.changes == snapshot.1 && coordinator.panel.staged == snapshot.0)
        #expect(coordinator.panel.untracked == snapshot.2 && coordinator.panel.branch == snapshot.3)
    }

    @Test func notARepoFolderShowsStateAndSpawnsOnce() async throws {
        let rig = Rig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await settle(rig, "notARepo") { coordinator.panel.state == .notARepo }
        let n = coordinator.spawnCount
        rig.workspace.onSaved?("a.txt")
        for _ in 0..<10 { rig.clock.advance(by: 1); try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(coordinator.spawnCount == n)
    }
}
