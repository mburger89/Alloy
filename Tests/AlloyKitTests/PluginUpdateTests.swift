import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
private func waitFor(_ timeout: Duration = .seconds(30), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// Installing a plugin from a local git repository and updating it: the old folder waits until the new version has started.
@MainActor
@Suite(.serialized) struct PluginUpdateTests {
    private let id = "dev.example.gitfake"

    private func rig() -> PluginRig {
        PluginRig(pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"])
    }

    /// A repository holding the fake plugin, version 1.0.0 tagged `v1.0.0`.
    private func fakeRepo(_ p: PluginRig) throws -> (dir: URL, url: String) {
        let parent = p.rig.root.appendingPathComponent("repos")
        let dir = try writeFakePlugin(id: id, in: parent)
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "add", "alloy-plugin.json", "script.json")
        try git(dir, "commit", "-q", "-m", "1.0.0")
        try git(dir, "tag", "v1.0.0")
        return (dir, "file://" + dir.path)
    }

    /// Commits version 2.0.0 of the fake with `script` and `permissions`, tagged `v2.0.0`.
    private func release2(_ p: PluginRig, _ dir: URL, script: JSONValue = .object([:]), permissions: [String] = []) throws {
        try writeFakePlugin(id: id, in: dir.deletingLastPathComponent(), permissions: permissions, script: script)
        let manifest = dir.appendingPathComponent("alloy-plugin.json")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: #""version":"1.0.0""#, with: #""version":"2.0.0""#)
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        try git(dir, "add", "alloy-plugin.json", "script.json")
        try git(dir, "commit", "-q", "-m", "2.0.0")
        try git(dir, "tag", "v2.0.0")
    }

    private func installedVersion(_ p: PluginRig) -> String? {
        let url = p.paths.plugins.appendingPathComponent("\(id)/alloy-plugin.json")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.contains(#""version":"2.0.0""#) ? "2.0.0" : text.contains(#""version":"1.0.0""#) ? "1.0.0" : nil
    }

    private func previousExists(_ p: PluginRig) -> Bool {
        FileManager.default.fileExists(atPath: p.paths.plugins.appendingPathComponent(".\(id).previous").path)
    }

    /// Installs v1.0.0, enables and starts it, publishes v2.0.0 and checks for the update.
    private func startedWithUpdate(script: JSONValue = .object([:]), permissions: [String] = []) async throws -> PluginRig {
        let p = rig()
        let (dir, url) = try fakeRepo(p)
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        try p.coordinator.enable(id)
        #expect(await p.coordinator.activate(plugin: id, .startup))
        try release2(p, dir, script: script, permissions: permissions)
        await p.coordinator.checkForUpdate(id)
        #expect(p.row(id)?.update == .available(version: "2.0.0"))
        return p
    }

    @Test func installRecordsTheGitSource() async throws {
        let p = rig()
        let (dir, url) = try fakeRepo(p)
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        let commit = try git(dir, "rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(p.rig.workspace.settings.plugins[id]?.source == .git(url: url, tag: "v1.0.0", commit: commit))
        #expect(p.rig.workspace.settings.plugins[id]?.enabled == false)
    }

    @Test func updateSucceedsAndDropsThePreviousFolder() async throws {
        let p = try await startedWithUpdate()
        try await p.coordinator.applyUpdate(id)
        #expect(await waitFor { !self.previousExists(p) && p.row(self.id)?.status == .running })
        #expect(installedVersion(p) == "2.0.0")
        #expect(p.rig.workspace.settings.plugins[id]?.version == "2.0.0")
        if case .git(_, let tag, _)? = p.rig.workspace.settings.plugins[id]?.source { #expect(tag == "v2.0.0") } else { Issue.record("not a git source") }
    }

    @Test func failedInitializeRestoresPrevious() async throws {
        let p = try await startedWithUpdate(script: .object(["exitOnInitialize": .bool(true)]))
        try await p.coordinator.applyUpdate(id)
        #expect(await waitFor { self.installedVersion(p) == "1.0.0" && !self.previousExists(p) })
        #expect(await waitFor { p.rig.workspace.settings.plugins[self.id]?.version == "1.0.0" })
        if case .git(_, let tag, _)? = p.rig.workspace.settings.plugins[id]?.source { #expect(tag == "v1.0.0") } else { Issue.record("not a git source") }
    }

    @Test func newPermissionsLeaveItDisabled() async throws {
        let p = try await startedWithUpdate(permissions: ["project.read"])
        try await p.coordinator.applyUpdate(id)
        #expect(await waitFor { p.row(self.id)?.status == .needsPermissions([.projectRead]) })
        #expect(!p.coordinator.isActive(id))
        #expect(await waitFor { !self.previousExists(p) })
        #expect(installedVersion(p) == "2.0.0")
    }

    // MARK: Approved commands

    private func taskContributes(_ ids: [String]) -> JSONValue {
        .object(["taskCommands": .array(ids.map { .object(["id": .string($0), "title": .string($0), "command": .string("make"),
                                                              "args": .array([.string($0)])]) })])
    }

    /// A repository holding the fake with the given task commands at 1.0.0 (tagged `v1.0.0`).
    private func taskRepo(_ p: PluginRig, tasks: [String]) throws -> (dir: URL, url: String) {
        let parent = p.rig.root.appendingPathComponent("repos")
        let dir = try writeFakePlugin(id: id, in: parent, permissions: ["process.spawn"], contributes: taskContributes(tasks))
        try git(dir, "init", "-q", "-b", "main")
        try git(dir, "add", "alloy-plugin.json", "script.json")
        try git(dir, "commit", "-q", "-m", "1.0.0")
        try git(dir, "tag", "v1.0.0")
        return (dir, "file://" + dir.path)
    }

    private func releaseTasks(_ p: PluginRig, _ dir: URL, tasks: [String]) throws {
        try writeFakePlugin(id: id, in: dir.deletingLastPathComponent(), permissions: ["process.spawn"], contributes: taskContributes(tasks))
        let manifest = dir.appendingPathComponent("alloy-plugin.json")
        let text = try String(contentsOf: manifest, encoding: .utf8).replacingOccurrences(of: #""version":"1.0.0""#, with: #""version":"2.0.0""#)
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        try git(dir, "add", "alloy-plugin.json", "script.json")
        try git(dir, "commit", "-q", "-m", "2.0.0")
        try git(dir, "tag", "v2.0.0")
    }

    @Test func updateThatAddsATaskCommandNeedsApprovalAndDoesNotRunIt() async throws {
        let p = rig()
        let (dir, url) = try taskRepo(p, tasks: ["build"])
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        try p.coordinator.enable(id)
        #expect(p.coordinator.registeredTasks[id]?.count == 1)
        #expect(p.rig.workspace.settings.plugins[id]?.approvedCommandsHash != nil)
        try releaseTasks(p, dir, tasks: ["build", "evil"])
        await p.coordinator.checkForUpdate(id)
        try await p.coordinator.applyUpdate(id)
        #expect(installedVersion(p) == "2.0.0")
        #expect(p.row(id)?.status == .needsPermissions([]), "the same needs-approval state as a new permission")
        #expect(p.row(id)?.notes.contains { $0.contains("commands it runs changed") } == true)
        #expect(!p.coordinator.isActive(id))
        #expect(p.coordinator.registeredTasks[id] == nil)
        #expect(p.coordinator.registry.command(id: "\(id).task.evil") == nil, "the new task is not even listed")
        #expect(p.coordinator.registry.command(id: "\(id).task.build") == nil)
        // The row lists exactly what would run, and approving it brings both tasks.
        #expect(p.row(id)?.commandsToRun == ["'make' 'build'", "'make' 'evil'"])
        try p.coordinator.enable(id)
        #expect(p.coordinator.isActive(id))
        #expect(p.coordinator.registry.command(id: "\(id).task.evil") != nil)
        await p.coordinator.shutdown()
    }

    @Test func updateKeepingTheSameCommandsStaysEnabled() async throws {
        let p = rig()
        let (dir, url) = try taskRepo(p, tasks: ["build"])
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        try p.coordinator.enable(id)
        try releaseTasks(p, dir, tasks: ["build"])
        await p.coordinator.checkForUpdate(id)
        try await p.coordinator.applyUpdate(id)
        #expect(p.coordinator.isActive(id))
        #expect(p.coordinator.registry.command(id: "\(id).task.build") != nil)
        await p.coordinator.shutdown()
    }

    @Test func reinstallingFromTheSameURLWithNewCommandsAsksAgain() async throws {
        let p = rig()
        let (dir, url) = try taskRepo(p, tasks: ["build"])
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        try p.coordinator.enable(id)
        try releaseTasks(p, dir, tasks: ["build", "evil"])
        try await p.coordinator.install(gitURL: url, tag: "v2.0.0")
        #expect(p.row(id)?.status == .needsPermissions([]))
        #expect(!p.coordinator.isActive(id))
        #expect(p.coordinator.registry.command(id: "\(id).task.evil") == nil)
        await p.coordinator.shutdown()
    }

    @Test func folderReinstallWithNewCommandsAsksAgain() async throws {
        let p = rig()
        func manifest(_ version: String, _ extra: String) -> String {
            """
            {"id":"dev.example.tasks","name":"Tasks","version":"\(version)","permissions":["process.spawn"],
             "contributes":{"taskCommands":[{"id":"a","title":"A","command":"make"}\(extra)]}}
            """
        }
        try await p.coordinator.install(folder: p.source("dev.example.tasks", manifest: manifest("1.0.0", "")))
        try p.coordinator.enable("dev.example.tasks")
        #expect((p.coordinator.registeredTasks["dev.example.tasks"] != nil))
        try await p.coordinator.install(folder: p.source("dev.example.tasks", manifest: manifest("1.0.1", #",{"id":"b","title":"B","command":"rm"}"#)))
        #expect(p.row("dev.example.tasks")?.status == .needsPermissions([]))
        #expect(!(p.coordinator.registeredTasks["dev.example.tasks"] != nil))
        // Same commands again: nothing to approve.
        try p.coordinator.enable("dev.example.tasks")
        try await p.coordinator.install(folder: p.source("dev.example.tasks", manifest: manifest("1.0.2", #",{"id":"b","title":"B","command":"rm"}"#)))
        #expect((p.coordinator.registeredTasks["dev.example.tasks"] != nil))
        await p.coordinator.shutdown()
    }

    @Test func settingsWithoutAHashAreKeptOnlyWhileTheVersionIsUnchanged() async throws {
        let p = rig()
        let source = p.source("dev.example.tasks", manifest: """
        {"id":"dev.example.tasks","name":"Tasks","version":"1.0.0","permissions":["process.spawn"],
         "contributes":{"taskCommands":[{"id":"a","title":"A","command":"make"}]}}
        """)
        try await p.coordinator.install(folder: source)
        try p.coordinator.enable("dev.example.tasks")
        func clearHash(version: String) throws {
            var s = p.rig.workspace.settings
            s.plugins["dev.example.tasks"]?.approvedCommandsHash = nil
            s.plugins["dev.example.tasks"]?.version = version
            try p.rig.workspace.updateSettings(s)
            p.coordinator.adopt(catalog: PluginCatalog.scan(p.paths.plugins, pathDirs: []))
        }
        try clearHash(version: "1.0.0")
        #expect((p.coordinator.registeredTasks["dev.example.tasks"] != nil), "unchanged since it was enabled")
        #expect(p.rig.workspace.settings.plugins["dev.example.tasks"]?.approvedCommandsHash != nil)
        try clearHash(version: "0.9.0")
        #expect(!(p.coordinator.registeredTasks["dev.example.tasks"] != nil), "the version moved on without an approval on record")
        #expect(p.row("dev.example.tasks")?.status == .needsPermissions([]))
        await p.coordinator.shutdown()
    }

    // MARK: In flight

    /// Delays every clone so a second request arrives while the first runs.
    private struct SlowRunner: PluginGitRunner {
        let inner = LivePluginGitRunner()
        func run(_ args: [String], in dir: URL, timeout: Double, sizeCap: UInt64?, watch: URL?) async -> GitResult {
            if args.contains("clone") { try? await Task.sleep(for: .milliseconds(600)) }
            return await inner.run(args, in: dir, timeout: timeout, sizeCap: sizeCap, watch: watch)
        }
    }

    @Test func aSecondApplyUpdateWhileOneRunsDoesNothing() async throws {
        let p = try await startedWithUpdate()
        p.coordinator.gitRunner = SlowRunner()
        async let first: Void = p.coordinator.applyUpdate(id)
        try await Task.sleep(for: .milliseconds(150))
        #expect(p.row(id)?.update == .updating, "the button shows the run and is disabled")
        try await p.coordinator.applyUpdate(id)   // the second call returns at once
        #expect(!previousExists(p), "the second call moved nothing")
        try await first
        #expect(installedVersion(p) == "2.0.0")
        #expect(await waitFor { !self.previousExists(p) && p.row(self.id)?.status == .running })
        #expect(p.row(id)?.update == .upToDate)
    }

    @Test func aSecondGitInstallWhileOneRunsDoesNothing() async throws {
        let p = rig()
        let (_, url) = try fakeRepo(p)
        p.coordinator.gitRunner = SlowRunner()
        async let first: Void = p.coordinator.install(gitURL: url, tag: "v1.0.0")
        try await Task.sleep(for: .milliseconds(150))
        #expect(p.coordinator.status.installingGit)
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        try await first
        #expect(!p.coordinator.status.installingGit)
        #expect(installedVersion(p) == "1.0.0")
    }

    @Test func failedUpdateClearsTheUpdatingState() async throws {
        let p = try await startedWithUpdate()
        struct Failing: PluginGitRunner {
            func run(_ args: [String], in dir: URL, timeout: Double, sizeCap: UInt64?, watch: URL?) async -> GitResult { GitResult(status: 128) }
        }
        p.coordinator.gitRunner = Failing()
        await #expect(throws: (any Error).self) { try await p.coordinator.applyUpdate(id) }
        #expect(p.row(id)?.update == nil, "the user can check again")
    }

    // MARK: Previous folders

    @Test func updateToANewerAPILeavesTheOldVersionInPlace() async throws {
        let p = try await startedWithUpdate(script: .object(["initializeResult": .object(["apiVersion": .number(9)])]))
        try await p.coordinator.applyUpdate(id)
        #expect(await waitFor { self.installedVersion(p) == "1.0.0" && !self.previousExists(p) })
        #expect(await waitFor { p.rig.workspace.settings.plugins[self.id]?.version == "1.0.0" })
    }

    @Test func staleDotPreviousFoldersGoAtLaunch() async throws {
        let p = rig()
        let stale = p.paths.plugins.appendingPathComponent(".dev.example.old.previous")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        await p.coordinator.activate()
        #expect(await waitFor { !FileManager.default.fileExists(atPath: stale.path) })
        await p.coordinator.shutdown()
    }

    // MARK: Guard

    @Test func settingsIdleAfterUpdateCheckCostsNothing() async throws {
        let p = rig()
        let (_, url) = try fakeRepo(p)
        try await p.coordinator.install(gitURL: url, tag: "v1.0.0")
        testCenter(for: p.rig.workspace).plugins = p.coordinator
        let main = try alloyWindow(p.rig.workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings.plugins.row.\(self.id).update")) != nil }
        await p.coordinator.checkForUpdate(id)
        for _ in 0..<10 { settings.tick(); await Task.yield() }
        var last = -1
        for _ in 0..<40 {
            settings.resetFrameWork()
            settings.tick()
            await Task.yield()
            let now = settings.frameWork.last?.elementRequests ?? 0
            if now == last { break }
            last = now
        }
        settings.resetFrameWork()
        for _ in 0..<20 { settings.tick(); await Task.yield() }
        let requests = settings.frameWork.reduce(0) { $0 + $1.elementRequests }
        #expect(requests == 0, "idle Settings frames after an update check asked for \(requests) elements")
        #expect(p.row(id)?.update == .upToDate)
    }
}
