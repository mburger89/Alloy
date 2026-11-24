import AlloyCore
import AlloyLSP
@testable import AlloyKit
import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct PluginDeclarativeTests {
    private let themeID = "plugin/dev.example.themes/midnight"

    @Test func themePackListsOnEnableAndLeavesOnDisable() async throws {
        let p = PluginRig()
        try await p.coordinator.install(folder: p.themePack())
        #expect(!p.themes.library.all.contains { $0.id == themeID }, "installed plugins start disabled")
        try p.coordinator.enable("dev.example.themes")
        #expect(p.themes.library.all.contains { $0.id == themeID })
        #expect(p.row("dev.example.themes")?.status == .enabled)
        try p.coordinator.disable("dev.example.themes")
        #expect(!p.themes.library.all.contains { $0.id == themeID })
        #expect(p.row("dev.example.themes")?.status == .disabled)
    }

    @Test func activeThemeFallsBackWhenItsPluginIsDisabled() async throws {
        let p = PluginRig()
        try await p.coordinator.install(folder: p.themePack())
        try p.coordinator.enable("dev.example.themes")
        try p.themes.choose(theme: themeID)
        #expect(p.themes.shownTheme?.id == themeID)
        #expect(p.themes.notice == nil)
        try p.coordinator.disable("dev.example.themes")
        #expect(p.themes.shownTheme?.id == "dracula")
        #expect(p.themes.notice != nil)
    }

    private func lspRig(_ p: PluginRig) -> LSPCoordinator {
        let config = ServerConfig(id: "fake", name: "Fake", languageID: "rust", extensions: ["rs"], command: "fake-builtin")
        return LSPCoordinator.install(on: p.rig.workspace, builtIn: [config], locator: ServerLocator(loginPATH: { nil }, xcrunFind: { _ in nil }),
                                      launcher: ServerLauncher { _, _, _ in throw CancellationError() })
    }

    @Test func serverOrderIsBuiltInThenPluginThenUser() async throws {
        let p = PluginRig()
        let lsp = lspRig(p)
        #expect(lsp.effectiveRegistry.server(forPath: "a.rs")?.command == "fake-builtin")
        try await p.coordinator.install(folder: p.serverPack("dev.example.servers", name: "Servers"))
        try p.coordinator.enable("dev.example.servers")
        #expect(lsp.effectiveRegistry.server(forPath: "a.rs")?.command == "fake-a", "the plugin beats the built-in")
        var s = p.rig.workspace.settings
        s.languageServers["fake"] = ServerConfigOverride(arguments: ["--user"])
        try p.rig.workspace.updateSettings(s)
        let both = lsp.effectiveRegistry.server(forPath: "a.rs")
        #expect(both?.command == "fake-a" && both?.arguments == ["--user"], "user arguments layer over the plugin's command")
        s.languageServers["fake"] = ServerConfigOverride(command: "fake-user", arguments: ["--user"])
        try p.rig.workspace.updateSettings(s)
        #expect(lsp.effectiveRegistry.server(forPath: "a.rs")?.command == "fake-user", "the user's command beats the plugin's")
        try p.coordinator.disable("dev.example.servers")
        #expect(lsp.effectiveRegistry.server(forPath: "a.rs")?.command == "fake-user")
    }

    @Test func secondPluginOnSameServerGetsClashNote() async throws {
        let p = PluginRig()
        let lsp = lspRig(p)
        try await p.coordinator.install(folder: p.serverPack("dev.example.alpha", name: "Alpha", command: "alpha-ls"))
        try await p.coordinator.install(folder: p.serverPack("dev.example.beta", name: "Beta", command: "beta-ls"))
        try p.coordinator.enable("dev.example.alpha")
        try p.coordinator.enable("dev.example.beta")
        #expect(lsp.effectiveRegistry.server(forPath: "a.rs")?.command == "alpha-ls")
        #expect(p.row("dev.example.beta")?.notes == ["Server fake is already provided by Alpha"])
        #expect(p.row("dev.example.alpha")?.notes == [])
    }

    @Test func scriptedSpawnPluginCannotBeEnabledWithoutBackend() async throws {
        let p = PluginRig()
        let dir = p.source("dev.example.script", manifest: """
        {"id":"dev.example.script","name":"Script","version":"1.0.0","main":{"command":"run.sh"},"permissions":["process.spawn"]}
        """, files: ["run.sh": "#!/bin/sh\n"])
        try await p.coordinator.install(folder: dir)
        #expect(p.row("dev.example.script")?.status == .sandboxUnavailable)
        #expect(throws: PluginError.sandboxUnavailable) { try p.coordinator.enable("dev.example.script") }
        #expect(p.rig.workspace.settings.plugins["dev.example.script"]?.enabled == false)
        #expect(p.row("dev.example.script")?.status.text == "sandbox unavailable")
    }

    @Test func updateWithNewPermissionStaysOff() async throws {
        let p = PluginRig()
        let dir = p.themePack()
        try await p.coordinator.install(folder: dir)
        try p.coordinator.enable("dev.example.themes")
        #expect(p.themes.library.all.contains { $0.id == themeID })
        try """
        {"id":"dev.example.themes","name":"Themes","version":"1.1.0","permissions":["network"],
         "contributes":{"themes":[{"path":"themes/midnight.json"}]}}
        """.write(to: dir.appendingPathComponent("alloy-plugin.json"), atomically: true, encoding: .utf8)
        try await p.coordinator.install(folder: dir)
        #expect(p.row("dev.example.themes")?.status == .needsPermissions([.network]))
        #expect(p.row("dev.example.themes")?.version == "1.1.0")
        #expect(!p.themes.library.all.contains { $0.id == themeID }, "nothing is applied until the user approves")
    }

    @Test func missingFolderIsListedAndInert() async throws {
        let p = PluginRig()
        try await p.coordinator.install(folder: p.themePack())
        try p.coordinator.enable("dev.example.themes")
        var s = p.rig.workspace.settings
        s.plugins["dev.example.gone"] = PluginSetting(enabled: true, version: "1.0.0", source: .folder(path: "/nowhere"), grants: [.processSpawn], enableOrder: 5)
        try p.rig.workspace.updateSettings(s)
        #expect(p.row("dev.example.gone")?.status == .missing)
        #expect(p.row("dev.example.gone")?.status.text == "folder missing")
        #expect(p.coordinator.effectiveServers.isEmpty)
        #expect(p.themes.library.all.contains { $0.id == themeID }, "the other plugin is unaffected")
    }

    @Test func removeDropsSettingsEntryAndFolder() async throws {
        let p = PluginRig()
        try await p.coordinator.install(folder: p.themePack())
        try p.coordinator.enable("dev.example.themes")
        try await p.coordinator.remove("dev.example.themes")
        #expect(p.rig.workspace.settings.plugins.isEmpty)
        #expect(p.row("dev.example.themes") == nil)
        #expect(!FileManager.default.fileExists(atPath: p.paths.plugins.appendingPathComponent("dev.example.themes").path))
        #expect(!p.themes.library.all.contains { $0.id == themeID })
    }

    // MARK: Guard

    private final class Keep { var rigs: [PluginRig] = [] }
    private let keep = Keep()

    /// A theme pack and a server pack, enabled before anything opens.
    private func enableBoth(_ rig: Rig) {
        let p = PluginRig(rig: rig)
        keep.rigs.append(p)
        do {
            try p.installNow(p.themePack())
            try p.installNow(p.serverPack("dev.example.servers", name: "Servers"))
            try p.coordinator.enable("dev.example.themes")
            try p.coordinator.enable("dev.example.servers")
        } catch { Issue.record("setup failed: \(error)") }
    }

    @Test func enabledPackagesCostNothing() async throws {
        let perf = CodeModePerformanceTests()
        let (rig, window, _) = try await perf.rigged(.code1, install: { enableBoth($0) })
        #expect(keep.rigs.first?.row("dev.example.themes")?.status == .enabled, "the packs are on")
        for _ in 0..<15 { window.tick(); await Task.yield() }
        window.resetFrameWork()
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        let requests = window.frameWork.reduce(0) { $0 + $1.elementRequests }
        print("PLUGIN idle requests=\(requests)")
        #expect(reruns.isEmpty, "idle ticks re-ran \(reruns)")
        #expect(requests == 0, "idle frames cost \(window.frameWork.map(\.elementRequests))")
        withExtendedLifetime((rig, window)) {}
        try await perf.guardTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, install: { enableBoth($0) })
    }
}
