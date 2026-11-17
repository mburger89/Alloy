@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A Code-mode window on one file of a real repository with a git coordinator installed.
@MainActor
struct MarkRig {
    let rig: Rig
    let coordinator: GitCoordinator
    let window: TestWindow
    let pane: PaneID
    let path: String
    let doc: EditorDocument
    let view: OpenDocumentView
    var marks: GitDocumentMarks { view.gitMarks! }
    var workspace: Workspace { rig.workspace }

    static let base = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\n"

    /// `files` are committed (unless `commit` is false); `worktree` is written afterwards (modified, new or untracked
    /// files). `rig` may be given to reuse one with a ledger. The file `open` is shown in a group of Code mode.
    static func make(files: [String: String] = ["a.txt": base], worktree: [String: String] = [:], commit: Bool = true,
                     open path: String = "a.txt", rig given: Rig? = nil, initRepo: Bool = true, mode: Mode = .code,
                     configure: ((GitCoordinator) -> Void)? = nil) async throws -> MarkRig {
        let rig = given ?? Rig()
        if initRepo { try git(rig.root, "init", "-q", "-b", "main") }
        for (rel, text) in files { try writeFile(rig.root, rel, text) }
        if commit { try git(rig.root, "add", "-A"); try git(rig.root, "commit", "-qm", "init") }
        for (rel, text) in worktree { try writeFile(rig.root, rel, text) }
        let coordinator = GitCoordinator.install(on: rig.workspace)
        configure?(coordinator)
        await coordinator.service.refreshNow()
        let workspace = rig.workspace
        let pane: PaneID
        if mode == .code {
            await workspace.restoreUIState()
            workspace.setMode(.code)
            let g0 = workspace.codeLayout.focusedGroupID
            pane = .group(g0)
            await workspace.open(path, in: pane)
        } else {
            pane = .chat
            workspace.openFilePath = path
        }
        let window = try alloyWindow(workspace)
        let id = mode == .code ? "code-view-\(workspace.codeLayout.focusedGroupID.uuidString)" : "code-view"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        let doc = try #require(workspace.document(path))
        var found: OpenDocumentView?
        for _ in 0..<2000 where found == nil { found = CodePanelStore.existingView(for: doc, in: pane); window.tick(); await Task.yield() }
        let view = try #require(found)
        for _ in 0..<2000 where view.gitMarks == nil { window.tick(); await Task.yield() }
        _ = try #require(view.gitMarks)
        return MarkRig(rig: rig, coordinator: coordinator, window: window, pane: pane, path: path, doc: doc, view: view)
    }

    enum Mode { case code, chat }

    /// Ticks, yields and advances the clock until `condition` holds.
    func settle(_ what: String, advance: Double = 0.01, _ condition: () -> Bool) async {
        for _ in 0..<3000 where !condition() {
            if advance > 0 { rig.clock.advance(by: advance) }
            window.tick()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition(), Comment(rawValue: "never became true: \(what)"))
    }

    /// Lets everything already scheduled finish (a recompute that finds nothing to change has no condition to wait for).
    func quiesce(_ rounds: Int = 60) async {
        for _ in 0..<rounds { window.tick(); try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    var text: String { doc.buffer.snapshot().text }

    /// Replaces the buffer's text (one edit) and saves it.
    func edit(to new: String, save: Bool = true) async throws {
        let n = doc.buffer.snapshot().utf8Count
        doc.buffer.replace(0..<n, with: new)
        if save { try await workspace.save(path) }
    }

    /// The 3 pt gutter bars the code view draws, top to bottom (as the diff tests find them).
    func bars() -> [MUIRect] {
        window.allRects.filter { $0.bounds.size.width == 3 && $0.bounds.origin.x > 150 && $0.bounds.size.height <= 40 }
            .sorted { $0.bounds.origin.y < $1.bounds.origin.y }
    }
}
