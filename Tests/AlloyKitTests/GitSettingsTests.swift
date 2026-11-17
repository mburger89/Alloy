@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct GitSettingsTests {
    static let modified = "l1\nL2\nl3\nl4\nl5\nL6\nl7\nl8\n"

    private func settingsWindow(_ workspace: Workspace) async throws -> TestWindow {
        let main = try alloyWindow(workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-git-section")) != nil }
        return settings
    }

    @Test func defaultsAreLiveMarksOffOthersOn() {
        let g = AlloySettings().git
        #expect(g.gutterMarks && g.statusColours && !g.liveMarks && g.gitPath.isEmpty)
    }

    @Test func sectionHasItsIdsAndTheDraftNote() async throws {
        let rig = Rig()
        let window = try await settingsWindow(rig.workspace)
        for id in ["settings-git-section", "settings-git-gutter-marks", "settings-git-status-colours", "settings-git-live-marks",
                   "settings-git-path", "settings-git-draft-note"] {
            _ = try window.element(identifier: id)
        }
        let note = try window.element(identifier: "settings-git-draft-note")
        #expect((note.label ?? note.value ?? "").contains("unencrypted"))
    }

    @Test func togglesPersistThroughUpdateSettings() async throws {
        let rig = Rig()
        let window = try await settingsWindow(rig.workspace)
        let before = rig.workspace.settingsSaveCount
        try window.click(window.element(identifier: "settings-git-live-marks"))
        window.tick()
        #expect(rig.workspace.settings.git.liveMarks)
        #expect(rig.workspace.settingsSaveCount == before + 1)
        try window.click(window.element(identifier: "settings-git-status-colours"))
        window.tick()
        #expect(!rig.workspace.settings.git.statusColours)
        let reloaded = AlloySettings.load(appSupport: rig.workspace.appSupport)
        #expect(reloaded.git.liveMarks && !reloaded.git.statusColours && reloaded.git.gutterMarks)
    }

    @Test func gutterMarksOffRemovesMarks() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("shown") { m.marks.isShowing }
        var s = m.workspace.settings
        s.git.gutterMarks = false
        try m.workspace.updateSettings(s, persist: false)
        await m.settle("removed") { !m.marks.isShowing }
        s.git.gutterMarks = true
        try m.workspace.updateSettings(s, persist: false)
        await m.settle("back") { m.marks.isShowing }
    }

    @Test func statusColoursOffClearsTreeWithoutASpawn() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        let cell = m.coordinator.tree.cell(for: "a.txt")
        await m.settle("coloured") { cell.status != nil }
        let spawned = m.coordinator.spawnCount
        var s = m.workspace.settings
        s.git.statusColours = false
        try m.workspace.updateSettings(s, persist: false)
        #expect(cell.status == nil)
        s.git.statusColours = true
        try m.workspace.updateSettings(s, persist: false)
        #expect(cell.status != nil)
        await m.quiesce(20)
        #expect(m.coordinator.spawnCount == spawned, "no git process for a colour toggle")
    }

    @Test func liveMarksOnStartsTheIdleTaskAndOffStopsIt() async throws {
        let m = try await MarkRig.make(worktree: ["a.txt": Self.modified])
        await m.settle("shown") { m.marks.isShowing }
        await m.quiesce()
        var s = m.workspace.settings
        s.git.liveMarks = true
        try m.workspace.updateSettings(s, persist: false)
        await m.quiesce(20)
        let n = m.marks.recomputeCount
        let end = m.doc.buffer.snapshot().utf8Count
        m.doc.buffer.replace(end..<end, with: "tail\n")
        await m.quiesce(20)
        m.rig.clock.advance(by: 0.9)
        await m.settle("recomputed while typing", advance: 0) { m.marks.recomputeCount == n + 1 }
        // Off again: a pending timer is dropped and later edits start none.
        m.doc.buffer.replace(0..<0, with: "x\n")
        await m.quiesce(20)
        s.git.liveMarks = false
        try m.workspace.updateSettings(s, persist: false)
        await m.quiesce(20)
        let after = m.marks.recomputeCount
        m.rig.clock.advance(by: 0.9)   // past the 750 ms idle, short of the autosave (a save recomputes on its own)
        await m.quiesce(40)
        #expect(m.marks.recomputeCount == after)
    }
}
