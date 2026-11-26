@testable import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SettingsViewTests {
    /// Opens Settings from the main window's menu; the result is the Settings window.
    private func open(_ main: TestWindow) async throws -> TestWindow {
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-view")) != nil }
        return settings
    }

    @Test func menuItemOpensASettingsWindowAndEscCloses() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        #expect((try? main.element(identifier: "settings-view")) == nil)
        #expect(!main.settingsController.isOpen)
        let window = try await open(main)
        #expect(main.settingsController.isOpen)
        #expect(window !== main)
        #expect((try? main.element(identifier: "settings-view")) == nil, "not an overlay in the main window")
        #expect(window.window.title == "Settings")
        for id in ["settings-title", "settings-claude-path", "settings-share-knowledge", "settings-ask-shared-notes",
                   "settings-reset"] {
            _ = try window.element(identifier: id)
        }
        // The traffic lights close the window, so the title island has no close button of its own.
        #expect((try? window.element(identifier: "settings-close")) == nil)
        window.typeKey(.escape)
        try await closed(main)
    }

    /// Esc closes the window when the focus is elsewhere too (the window-level cancel shortcut).
    @Test func escClosesWhereverTheFocusIs() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeKey(.escape)
        try await closed(main)
    }

    /// The window's own close (its red button) forgets it too, so the next open makes a new one.
    @Test func closingTheWindowForgetsIt() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let first = try await open(main)
        first.close()
        try await closed(main)
        let second = try await open(main)
        #expect(second !== first)
        #expect(main.settingsController.isOpen)
    }

    /// Asking again while Settings is open brings the open window to the front; no second window.
    @Test func menuItemWhileSettingsIsOpenFrontsIt() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        let before = window.platformWindow.orderFrontCalls
        let again = try main.openSettingsFromMenu()
        #expect(again === window)
        #expect(window.platformWindow.orderFrontCalls == before + 1)
        #expect(main.testApp.windows.filter { $0 !== main }.count == 1, "one Settings window")
        _ = try window.element(identifier: "settings-view")
    }

    /// Closing the controller (the main window's close does) closes the Settings window.
    @Test func controllerCloseClosesTheWindow() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        main.settingsController.close()
        #expect(!main.settingsController.isOpen)
        #expect(window.platformWindow.isClosed)
    }

    @Test func settingsViewRendersInItsOwnWindowWithoutAnyRootView() async throws {
        let rig = Rig()
        let window = try TestWindow(size: SettingsWindowController.windowSize) {
            settingsWindowElement(SettingsWindowRoot(workspace: rig.workspace, themes: nil, close: {}, gone: {}))
        }
        window.tick(); window.tick()
        _ = try window.element(identifier: "settings-view")
    }

    /// The Settings window looks like the main one: a title island reading "Settings" across the top, the content in one
    /// island below it, both inset by the style's gutter and sharing its corner radius.
    @Test func settingsWindowIsATitleIslandOverAContentIsland() throws {
        let rig = Rig()
        let style = AppearanceStyle.defaults
        let window = try TestWindow(size: SettingsWindowController.windowSize) {
            settingsWindowElement(SettingsWindowRoot(workspace: rig.workspace, themes: nil, close: {}, gone: {}))
        }
        window.tick(); window.tick()
        let title = try window.element(identifier: "island-settings-title").frame
        let content = try window.element(identifier: "island-settings").frame
        let gutter = Pixels(Float(style.gutter))
        #expect(title.minX == gutter && title.minY == gutter)
        #expect(title.maxY - title.minY == Pixels(Float(style.titleIslandHeight)))
        #expect(content.minX == gutter)
        #expect(content.minY - title.maxY == gutter)
        #expect(content.maxY == SettingsWindowController.windowSize.height - gutter)
        #expect(content.maxX == SettingsWindowController.windowSize.width - gutter)
        let label = try window.element(identifier: "settings-title")
        #expect(label.label == "Settings" || label.value == "Settings")
        #expect(label.frame.minY >= title.minY && label.frame.maxY <= title.maxY)
        let view = try window.element(identifier: "settings-view").frame
        #expect(view.minX >= content.minX && view.maxX <= content.maxX && view.minY >= content.minY)
        #expect(throws: (any Error).self) { try window.element(identifier: "title-new-session") }
    }

    private func closed(_ main: TestWindow) async throws {
        for _ in 0..<200 where main.settingsController.isOpen { await Task.yield(); main.tick() }
        #expect(!main.settingsController.isOpen)
    }

    @Test func appMenuHasSettingsWithCommandComma() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let appMenu = try #require(window.testApp.menuBar.first)
        let titles = appMenu.items.map(\.title)
        let about = try #require(titles.firstIndex { $0.hasPrefix("About") })
        let settings = try #require(titles.firstIndex(of: "Settings…"))
        #expect(settings > about)
        let item = try #require(window.testApp.menuBar.flatMap(\.items).first { $0.title == "Settings…" })
        #expect(item.shortcut?.key == ",")
        #expect(item.shortcut?.modifiers == [.command])
        #expect(item.isEnabled)
    }

    @Test func settingsMenuItemIsDisabledWithoutAProject() throws {
        let model = LauncherModel()
        let window = try TestWindow(size: Size(width: Pixels(900), height: Pixels(600))) { launcherRoot(model: model, center: testCenter(for: model)) }
        window.installAlloyMenu(model: model)
        window.tick()
        let item = try #require(window.testApp.menuBar.flatMap(\.items).first { $0.title == "Settings…" })
        #expect(!item.isEnabled)
        #expect(throws: (any Error).self) { try window.openSettingsFromMenu() }
    }

    @Test func sidebarNoLongerHasSettingsButton() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        #expect((try? window.element(identifier: "settings")) == nil)
    }

    @Test func existingSettingsIdsStillWork() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
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
        #expect(AlloySettings.load(appSupport: rig.appSupport).claudePath == "/opt/claude2")
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
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        try window.click(window.element(identifier: "settings-ask-shared-notes"))
        try await window.runUntil { rig.workspace.settings.askBeforeSharedNotes }
        await rig.workspace.settle()
        let support = rig.appSupport
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

    @Test func terminalSectionShowsEveryControlAndSavesAtOnce() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        for id in ["settings-terminal-heading", "settings-terminal-shell", "settings-terminal-font-size",
                   "settings-terminal-scrollback", "settings-terminal-option-meta", "settings-terminal-cursor",
                   "settings-terminal-blink", "settings-terminal-paste-confirm"] {
            _ = try window.element(identifier: id)
        }
        #expect(rig.workspace.settings.terminal.cursorBlink)
        try window.click(window.element(identifier: "settings-terminal-blink"))
        try await window.runUntil { !rig.workspace.settings.terminal.cursorBlink }
        await rig.workspace.settle()
        let support = rig.appSupport
        #expect(!AlloySettings.load(appSupport: support).terminal.cursorBlink)
        await rig.workspace.stopAll()
    }

    @Test func rereadStatShowsOnlyWhenNonZero() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        // A window just wide enough that the split view gives the sidebar its 200 pt minimum.
        let window = try TestWindow(size: Size(width: Pixels(760), height: Pixels(800))) { rootView(workspace: rig.workspace, center: testCenter(for: rig.workspace)) }
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
        let window = try TestWindow(size: Size(width: Pixels(760), height: Pixels(800))) { rootView(workspace: rig.workspace, center: testCenter(for: rig.workspace)) }
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

    @Test func escWhileThePathFieldIsFocusedCloses() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        try window.click(window.element(identifier: "settings-claude-path"))
        window.typeText("/x")
        window.typeKey(.escape)
        try await closed(main)
    }

    // MARK: Failures and relaunches

    @Test func failedPathSaveShowsErrorAndEditingClearsIt() async throws {
        let rig = Rig()
        // A file where the support directory should be: the settings file cannot be created.
        try Data().write(to: rig.appSupport)
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
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
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
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
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        #expect(try window.element(identifier: "settings-share-other-projects").isEnabled)
        try window.click(window.element(identifier: "settings-share-other-projects"))
        try await window.runUntil { !rig.workspace.settings.shareAcrossProjects }
        #expect(!AlloySettings.load(appSupport: rig.appSupport).shareAcrossProjects)
        await rig.workspace.stopAll()
    }

    @Test func paletteShowDisabledToggleSaves() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        #expect(rig.workspace.settings.paletteShowsDisabled)
        try window.click(window.element(identifier: "settings-palette-show-disabled"))
        try await window.runUntil { !rig.workspace.settings.paletteShowsDisabled }
        #expect(!AlloySettings.load(appSupport: rig.appSupport).paletteShowsDisabled)
        await rig.workspace.stopAll()
    }

    @Test func failedPaletteToggleSaveShowsErrorAndKeepsTheValue() async throws {
        let rig = Rig()
        try Data().write(to: rig.appSupport)
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        try window.click(window.element(identifier: "settings-palette-show-disabled"))
        try await window.runUntil { (try? window.element(identifier: "settings-error")) != nil }
        #expect(rig.workspace.settings.paletteShowsDisabled)
    }

    @Test func shareOtherProjectsDisabledWithoutSharing() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
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
        let main = try alloyWindow(rig.workspace)
        let window = try await open(main)
        let view = try window.element(identifier: "settings-view")
        #expect(view.label == "Settings")
        #expect(view.role == .group)
    }
}

/// Settings > Language servers: the Linters group and the Clippy switch.
@MainActor
@Suite struct SettingsLintersTests {
    /// The real built-in table; nothing is launched because no file is open and no command is found.
    private func open(_ rig: Rig) async throws -> TestWindow {
        let coordinator = LSPCoordinator.install(on: rig.workspace,
                                                 locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                                 launcher: ServerLauncher { _, _, _ in throw CancellationError() })
        let main = try alloyWindow(rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-lsp-rust-analyzer")) != nil }
        withExtendedLifetime(coordinator) {}
        return settings
    }

    @Test func lintersHaveTheirOwnGroup() async throws {
        let rig = Rig()
        let settings = try await open(rig)
        _ = try settings.element(identifier: "settings-linters-heading")
        for id in ["ruff", "eslint", "biome"] {
            _ = try settings.element(identifier: "settings-linter-\(id)")
            _ = try settings.element(identifier: "settings-linter-status-\(id)")
            #expect((try? settings.element(identifier: "settings-lsp-\(id)")) == nil, "\(id) is not among the servers")
        }
        _ = try settings.element(identifier: "settings-lsp-rust-analyzer")
        #expect((try? settings.element(identifier: "settings-linter-rust-analyzer")) == nil)
    }

    @Test func togglingALinterPersists() async throws {
        let rig = Rig()
        let settings = try await open(rig)
        try settings.click(settings.element(identifier: "settings-linter-ruff"))
        #expect(rig.workspace.settings.languageServers["ruff"]?.enabled == false)
        let reloaded = AlloySettings.load(appSupport: rig.appSupport)
        #expect(reloaded.languageServers["ruff"]?.enabled == false)
    }

    @Test func clippyTogglePersists() async throws {
        let rig = Rig()
        let settings = try await open(rig)
        try settings.click(settings.element(identifier: "settings-lsp-rust-analyzer-clippy"))
        #expect(rig.workspace.settings.languageServers["rust-analyzer"]?.clippy == true)
        let reloaded = AlloySettings.load(appSupport: rig.appSupport)
        #expect(reloaded.languageServers["rust-analyzer"]?.clippy == true)
    }

    @Test func userAddedLinterIsListed() async throws {
        let rig = Rig()
        try rig.workspace.updateSettings({
            var s = rig.workspace.settings
            s.languageServers["mylint"] = ServerConfigOverride(name: "MyLint", extensions: ["zz"], command: "mylint", role: .linter)
            return s
        }())
        let settings = try await open(rig)
        _ = try settings.element(identifier: "settings-linter-mylint")
        #expect((try? settings.element(identifier: "settings-lsp-mylint")) == nil)
    }
}

/// Settings > Language servers: format on save and the formatter choice.
@MainActor
@Suite struct SettingsFormatTests {
    private func open(_ rig: Rig) async throws -> TestWindow {
        let coordinator = LSPCoordinator.install(on: rig.workspace,
                                                 locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                                 launcher: ServerLauncher { _, _, _ in throw CancellationError() })
        let main = try alloyWindow(rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-lsp-rust-analyzer")) != nil }
        withExtendedLifetime(coordinator) {}
        return settings
    }

    @Test func formatOnSaveToggleExistsForServersAndLintersAndPersists() async throws {
        let rig = Rig()
        let settings = try await open(rig)
        _ = try settings.element(identifier: "settings-lsp-format-on-save-ruff")
        try settings.click(settings.element(identifier: "settings-lsp-format-on-save-rust-analyzer"))
        #expect(rig.workspace.settings.languageServers["rust-analyzer"]?.formatOnSave == true)
        let reloaded = AlloySettings.load(appSupport: rig.appSupport)
        #expect(reloaded.languageServers["rust-analyzer"]?.formatOnSave == true)
    }

    @Test func formatterPickerPersistsTheChoice() async throws {
        let rig = Rig()
        let settings = try await open(rig)
        let choice = try #require(LanguageServersSection.formatterChoices(ServerRegistry().all).first)
        let picker = try settings.element(identifier: "settings-lsp-formatter-\(choice.languageID)")
        let linter = try #require(choice.servers.first { $0.role == .linter })
        let row = try #require(descendants(of: picker, in: settings).first { $0.label == linter.name })
        try settings.click(row)
        #expect(rig.workspace.settings.formatters[choice.languageID] == linter.id)
        let reloaded = AlloySettings.load(appSupport: rig.appSupport)
        #expect(reloaded.formatters[choice.languageID] == linter.id)
    }
}

@MainActor
@Suite struct SettingsSearchTests {
    @Test func searchGroupEditsPersist() async throws {
        let rig = Rig()
        let main = try alloyWindow(rig.workspace)
        let window = try main.openSettingsFromMenu()
        try await window.runUntil { (try? window.element(identifier: "settings-search-excludes")) != nil }
        _ = try window.element(identifier: "settings-search-max-results")
        try window.click(window.element(identifier: "settings-search-excludes"))
        window.typeText("dist/**")
        for _ in 0..<3 { window.tick() }
        #expect(rig.workspace.settings.searchExcludes == ["dist/**"])
        let reloaded = AlloySettings.load(appSupport: rig.workspace.appSupport)
        #expect(reloaded.searchExcludes == ["dist/**"])
    }
}
