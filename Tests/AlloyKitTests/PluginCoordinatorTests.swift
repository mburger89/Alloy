import AlloyCore
@testable import AlloyKit
import AlloyPlugins
import AlloyRPC
import AlloyTestSupport
import Darwin
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
private func waitFor(_ timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@MainActor
@Suite(.serialized) struct PluginCoordinatorTests {
    private func rig(clock: any AutosaveClock = SystemAutosaveClock(), probe: any PluginProcessProbe = LiveProcessProbe(),
                     limits: PluginLimits = PluginLimits()) -> PluginRig {
        PluginRig(pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], clock: clock, probe: probe, limits: limits)
    }

    private func log(_ folder: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    private func methods(_ folder: URL) -> [String] { log(folder).compactMap { $0["method"]?.stringValue } }
    private func running(_ p: PluginRig) -> [String] { PluginRunningFile.read(p.paths.running).map(\.id).sorted() }

    // MARK: Guard c

    @Test func noHostWhileNoScriptedPluginIsEnabled() async throws {
        let p = rig()
        #expect(!p.coordinator.hasHost, "no plugins")
        try await p.coordinator.install(folder: p.themePack())
        try p.coordinator.enable("dev.example.themes")
        #expect(!p.coordinator.hasHost, "a theme pack is not scripted")
        try p.fake("dev.test.off", enable: false)
        #expect(!p.coordinator.hasHost, "a disabled scripted plugin")
        try p.coordinator.enable("dev.test.off")
        #expect(p.coordinator.hasHost)
        #expect(p.coordinator.host != nil)
        try p.coordinator.disable("dev.test.off")
        #expect(!p.coordinator.hasHost)
        await p.coordinator.shutdown()
        #expect(!p.coordinator.hasHost)
    }

    @Test func revokingAGrantStopsTheProcess() async throws {
        let p = rig()
        try p.fake("dev.test.a", permissions: ["project.read"])
        try p.fake("dev.test.b")
        #expect(await p.coordinator.activate(plugin: "dev.test.a", .command))
        #expect(await p.coordinator.activate(plugin: "dev.test.b", .command))
        #expect(await waitFor { running(p) == ["dev.test.a", "dev.test.b"] })
        try p.coordinator.setGrant(.projectRead, false, for: "dev.test.a")
        #expect(await waitFor { running(p) == ["dev.test.b"] }, "\(running(p))")
        #expect(p.row("dev.test.a")?.status == .needsPermissions([.projectRead]))
        await p.coordinator.shutdown()
    }

    @Test func startupStartsAtMostThreeInEnableOrder() async throws {
        let p = rig()
        let ids = (1...5).map { "dev.test.s\($0)" }
        var folders: [URL] = []
        for id in ids { folders.append(try p.fake(id, activation: ["onStartup"])) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(folders.allSatisfy { methods($0).isEmpty }, "nothing starts before noteStartupComplete")
        p.coordinator.noteStartupComplete()
        #expect(await waitFor { folders.prefix(3).allSatisfy { methods($0).contains("initialized") } })
        try await Task.sleep(for: .milliseconds(300))
        #expect(folders.suffix(2).allSatisfy { methods($0).isEmpty }, "the rest wait for another activation")
        #expect(running(p) == Array(ids.prefix(3)))
        await p.coordinator.shutdown()
    }

    @Test func rowShowsCrashCountThenDisabled() async throws {
        let clock = ManualClock()
        let p = rig(clock: clock)
        try p.fake("dev.test.crash", script: .object(["crashAfter": .number(1)]))
        _ = await p.coordinator.activate(plugin: "dev.test.crash", .command)
        #expect(await waitFor { p.row("dev.test.crash")?.status == .crashed(1) }, "\(String(describing: p.row("dev.test.crash")?.status))")
        try await Task.sleep(for: .milliseconds(100))
        clock.advance(by: 40)
        #expect(await waitFor { p.row("dev.test.crash")?.status == .crashed(2) })
        try await Task.sleep(for: .milliseconds(100))
        clock.advance(by: 40)
        #expect(await waitFor { p.row("dev.test.crash")?.status == .disabledAfterCrashes })
        await p.coordinator.shutdown()
    }

    @Test func autoDisableSavesSettings() async throws {
        let clock = ManualClock()
        let p = rig(clock: clock)
        try p.fake("dev.test.crash", script: .object(["crashAfter": .number(1)]))
        _ = await p.coordinator.activate(plugin: "dev.test.crash", .command)
        for _ in 0..<3 {
            _ = await waitFor(.seconds(3)) { p.rig.workspace.settings.plugins["dev.test.crash"]?.disabledAfterCrashes == true || clock.pendingSleepers > 0 }
            try await Task.sleep(for: .milliseconds(100))
            clock.advance(by: 40)
        }
        #expect(await waitFor { p.rig.workspace.settings.plugins["dev.test.crash"]?.disabledAfterCrashes == true })
        #expect(p.rig.workspace.settings.plugins["dev.test.crash"]?.enabled == false)
        #expect(await waitFor { !p.coordinator.hasHost }, "the last scripted plugin is off, so the host goes")
        await p.coordinator.shutdown()
    }

    @Test func workspaceSwitchReachesHost() async throws {
        let a = rig()
        let folder = try a.fake("dev.test.ws")
        let b = Rig()
        try b.workspace.updateSettings(a.rig.workspace.settings)
        _ = await a.coordinator.activate(plugin: "dev.test.ws", .startup)
        #expect(await waitFor { methods(folder).contains("workspace/opened") })
        a.coordinator.bind(b.workspace)
        #expect(await waitFor { methods(folder).filter { $0.hasPrefix("workspace/") } == ["workspace/opened", "workspace/closed", "workspace/opened"] },
                "\(methods(folder))")
        let uris = log(folder).filter { $0["method"]?.stringValue?.hasPrefix("workspace/") == true }.compactMap { $0["params"]?["root"]?.stringValue }
        #expect(uris.count == 3 && uris[1] == uris[0] && uris[2] != uris[0])
        await a.coordinator.shutdown()
    }

    // MARK: Review fixes

    @Test func scriptedPluginsStayOffWhileUnsupported() async throws {
        let p = PluginRig(pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], scripted: false)
        let id = "dev.test.later"
        let folder = try writeFakePlugin(id: id, in: p.paths.plugins, activation: ["onStartup"],
                                         contributes: .object(["themes": .array([.object(["path": .string("themes/m.json")])])]))
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("themes"), withIntermediateDirectories: true)
        try PluginRig.midnight.write(to: folder.appendingPathComponent("themes/m.json"), atomically: true, encoding: .utf8)
        var s = p.rig.workspace.settings
        s.plugins[id] = PluginSetting(enabled: true, version: "1.0.0", source: .folder(path: folder.path))
        try p.rig.workspace.updateSettings(s)
        p.coordinator.adopt(catalog: PluginCatalog.scan(p.paths.plugins, pathDirs: [fakePluginDirectory]))
        p.coordinator.noteStartupComplete()
        try await Task.sleep(for: .milliseconds(300))
        #expect(p.row(id)?.status == .scriptedUnavailable)
        #expect(p.row(id)?.status.text == "Scripted plugins arrive in a later Alloy version")
        #expect(!p.coordinator.hasHost)
        #expect(methods(folder).isEmpty, "onStartup did not start it")
        #expect(!p.themes.library.all.contains { $0.id == "plugin/\(id)/m" } && p.themes.library.all.allSatisfy { !$0.id.hasPrefix("plugin/\(id)/") },
                "its themes stay off")
        #expect(throws: PluginError.scriptedUnsupported) { try p.coordinator.enable(id) }
        #expect(await p.coordinator.activate(plugin: id, .command) == false)
    }

    @Test func themeFilesAreReadOnlyWhenTheListChanges() async throws {
        let p = PluginRig()
        try await p.coordinator.install(folder: p.themePack())
        var loads = 0
        p.coordinator.loadThemes = { loads += 1; return ThemeLibrary.loadPluginThemes($0).entries }
        try p.coordinator.enable("dev.example.themes")
        #expect(loads == 1)
        for _ in 0..<5 { p.coordinator.recompute() }
        try p.coordinator.setValue(.bool(true), key: "x", for: "dev.example.themes")
        #expect(loads == 1, "a settings change that moves no theme file reads nothing")
        try p.coordinator.disable("dev.example.themes")
        try p.coordinator.enable("dev.example.themes")
        #expect(loads == 2)
    }

    @Test func commandQueuedAfterShutdownAnswersFalse() async throws {
        let p = rig()
        try p.fake("dev.test.late")
        let late = Task { @MainActor in await p.coordinator.activate(plugin: "dev.test.late", .command) }
        await p.coordinator.shutdown()
        let answered = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await late.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(answered != nil, "the command was never answered")
        #expect(await p.coordinator.activate(plugin: "dev.test.late", .command) == false)
    }

    @Test func folderWithoutSettingsEntryShowsAsNotEnabledAndCanBeRemoved() async throws {
        let p = PluginRig()
        let folder = p.themePack()
        let target = p.paths.plugins.appendingPathComponent("dev.example.themes")
        try FileManager.default.createDirectory(at: p.paths.plugins, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: target)
        p.coordinator.adopt(catalog: PluginCatalog.scan(p.paths.plugins, pathDirs: []))
        #expect(p.rig.workspace.settings.plugins["dev.example.themes"] == nil)
        #expect(p.row("dev.example.themes")?.status == .notEnabled)
        #expect(p.row("dev.example.themes")?.status.text == "not enabled")
        try await p.coordinator.remove("dev.example.themes")
        #expect(p.row("dev.example.themes") == nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func aLaunchWithNoPluginsLeavesThePluginFolderAlone() async throws {
        let p = PluginRig()
        await p.coordinator.activate()
        #expect(!FileManager.default.fileExists(atPath: p.paths.running.path))
    }

    @Test func staleGroupsAreKilledBeforeTheFirstStart() async throws {
        let p = rig()
        let process = try ServerProcess(executable: "/bin/sh", arguments: ["-c", "sleep 600"], environment: ["PATH": "/usr/bin:/bin"],
                                        currentDirectory: p.rig.root, processGroup: true)
        let pid = process.processIdentifier
        defer { kill(-pid, SIGKILL) }
        let start = try #require(LiveProcessProbe().startTime(pid: pid))
        PluginRunningFile.write([.init(id: "dev.stale", pid: pid, start: start)], to: p.paths.running)
        await p.coordinator.activate()
        #expect(!process.isRunning, "activate() returns after the stale group is gone")
    }

    @Test func quitStopsEveryGroupAndClearsRunningFile() async throws {
        let p = rig()
        let plain = try p.fake("dev.test.plain")
        let stubborn = try p.fake("dev.test.stubborn", script: .object(["ignoreSigterm": .bool(true)]))
        let parent = try p.fake("dev.test.parent", script: .object(["spawnChild": .bool(true)]))
        for id in ["dev.test.plain", "dev.test.stubborn", "dev.test.parent"] { #expect(await p.coordinator.activate(plugin: id, .command)) }
        #expect(await waitFor { PluginRunningFile.read(p.paths.running).count == 3 })
        let pids = PluginRunningFile.read(p.paths.running).map(\.pid)
        #expect(await waitFor { FileManager.default.fileExists(atPath: parent.appendingPathComponent("log.jsonl.child").path) })
        let child = (try? String(contentsOf: parent.appendingPathComponent("log.jsonl.child"), encoding: .utf8)).flatMap { Int32($0) }
        _ = (plain, stubborn)
        let start = ContinuousClock.now
        await p.coordinator.shutdown()
        #expect(ContinuousClock.now - start < .milliseconds(2500), "quit was held \(ContinuousClock.now - start)")
        #expect(PluginRunningFile.read(p.paths.running).isEmpty)
        for pid in pids + [child].compactMap({ $0 }) {
            #expect(await waitFor(.milliseconds(500)) { kill(pid, 0) != 0 }, "pid \(pid) is alive")
        }
    }

    @Test func logDisclosureShowsRedactedTail() async throws {
        let p = rig()
        try p.fake("dev.test.log", script: .object(["stderr": .string("token sk-abc123\n")]))
        testCenter(for: p.rig.workspace).plugins = p.coordinator
        let main = try alloyWindow(p.rig.workspace)
        let settings = try main.openSettingsFromMenu()
        func exists(_ id: String) -> Bool { (try? settings.element(identifier: id)) != nil }
        for _ in 0..<300 where !exists("settings.plugins.row.dev.test.log") { settings.tick(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(!exists("settings.plugins.row.dev.test.log.log-text"), "collapsed: no element")
        #expect(await p.coordinator.activate(plugin: "dev.test.log", .command))
        #expect(await waitFor { await p.coordinator.host?.stderrTail(of: "dev.test.log").contains("token") == true })
        try settings.click(settings.element(identifier: "settings.plugins.row.dev.test.log.log"))
        for _ in 0..<300 where !exists("settings.plugins.row.dev.test.log.log-text") { settings.tick(); try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<4 { settings.tick() }
        let e = try settings.element(identifier: "settings.plugins.row.dev.test.log.log-text")
        let text = e.value ?? e.label ?? ""
        #expect(text.contains(PluginLogRedactor.marker), "\(text)")
        #expect(!text.contains("sk-abc123"))
        try settings.click(settings.element(identifier: "settings.plugins.row.dev.test.log.log"))
        for _ in 0..<4 { settings.tick() }
        #expect(!exists("settings.plugins.row.dev.test.log.log-text"), "collapsed again")
        await p.coordinator.shutdown()
    }

    @Test func valueChangeSendsSettingsChanged() async throws {
        let p = rig()
        let folder = try p.fake("dev.test.vals")
        #expect(await p.coordinator.activate(plugin: "dev.test.vals", .command))
        #expect(await waitFor { methods(folder).contains("initialized") })
        try p.coordinator.setValue(.bool(false), key: "x", for: "dev.test.vals")
        #expect(await waitFor { methods(folder).contains("settings/changed") })
        let message = log(folder).first { $0["method"]?.stringValue == "settings/changed" }
        #expect(message?["params"]?["values"]?["x"]?.boolValue == false)
        #expect(methods(folder).filter { $0 == "initialize" }.count == 1, "a value change does not restart the plugin")
        await p.coordinator.shutdown()
    }

    // MARK: Guard

    @Test func idleTicksWithRunningPluginsCostNothing() async throws {
        let p = rig()
        for i in 1...3 { try p.fake("dev.test.idle\(i)") }
        for i in 1...3 { #expect(await p.coordinator.activate(plugin: "dev.test.idle\(i)", .command)) }
        #expect(await waitFor { running(p).count == 3 })
        let window = try alloyWindow(p.rig.workspace)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        let before = BodyProbe.counts
        for _ in 0..<120 { window.tick(); await Task.yield() }
        let requests = window.frameWork.reduce(0) { $0 + $1.elementRequests }
        #expect(requests == 0, "idle element requests \(requests)")
        let changed = BodyProbe.counts.filter { $0.value != (before[$0.key] ?? 0) }
        #expect(changed.isEmpty, "\(changed)")
        #expect(BodyProbe.counts["AlloyScreen", default: 0] == before["AlloyScreen", default: 0])
        #expect(BodyProbe.counts["SidebarView", default: 0] == before["SidebarView", default: 0])
        await p.coordinator.shutdown()
    }
}
