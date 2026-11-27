@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

/// Code mode's anti-goals (spec "Anti-goals"): typing, idle and the hidden mode cost no more than Chat mode with the
/// same file open. Everything here counts (element requests, body evaluations); nothing is timed.
@MainActor
@Suite struct CodeModePerformanceTests {
    /// The layouts measured: Chat mode, then Code mode with 1, 2 (same file twice) and 3 (two on one file, one on another).
    enum Layout: String, CaseIterable { case chat, code1, code2, code3 }

    struct Typing {
        var perFrame: [Int]
        var requests: Int
        var bodies: Int
        var reruns: [String: Int]
        var documentGrew: Bool
    }

    /// Keeps the coordinators of the rigs alive for the test's length.
    private final class CoordinatorBox { var all: [GitCoordinator] = [] }
    private let coordinatorBox = CoordinatorBox()
    private var gitCoordinators: [GitCoordinator] { coordinatorBox.all }

    func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    /// A window on `layout` with login.swift open (plus other.swift in the third group), settled; `codeViewID` is the
    /// code view that takes the typing.
    /// `install` runs on the rig before anything is opened (a test that needs a language server puts it there).
    /// With `git`, the project is a committed repository with a git coordinator installed and its first status read
    /// before any frame is measured (later git tasks extend this rig with tree colours, marks and the Git tab).
    func rigged(_ layout: Layout, git useGit: Bool = false, gitTab: Bool = false, lines: Int = 0, install: ((Rig) -> Void)? = nil) async throws -> (rig: Rig, window: TestWindow, codeViewID: String) {
        let (rig, _) = try await editedRig()
        install?(rig)
        // A longer login.swift (before it is opened) when a test needs room for many carets, one per line.
        if lines > 0 {
            let body = panelNewText + (0..<lines).map { "let v\($0) = \($0)\n" }.joined()
            try body.write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        }
        try "let other = 1\n".write(to: rig.root.appendingPathComponent("other.swift"), atomically: true, encoding: .utf8)
        if useGit {
            try git(rig.root, "init", "-q", "-b", "main")
            // login.swift is committed as it was before the session's edit, so its edited line shows as a gutter mark.
            try panelOldText.write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
            try git(rig.root, "add", "login.swift", "other.swift")
            try git(rig.root, "commit", "-qm", "initial")
            try panelNewText.write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
            // One modified tracked file and one untracked, so tree rows carry colours.
            try "let other = 2\n".write(to: rig.root.appendingPathComponent("other.swift"), atomically: true, encoding: .utf8)
            try "notes\n".write(to: rig.root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
            let coordinator = GitCoordinator.install(on: rig.workspace)
            await coordinator.service.refreshNow()
            // The title island shows its branch as a menu.
            rig.workspace.baselineEventSeen()
            coordinatorBox.all.append(coordinator)
        }
        let workspace = rig.workspace
        if layout == .chat {
            workspace.openFilePath = "login.swift"
            let window = try alloyWindow(workspace)
            try await window.runUntil { self.exists(window, "code-view") }
            return (rig, window, "code-view")
        }
        await workspace.restoreUIState()
        workspace.setMode(.code)
        let g0 = workspace.codeLayout.focusedGroupID
        await workspace.open("login.swift", in: .group(g0))
        if layout == .code2 || layout == .code3 { workspace.splitFocused(.horizontal) }
        if layout == .code3 {
            let g1 = workspace.codeLayout.focusedGroupID
            workspace.splitFocused(.vertical)
            let g2 = workspace.codeLayout.focusedGroupID
            await workspace.open("other.swift", in: .group(g2))
            _ = g1
        }
        workspace.focusGroup(id: g0)
        if gitTab, let coordinator = gitCoordinators.last { coordinator.sidebar.tab = .git }
        let window = try alloyWindow(workspace)
        let id = "code-view-\(g0.uuidString)"
        try await window.runUntil { self.exists(window, id) }
        if gitTab { try await window.runUntil { self.exists(window, "git-row-notes.txt") } }
        let groups = workspace.codeLayout.tree.groupIDs
        try await window.runUntil { groups.allSatisfy { g in self.exists(window, "code-group-\(g.uuidString)") } }
        // The tree's first scan builds off the main actor; its snapshot must have landed before a frame is measured, or
        // it arrives mid-typing and re-runs the tree's rows in one of the counted frames.
        for _ in 0..<3000 where workspace.fileTreeActive && workspace.fileTree.buildCount == 0 { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(!workspace.fileTreeActive || workspace.fileTree.buildCount >= 1, "the file tree's first build landed")
        if useGit, let doc = workspace.document("login.swift"), let view = CodePanelStore.existingView(for: doc, in: .group(g0)) {
            // The modified file's marks are in the gutter before anything is measured, and no popover is open.
            for _ in 0..<3000 where !(view.gitMarks?.isShowing ?? false) { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
            #expect(view.gitMarks?.isShowing == true, "the modified file shows its marks")
            #expect(view.selectedGitHunk == nil)
            for _ in 0..<10 { window.tick(); await Task.yield() }
        }
        return (rig, window, id)
    }

    /// The warm-up of `typingLeavesSidebarScreenAndChatAlone`, then 20 counted keystroke frames. `probe` names get their
    /// re-run counts; `bodies` is every body evaluation of every probe.
    func typing(_ window: TestWindow, _ rig: Rig, codeViewID: String, names: [String], carets: Int = 1) async throws -> Typing {
        for _ in 0..<10 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: codeViewID))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        if carets > 1 {
            // Several carets through the command path, one per line from the top.
            let pane = rig.workspace.defaultPane
            let state = try #require(rig.workspace.selectionState(for: "login.swift", in: pane))
            state.setSelections([CodeSelection(caret: 0)], primary: 0)
            for _ in 1..<carets { rig.workspace.runMultiCursor(.addCaretBelow) }
            #expect(state.selections.count == carets, "carets placed")
            for _ in 0..<5 { window.tick(); await Task.yield() }
        }
        let doc = try #require(rig.workspace.document("login.swift"))
        let version = doc.buffer.version
        window.resetFrameWork()
        for i in 0..<40 {
            window.typeText("a"); window.tick(); await Task.yield()
            let last = window.frameWork.suffix(2).map(\.elementRequests)
            if i >= 9, last.count == 2, last[0] == last[1] { break }
        }
        let settled = window.frameWork.suffix(2).map(\.elementRequests)
        #expect(settled.count == 2 && settled[0] == settled[1], "warm-up did not settle: \(settled)")
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        let allBefore = BodyProbe.counts
        for _ in 0..<20 {
            let before = names.map(BodyProbe.count)
            window.typeText("a"); window.tick()
            for (i, n) in names.enumerated() { reruns[n, default: 0] += BodyProbe.count(n) - before[i] }
            await Task.yield()
        }
        let work = window.frameWork.map(\.elementRequests)
        let bodies = BodyProbe.counts.reduce(0) { $0 + $1.value - (allBefore[$1.key] ?? 0) }
        return Typing(perFrame: work, requests: work.reduce(0, +), bodies: bodies, reruns: reruns, documentGrew: doc.buffer.version != version)
    }

    private static let gitTabNames = ["GitTab", "GitReadyTab", "GitHeader", "GitBanners", "GitFileRow", "GitListRow", "GitCommitBox", "GitErrorLine"]

    static let watched = ["IslandRow", "CodeIslandRow", "EditorAreaView", "EditorGroupView", "GroupBar", "GroupTabStrip", "FilePanelHeader",
                                  "FileTabStrip", "CodeChatColumn", "CodeSidebarView", "TitleIsland", "BranchMenu", "IslandBackdrop", "GlassBackdrop",
                                  "ChatView", "ChatColumn", "SidebarView", "AlloyScreen", "CodePanel", "FilePanelView", "TranscriptView"]

    /// Every probe's count change over `body`, run synchronously (see `probed` in ViewRerunTests).
    func allProbes(_ body: () -> Void) -> [String: Int] {
        let before = BodyProbe.counts
        body()
        return BodyProbe.counts.reduce(into: [:]) { out, kv in
            let d = kv.value - (before[kv.key] ?? 0)
            if d != 0, !kv.key.contains("#") { out[kv.key] = d }
        }
    }

    // The steady keystroke frame of Code mode, measured on this branch (Chat mode is `ViewRerunTests.steadyFrameRequests`,
    // 90). A group adds its own glass bar, tab strip, header and code view; the same file in two groups types into both.
    // History: 109 / 126 / 137 before CodeSidebarView, CodeChatColumn and CodeIslandRow became equatable.
    static let steadyCode1 = 46
    static let steadyCode2 = 62
    static let steadyCode3 = 72

    func guardTyping(_ layout: Layout, steady: Int, git useGit: Bool = false, gitTab: Bool = false, blame: Bool = false, carets: Int = 1,
                     install: ((Rig) -> Void)? = nil, settle: ((TestWindow) async -> Void)? = nil) async throws {
        let (rig, window, id) = try await rigged(layout, git: useGit, gitTab: gitTab, lines: carets > 1 ? carets : 0, install: install)
        // Whatever `install` started (a plugin process) is up before anything is measured.
        await settle?(window)
        if blame {
            // File blame on before anything is measured: the lane is reserved once, at the toggle.
            let g0 = rig.workspace.codeLayout.focusedGroupID
            let doc = try #require(rig.workspace.document("login.swift"))
            let view = try #require(CodePanelStore.existingView(for: doc, in: .group(g0)))
            try #require(gitCoordinators.last).toggleFileBlame(in: view)
            for _ in 0..<3000 where view.blame.runs.isEmpty { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
            #expect(!view.blame.runs.isEmpty, "blame loaded")
            for _ in 0..<10 { window.tick(); await Task.yield() }
        }
        let spawned = gitCoordinators.last?.spawnCount
        if useGit { #expect(exists(window, "title-branch"), "the git rig shows the branch menu") }
        let t = try await typing(window, rig, codeViewID: id, names: Self.watched + Self.gitTabNames, carets: carets)
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= steady + 2 }, "per-frame element requests \(t.perFrame)")
        #expect(t.requests <= steady * 20 * 102 / 100, "element requests \(t.requests)")
        print("TYPING \(layout.rawValue) perFrame=\(t.perFrame.first ?? 0) requests=\(t.requests) bodies=\(t.bodies) reruns=\(t.reruns.filter { $0.value > 0 })")
        for n in ["CodeIslandRow", "EditorAreaView", "CodeChatColumn", "CodeSidebarView", "TitleIsland", "IslandBackdrop", "GlassBackdrop",
                  "ChatView", "ChatColumn", "TranscriptView", "AlloyScreen"] {
            #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times")
        }
        // The branch menu in the title island is left alone by typing.
        if useGit { #expect(t.reruns["BranchMenu"] == 0, "\(layout) BranchMenu re-ran \(t.reruns["BranchMenu"] ?? -1) times") }
        // The Git tab, when shown, is left alone by typing in the editor.
        if gitTab { for n in Self.gitTabNames { #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times") } }
        // The bar shows the dirty dot: one re-run for clean to dirty, none per keystroke after that.
        for n in ["GroupBar", "GroupTabStrip", "FilePanelHeader"] { #expect(t.reruns[n]! <= 1, "\(layout) \(n) \(t.reruns[n]!)") }
        // No body is evaluated per keystroke beyond Chat's own (typing is the code view's element alone).
        let chat = try await chatBodies()
        #expect(t.bodies <= chat, "\(layout) bodies \(t.bodies) > chat \(chat)")
        // Typing starts no git process: marks and status wait for a save or an outside change.
        if useGit { #expect(gitCoordinators.last?.spawnCount == spawned, "typing spawned git") }
        withExtendedLifetime((rig, window)) {}
    }

    func chatBodies() async throws -> Int {
        let (rig, window, id) = try await rigged(.chat)
        let t = try await typing(window, rig, codeViewID: id, names: Self.watched)
        withExtendedLifetime((rig, window)) {}
        return t.bodies
    }

    @Test func typingInCodeModeHoldsTheSteadyFrameGuard() async throws { try await guardTyping(.code1, steady: Self.steadyCode1) }
    @Test func typingWithTwoGroupsHoldsItsGuard() async throws { try await guardTyping(.code2, steady: Self.steadyCode2) }
    @Test func typingWithThreeGroupsHoldsItsGuard() async throws { try await guardTyping(.code3, steady: Self.steadyCode3) }

    // The same guards with a git coordinator installed: the numbers do not move.
    @Test func typingWithGitOnHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Self.steadyCode1, git: true) }
    @Test func typingWithGitOnHoldsTheGuardCode2() async throws { try await guardTyping(.code2, steady: Self.steadyCode2, git: true) }
    @Test func typingWithGitOnHoldsTheGuardCode3() async throws { try await guardTyping(.code3, steady: Self.steadyCode3, git: true) }

    // The same guards with file blame on: typing holds the numbers and spawns nothing.
    @Test func typingWithFileBlameHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Self.steadyCode1, git: true, blame: true) }
    @Test func typingWithFileBlameHoldsTheGuardCode2() async throws { try await guardTyping(.code2, steady: Self.steadyCode2, git: true, blame: true) }
    @Test func typingWithFileBlameHoldsTheGuardCode3() async throws { try await guardTyping(.code3, steady: Self.steadyCode3, git: true, blame: true) }

    // The final guard: everything on at once (marks, status colours, the Git tab shown, file blame, the branch menu).
    @Test func typingWithEverythingOnHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Self.steadyCode1, git: true, gitTab: true, blame: true) }
    @Test func typingWithEverythingOnHoldsTheGuardCode2() async throws { try await guardTyping(.code2, steady: Self.steadyCode2, git: true, gitTab: true, blame: true) }
    @Test func typingWithEverythingOnHoldsTheGuardCode3() async throws { try await guardTyping(.code3, steady: Self.steadyCode3, git: true, gitTab: true, blame: true) }

    /// Chat mode with a coordinator installed costs what it did without one (the Chat guard).
    @Test func typingInChatWithACoordinatorHoldsTheChatGuard() async throws { try await guardTyping(.chat, steady: ViewRerunTests.steadyFrameRequests, git: true) }

    /// The hidden mode builds nothing for git: a coordinator in Chat mode runs no git body and no process on idle frames.
    @Test func theHiddenModeBuildsNothingForGit() async throws {
        let (rig, window, _) = try await rigged(.code1, git: true, gitTab: true)
        let coordinator = try #require(gitCoordinators.last)
        rig.workspace.setMode(.chat)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let spawned = coordinator.spawnCount
        var chat: [String: Int] = [:]
        for _ in 0..<20 { for (k, v) in allProbes({ window.tick() }) { chat[k, default: 0] += v }; await Task.yield() }
        for n in Self.gitTabNames + ["GitReadyTab", "CodeSidebarView", "FileTreeView"] { #expect(chat[n] == nil, "Chat mode ran \(n) \(chat[n] ?? 0) times") }
        #expect(coordinator.spawnCount == spawned)
        withExtendedLifetime(rig) {}
    }

    // The same guards with the Git tab showing in the sidebar.
    @Test func typingWithGitTabHoldsTheGuardCode1() async throws { try await guardTyping(.code1, steady: Self.steadyCode1, git: true, gitTab: true) }
    @Test func typingWithGitTabHoldsTheGuardCode2() async throws { try await guardTyping(.code2, steady: Self.steadyCode2, git: true, gitTab: true) }
    @Test func typingWithGitTabHoldsTheGuardCode3() async throws { try await guardTyping(.code3, steady: Self.steadyCode3, git: true, gitTab: true) }

    /// Idle frames with the Git tab showing: no body runs, no process starts.
    @Test func idleTicksWithGitTabSpawnNothingAndCostZero() async throws {
        let (rig, window, id) = try await rigged(.code1, git: true, gitTab: true)
        let coordinator = try #require(gitCoordinators.last)
        for focused in [false, true] {
            if focused { try window.click(window.element(identifier: id)) }
            for _ in 0..<15 { window.tick(); await Task.yield() }
            let spawned = coordinator.spawnCount
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                rig.clock.advance(by: 1)
                for (k, v) in allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                await Task.yield()
            }
            #expect(reruns.isEmpty, "idle ticks with the Git tab re-ran \(reruns)")
            #expect(coordinator.spawnCount == spawned)
        }
        withExtendedLifetime((rig, window)) {}
    }

    /// A file in `.compareHead` is a new presentation (two code views): typing in its right pane is measured against
    /// its own guard, and the `.plain` guards above hold 46/62/72.
    private static let steadyCompare = 77   // measured 75 per frame in `.compareHead` (two code views and the hunk bar)

    @Test func typingInCompareHeadStaysWithinItsGuard() async throws {
        let (rig, window, _) = try await rigged(.code1, git: true)
        let workspace = rig.workspace
        let g0 = workspace.codeLayout.focusedGroupID
        let doc = try #require(workspace.document("login.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc, in: .group(g0)))
        workspace.setPresentation(.compareHead, of: "login.swift", in: .group(g0))
        for _ in 0..<3000 where view.compare == nil { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(view.compare != nil)
        let right = "sbs-right-\(g0.uuidString)"
        for _ in 0..<200 { window.tick(); await Task.yield() }
        let spawned = gitCoordinators.last?.spawnCount
        let t = try await typing(window, rig, codeViewID: right, names: Self.watched)
        print("TYPING compareHead perFrame=\(t.perFrame.first ?? 0) requests=\(t.requests) bodies=\(t.bodies)")
        #expect(t.documentGrew)
        #expect(t.perFrame.allSatisfy { $0 <= Self.steadyCompare }, "per-frame element requests \(t.perFrame)")
        #expect(gitCoordinators.last?.spawnCount == spawned, "typing spawned git")
        withExtendedLifetime((rig, window)) {}
    }

    /// Idle frames with git on: no body runs, no process starts, and the clock moving costs nothing.
    @Test func idleTicksWithGitSpawnNothingAndCostZero() async throws {
        let (rig, window, id) = try await rigged(.code1, git: true)
        let coordinator = try #require(gitCoordinators.last)
        for focused in [false, true] {
            if focused { try window.click(window.element(identifier: id)) }
            for _ in 0..<15 { window.tick(); await Task.yield() }
            let spawned = coordinator.spawnCount
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                rig.clock.advance(by: 1)
                for (k, v) in allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                await Task.yield()
            }
            #expect(reruns.isEmpty, "idle ticks with git re-ran \(reruns)")
            #expect(coordinator.spawnCount == spawned)
        }
        withExtendedLifetime((rig, window)) {}
    }

    /// Two groups on one file cost one more group's elements, nothing more: the delta over one group is what a single
    /// further group adds (three groups minus two), within a few elements.
    @Test func twoGroupsOnOneFileCost() async throws {
        var steady: [Layout: Int] = [:]
        for layout in [Layout.chat, .code1, .code2, .code3] {
            let (rig, window, id) = try await rigged(layout)
            let t = try await typing(window, rig, codeViewID: id, names: Self.watched)
            steady[layout] = t.perFrame.max()
            print("FRAMEWORK \(layout.rawValue) steadyFrame=\(t.perFrame.max() ?? 0) requests=\(t.requests) bodies=\(t.bodies)")
            withExtendedLifetime((rig, window)) {}
        }
        let one = steady[.code1]!, two = steady[.code2]!, three = steady[.code3]!
        print("FRAMEWORK twoGroupsOnOneFile delta=\(two - one) (a third group adds \(three - two))")
        #expect(two - one <= (three - two) + (two - one) / 4 + 8, "a second group on the same file costs \(two - one) elements")
        #expect(two - one <= 20, "delta \(two - one)")
    }

    /// Idle frames: after settling, Code mode's ticks evaluate no body and cost no more elements than Chat's.
    @Test func idleTicksInCodeModeRerunNothing() async throws {
        var chatIdle: [Bool: Int] = [:]
        for layout in [Layout.chat, .code1, .code2] {
            let (rig, window, id) = try await rigged(layout)
            for focused in [false, true] {
                if focused { try window.click(window.element(identifier: id)) }
                for _ in 0..<15 { window.tick(); await Task.yield() }
                window.resetFrameWork()
                var reruns: [String: Int] = [:]
                for _ in 0..<20 {
                    for (k, v) in allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                    await Task.yield()
                }
                let work = window.frameWork
                let requests = work.reduce(0) { $0 + $1.elementRequests }
                print("IDLE \(layout.rawValue) focused=\(focused) frames=\(work.count) requests=\(requests) reruns=\(reruns)")
                #expect(reruns.isEmpty, "\(layout) idle ticks re-ran \(reruns)")
                if layout == .chat { chatIdle[focused] = requests } else {
                    #expect(requests <= chatIdle[focused]!, "\(layout) focused=\(focused) idle requests \(requests) > chat \(chatIdle[focused]!)")
                }
            }
            withExtendedLifetime((rig, window)) {}
        }
    }

    /// The Search tab open and idle: typing in the editor holds the same guard, and neither SearchView nor the sidebar re-runs.
    @Test func typingWithTheSearchTabOpenHoldsTheGuard() async throws {
        for (layout, steady) in [(Layout.code1, Self.steadyCode1), (.code2, Self.steadyCode2), (.code3, Self.steadyCode3)] {
            let (rig, window, id) = try await rigged(layout)
            rig.workspace.codeLayout.sidebarTab = .search
            for _ in 0..<5 { window.tick(); await Task.yield() }
            #expect(exists(window, "search-query"))
            let t = try await typing(window, rig, codeViewID: id, names: Self.watched + ["SearchView"])
            #expect(t.documentGrew)
            #expect(t.perFrame.allSatisfy { $0 <= steady + 2 }, "\(layout) per-frame element requests \(t.perFrame)")
            #expect(t.requests <= steady * 20 * 102 / 100, "\(layout) element requests \(t.requests)")
            for n in ["SearchView", "CodeSidebarView"] { #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times") }
            withExtendedLifetime((rig, window)) {}
        }
    }

    /// 2,000 files with one match each, searched from the Search tab and waited for; the results are on screen.
    private func finishedSearch(_ rig: Rig, _ window: TestWindow) async throws {
        for i in 0..<2_000 {
            try "needle \(i)\n".write(to: rig.root.appendingPathComponent("hit\(i).txt"), atomically: true, encoding: .utf8)
        }
        let model = rig.workspace.search
        rig.workspace.fileIndexStale = true         // no watcher event here: the files are new to the index
        model.setQuery(SearchQuery(text: "needle"))
        model.submit()
        try await window.runUntil { model.facts != nil && !model.isRunning }
        for _ in 0..<6 { window.tick(); await Task.yield() }
        #expect(model.groups.count == 2_000, "\(model.groups.count) groups, \(model.summary)")
    }

    /// Finished results (2,000 files) on screen, then typing in the editor: the same guard, and no search view re-runs.
    @Test func typingWithFinishedSearchResultsHoldsTheGuard() async throws {
        for (layout, steady) in [(Layout.code1, Self.steadyCode1), (.code2, Self.steadyCode2), (.code3, Self.steadyCode3)] {
            let (rig, window, id) = try await rigged(layout)
            rig.workspace.codeLayout.sidebarTab = .search
            for _ in 0..<5 { window.tick(); await Task.yield() }
            try await finishedSearch(rig, window)
            #expect(exists(window, "search-file-0"))
            let t = try await typing(window, rig, codeViewID: id, names: Self.watched + ["SearchView", "SearchResultsView", "SearchResultRow"])
            #expect(t.documentGrew)
            #expect(t.perFrame.allSatisfy { $0 <= steady + 2 }, "\(layout) per-frame element requests \(t.perFrame)")
            #expect(t.requests <= steady * 20 * 102 / 100, "\(layout) element requests \(t.requests)")
            for n in ["SearchView", "SearchResultsView", "SearchResultRow", "CodeSidebarView"] {
                #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times")
            }
            withExtendedLifetime((rig, window)) {}
        }
    }

    /// Stale results (already marked) while typing, with autosave firing on the manual clock: saves hit the model's
    /// guard and cost nothing; the search views never re-run.
    @Test func staleResultsWhileTypingWithAutosaveRerunNothing() async throws {
        let (rig, window, id) = try await rigged(.code1)
        rig.workspace.codeLayout.sidebarTab = .search
        for _ in 0..<5 { window.tick(); await Task.yield() }
        try await finishedSearch(rig, window)
        rig.workspace.search.noteChanged("hit0.txt")
        for _ in 0..<6 { window.tick(); await Task.yield() }
        #expect(rig.workspace.search.isStale)
        let names = Self.watched + ["SearchView", "SearchResultsView", "SearchResultRow"]
        let t = try await typing(window, rig, codeViewID: id, names: names)
        for n in ["SearchView", "SearchResultsView", "SearchResultRow"] { #expect(t.reruns[n] == 0, "\(n) re-ran \(t.reruns[n] ?? -1) times") }
        #expect(t.perFrame.allSatisfy { $0 <= Self.steadyCode1 + 2 }, "per-frame element requests \(t.perFrame)")
        // Autosave fires and saves the typed text: every save calls `noteChanged`, which returns at its guard.
        let before = BodyProbe.counts.filter { $0.key.hasPrefix("Search") }
        rig.clock.advance(by: 30)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        #expect(BodyProbe.counts.filter { $0.key.hasPrefix("Search") } == before)
        withExtendedLifetime((rig, window)) {}
    }

    /// Idle ticks with finished results on screen re-run nothing and cost no more than idle ticks with the empty tab.
    @Test func idleTicksWithFinishedSearchRerunNothing() async throws {
        let (rig, window, _) = try await rigged(.code1)
        rig.workspace.codeLayout.sidebarTab = .search
        for _ in 0..<10 { window.tick(); await Task.yield() }
        try await finishedSearch(rig, window)
        for _ in 0..<15 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            for (k, v) in allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        #expect(reruns.isEmpty, "idle ticks with finished results re-ran \(reruns)")
        let requests = window.frameWork.reduce(0) { $0 + $1.elementRequests }
        print("IDLE finished-search requests=\(requests)")
        #expect(requests == 0, "idle frames cost \(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
    }

    /// Replace across 200 files, then the review list on screen: typing in the editor holds the Code guards, no search
    /// view re-runs, and the replace itself runs the sidebar's body at most once.
    @Test func reviewListHoldsTheGuardAndReplaceRerunsTheSidebarOnce() async throws {
        for (layout, steady) in [(Layout.code1, Self.steadyCode1), (.code2, Self.steadyCode2), (.code3, Self.steadyCode3)] {
            let (rig, window, id) = try await rigged(layout)
            rig.workspace.codeLayout.sidebarTab = .search
            rig.workspace.searchReplaceRevealed = true
            for _ in 0..<5 { window.tick(); await Task.yield() }
            let model = rig.workspace.search
            for i in 0..<200 { try "needle \(i)\n".write(to: rig.root.appendingPathComponent("hit\(i).txt"), atomically: true, encoding: .utf8) }
            rig.workspace.fileIndexStale = true
            model.setQuery(SearchQuery(text: "needle")); model.submit()
            try await window.runUntil { model.facts != nil && !model.isRunning }
            for _ in 0..<6 { window.tick(); await Task.yield() }
            model.replacement = "thread"
            let sidebar = BodyProbe.count("CodeSidebarView")
            model.replaceAll()
            try await window.runUntil { model.review != nil }
            for _ in 0..<10 { window.tick(); await Task.yield() }
            #expect(model.review?.rows.count == 200)
            #expect(BodyProbe.count("CodeSidebarView") - sidebar <= 1, "\(layout) sidebar ran \(BodyProbe.count("CodeSidebarView") - sidebar) times")
            #expect(exists(window, "search-review-keep-all"))
            let t = try await typing(window, rig, codeViewID: id, names: Self.watched + ["SearchView", "SearchResultsView", "SearchReviewList", "SearchReplaceBar"])
            #expect(t.documentGrew)
            #expect(t.perFrame.allSatisfy { $0 <= steady + 2 }, "\(layout) per-frame element requests \(t.perFrame)")
            #expect(t.requests <= steady * 20 * 102 / 100, "\(layout) element requests \(t.requests)")
            for n in ["SearchView", "SearchResultsView", "SearchReviewList", "SearchReplaceBar", "CodeSidebarView"] {
                #expect(t.reruns[n] == 0, "\(layout) \(n) re-ran \(t.reruns[n] ?? -1) times")
            }
            withExtendedLifetime((rig, window)) {}
        }
    }

    /// Chat mode with a finished search held by the workspace: the Chat guard (88) is unchanged.
    @Test func chatModeWithAFinishedSearchHoldsTheGuard() async throws {
        let (rig, window, id) = try await rigged(.chat)
        let model = rig.workspace.search
        for i in 0..<200 { try "needle \(i)\n".write(to: rig.root.appendingPathComponent("hit\(i).txt"), atomically: true, encoding: .utf8) }
        rig.workspace.fileIndexStale = true
        model.setQuery(SearchQuery(text: "needle")); model.submit()
        try await window.runUntil { model.facts != nil && !model.isRunning }
        #expect(model.groups.count == 200)
        let t = try await typing(window, rig, codeViewID: id, names: Self.watched + ["SearchView", "SearchResultsView"])
        #expect(t.perFrame.allSatisfy { $0 <= 88 + 2 }, "chat per-frame element requests \(t.perFrame)")
        #expect(t.reruns["SearchView"] ?? 0 == 0 && t.reruns["SearchResultsView"] ?? 0 == 0)
        withExtendedLifetime((rig, window)) {}
    }

    /// Idle ticks with the Search tab open re-run nothing and cost no more than the file tree's idle frames.
    @Test func idleTicksWithTheSearchTabOpenCostNothing() async throws {
        var idle: [String: Int] = [:]
        for tab in [SidebarTab.files, .search] {
            let (rig, window, _) = try await rigged(.code1)
            rig.workspace.codeLayout.sidebarTab = tab
            for _ in 0..<15 { window.tick(); await Task.yield() }
            window.resetFrameWork()
            var reruns: [String: Int] = [:]
            for _ in 0..<20 {
                for (k, v) in allProbes({ window.tick() }) { reruns[k, default: 0] += v }
                await Task.yield()
            }
            let requests = window.frameWork.reduce(0) { $0 + $1.elementRequests }
            print("IDLE tab=\(tab.rawValue) requests=\(requests) reruns=\(reruns)")
            #expect(reruns.isEmpty, "\(tab) idle ticks re-ran \(reruns)")
            idle[tab.rawValue] = requests
            withExtendedLifetime((rig, window)) {}
        }
        #expect(idle["search"]! <= idle["files"]!, "search idle \(idle["search"]!) > files idle \(idle["files"]!)")
    }

    /// Chat mode with the Search tab saved as the sidebar tab: the Chat guard (88) is unchanged, the tab builds nothing.
    @Test func chatModeIgnoresTheSavedSearchTab() async throws {
        let (rig, window, id) = try await rigged(.chat)
        rig.workspace.codeLayout.sidebarTab = .search
        let t = try await typing(window, rig, codeViewID: id, names: Self.watched + ["SearchView"])
        #expect(t.perFrame.allSatisfy { $0 <= 88 + 2 }, "chat per-frame element requests \(t.perFrame)")
        #expect(t.reruns["SearchView"] ?? 0 == 0)
        #expect(!exists(window, "search-query"))
        withExtendedLifetime((rig, window)) {}
    }

    /// The mode not shown builds nothing and costs nothing per frame.
    @Test func theHiddenModeBuildsNothing() async throws {
        let (rig, window, _) = try await rigged(.code1)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        var code: [String: Int] = [:]
        for _ in 0..<20 { for (k, v) in allProbes({ window.tick() }) { code[k, default: 0] += v }; await Task.yield() }
        for n in ["IslandRow", "SidebarView", "FilePanelView"] { #expect(code[n] == nil, "Code mode ran \(n) \(code[n] ?? 0) times") }
        #expect(!exists(window, "island-files") && !exists(window, "island-sidebar"))
        rig.workspace.setMode(.chat)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        var chat: [String: Int] = [:]
        for _ in 0..<20 { for (k, v) in allProbes({ window.tick() }) { chat[k, default: 0] += v }; await Task.yield() }
        for n in ["CodeIslandRow", "EditorGroupView", "CodeChatColumn", "CodeSidebarView", "EditorAreaView", "GroupBar"] {
            #expect(chat[n] == nil, "Chat mode ran \(n) \(chat[n] ?? 0) times")
        }
        #expect(!exists(window, "code-screen"))
        withExtendedLifetime(rig) {}
    }

    /// Streaming chunks re-run the transcript, not the editor, its strip or header, or the tree; typing re-runs no chat.
    @Test func streamingAndTypingStayInTheirColumns() async throws {
        let (rig, window, id) = try await rigged(.code2)
        let a = try #require(rig.workspace.sessions.first)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let editor = ["EditorAreaView", "EditorGroupView", "GroupBar", "GroupTabStrip", "FilePanelHeader", "CodePanel", "CodeSidebarView", "CodeIslandRow"]
        var streamed: [String: Int] = [:]
        for i in 0..<10 {
            await rig.transports[0].emit(.assistantBlock(messageID: "s\(i)", block: .text("chunk \(i)")))
            for _ in 0..<20_000 where a.transcript.blocks.count < i + 1 { await Task.yield() }
            for (k, v) in allProbes({ window.tick() }) { streamed[k, default: 0] += v }
            await Task.yield()
        }
        print("STREAM reruns=\(streamed)")
        #expect((streamed["TranscriptView"] ?? 0) >= 10)
        for n in editor { #expect(streamed[n] == nil, "streaming re-ran \(n) \(streamed[n] ?? 0) times") }
        // Typing: the chat column, transcript and composer stay.
        try window.click(window.element(identifier: id))
        for _ in 0..<5 { window.tick(); await Task.yield() }
        var typed: [String: Int] = [:]
        for _ in 0..<10 { for (k, v) in allProbes({ window.typeText("a"); window.tick() }) { typed[k, default: 0] += v }; await Task.yield() }
        for n in ["CodeChatColumn", "SessionMenuHeader", "ChatView", "ChatColumn", "TranscriptView", "ComposerView"] {
            #expect(typed[n] == nil, "typing re-ran \(n) \(typed[n] ?? 0) times")
        }
    }

    /// Chat to Code and back keeps the caret, scroll, open find and unsaved text, and the undo history; nothing is written.
    @Test func aSwitchKeepsCaretScrollFindAndUndo() async throws {
        let rig = Rig()
        let lines = (0..<400).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        try lines.write(to: rig.root.appendingPathComponent("big.swift"), atomically: true, encoding: .utf8)
        rig.workspace.openFilePath = "big.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { self.exists(window, "code-view") }
        let doc = try #require(rig.workspace.document("big.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        // Opening find moves focus to its field (a blur in Chat mode saves, by today's rule), so open it first, then
        // type unsaved text into the code view.
        view.showFind(); view.setQuery("value3")
        for _ in 0..<10 { window.tick(); await Task.yield() }
        try window.click(window.element(identifier: "code-view"))
        window.typeText("x")
        for _ in 0..<10 { window.tick(); await Task.yield() }
        rig.workspace.selectionState(for: "big.swift", in: .chat)!.select(120..<125)
        view.scroll.position = CodeScrollPosition(row: 40, x: 0)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let caret = rig.workspace.selectionState(for: "big.swift", in: .chat)!.primarySelection.range, scroll = view.scroll.position, text = doc.buffer.snapshot().text
        let writes = rig.workspace.writeCount, version = doc.buffer.version
        #expect(doc.buffer.canUndo && doc.isDirty)
        rig.workspace.setMode(.code)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        rig.workspace.setMode(.chat)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let after = try #require(CodePanelStore.existingView(for: doc))
        #expect(after === view)
        #expect(rig.workspace.selectionState(for: "big.swift", in: .chat)?.primarySelection.range == caret)
        #expect(after.scroll.position == scroll, "scroll \(after.scroll.position) vs \(scroll)")
        #expect(after.findVisible && after.findQuery == "value3")
        #expect(doc.buffer.snapshot().text == text && doc.isDirty && doc.buffer.canUndo)
        #expect(doc.buffer.version == version)
        #expect(rig.workspace.writeCount == writes)
        #expect(rig.workspace.document("big.swift") === doc)
    }
}
