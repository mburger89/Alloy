@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SettingsViewTests {
    private func open(_ window: TestWindow) async throws {
        try window.click(window.element(identifier: "settings"))
        try await window.runUntil { (try? window.element(identifier: "settings-view")) != nil }
    }

    private func gone(_ window: TestWindow, _ id: String) async throws {
        try await window.runUntil { (try? window.element(identifier: id)) == nil }
    }

    @Test func gearOpensSettingsViewAndEscCloses() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect((try? window.element(identifier: "settings-view")) == nil)
        try await open(window)
        for id in ["settings-close", "settings-claude-path", "settings-share-knowledge", "settings-ask-shared-notes",
                   "settings-reset"] {
            _ = try window.element(identifier: id)
        }
        window.typeKey(.escape)
        try await gone(window, "settings-view")
        // The close button does the same.
        try await open(window)
        try window.click(window.element(identifier: "settings-close"))
        try await gone(window, "settings-view")
    }

    @Test func existingSettingsIdsStillWork() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "settings-detect"))
        try await window.runUntil { (try? window.element(identifier: "settings-detected")) != nil }
        let text = try window.element(identifier: "settings-detected")
        #expect((text.value ?? text.label ?? "").contains("/fake/claude"))

        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeText("/opt/claude")
        try window.click(window.element(identifier: "settings-save"))
        try await window.runUntil { rig.workspace.settings.claudePath == "/opt/claude" }
        try await window.runUntil { (try? window.element(identifier: "settings-saved")) != nil }
        _ = try window.element(identifier: "settings-view")   // Save does not close the view
        // Editing the path clears "Saved"; Return in the field saves again.
        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeText("2")
        try await window.runUntil { (try? window.element(identifier: "settings-saved")) == nil }
        window.typeKey(.return)
        try await window.runUntil { rig.workspace.settings.claudePath == "/opt/claude2" }
        try await window.runUntil { (try? window.element(identifier: "settings-saved")) != nil }
        _ = try window.element(identifier: "settings-view")
        #expect(AlloySettings.load(appSupport: rig.root.appendingPathComponent("support")).claudePath == "/opt/claude2")
        // Detect clears the field; Save then clears the override.
        try window.click(window.element(identifier: "settings-detect"))
        try window.click(window.element(identifier: "settings-save"))
        try await window.runUntil { rig.workspace.settings.claudePath == nil }
    }

    @Test func togglesPersistAndRelaunchAtIdle() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.systemInit(SystemInit(model: "claude-opus-5-5", permissionMode: "default", sessionID: "s",
                                                            tools: [], slashCommands: [], terminalSlashCommands: [])))
        await rig.transports[0].emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1,
                                                        outputTokens: 1, sessionID: "s", terminalReason: nil,
                                                        cacheCreationTokens: 0, cacheReadTokens: 0)))
        for _ in 0..<20_000 where !(s.status == .idle && s.hasConversation) { await Task.yield() }
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "settings-ask-shared-notes"))
        try await window.runUntil { rig.workspace.settings.askBeforeSharedNotes }
        await rig.workspace.settle()
        let support = rig.root.appendingPathComponent("support")
        #expect(AlloySettings.load(appSupport: support).askBeforeSharedNotes)
        #expect(rig.transports.count == 2, "relaunched at idle")
        try window.click(window.element(identifier: "settings-share-knowledge"))
        try await window.runUntil { !rig.workspace.settings.shareKnowledge }
        #expect(!AlloySettings.load(appSupport: support).shareKnowledge)
        // Back to defaults restores the two toggles and nothing else.
        var custom = rig.workspace.settings
        custom.claudePath = "/keep/me"
        try rig.workspace.updateSettings(custom)
        try window.click(window.element(identifier: "settings-reset"))
        try await window.runUntil { rig.workspace.settings.shareKnowledge && !rig.workspace.settings.askBeforeSharedNotes }
        #expect(rig.workspace.settings.claudePath == "/keep/me")
        await rig.workspace.stopAll()
    }

    @Test func rereadStatShowsOnlyWhenNonZero() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        // A window just wide enough that the split view gives the sidebar its 200 pt minimum.
        let window = try TestWindow(size: Size(width: Pixels(760), height: Pixels(800))) { rootView(workspace: rig.workspace) }
        window.tick(); window.tick()
        let id = "session-rereads-\(a.id.uuidString)"
        try await window.runUntil { (try? window.element(identifier: "session-row-\(a.id.uuidString)")) != nil }
        #expect((try? window.element(identifier: id)) == nil)
        a.redundantReads = 12
        // The worst row: the longest status word, a large cost and token count, a mode badge.
        a.status = .awaitingPermission
        a.costUSD = 123.45
        a.inputTokens = 123_400
        a.permissionMode = "acceptEdits"
        a.model = "claude-opus-5-5"
        try await window.runUntil { (try? window.element(identifier: id)) != nil }
        let stat = try window.element(identifier: id)
        #expect((stat.value ?? stat.label) == "12 re-reads")
        let row = try window.element(identifier: "session-row-\(a.id.uuidString)")
        #expect(row.frame.size.width.value <= 200.5, "sidebar is at its minimum: \(row.frame)")
        // Every text of the row stays inside it, and the stat is not clipped by the menu button.
        let menu = try window.element(identifier: "session-menu-\(a.id.uuidString)")
        for e in descendants(of: row, in: window) where e.role == .staticText {
            #expect(e.frame.minX >= row.frame.minX && e.frame.maxX <= row.frame.maxX, "\(e.identifier ?? e.label ?? "")")
            #expect(e.frame.minY >= row.frame.minY && e.frame.maxY <= row.frame.maxY, "\(e.identifier ?? e.label ?? "")")
        }
        for e in descendants(of: row, in: window) where e.role == .staticText {
            #expect(e.frame.maxX <= menu.frame.minX, "\(e.identifier ?? e.label ?? "") \(e.frame) menu \(menu.frame)")
        }
        a.redundantReads = 0
        try await window.runUntil { (try? window.element(identifier: id)) == nil }
    }

    @Test func knowledgeStatsCount() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let stats = try window.element(identifier: "knowledge-stats")
        #expect((stats.value ?? stats.label) == "Notes used 0\u{00D7} \u{00B7} 0 repeat reads")
        rig.workspace.notesServed = 3
        rig.workspace.redundantReads = 5
        try await window.runUntil {
            ((try? window.element(identifier: "knowledge-stats"))?.value ?? (try? window.element(identifier: "knowledge-stats"))?.label)
                == "Notes used 3\u{00D7} \u{00B7} 5 repeat reads"
        }
    }

    @Test func knowledgeStatsAndRereadCountsHideWhileSharingIsOff() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        a.redundantReads = 4
        rig.workspace.notesServed = 2
        let window = try TestWindow(size: Size(width: Pixels(760), height: Pixels(800))) { rootView(workspace: rig.workspace) }
        window.tick(); window.tick()
        let rereads = "session-rereads-\(a.id.uuidString)"
        try await window.runUntil { (try? window.element(identifier: "knowledge-stats")) != nil && (try? window.element(identifier: rereads)) != nil }
        try rig.workspace.updateSettings(AlloySettings(shareKnowledge: false))
        try await window.runUntil { (try? window.element(identifier: "knowledge-stats")) == nil && (try? window.element(identifier: rereads)) == nil }
        try rig.workspace.updateSettings(AlloySettings(shareKnowledge: true))
        try await window.runUntil { (try? window.element(identifier: "knowledge-stats")) != nil && (try? window.element(identifier: rereads)) != nil }
        await rig.workspace.stopAll()
    }

    // MARK: Keys and focus

    private func twoSessions(_ rig: Rig) async -> (Session, Session) {
        let a = await rig.workspace.newSession(name: "A")
        let b = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = a.id
        return (a, b)
    }

    @Test func escWhileThePathFieldIsFocusedCloses() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeText("/x")
        window.typeKey(.escape)
        try await gone(window, "settings-view")
    }

    @Test func selectingAnotherSessionKeepsKeysFromTheComposer() async throws {
        let rig = Rig()
        let (_, b) = await twoSessions(rig)
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "session-name-\(b.id.uuidString)"))
        for _ in 0..<5 { window.tick() }
        window.typeText("leak")
        window.typeKey(.escape)
        try await gone(window, "settings-view")
        let composer = try window.element(identifier: "composer")
        #expect(!(composer.value ?? "").contains("leak"), "\(composer.value ?? "")")
        #expect(await rig.transports[1].sentAfterInitialize.isEmpty)
    }

    @Test func closingRestoresComposerFocus() async throws {
        let rig = Rig()
        _ = await twoSessions(rig)
        let window = try alloyWindow(rig.workspace)
        try window.click(window.element(identifier: "composer"))
        for _ in 0..<3 { window.tick() }   // focus changes reach the model one frame later
        #expect(try window.element(identifier: "composer").isFocused)
        try await open(window)
        #expect(!(try window.element(identifier: "composer").isFocused), "Settings holds the keyboard")
        window.typeKey(.escape)
        try await gone(window, "settings-view")
        for _ in 0..<3 { window.tick() }
        #expect(try window.element(identifier: "composer").isFocused)
    }

    @Test func escWithQuickOpenClosesOnlyQuickOpen() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        window.typeKey("p", modifierFlags: .command)
        try await window.runUntil { (try? window.element(identifier: "quick-open-field")) != nil }
        window.typeKey(.escape)
        try await window.runUntil { (try? window.element(identifier: "quick-open-field")) == nil }
        _ = try window.element(identifier: "settings-view")
    }

    // MARK: Failures and relaunches

    @Test func failedPathSaveShowsErrorAndEditingClearsIt() async throws {
        let rig = Rig()
        // A file where the support directory should be: the settings file cannot be created.
        try Data().write(to: rig.root.appendingPathComponent("support"))
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeText("/opt/claude")
        try window.click(window.element(identifier: "settings-save"))
        try await window.runUntil { (try? window.element(identifier: "settings-error")) != nil }
        #expect((try? window.element(identifier: "settings-saved")) == nil)
        _ = try window.element(identifier: "settings-view")
        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeText("2")
        try await window.runUntil { (try? window.element(identifier: "settings-error")) == nil }
    }

    @Test func threeTogglesMidTurnRelaunchOnce() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.systemInit(SystemInit(model: "claude-opus-5-5", permissionMode: "default", sessionID: "s",
                                            tools: [], slashCommands: [], terminalSlashCommands: [])))
        for _ in 0..<20_000 where s.status != .working { await Task.yield() }
        #expect(s.status == .working)
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "settings-share-knowledge"))
        try await window.runUntil { !rig.workspace.settings.shareKnowledge }
        try window.click(window.element(identifier: "settings-ask-shared-notes"))
        try await window.runUntil { rig.workspace.settings.askBeforeSharedNotes }
        try window.click(window.element(identifier: "settings-share-knowledge"))
        try await window.runUntil { rig.workspace.settings.shareKnowledge }
        await rig.workspace.settle()
        #expect(rig.transports.count == 1, "no relaunch mid-turn")
        await t.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1,
                                        sessionID: "s", terminalReason: nil, cacheCreationTokens: 0, cacheReadTokens: 0)))
        for _ in 0..<20_000 where rig.transports.count < 2 { await Task.yield() }
        await rig.workspace.settle()
        for _ in 0..<200 { await Task.yield() }
        #expect(rig.transports.count == 2, "exactly one relaunch")
        await rig.workspace.stopAll()
    }

    @Test func shareOtherProjectsToggleSaves() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        #expect(try window.element(identifier: "settings-share-other-projects").isEnabled)
        try window.click(window.element(identifier: "settings-share-other-projects"))
        try await window.runUntil { !rig.workspace.settings.shareAcrossProjects }
        #expect(!AlloySettings.load(appSupport: rig.root.appendingPathComponent("support")).shareAcrossProjects)
        await rig.workspace.stopAll()
    }

    @Test func shareOtherProjectsDisabledWithoutSharing() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        try window.click(window.element(identifier: "settings-share-knowledge"))
        try await window.runUntil { !rig.workspace.settings.shareKnowledge }
        try await window.runUntil { (try? window.element(identifier: "settings-share-other-projects").isEnabled) == false }
        try window.click(window.element(identifier: "settings-share-other-projects"))
        for _ in 0..<50 { window.tick() }
        #expect(rig.workspace.settings.shareAcrossProjects, "a disabled toggle does not change")
        await rig.workspace.stopAll()
    }

    @Test func panelHasLabelAndRole() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        try await open(window)
        let view = try window.element(identifier: "settings-view")
        #expect(view.label == "Settings")
        #expect(view.role == .group)
    }
}
