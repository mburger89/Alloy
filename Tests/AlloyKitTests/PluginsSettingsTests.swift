@testable import AlloyCore
@testable import AlloyKit
import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct PluginsSettingsTests {
    private let todo = "dev.example.todo"

    private func open(_ p: PluginRig, picking: URL? = nil) async throws -> (main: TestWindow, settings: TestWindow) {
        testCenter(for: p.rig.workspace).plugins = p.coordinator
        p.coordinator.pickFolder = { picking }
        let main = try alloyWindow(p.rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { exists(settings, "settings.plugins") }
        return (main, settings)
    }

    private func exists(_ w: TestWindow, _ id: String) -> Bool { (try? w.element(identifier: id)) != nil }
    private func text(_ w: TestWindow, _ id: String) throws -> String {
        let e = try w.element(identifier: id)
        return e.value ?? e.label ?? ""
    }
    private func settle(_ w: TestWindow) { for _ in 0..<4 { w.tick() } }
    private func until(_ w: TestWindow, _ cond: () -> Bool) async throws {
        for _ in 0..<300 where !cond() { w.tick(); try await Task.sleep(for: .milliseconds(10)) }
    }
    private func click(_ w: TestWindow, _ id: String) throws {
        try w.click(w.element(identifier: id))
        settle(w)
    }

    @discardableResult
    private func todoSource(_ p: PluginRig, permissions: String = #"["project.read"]"#, extra: String = "") -> URL {
        p.source(todo, manifest: """
        {"id":"\(todo)","name":"Todo","version":"1.2.0","permissions":\(permissions)\(extra),
         "main":{"command":"./run.sh"}}
        """, files: ["run.sh": "#!/bin/sh\n"])
    }

    /// Installs through the Install button.
    private func installTodo(_ p: PluginRig, _ settings: TestWindow) async throws {
        try click(settings, "settings.plugins.install")
        try await until(settings) { exists(settings, "settings.plugins.row.\(todo)") }
        settle(settings)
    }

    @Test func emptyStateShowsInstallHint() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p)
        #expect(try text(settings, "settings.plugins.empty") == "No plugins installed. Install a folder that holds an alloy-plugin.json.")
        #expect(exists(settings, "settings.plugins.install"))
    }

    @Test func installAddsADisabledRow() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p))
        try await installTodo(p, settings)
        #expect(try text(settings, "settings.plugins.row.\(todo).status") == "disabled")
        #expect(try text(settings, "settings.plugins.row.\(todo).permissions") == "project.read")
        #expect(try text(settings, "settings.plugins.row.\(todo).source").contains("Folder:"))
        #expect(!exists(settings, "settings.plugins.empty"))
        #expect(p.rig.workspace.settings.plugins[todo]?.enabled == false)
    }

    @Test func installErrorShowsBadManifestReason() async throws {
        let p = PluginRig()
        let bad = p.source("bad", manifest: "{ not json")
        let (_, settings) = try await open(p, picking: bad)
        try click(settings, "settings.plugins.install")
        try await until(settings) { exists(settings, "settings.plugins.install-error") }
        settle(settings)
        let message = try text(settings, "settings.plugins.install-error")
        #expect(message.hasPrefix("Could not install: ") && message.count > "Could not install: ".count, "\(message)")
        #expect(p.coordinator.status.rows.isEmpty)
    }

    @Test func enableShowsPromptAndConfirmGrants() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p))
        try await installTodo(p, settings)
        try click(settings, "settings.plugins.row.\(todo).toggle")
        #expect(exists(settings, "settings.plugins.enable-prompt.\(todo)"))
        #expect(exists(settings, "settings.plugins.grant.\(todo).project.read"))
        #expect(try text(settings, "settings.plugins.grant.\(todo).project.read") == "Read files in this project")
        #expect(p.rig.workspace.settings.plugins[todo]?.enabled == false, "nothing is granted before the confirm")
        try click(settings, "settings.plugins.enable-confirm.\(todo)")
        #expect(p.rig.workspace.settings.plugins[todo]?.grants == [.projectRead])
        #expect(p.rig.workspace.settings.plugins[todo]?.enabled == true)
        #expect(!exists(settings, "settings.plugins.enable-prompt.\(todo)"))
    }

    @Test func cancelLeavesItDisabled() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p))
        try await installTodo(p, settings)
        try click(settings, "settings.plugins.row.\(todo).toggle")
        try click(settings, "settings.plugins.enable-cancel.\(todo)")
        #expect(!exists(settings, "settings.plugins.enable-prompt.\(todo)"))
        #expect(p.rig.workspace.settings.plugins[todo]?.enabled == false)
        #expect(p.rig.workspace.settings.plugins[todo]?.grants == [])
    }

    @Test func revokingOneGrantSavesIt() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p, permissions: #"["project.read","sessions.read"]"#))
        try await installTodo(p, settings)
        try click(settings, "settings.plugins.row.\(todo).toggle")
        try click(settings, "settings.plugins.enable-confirm.\(todo)")
        #expect(p.rig.workspace.settings.plugins[todo]?.grants == [.projectRead, .sessionsRead])
        try click(settings, "settings.plugins.grant.\(todo).sessions.read")
        #expect(p.rig.workspace.settings.plugins[todo]?.grants == [.projectRead])
        #expect(p.row(todo)?.status == .needsPermissions([.sessionsRead]))
        try click(settings, "settings.plugins.grant.\(todo).sessions.read")
        #expect(p.rig.workspace.settings.plugins[todo]?.grants == [.projectRead, .sessionsRead])
    }

    @Test func declarativePromptListsTheCommandsItRuns() async throws {
        let p = PluginRig()
        let pack = p.serverPack("dev.example.servers", name: "Servers", command: "fake-a")
        let (_, settings) = try await open(p, picking: pack)
        try click(settings, "settings.plugins.install")
        try await until(settings) { exists(settings, "settings.plugins.row.dev.example.servers") }
        settle(settings)
        try click(settings, "settings.plugins.row.dev.example.servers.toggle")
        #expect(try text(settings, "settings.plugins.enable-runs.dev.example.servers.0") == "Runs: fake-a")
        #expect(try text(settings, "settings.plugins.grant.dev.example.servers.process.spawn") == "Run programs")
    }

    @Test func taskPromptShowsTheQuotedLineThatWillBeTyped() async throws {
        let p = PluginRig()
        let source = p.source("dev.example.tasks", manifest: """
        {"id":"dev.example.tasks","name":"Tasks","version":"1.0.0","permissions":["process.spawn"],
         "contributes":{"taskCommands":[{"id":"t","title":"T","command":"npm","args":["run it"]}]}}
        """)
        let (_, settings) = try await open(p, picking: source)
        try click(settings, "settings.plugins.install")
        try await until(settings) { exists(settings, "settings.plugins.row.dev.example.tasks") }
        settle(settings)
        try click(settings, "settings.plugins.row.dev.example.tasks.toggle")
        #expect(try text(settings, "settings.plugins.enable-runs.dev.example.tasks.0") == "Runs: 'npm' 'run it'")
    }

    @Test func tagMovedLetsTheUserCheckAgain() {
        #expect(PluginRowView.updateDisabled(.tagMoved) == false)
        #expect(PluginRowView.updateDisabled(.checking) && PluginRowView.updateDisabled(.updating))
        #expect(!PluginRowView.updateDisabled(nil) && !PluginRowView.updateDisabled(.upToDate))
        #expect(PluginRowView.updateTitle(.tagMoved).hasSuffix("Check again"))
    }

    @Test func scriptedPromptSaysItRunsWithAccountAccess() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p))
        try await installTodo(p, settings)
        try click(settings, "settings.plugins.row.\(todo).toggle")
        let expected = PluginSandbox.backendAvailable ? "Runs in a macOS sandbox limited to these permissions." : "Runs with your account's file access."
        #expect(try text(settings, "settings.plugins.enable-runs.\(todo)") == expected)
    }

    @Test func removeAsksThenDeletes() async throws {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p))
        try await installTodo(p, settings)
        try click(settings, "settings.plugins.row.\(todo).remove")
        #expect(try text(settings, "settings.plugins.row.\(todo).remove-confirm-text") == "Remove Todo? Its folder and settings are deleted.")
        try click(settings, "settings.plugins.row.\(todo).remove-cancel")
        #expect(p.rig.workspace.settings.plugins[todo] != nil)
        try click(settings, "settings.plugins.row.\(todo).remove")
        try click(settings, "settings.plugins.row.\(todo).remove-confirm")
        try await until(settings) { p.rig.workspace.settings.plugins[todo] == nil && !exists(settings, "settings.plugins.row.\(todo)") }
        settle(settings)
        #expect(p.rig.workspace.settings.plugins[todo] == nil)
        #expect(!exists(settings, "settings.plugins.row.\(todo)"))
        #expect(!FileManager.default.fileExists(atPath: p.paths.plugins.appendingPathComponent(todo).path))
        #expect(exists(settings, "settings.plugins.empty"))
    }

    private static let declared = """
    ,"contributes":{"settings":[
      {"key":"auto","title":"Auto","type":"bool","default":false},
      {"key":"name","title":"Name","type":"string"},
      {"key":"limit","title":"Limit","type":"number"},
      {"key":"mode","title":"Mode","type":"enum","options":["fast","slow"],"default":"fast"}]}
    """

    private func value(_ p: PluginRig, _ key: String) -> JSONValue? { p.rig.workspace.settings.plugins[todo]?.values[key] }

    private func settingsRig() async throws -> (PluginRig, TestWindow) {
        let p = PluginRig()
        let (_, settings) = try await open(p, picking: todoSource(p, extra: Self.declared))
        try await installTodo(p, settings)
        #expect(p.row(todo)?.settings.count == 4, "manifest: \(String(describing: p.coordinator.installedManifests[todo]))")
        let disclosure = try settings.element(identifier: "settings.plugins.settings.\(todo)")
        try settings.click(#require(descendants(of: disclosure, in: settings).first { $0.label == "Settings" }))
        settle(settings)
        return (p, settings)
    }

    @Test func settingsDisclosureEditsEachType() async throws {
        let (p, settings) = try await settingsRig()
        let prefix = "settings.plugins.value.\(todo)."
        try click(settings, prefix + "auto")
        #expect(value(p, "auto") == .bool(true))
        try settings.typeText("hello", into: settings.element(identifier: prefix + "name"))
        settings.typeKey(.return)
        settle(settings)
        #expect(value(p, "name") == .string("hello"))
        try settings.typeText("42", into: settings.element(identifier: prefix + "limit"))
        settings.typeKey(.return)
        settle(settings)
        #expect(value(p, "limit") == .number(42))
        let picker = try settings.element(identifier: prefix + "mode")
        let slow = try #require(descendants(of: picker, in: settings).first { $0.label == "slow" })
        try settings.click(slow)
        settle(settings)
        #expect(value(p, "mode") == .string("slow"))
    }

    @Test func badNumberIsNotSaved() async throws {
        let (p, settings) = try await settingsRig()
        try settings.typeText("abc", into: settings.element(identifier: "settings.plugins.value.\(todo).limit"))
        settings.typeKey(.return)
        settle(settings)
        #expect(value(p, "limit") == nil)
    }

    @Test func missingFolderRowOffersRemoveOnly() async throws {
        let p = PluginRig()
        var s = p.rig.workspace.settings
        s.plugins["dev.example.gone"] = PluginSetting(enabled: true, version: "1.0.0", source: .folder(path: "/nowhere"))
        try p.rig.workspace.updateSettings(s)
        let (_, settings) = try await open(p)
        #expect(try text(settings, "settings.plugins.row.dev.example.gone.status") == "folder missing")
        #expect(exists(settings, "settings.plugins.row.dev.example.gone.remove"))
        #expect(!exists(settings, "settings.plugins.row.dev.example.gone.toggle"))
    }

    // MARK: Log

    private func logRig() async throws -> (PluginRig, TestWindow) {
        let p = PluginRig(pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"])
        try p.fake("dev.test.log", script: .object(["stderr": .string("hello world\n")]))
        testCenter(for: p.rig.workspace).plugins = p.coordinator
        let main = try alloyWindow(p.rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { exists(settings, "settings.plugins.row.dev.test.log") }
        #expect(await p.coordinator.activate(plugin: "dev.test.log", .command))
        for _ in 0..<300 where await p.coordinator.host?.stderrTail(of: "dev.test.log").contains("hello") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        try click(settings, "settings.plugins.row.dev.test.log.log")
        try await until(settings) { exists(settings, "settings.plugins.row.dev.test.log.log-text") }
        settle(settings)
        return (p, settings)
    }

    @Test func logTextIsSelectable() async throws {
        let (p, settings) = try await logRig()
        let log = try settings.element(identifier: "settings.plugins.row.dev.test.log.log-text")
        try settings.click(log)
        settings.typeKey("a", modifierFlags: .command)
        settings.typeKey("c", modifierFlags: .command)
        settle(settings)
        let copied = settings.clipboardRepresentations.compactMap { String(bytes: $0.bytes, encoding: .utf8) }.joined()
        #expect(copied.contains("hello world"), "clipboard: \(copied)")
        await p.coordinator.shutdown()
    }

    @Test func logDoesNotRebuildWithSettings() async throws {
        let (p, settings) = try await logRig()
        let before = BodyProbe.count("PluginLogView")
        #expect(before > 0)
        let sectionBefore = BodyProbe.count("PluginsSection")
        try click(settings, "settings.plugins.install")
        settle(settings)
        #expect(BodyProbe.count("PluginsSection") > sectionBefore, "the section did re-run")
        #expect(BodyProbe.count("PluginLogView") == before, "log rebuilt with Settings")
        await p.coordinator.shutdown()
    }

    // MARK: Guard

    private func idleFrame(_ window: TestWindow) async -> Int {
        var last = -1
        for _ in 0..<40 {
            window.resetFrameWork()
            window.tick()
            await Task.yield()
            let now = window.frameWork.last?.elementRequests ?? 0
            if now == last { return now }
            last = now
        }
        return last
    }

    @Test func closedAndIdleSectionCostNothing() async throws {
        let p = PluginRig()
        try p.installNow(p.themePack())
        try p.installNow(p.serverPack("dev.example.servers", name: "Servers"))
        testCenter(for: p.rig.workspace).plugins = p.coordinator
        let main = try alloyWindow(p.rig.workspace)
        #expect(await idleFrame(main) == 0, "main window idle with Settings closed")
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { exists(settings, "settings.plugins") }
        #expect(await idleFrame(settings) == 0, "Settings window idle")
        #expect(await idleFrame(main) == 0, "main window idle with Settings open")
        var reruns = 0
        for _ in 0..<20 {
            let b = BodyProbe.count("PluginsSection")
            settings.tick()
            reruns += BodyProbe.count("PluginsSection") - b
        }
        #expect(reruns == 0, "PluginsSection body re-ran \(reruns) times while idle")
    }
}
