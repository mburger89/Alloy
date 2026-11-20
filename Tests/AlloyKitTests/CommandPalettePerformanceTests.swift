@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The palette's cost: closed it adds nothing to a frame, open it re-runs only itself, and ranking is fast. The
/// Chat and Code steady-frame guards (`ViewRerunTests`, `CodeModePerformanceTests`) run with the palette layer wired in
/// and closed, so they hold the "closed costs nothing" line for typing.
@MainActor
@Suite struct CommandPalettePerformanceTests {
    private func exists(_ window: TestWindow, _ id: String) -> Bool { (try? window.element(identifier: id)) != nil }

    /// The element requests of one settled idle frame.
    private func idleFrame(_ window: TestWindow) async -> Int {
        var last = -1
        for _ in 0..<40 {
            window.resetFrameWork()
            window.tick()
            await Task.yield()
            let now = window.frameWork.last?.elementRequests ?? -1
            if now == last { return now }
            last = now
        }
        return last
    }

    @Test func closedAfterOpenReturnsToTheSteadyCount() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        let before = await idleFrame(window)
        window.typeKey("p", modifierFlags: [.command, .shift])
        try await window.runUntil { self.exists(window, "command-palette-field") }
        window.typeKey(.escape)
        try await window.runUntil { !self.exists(window, "command-palette-field") }
        let after = await idleFrame(window)
        #expect(after == before, "steady element requests \(before) before, \(after) after")
    }

    @Test func toggledSettingAndOpenSettingsWindowLeaveTheMainIdleFrameAlone() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        let before = await idleFrame(window)
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { self.exists(settings, "settings-view") }
        try settings.click(settings.element(identifier: "settings-palette-show-disabled"))
        try await settings.runUntil { !rig.workspace.settings.paletteShowsDisabled }
        let after = await idleFrame(window)
        #expect(after == before, "steady element requests \(before) before, \(after) after")
        window.resetFrameWork()
        for _ in 0..<5 { window.tick() }
        #expect(window.frameWork.reduce(0) { $0 + $1.elementRequests } == 0)
        await rig.workspace.stopAll()
    }

    @Test func openKeyboardSectionLeavesTheMainIdleFrameAlone() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        let before = await idleFrame(window)
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { self.exists(settings, "settings-keyboard") }
        let after = await idleFrame(window)
        #expect(after == before, "steady element requests \(before) before, \(after) after")
        await rig.workspace.stopAll()
    }

    @Test func openKeyboardSectionIdleRequestsNothing() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { self.exists(settings, "settings-keyboard") }
        for _ in 0..<10 { settings.tick(); await Task.yield() }
        settings.resetFrameWork()
        for _ in 0..<5 { settings.tick() }
        #expect(settings.frameWork.reduce(0) { $0 + $1.elementRequests } == 0)
    }

    /// A rebind rebuilds the keymap and menus once; the main window's steady frame is the same afterwards, in Chat and
    /// in Code mode (the guard constants themselves are asserted by `ViewRerunTests` and `CodeModePerformanceTests`).
    @Test func rebindLeavesMainWindowSteadyCounts() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        for mode in [WorkspaceMode.chat, WorkspaceMode.code] {
            rig.workspace.setMode(mode)
            for _ in 0..<10 { window.tick(); await Task.yield() }
            let before = await idleFrame(window)
            var s = rig.workspace.settings
            s.keybindings = ["view.toggleChatColumn": "cmd+alt+shift+j", "go.quickOpen": "none"]
            try rig.workspace.updateSettings(s)
            for _ in 0..<10 { window.tick(); await Task.yield() }
            let after = await idleFrame(window)
            #expect(after == before, "\(mode): steady element requests \(before) before, \(after) after a rebind")
            s.keybindings = [:]
            try rig.workspace.updateSettings(s)
        }
        await rig.workspace.stopAll()
    }

    @Test func idleFramesWithTheOpenPaletteRequestNothing() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        window.typeKey("p", modifierFlags: [.command, .shift])
        try await window.runUntil { self.exists(window, "command-palette-field") }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        for _ in 0..<5 { window.tick() }
        // A frame with nothing to do is not drawn at all, so it records no work; any recorded frame must request nothing.
        #expect(window.frameWork.reduce(0) { $0 + $1.elementRequests } == 0)
    }

    @Test func typingIntoTheOpenPaletteLeavesTheScreenAlone() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        window.typeKey("p", modifierFlags: [.command, .shift])
        try await window.runUntil { self.exists(window, "command-palette-field") }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        var reruns = 0
        for i in 0..<20 {
            let before = BodyProbe.count("AlloyScreen")
            window.typeText(i % 2 == 0 ? "s" : "p")
            window.tick()
            reruns += BodyProbe.count("AlloyScreen") - before
            await Task.yield()
        }
        #expect(reruns == 0, "AlloyScreen re-ran \(reruns) times")
        #expect(exists(window, "command-palette-field"))
    }

    /// Ranking does bounded work, counted rather than timed; the release timing is in the Benchmarks package
    /// ("CommandPalette ranking").
    @Test func rankingTwoThousandCommandsDoesBoundedWork() {
        let titles = (0..<2_000).map { "Category \($0 % 17): Do Something Number \($0) With Words" }
        let expectedTop: [String: [Int]] = ["do so": [0, 1, 2], "num 19": [19, 190, 191], "cat 3 words": [3, 20, 34], "xyz": []]
        for (query, top) in expectedTop.sorted(by: { $0.key < $1.key }) {
            let (results, work) = FuzzyMatch.topIndicesCounting(query: query, in: titles, limit: 50)
            let units = query.unicodeScalars.filter { !$0.properties.isWhitespace }.count
            let bound = titles.reduce(0) { $0 + units * $1.utf8.count }
            #expect(work.candidatesScored == titles.count, "\(query): every candidate is considered")
            #expect(work.cellsEvaluated <= bound, "\(query): \(work.cellsEvaluated) cells beyond the bound \(bound)")
            #expect(results.count <= 50)
            // Same results as the plain call.
            let plain = FuzzyMatch.topIndices(query: query, in: titles, limit: 50)
            #expect(plain.map(\.index) == results.map(\.index))
            if query == "xyz" { #expect(results.isEmpty && work.cellsEvaluated == 0) }
            #expect(results.prefix(3).map(\.index) == top, "\(query): top three")
        }
    }
}
