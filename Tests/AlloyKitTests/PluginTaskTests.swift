import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
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
@Suite(.serialized) struct PluginTaskTests {
    private let todo = "dev.example.todo"

    private struct Fixture {
        let p: PluginRig
        let center: CommandCenter
        let store: TerminalPanelStore
        let spawner: ScriptedPtySpawner
    }

    private func manifest(_ id: String, task: String) -> String {
        """
        {"id":"\(id)","name":"Todo","version":"1.0.0","permissions":["process.spawn"],
         "contributes":{"taskCommands":[\(task)]}}
        """
    }

    private func fixture(task: String = #"{"id":"test","title":"Test","command":"npm","args":["test"]}"#,
                         enable: Bool = true) async throws -> Fixture {
        let rig = Rig()
        await rig.workspace.restoreUIState()
        let center = testCenter(for: rig.workspace)
        let spawner = ScriptedPtySpawner()
        let store = TerminalPanelStore(workspace: rig.workspace, spawner: spawner, environment: ["SHELL": "/bin/sh"])
        let p = PluginRig(rig: rig, registry: center.registry)
        try await p.coordinator.install(folder: p.source(todo, manifest: manifest(todo, task: task)))
        if enable { try p.coordinator.enable(todo) }
        return Fixture(p: p, center: center, store: store, spawner: spawner)
    }

    private func paletteTitles(_ f: Fixture, _ query: String) -> [String] {
        f.center.palette.show(registry: f.center.registry, workspace: f.p.rig.workspace)
        f.center.palette.setQuery(query)
        defer { f.center.palette.hide() }
        return f.center.palette.rows.map(\.displayTitle)
    }

    @Test func taskRegistersAndRunsInANewTab() async throws {
        let f = try await fixture()
        let workspace = f.p.rig.workspace
        #expect(paletteTitles(f, "Run Task").contains("Todo: Run Task: Test"))
        #expect(workspace.mode == .chat)
        #expect(f.center.registry.run(id: "\(todo).task.test"))
        #expect(await waitFor { f.spawner.spawned.count == 1 })
        #expect(f.store.tabSummaries.map(\.title) == ["Test"])
        #expect(String(decoding: f.spawner.spawned[0].written, as: UTF8.self) == "'npm' 'test'\n")
        #expect(f.p.row(todo)?.status == .enabled, "no plugin process was involved")
        await f.p.coordinator.shutdown()
    }

    @Test func promptShowsTheExactQuotedLine() async throws {
        let f = try await fixture(task: #"{"id":"test","title":"Test","command":"npm","args":["run it","it's"]}"#, enable: false)
        #expect(f.p.row(todo)?.commandsToRun == ["'npm' 'run it' 'it'\\''s'"])
        await f.p.coordinator.shutdown()
    }

    @Test func controlCharacterInATaskFieldFailsTheInstall() async throws {
        let rig = Rig()
        let p = PluginRig(rig: rig)
        let source = p.source(todo, manifest: manifest(todo, task: #"{"id":"test","title":"Test","command":"npm","args":["a\u0015b"]}"#))
        do {
            try await p.coordinator.install(folder: source)
            Issue.record("expected the manifest to be refused")
        } catch let error as PluginInstallError {
            if case .badManifest(let why) = error { #expect(why.description.contains("control characters")) } else { Issue.record("\(error)") }
        }
        #expect(p.coordinator.installedManifests[todo] == nil)
    }

    @Test func tasksAreSupportedOnThisPlatform() {
        #expect(PluginCoordinator.tasksSupported == true)
        #expect(PluginCoordinator.tasksUnsupportedNote == "Task commands aren't supported on Windows yet")
    }

    @Test func argsAreQuoted() {
        #expect(ShellQuote.line(command: "echo", args: ["a b", "it's"], cwd: nil) == "'echo' 'a b' 'it'\\''s'")
    }

    @Test func cwdIsPrefixed() async throws {
        #expect(ShellQuote.line(command: "make", args: [], cwd: "/p/sub dir") == "cd '/p/sub dir' && 'make'")
        let f = try await fixture(task: #"{"id":"b","title":"Build","command":"make","cwd":"sub"}"#)
        let root = f.p.rig.workspace.projectRoot.standardizedFileURL.path
        #expect(f.center.registry.run(id: "\(todo).task.b"))
        #expect(await waitFor { f.spawner.spawned.count == 1 })
        let typed = String(decoding: f.spawner.spawned[0].written, as: UTF8.self)
        #expect(typed == "cd '\(root)/sub' && 'make'\n", "\(typed)")
        await f.p.coordinator.shutdown()
    }

    @Test func cwdOutsideRootDisablesTask() async throws {
        let f = try await fixture(task: #"{"id":"out","title":"Out","command":"ls","cwd":"../elsewhere"}"#)
        let command = try #require(f.center.registry.command(id: "\(todo).task.out"))
        #expect(!command.isEnabled())
        #expect(!f.center.registry.run(id: "\(todo).task.out"))
        #expect(f.spawner.spawned.isEmpty)
        #expect(f.p.row(todo)?.notes.contains("Task out has a working directory outside the project") == true)
        await f.p.coordinator.shutdown()
    }

    @Test func disableUnregistersTasks() async throws {
        let f = try await fixture()
        #expect(f.center.registry.command(id: "\(todo).task.test") != nil)
        try f.p.coordinator.disable(todo)
        #expect(f.center.registry.command(id: "\(todo).task.test") == nil)
        #expect(!f.center.registry.commands.contains { $0.descriptor.source == .plugin(id: todo) })
        await f.p.coordinator.shutdown()
    }

    @Test func chatModeSwitchesToCodeAndShowsPanel() async throws {
        let f = try await fixture()
        let workspace = f.p.rig.workspace
        workspace.setMode(.chat)
        #expect(!workspace.terminalVisible)
        #expect(f.center.registry.run(id: "\(todo).task.test"))
        #expect(workspace.mode == .code)
        #expect(workspace.terminalVisible)
        #expect(workspace.terminalLayout.tabs.count == 1)
        #expect(workspace.terminalLayout.tabs.first?.panes.values.first?.lastCwd == workspace.projectRoot.path)
        await f.p.coordinator.shutdown()
    }

    // MARK: Guard

    private final class Keeper { var rigs: [PluginRig] = [] }

    /// An enabled task plugin costs nothing until a task runs: idle frames request nothing and typing holds the Code 1 count.
    @Test func taskPluginCostsNothingUntilRun() async throws {
        let keeper = Keeper()
        let perf = CodeModePerformanceTests()
        try await perf.guardTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, install: { rig in
            let p = PluginRig(rig: rig)
            keeper.rigs.append(p)
            let source = p.source(todo, manifest: manifest(todo, task: #"{"id":"test","title":"Test","command":"npm","args":["test"]}"#))
            try? p.installNow(source)
            try? p.coordinator.enable(todo)
        })
        #expect(keeper.rigs.first?.coordinator.registeredTasks[todo]?.count == 1)
        #expect(keeper.rigs.first?.rig.workspace.terminalVisible == false, "no terminal was opened until a task runs")
        for p in keeper.rigs { await p.coordinator.shutdown() }
    }
}
