import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ThemeControllerTests {
    /// A one-element window that reports how `colors` resolve under whatever theme its `Window` holds.
    @MainActor private struct Probe {
        let window: TestWindow
        let box = ResolvedBox()
        let colors: [Color]
        init(_ colors: [Color]) throws {
            self.colors = colors
            let box = self.box
            window = try TestWindow(size: Size(width: Pixels(100), height: Pixels(100))) { ColorProbe(colors: colors, box: box) }
            window.tick()
        }
        func resolved() -> [Color.Resolved] {
            window.window.setNeedsRedraw()
            window.tick(); window.tick()
            return box.colors
        }
    }

    private func hex(_ value: String) -> Color { Color(ThemeRGBA(hex: value)!.hsla) }

    private func same(_ a: Color.Resolved, _ b: Color.Resolved) -> Bool {
        abs(a.red - b.red) < 0.01 && abs(a.green - b.green) < 0.01 && abs(a.blue - b.blue) < 0.01
    }

    private func themesDirectory(_ rig: Rig) -> URL {
        ThemeLibrary.userDirectory(appSupport: rig.root.appendingPathComponent("support"))
    }

    private func userTheme(accent: String) -> String {
        """
        {"name":"Mine","appearance":"dark","base":"dracula","colors":{"accent":"\(accent)"}}
        """
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "\(what)")
    }

    /// A host that counts how often the themes are installed on it.
    @MainActor private final class CountingHost: ThemeHost {
        var installs = 0
        var lightTheme: Theme = .light { didSet { installs += 1 } }
        var darkTheme: Theme = .dark { didSet { installs += 1 } }
        var preferredColorScheme: ColorScheme?
    }

    /// Choosing a theme whose style differs changes the style inside `apply()`; the themes are installed once, not again for the style.
    @Test func styleChangingApplyInstallsOnce() throws {
        let rig = Rig()
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"Wide","appearance":"dark","base":"dracula","style":{"gutter":14}}"#
            .write(to: dir.appendingPathComponent("wide.json"), atomically: true, encoding: .utf8)
        let host = CountingHost()
        let controller = ThemeController(workspace: rig.workspace, host: host, watcher: nil)
        controller.stop()
        #expect(controller.style.gutter == AppearanceStyle.defaults.gutter)
        host.installs = 0
        try controller.choose(theme: "user/wide")
        #expect(controller.style.gutter == 14, "the style followed the theme")
        // Single mode installs the light and dark slots: one install is two assignments.
        #expect(host.installs == 2, "installed \(host.installs / 2) times")
    }

    @Test func defaultIsDraculaForcedDark() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill, hex("#282A36")])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        #expect(probe.window.window.preferredColorScheme == .dark)
        let r = probe.resolved()
        #expect(same(r[0], r[1]), "chatFill is Dracula's")
        #expect(controller.notice == nil)
        let dracula = ThemeApplier.theme(for: try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("dracula")))
        #expect(probe.window.window.darkTheme == dracula, "dark slot")
        #expect(probe.window.window.lightTheme == dracula, "light slot")
    }

    @Test func oldSettingsFileDecodesWithThemeDefaults() throws {
        let old = #"{"claudePath":"/x/claude","lastProjectPath":"/p","shareKnowledge":false,"askBeforeSharedNotes":true}"#
        let s = try JSONDecoder().decode(AlloySettings.self, from: Data(old.utf8))
        #expect(s.themeMode == .single && s.theme == "dracula")
        #expect(s.lightTheme == "alloy-light" && s.darkTheme == "dracula")
        #expect(s.claudePath == "/x/claude" && s.lastProjectPath == "/p" && !s.shareKnowledge && s.askBeforeSharedNotes)
        let again = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(
            AlloySettings(themeMode: .matchSystem, theme: "one-dark", lightTheme: "solarized-light", darkTheme: "one-dark")))
        #expect(again.themeMode == .matchSystem && again.lightTheme == "solarized-light")
    }

    @Test func badThemeKeysKeepEveryOtherSetting() throws {
        let bad = ##"{"claudePath":"/x/claude","lastProjectPath":"/p","shareKnowledge":false,"askBeforeSharedNotes":true,"themeMode":"system","theme":7,"lightTheme":null,"darkTheme":["x"]}"##
        let s = try JSONDecoder().decode(AlloySettings.self, from: Data(bad.utf8))
        #expect(s.claudePath == "/x/claude" && s.lastProjectPath == "/p" && !s.shareKnowledge && s.askBeforeSharedNotes)
        #expect(s.themeMode == .single && s.theme == "dracula" && s.lightTheme == "alloy-light" && s.darkTheme == "dracula")
    }

    @Test func matchSystemFollowsAppearanceAndClearsForce() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill, hex("#FDF6E3"), hex("#282C34")])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        try controller.choose(mode: .matchSystem, light: "solarized-light", dark: "one-dark")
        #expect(probe.window.window.preferredColorScheme == nil)
        probe.window.setAppearance(.light)
        var r = probe.resolved()
        #expect(same(r[0], r[1]), "light is Solarized Light")
        probe.window.setAppearance(.dark)
        r = probe.resolved()
        #expect(same(r[0], r[2]), "dark is One Dark")
        try controller.choose(mode: .single)
        #expect(probe.window.window.preferredColorScheme == .dark)
    }

    @Test func missingSelectedThemeFallsBackWithNotice() throws {
        let rig = Rig()
        try rig.workspace.updateSettings(AlloySettings(theme: "user/gone"))
        let file = rig.root.appendingPathComponent("support/Alloy/settings.json")
        let before = try Data(contentsOf: file)
        let probe = try Probe([.chatFill, hex("#282A36")])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        let r = probe.resolved()
        #expect(same(r[0], r[1]), "Dracula applied")
        #expect(controller.notice?.contains("user/gone") == true)
        #expect(controller.notice == "Theme \"user/gone\" isn't available; using Dracula.")
        #expect(try Data(contentsOf: file) == before, "settings.json untouched")
    }

    @Test func liveEditAppliesWithoutRestart() async throws {
        let rig = Rig()
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mine.json")
        try userTheme(accent: "#FF0000").write(to: url, atomically: true, encoding: .utf8)
        try rig.workspace.updateSettings(AlloySettings(theme: "user/mine"))
        let probe = try Probe([Color(ColorToken.accent), hex("#00FF00")])
        let watcher = ScriptedChangeSource()
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: watcher)
        defer { controller.stop() }
        var r = probe.resolved()
        #expect(abs(r[0].red - 1) < 0.01 && r[0].green < 0.01)
        try userTheme(accent: "#00FF00").write(to: url, atomically: true, encoding: .utf8)
        watcher.send([url.path])
        await waitFor("accent turns green") { let r = probe.resolved(); return self.same(r[0], r[1]) }
        r = probe.resolved()
        #expect(same(r[0], r[1]))
        #expect(rig.transports.count == 0)
    }

    @Test func brokenActiveFileKeepsLastGood() async throws {
        let rig = Rig()
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mine.json")
        try userTheme(accent: "#FF0000").write(to: url, atomically: true, encoding: .utf8)
        try rig.workspace.updateSettings(AlloySettings(theme: "user/mine"))
        let probe = try Probe([Color(ColorToken.accent)])
        let watcher = ScriptedChangeSource()
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: watcher)
        defer { controller.stop() }
        let before = probe.resolved()[0]
        try #"{"name":"#.write(to: url, atomically: true, encoding: .utf8)
        watcher.send([url.path])
        await waitFor("error reported") { controller.library.errors.contains { $0.fileName == "mine.json" } }
        #expect(controller.library.errors.contains { $0.fileName == "mine.json" })
        #expect(same(probe.resolved()[0], before), "colours unchanged")
        #expect(controller.library.entry("user/mine") != nil)
    }

    @Test func missingFolderIsCreatedForTheWatcher() async throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: ScriptedChangeSource())
        defer { controller.stop() }
        let dir = themesDirectory(rig)
        await waitFor("folder exists") { FileManager.default.fileExists(atPath: dir.path) }
    }

    @Test func stoppedWatcherNoLongerReloads() async throws {
        let rig = Rig()
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = try Probe([.chatFill])
        let watcher = ScriptedChangeSource()
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: watcher)
        controller.stop()
        try userTheme(accent: "#FF0000").write(to: dir.appendingPathComponent("late.json"), atomically: true, encoding: .utf8)
        watcher.send([dir.path])
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.library.entry("user/late") == nil)
    }

    @Test func switchingOnlyRepaints() async throws {
        let rig = Rig()
        let big = (1...400).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        try big.write(to: rig.root.appendingPathComponent("big.swift"), atomically: true, encoding: .utf8)
        let s = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.systemInit(SystemInit(model: "claude-opus-5-5", permissionMode: "default", sessionID: "s",
                                            tools: [], slashCommands: [], terminalSlashCommands: [])))
        for _ in 0..<20_000 where s.status != .working { await Task.yield() }
        #expect(s.status == .working)
        rig.workspace.openFilePath = "big.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        window.tick()
        let area = try window.element(identifier: "code-view")
        let doc = try #require(rig.workspace.document("big.swift"))
        let view = try #require(CodePanelStore.existingView(for: doc))
        window.scroll(at: Point(x: area.frame.origin.x + 60, y: area.frame.origin.y + 60), byDeltaX: 0, deltaY: Float(-200 * 14))
        try await window.runUntil { view.scroll.position.row > 50 }
        window.tick(); window.tick()
        let row = view.scroll.position.row, tabs = rig.workspace.tabs, generation = rig.workspace.settingsGeneration
        let transports = rig.transports.count

        try controller.choose(theme: "one-dark")
        window.tick(); window.tick()
        await rig.workspace.settle()

        #expect(rig.workspace.tabs == tabs && rig.workspace.activeTab == "big.swift")
        let doc2 = try #require(rig.workspace.document("big.swift"))
        let after = try #require(CodePanelStore.existingView(for: doc2))
        #expect(after === view, "the same code view instance")
        #expect(abs(after.scroll.position.row - row) < 0.01, "same first visible line")
        #expect(await !t.terminated, "the transport was not stopped")
        #expect(rig.workspace.sessions.first?.id == s.id && rig.workspace.sessions.count == 1 && !rig.workspace.hasPendingRelaunch, "no pending relaunch")
        #expect(rig.transports.count == transports, "no session relaunch")
        #expect(s.status == .working)
        let oneDark = try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("one-dark"))
        #expect(window.window.darkTheme == ThemeApplier.theme(for: oneDark), "the theme did change")
        #expect(rig.workspace.settingsGeneration == generation + 1, "exactly one settings write")
        await rig.workspace.stopAll()
    }

    @Test func themeChangesDoNotRelaunchSessions() async throws {
        let rig = Rig()
        let s = await rig.workspace.newSession(name: "A")
        let t = rig.transports[0]
        await t.emit(.systemInit(SystemInit(model: "claude-opus-5-5", permissionMode: "default", sessionID: "s",
                                            tools: [], slashCommands: [], terminalSlashCommands: [])))
        for _ in 0..<20_000 where s.status != .working { await Task.yield() }
        await t.emit(.result(TurnResult(subtype: "success", isError: false, costUSD: 0, inputTokens: 1, outputTokens: 1,
                                        sessionID: "s", terminalReason: nil, cacheCreationTokens: 0, cacheReadTokens: 0)))
        for _ in 0..<20_000 where s.status != .idle { await Task.yield() }
        var settings = rig.workspace.settings
        settings.themeMode = .matchSystem; settings.theme = "one-dark"; settings.lightTheme = "solarized-light"
        try rig.workspace.updateSettings(settings)
        await rig.workspace.settle()
        for _ in 0..<200 { await Task.yield() }
        #expect(rig.transports.count == 1)
        #expect(await !t.terminated)
        await rig.workspace.stopAll()
    }

    @Test func openThemesFolderCreatesIt() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        var opened: URL?
        controller.openThemesFolder { opened = $0 }
        let dir = themesDirectory(rig)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
        #expect(opened == dir)
    }

    // MARK: Unbound controller

    @Test func unboundControllerAppliesToTheHost() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-theme-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let probe = try Probe([.chatFill])
        _ = ThemeController(appSupport: support, settings: AlloySettings(theme: "one-dark"), host: probe.window.window, watcher: nil)
        let oneDark = ThemeApplier.theme(for: try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("one-dark")))
        #expect(probe.window.window.darkTheme == oneDark && probe.window.window.lightTheme == oneDark)
        #expect(probe.window.window.preferredColorScheme == .dark)
    }

    @Test func unboundChoosePersistsThenBindKeepsTheTheme() throws {
        let rig = Rig()
        let support = rig.root.appendingPathComponent("support")
        let probe = try Probe([.chatFill])
        let controller = ThemeController(appSupport: support, settings: AlloySettings(), host: probe.window.window, watcher: nil)
        try controller.choose(theme: "one-dark")
        #expect(AlloySettings.load(appSupport: support).theme == "one-dark", "saved to disk without a workspace")
        controller.bind(rig.workspace)
        #expect(rig.workspace.settings.theme == "one-dark")
        #expect(AlloySettings.load(appSupport: support).theme == "one-dark")
        let oneDark = ThemeApplier.theme(for: try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("one-dark")))
        #expect(probe.window.window.darkTheme == oneDark)
        try controller.choose(theme: "solarized-dark")
        #expect(rig.workspace.settings.theme == "solarized-dark", "bound choose goes through the workspace")
    }

    @Test func adoptingAFolderAfterChooseDoesNotRevertTheTheme() throws {
        let rig = Rig()
        let support = rig.root.appendingPathComponent("support")
        let probe = try Probe([.chatFill])
        let controller = ThemeController(appSupport: support, settings: AlloySettings(), host: probe.window.window, watcher: nil)
        try controller.choose(mode: .matchSystem, theme: "one-dark", light: "solarized-light", dark: "one-dark")
        // What main.swift does when a folder is picked: build the workspace from the controller's current settings.
        let settings = controller.settingsForNewWorkspace(lastProjectPath: "/picked")
        try settings.save(appSupport: support)
        let workspace = Workspace(projectRoot: rig.root, appSupport: support, settings: settings,
                                  locate: { _ in URL(fileURLWithPath: "/fake/claude") }, makeTransport: { _ in rig.transports.make() })
        controller.bind(workspace)
        let saved = AlloySettings.load(appSupport: support)
        #expect(saved.themeMode == .matchSystem && saved.lightTheme == "solarized-light" && saved.darkTheme == "one-dark")
        #expect(saved.lastProjectPath == "/picked")
        #expect(workspace.settings.themeMode == .matchSystem)
    }

    // MARK: Fallbacks and modes

    @Test func matchModeFallbackNamesTheMissingTheme() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        try controller.choose(mode: .matchSystem, light: "user/nolight", dark: "one-dark")
        #expect(controller.notice == "Theme \"user/nolight\" isn't available; using Alloy Light.")
        try controller.choose(light: "solarized-light", dark: "user/nodark")
        #expect(controller.notice == "Theme \"user/nodark\" isn't available; using Dracula.")
        try controller.choose(light: "user/a", dark: "user/b")
        #expect(controller.notice?.contains("user/a") == true && controller.notice?.contains("user/b") == true)
        #expect(rig.workspace.settings.darkTheme == "user/b", "settings keep the missing id")
    }

    @Test func choosingAMissingThemeSavesThenFallsBack() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        try controller.choose(theme: "user/gone")
        #expect(AlloySettings.load(appSupport: rig.root.appendingPathComponent("support")).theme == "user/gone")
        #expect(controller.notice == "Theme \"user/gone\" isn't available; using Dracula.")
        let dracula = ThemeApplier.theme(for: try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("dracula")))
        #expect(probe.window.window.darkTheme == dracula)
    }

    @Test func backToDraculaFromMatchModeForcesDarkDracula() throws {
        let rig = Rig()
        let probe = try Probe([.chatFill])
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: nil)
        try controller.choose(mode: .matchSystem, light: "solarized-light", dark: "one-dark")
        #expect(probe.window.window.preferredColorScheme == nil)
        try controller.backToDracula()
        #expect(rig.workspace.settings.themeMode == .single && rig.workspace.settings.theme == "dracula")
        #expect(probe.window.window.preferredColorScheme == .dark)
        let dracula = ThemeApplier.theme(for: try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("dracula")))
        #expect(probe.window.window.lightTheme == dracula && probe.window.window.darkTheme == dracula)
    }

    @Test func eventBurstsCoalesceIntoFewReloads() async throws {
        let rig = Rig()
        let dir = themesDirectory(rig)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = try Probe([.chatFill])
        let watcher = ScriptedChangeSource()
        let controller = ThemeController(workspace: rig.workspace, host: probe.window.window, watcher: watcher)
        defer { controller.stop() }
        try await Task.sleep(for: .milliseconds(50))
        for i in 0..<20 { watcher.send([dir.appendingPathComponent("t\(i).json").path]) }
        await waitFor("a reload ran") { controller.reloadCount >= 1 }
        try await Task.sleep(for: .milliseconds(300))   // room for any further reloads the burst might wrongly cause
        #expect(controller.reloadCount >= 1 && controller.reloadCount <= 3, "reloads: \(controller.reloadCount)")
    }
}
