@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A Code-mode window on a real repository with the Git tab selected.
@MainActor
struct TabRig {
    let rig: Rig
    let coordinator: GitCoordinator
    let window: TestWindow
    var root: URL { rig.root }
    var panel: GitPanelModel { coordinator.panel }
    var workspace: Workspace { rig.workspace }

    /// `files` are committed (unless `commit` is false); `worktree` is written afterwards; `prepare` runs before the
    /// coordinator exists (hooks, branches).
    static func make(files: [String: String] = ["a.txt": "one\n", "b.txt": "two\n"], worktree: [String: String] = [:],
                     commit: Bool = true, showGit: Bool = true, prepare: ((URL) throws -> Void)? = nil) async throws -> TabRig {
        let rig = Rig()
        try git(rig.root, "init", "-q", "-b", "main")
        for (rel, text) in files { try writeFile(rig.root, rel, text) }
        if commit { try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init") }
        for (rel, text) in worktree { try writeFile(rig.root, rel, text) }
        try prepare?(rig.root)
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        let out = TabRig(rig: rig, coordinator: coordinator, window: window)
        try await window.runUntil { out.has("code-sidebar-tab-git") }
        if showGit {
            try out.click("code-sidebar-tab-git")
            try await window.runUntil { out.has("git-tab") }
        }
        return out
    }

    func has(_ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    func element(_ id: String) throws -> TestElement { try window.element(identifier: id) }
    func click(_ id: String) throws { try window.click(window.element(identifier: id)) }

    /// Ticks, yields and advances the clock until `condition` holds.
    func settle(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<3000 where !condition() {
            rig.clock.advance(by: 0.6)
            window.tick()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition(), Comment(rawValue: "never became true: \(what)"))
    }

    func quiesce(_ rounds: Int = 40) async {
        for _ in 0..<rounds { rig.clock.advance(by: 0.6); window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    func paths(_ files: [GitFileStatus]) -> [String] { files.map(\.path) }
}

@MainActor
@Suite struct GitTabTests {
    // MARK: Lists

    @Test func sectionsAndCounts() async throws {
        let t = try await TabRig.make(files: ["a.txt": "1\n", "b.txt": "2\n", "c.txt": "3\n"],
                                      worktree: ["a.txt": "1x\n", "b.txt": "2x\n", "n.txt": "new\n"]) { root in
            try git(root, "add", "b.txt")
        }
        await t.settle("lists") { t.has("git-section-changes") && t.has("git-section-staged") && t.has("git-section-untracked") }
        #expect(t.paths(t.panel.staged) == ["b.txt"])
        #expect(t.paths(t.panel.changes) == ["a.txt"])
        #expect(t.paths(t.panel.untracked) == ["n.txt"])
        #expect(try t.element("git-section-changes").value == "Changes 1")
        #expect(t.has("git-row-a.txt") && t.has("git-row-b.txt") && t.has("git-row-n.txt"))
        #expect(!t.has("git-section-conflicts"))
    }

    @Test func conflictsSectionLists() async throws {
        let t = try await TabRig.make(files: ["a.txt": "base\n"], showGit: false) { root in
            try git(root, "switch", "-q", "-c", "other")
            try writeFile(root, "a.txt", "other\n"); try git(root, "commit", "-qam", "other")
            try git(root, "switch", "-q", "main")
            try writeFile(root, "a.txt", "main\n"); try git(root, "commit", "-qam", "main")
            _ = try? git(root, "merge", "other")
        }
        await t.settle("conflict") { !t.panel.conflicts.isEmpty }
        try t.click("code-sidebar-tab-git")
        await t.settle("conflict section") { t.has("git-section-conflicts") }
        #expect(t.paths(t.panel.conflicts) == ["a.txt"])
        #expect(try t.element("git-operation-banner").value == "Merge in progress")
    }

    @Test func stageUnstageButtonsMoveRows() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("a changed") { t.has("git-stage-a.txt") }
        try t.click("git-stage-a.txt")
        await t.settle("staged") { t.paths(t.panel.staged) == ["a.txt"] && t.has("git-unstage-a.txt") }
        #expect(t.panel.changes.isEmpty)
        #expect(try git(t.root, "diff", "--cached", "--name-only") == "a.txt\n")
        try t.click("git-unstage-a.txt")
        await t.settle("unstaged") { t.panel.staged.isEmpty && t.paths(t.panel.changes) == ["a.txt"] }
    }

    @Test func stageSpawnsTheWriteAndExactlyOneStatus() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("row") { t.has("git-stage-a.txt") }
        await t.quiesce()
        let before = t.coordinator.spawnCount
        try t.click("git-stage-a.txt")
        await t.settle("staged") { t.paths(t.panel.staged) == ["a.txt"] }
        await t.quiesce(80)
        // The write, plus the one status it asked for (`discover` already ran).
        #expect(t.coordinator.spawnCount == before + 2)
    }

    @Test func renameRowShowsOldArrowNew() async throws {
        let t = try await TabRig.make(files: ["old.txt": "some longer content here\nline two\nline three\n"]) { root in
            try git(root, "mv", "old.txt", "new.txt")
        }
        await t.settle("rename row") { t.has("git-row-new.txt") }
        #expect(try t.element("git-open-new.txt").label == "old.txt \u{2192} new.txt")
    }

    @Test func specialNamesStageAndShow() async throws {
        let t = try await TabRig.make(files: ["a.txt": "1\n"], worktree: ["-dash.txt": "x\n", "sp ace.txt": "y\n", "ü.txt": "z\n"])
        await t.settle("rows") { t.has("git-stage--dash.txt") && t.has("git-stage-sp ace.txt") }
        try t.click("git-stage--dash.txt")
        await t.settle("dash staged") { t.paths(t.panel.staged) == ["-dash.txt"] }
    }

    // MARK: Discard

    @Test func discardTrackedConfirmsThenRestores() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "changed\n"])
        await t.settle("row") { t.has("git-discard-a.txt") }
        try t.click("git-discard-a.txt")
        await t.settle("question") { t.has("git-discard-question") }
        #expect(try t.element("git-discard-question").value?.contains("a.txt") == true)
        #expect(try String(contentsOf: t.root.appendingPathComponent("a.txt"), encoding: .utf8) == "changed\n", "nothing yet")
        try t.click("git-discard-confirm")
        await t.settle("restored") { t.panel.changes.isEmpty && !t.has("git-row-a.txt") }
        #expect(try String(contentsOf: t.root.appendingPathComponent("a.txt"), encoding: .utf8) == "one\n")
        #expect(!t.has("git-discard-question"))
    }

    @Test func discardCancelKeepsTheFile() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "changed\n"])
        await t.settle("row") { t.has("git-discard-a.txt") }
        try t.click("git-discard-a.txt")
        await t.settle("question") { t.has("git-discard-cancel") }
        try t.click("git-discard-cancel")
        await t.settle("gone") { !t.has("git-discard-question") }
        #expect(try String(contentsOf: t.root.appendingPathComponent("a.txt"), encoding: .utf8) == "changed\n")
    }

    @Test func discardUntrackedDeletesAfterConfirm() async throws {
        let t = try await TabRig.make(worktree: ["new.txt": "x\n"])
        await t.settle("row") { t.has("git-discard-new.txt") }
        try t.click("git-discard-new.txt")
        await t.settle("question") { t.has("git-discard-question") }
        #expect(try t.element("git-discard-question").value == "Delete new.txt? It is not tracked by git and cannot be restored.")
        try t.click("git-discard-confirm")
        await t.settle("deleted") { !t.paths(t.panel.untracked).contains("new.txt") }
        #expect(!FileManager.default.fileExists(atPath: t.root.appendingPathComponent("new.txt").path))
    }

    @Test func discardOfAnOpenDocumentReloadsIt() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "changed\n"])
        await t.workspace.open("a.txt")
        let doc = try #require(t.workspace.document("a.txt"))
        #expect(doc.buffer.snapshot().text == "changed\n")
        await t.settle("row") { t.has("git-discard-a.txt") }
        try t.click("git-discard-a.txt")
        await t.settle("question") { t.has("git-discard-confirm") }
        try t.click("git-discard-confirm")
        await t.settle("restored on disk") { t.panel.changes.isEmpty }
        t.workspace.startWatching()
        t.rig.changes.send([t.root.appendingPathComponent("a.txt").path])
        await t.settle("buffer reloaded") { doc.buffer.snapshot().text == "one\n" }
    }

    // MARK: Commit

    private func disabled(_ t: TabRig, _ id: String) throws -> Bool { try !t.element(id).isEnabled }

    @Test func commitDisabledRules() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("row") { t.has("git-commit") }
        // Nothing staged, empty message.
        #expect(try disabled(t, "git-commit"))
        // Nothing staged but a message.
        t.coordinator.sidebar.message = "msg"
        await t.settle("still disabled") { (try? self.disabled(t, "git-commit")) == true }
        // Staged, empty message.
        t.coordinator.sidebar.message = ""
        try t.click("git-stage-a.txt")
        await t.settle("staged") { !t.panel.staged.isEmpty }
        await t.quiesce(5)
        #expect(try disabled(t, "git-commit"))
        // Staged and a message: enabled.
        t.coordinator.sidebar.message = "msg"
        await t.settle("enabled") { (try? self.disabled(t, "git-commit")) == false }
        #expect(GitCommitRules.blocker(panel: t.panel, message: "msg", amend: false) == nil)
    }

    @Test func commitDisabledWithUnmergedEntries() async throws {
        let t = try await TabRig.make(files: ["a.txt": "base\n"], showGit: false) { root in
            try git(root, "switch", "-q", "-c", "other")
            try writeFile(root, "a.txt", "other\n"); try git(root, "commit", "-qam", "other")
            try git(root, "switch", "-q", "main")
            try writeFile(root, "a.txt", "main\n"); try git(root, "commit", "-qam", "main")
            _ = try? git(root, "merge", "other")
            try writeFile(root, "b.txt", "b\n"); try git(root, "add", "b.txt")
        }
        await t.settle("conflict") { !t.panel.conflicts.isEmpty && !t.panel.staged.isEmpty }
        #expect(GitCommitRules.blocker(panel: t.panel, message: "m", amend: false) == "Resolve the conflicts first")
    }

    @Test func commitSendsMessageAndClearsDraft() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("row") { t.has("git-stage-a.txt") }
        try t.click("git-stage-a.txt")
        await t.settle("staged") { !t.panel.staged.isEmpty }
        t.coordinator.sidebar.message = "# not a comment\n\nbody"
        #expect(t.workspace.persistedCommitDraft == "# not a comment\n\nbody")
        await t.settle("enabled") { (try? self.disabled(t, "git-commit")) == false }
        try t.click("git-commit")
        await t.settle("committed") { t.panel.staged.isEmpty && t.panel.changes.isEmpty }
        #expect(try git(t.root, "log", "-1", "--format=%B").hasPrefix("# not a comment\n\nbody"))
        #expect(t.coordinator.sidebar.message == "")
        #expect(t.workspace.persistedCommitDraft == nil)
    }

    @Test func commitFailureShowsInlineError() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"]) { root in
            let hook = root.appendingPathComponent(".git/hooks/pre-commit")
            try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        await t.settle("row") { t.has("git-stage-a.txt") }
        try t.click("git-stage-a.txt")
        await t.settle("staged") { !t.panel.staged.isEmpty }
        t.coordinator.sidebar.message = "msg"
        await t.settle("enabled") { (try? self.disabled(t, "git-commit")) == false }
        try t.click("git-commit")
        await t.settle("error") { t.has("git-commit-error") }
        #expect(try t.element("git-commit-error").value?.contains("hook says no") == true)
        #expect(t.coordinator.sidebar.message == "msg", "the draft stays after a failure")
    }

    @Test func amendRewritesTheLastCommit() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        t.coordinator.sidebar.message = "reworded"
        await t.settle("amend enabled") { (try? self.disabled(t, "git-commit-amend")) == false }
        try t.click("git-commit-amend")
        await t.settle("amend finished") { !t.coordinator.sidebar.busy && t.coordinator.sidebar.message.isEmpty }
        #expect(try git(t.root, "log", "-1", "--format=%s") == "reworded\n")
        #expect(try git(t.root, "rev-list", "--count", "HEAD") == "1\n")
    }

    @Test func amendDisabledOnUnborn() async throws {
        let t = try await TabRig.make(files: [:], worktree: ["a.txt": "x\n"], commit: false)
        await t.settle("unborn") { t.panel.isUnborn && t.has("git-commit-amend") }
        t.coordinator.sidebar.message = "m"
        await t.quiesce(10)
        #expect(try disabled(t, "git-commit-amend"))
        #expect(GitCommitRules.blocker(panel: t.panel, message: "m", amend: true) == "There is nothing to amend yet")
    }

    @Test func operationBannerNamesMerge() async throws {
        let t = try await TabRig.make(files: ["a.txt": "base\n"], prepare: { root in
            try git(root, "switch", "-q", "-c", "other")
            try writeFile(root, "b.txt", "b\n"); try git(root, "add", "b.txt"); try git(root, "commit", "-qm", "other")
            try git(root, "switch", "-q", "main")
            try writeFile(root, "c.txt", "c\n"); try git(root, "add", "c.txt"); try git(root, "commit", "-qm", "main")
            try git(root, "merge", "--no-commit", "--no-ff", "other")
        })
        await t.settle("banner") { t.has("git-operation-banner") }
        #expect(try t.element("git-operation-banner").value == "Merge in progress")
    }

    @Test func mergeAllowsCommitWithoutUnmerged() async throws {
        let t = try await TabRig.make(files: ["a.txt": "base\n"], prepare: { root in
            try git(root, "switch", "-q", "-c", "other")
            try writeFile(root, "b.txt", "b\n"); try git(root, "add", "b.txt"); try git(root, "commit", "-qm", "other")
            try git(root, "switch", "-q", "main")
            try writeFile(root, "c.txt", "c\n"); try git(root, "add", "c.txt"); try git(root, "commit", "-qm", "main")
            try git(root, "merge", "--no-commit", "--no-ff", "other")
        })
        await t.settle("merge staged") { t.panel.operation == .merge && !t.panel.staged.isEmpty }
        #expect(GitCommitRules.blocker(panel: t.panel, message: "merge it", amend: false) == nil)
    }

    @Test func rebaseDisablesCommitWithMessage() async throws {
        let t = try await TabRig.make(files: ["a.txt": "base\n"], prepare: { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/rebase-merge"), withIntermediateDirectories: true)
            try writeFile(root, "b.txt", "b\n"); try git(root, "add", "b.txt")
        })
        await t.settle("rebase banner") { t.panel.operation == .rebase && t.has("git-operation-banner") }
        t.coordinator.sidebar.message = "m"
        await t.settle("hint") { t.has("git-commit-hint") }
        #expect(try t.element("git-commit-hint").value == "Rebase in progress: continue it in a terminal")
        #expect(try disabled(t, "git-commit"))
    }

    @Test func staleLockOfferedOnlyAfter60s() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("row") { t.has("git-stage-a.txt") }
        let lock = t.root.appendingPathComponent(".git/index.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        try t.click("git-stage-a.txt")
        await t.settle("error") { t.has("git-commit-error") }
        #expect(!t.has("git-remove-lock"), "a fresh lock may belong to a running git")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: lock.path)
        try t.click("git-stage-a.txt")
        await t.settle("offer") { t.has("git-remove-lock") }
        try t.click("git-remove-lock")
        await t.settle("confirm") { t.has("git-remove-lock-confirm") }
        #expect(FileManager.default.fileExists(atPath: lock.path))
        try t.click("git-remove-lock-confirm")
        await t.settle("removed") { !FileManager.default.fileExists(atPath: lock.path) && !t.has("git-commit-error") }
    }

    @Test func draftSurvivesRelaunch() async throws {
        let t = try await TabRig.make()
        t.coordinator.sidebar.message = "work in progress"
        t.coordinator.sidebar.tab = .git
        let state = t.workspace.currentUIState()
        let rig2 = Rig()
        try git(rig2.root, "init", "-q", "-b", "main")
        rig2.workspace.apply(state)
        rig2.workspace.codeLayout.sidebarTab = state.sidebarTab   // restoreUIState applies the one sidebar tab
        let again = GitCoordinator.install(on: rig2.workspace)
        #expect(again.sidebar.message == "work in progress")
        #expect(again.sidebar.tab == .git)
    }

    // MARK: Header and notes

    @Test func aheadBehindOnlyWithUpstream() async throws {
        let t = try await TabRig.make()
        await t.settle("header") { t.has("git-branch") }
        #expect(try t.element("git-branch").value == "main")
        #expect(!t.has("git-ahead-behind"))
        try git(t.root, "switch", "-q", "-c", "topic")
        try git(t.root, "branch", "-q", "-u", "main")
        try writeFile(t.root, "x.txt", "x\n"); try git(t.root, "add", "x.txt"); try git(t.root, "commit", "-qm", "ahead")
        t.workspace.startWatching()
        t.rig.changes.send([t.root.appendingPathComponent(".git/HEAD").path])
        await t.settle("ahead shown") { t.has("git-ahead-behind") }
        #expect(try t.element("git-ahead-behind").value == "\u{2191}1 \u{2193}0")
    }

    @Test func notARepoShowsOneLine() async throws {
        let rig = Rig()
        let coordinator = GitCoordinator.install(on: rig.workspace)
        await coordinator.service.refreshNow()
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        coordinator.sidebar.tab = .git
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "git-not-a-repo")) != nil }
    }

    @Test func unusableGitShowsOneLine() async throws {
        let rig = Rig()
        let runner: GitRunner = { _, _, _, _, _, _ in GitResult(status: 127, stdout: Data(), stderr: Data(), timedOut: false) }
        let service = GitService(root: rig.root, clock: rig.clock, runner: runner)
        let coordinator = GitCoordinator.install(on: rig.workspace, service: service)
        coordinator.panel.apply(GitUpdate(status: GitStatus(), state: .noGit("git was not found")))
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        coordinator.sidebar.tab = .git
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "git-unavailable")) != nil }
        #expect(try window.element(identifier: "git-unavailable").value == "Git is not available: git was not found.")
    }

    @Test func timeoutBannerThenManualRefresh() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("row") { t.has("git-row-a.txt") }
        t.panel.apply(GitUpdate(status: GitStatus(branch: "main"), timedOut: true))
        await t.settle("banner") { t.has("git-status-timeout") }
        try t.click("git-refresh")
        await t.settle("cleared") { !t.has("git-status-timeout") && t.has("git-row-a.txt") }
    }

    // MARK: Opening rows

    @Test func clickOnUntrackedOpensTheFile() async throws {
        let t = try await TabRig.make(worktree: ["new.txt": "x\n"])
        await t.settle("row") { t.has("git-open-new.txt") }
        try t.click("git-open-new.txt")
        await t.settle("open") { t.workspace.document("new.txt") != nil }
        #expect(t.workspace.presentation(of: "new.txt", in: t.workspace.defaultPane) == .plain)
    }

    @Test func clickOnModifiedOpensCompareWithHead() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "changed\n"])
        await t.settle("row") { t.has("git-open-a.txt") }
        try t.click("git-open-a.txt")
        await t.settle("compare") { t.workspace.presentation(of: "a.txt", in: t.workspace.defaultPane) == .compareHead }
    }

    // MARK: Laziness and re-runs

    @Test func lazyRowsOnlyBuildVisible() async throws {
        let start = BodyProbe.count("GitFileRow")
        var files: [String: String] = [:]
        for i in 0..<5000 { files["f\(String(format: "%04d", i)).txt"] = "x\n" }
        let t = try await TabRig.make(files: ["a.txt": "1\n"], worktree: files)
        await t.settle("rows") { t.panel.untracked.count == 5000 && t.has("git-commit-message") }
        for _ in 0..<10 { t.window.tick(); await Task.yield() }
        let built = BodyProbe.count("GitFileRow") - start
        #expect(built < 80, "built \(built) rows for 5000 entries")
    }

    @Test func commitBoxTypingDoesNotRerunRows() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n", "n.txt": "n\n"])
        await t.settle("rows") { t.has("git-row-a.txt") && t.has("git-commit-message") }
        await t.quiesce(10)
        try t.click("git-commit-message")
        for _ in 0..<5 { t.window.tick(); await Task.yield() }
        let names = ["GitTab", "GitReadyTab", "GitHeader", "GitFileRow", "GitBanners", "GitListRow", "CodeSidebarView"]
        let before = names.map(BodyProbe.count)
        let box = BodyProbe.count("GitCommitBox")
        for _ in 0..<10 { t.window.typeText("a"); t.window.tick(); await Task.yield() }
        for (i, n) in names.enumerated() { #expect(BodyProbe.count(n) == before[i], "\(n) re-ran while typing") }
        #expect(t.coordinator.sidebar.message.hasPrefix("a"))
        #expect(BodyProbe.count("GitCommitBox") >= box)
    }

    @Test func idleFramesRerunNothingOnTheGitTab() async throws {
        let t = try await TabRig.make(worktree: ["a.txt": "1x\n"])
        await t.settle("rows") { t.has("git-row-a.txt") }
        await t.quiesce(20)
        let spawned = t.coordinator.spawnCount
        let before = BodyProbe.counts
        for _ in 0..<20 { t.rig.clock.advance(by: 1); t.window.tick(); await Task.yield() }
        let changed = BodyProbe.counts.filter { $0.value != before[$0.key] ?? 0 && !$0.key.contains("#") }
        #expect(changed.isEmpty, "idle ticks re-ran \(changed)")
        #expect(t.coordinator.spawnCount == spawned)
    }
}
