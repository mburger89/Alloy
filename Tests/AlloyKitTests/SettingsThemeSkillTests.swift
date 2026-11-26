import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Every test injects a temporary home; none may touch the real `~/.claude`.
@MainActor
@Suite struct SettingsThemeSkillTests {
    private final class Holder { var controller: ThemeController? }

    private struct Setup {
        let rig: Rig
        let window: TestWindow
        let controller: ThemeController
        let installer: ThemeSkillInstaller
        let shared: ThemeSkillInstaller
        let files: [String: String]
    }

    private func setup(rig: Rig = Rig(),
                       prepare: (ThemeSkillInstaller, ThemeSkillInstaller, [String: String]) throws -> Void = { _, _, _ in }) async throws -> Setup {
        let home = rig.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installer = ThemeSkillInstaller(home: home)
        let shared = ThemeSkillInstaller(home: home, target: .sharedAgents)
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace))
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.testApp.app, watcher: ScriptedChangeSource())
        controller.skillInstallers = [.claudeCode: installer, .sharedAgents: shared]
        holder.controller = controller
        window.installAlloyMenu(rig.workspace, themes: controller)
        try prepare(installer, shared, ThemeSkill.files(themesFolder: controller.themesFolderPath))
        window.tick(); window.tick()
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-theme-section")) != nil }
        return Setup(rig: rig, window: settings, controller: controller, installer: installer, shared: shared,
                     files: ThemeSkill.files(themesFolder: controller.themesFolderPath))
    }

    private func label(_ t: Setup) async throws -> String {
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill")) != nil }
        return try t.window.element(identifier: "settings-install-theme-skill").label ?? ""
    }

    @Test func notInstalledShowsInstallAndClickInstalls() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        #expect(try await label(t) == "Install theme skill")
        _ = try t.window.element(identifier: "settings-theme-skill-hint")
        #expect(t.installer.status(files: t.files) == .notInstalled)
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Theme skill installed" }
        let button = try t.window.element(identifier: "settings-install-theme-skill")
        #expect(!button.isEnabled)
        #expect(t.installer.status(files: t.files) == .current)
        #expect(t.shared.status(files: t.files) == .current)
        #expect(t.installer.directory.path.hasPrefix(t.rig.root.path))
    }

    @Test func bothTargetsTickedByDefault() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        _ = try await label(t)
        for target in ["claudeCode", "sharedAgents"] {
            #expect(try t.window.element(identifier: "settings-theme-skill-target-\(target)").value == "1", "\(target)")
        }
        #expect(try t.window.element(identifier: "settings-theme-skill-target-claudeCode").label == "Claude Code")
        #expect(try t.window.element(identifier: "settings-theme-skill-target-sharedAgents").label
                == "Codex, Gemini CLI, OpenCode, Goose")
        let note = try t.window.element(identifier: "settings-theme-skill-note")
        #expect((note.value ?? note.label) == "OpenCode and Goose read both folders; the two copies are identical.")
        let hint = try t.window.element(identifier: "settings-theme-skill-hint")
        #expect((hint.value ?? hint.label) == "Lets your agents make Alloy themes in any session, not just /theme.")
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Theme skill installed" }
        #expect(FileManager.default.fileExists(atPath: t.installer.directory.appendingPathComponent("SKILL.md").path))
        #expect(FileManager.default.fileExists(atPath: t.shared.directory.appendingPathComponent("SKILL.md").path))
    }

    @Test func untickedTargetUntouched() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        _ = try await label(t)
        try t.window.click(t.window.element(identifier: "settings-theme-skill-target-sharedAgents"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-skill-target-sharedAgents"))?.value == "0" }
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Theme skill installed" }
        #expect(t.installer.status(files: t.files) == .current)
        #expect(!FileManager.default.fileExists(atPath: t.shared.directory.deletingLastPathComponent().deletingLastPathComponent().path))
    }

    @Test func editedTargetAsksOnlyForItself() async throws {
        let t = try await setup(prepare: { installer, _, files in
            try installer.install(files: files)
            try "my edits".write(to: installer.directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        })
        defer { t.controller.stop() }
        #expect(try await label(t) == "Update theme skill\u{2026}")
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-skill-replace")) != nil }
        try t.window.click(t.window.element(identifier: "settings-theme-skill-replace"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Theme skill installed" }
        #expect(t.installer.status(files: t.files) == .current)
        #expect(t.shared.status(files: t.files) == .current)
    }

    @Test func editedClaudeCopyDoesNotBlockTheOtherTarget() async throws {
        var skill: URL?
        let t = try await setup(prepare: { installer, _, files in
            try installer.install(files: files)
            let file = installer.directory.appendingPathComponent("SKILL.md")
            skill = file
            try "my edits".write(to: file, atomically: true, encoding: .utf8)
        })
        defer { t.controller.stop() }
        _ = try await label(t)
        try t.window.click(t.window.element(identifier: "settings-theme-skill-target-claudeCode"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Install theme skill" }
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Theme skill installed" }
        #expect((try? t.window.element(identifier: "settings-theme-skill-confirm")) == nil)
        #expect(t.shared.status(files: t.files) == .current)
        #expect(try String(contentsOf: try #require(skill), encoding: .utf8) == "my edits")
    }

    @Test func noTargetTickedDisablesButton() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        _ = try await label(t)
        for target in ["claudeCode", "sharedAgents"] {
            try t.window.click(t.window.element(identifier: "settings-theme-skill-target-\(target)"))
        }
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.isEnabled == false }
        #expect(try t.window.element(identifier: "settings-install-theme-skill").label == "Install theme skill")
    }

    @Test func makeThemeButtonNamesDefaultAgent() async throws {
        let custom = AgentDefinition(id: "opencode", name: "OpenCode", command: "opencode", args: ["acp"])
        let rig = Rig(agents: [], defaultAgentID: nil)
        try rig.workspace.saveAgent(custom)
        try rig.workspace.setDefaultAgent("opencode")
        let t = try await setup(rig: rig)
        defer { t.controller.stop() }
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-make-theme"))?.label == "Make a theme with OpenCode\u{2026}" }
        var settings = rig.workspace.settings
        settings.agents.removeAll()
        try rig.workspace.updateSettings(settings)
        #expect(rig.workspace.settings.defaultAgentID == "opencode")
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-make-theme"))?.label == "Make a theme with Claude\u{2026}" }
    }

    @Test func currentShowsDisabledInstalled() async throws {
        let t = try await setup(prepare: { installer, shared, files in try installer.install(files: files); try shared.install(files: files) })
        defer { t.controller.stop() }
        #expect(try await label(t) == "Theme skill installed")
        #expect(try !t.window.element(identifier: "settings-install-theme-skill").isEnabled)
    }

    @Test func differentAsksBeforeReplacingAndCancelWritesNothing() async throws {
        var skill: URL?
        let t = try await setup(prepare: { installer, shared, files in
            try installer.install(files: files)
            try shared.install(files: files)
            let file = installer.directory.appendingPathComponent("SKILL.md")
            skill = file
            try "my edits".write(to: file, atomically: true, encoding: .utf8)
        })
        defer { t.controller.stop() }
        #expect(try await label(t) == "Update theme skill\u{2026}")
        #expect((try? t.window.element(identifier: "settings-theme-skill-confirm")) == nil)
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-skill-confirm")) != nil }
        let confirm = try t.window.element(identifier: "settings-theme-skill-confirm")
        #expect((confirm.value ?? confirm.label) == "Replace the copy in your skills folder? Changes made to it will be lost.")
        try t.window.click(t.window.element(identifier: "settings-theme-skill-cancel"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-skill-confirm")) == nil }
        #expect(try String(contentsOf: try #require(skill), encoding: .utf8) == "my edits")
        #expect(try await label(t) == "Update theme skill\u{2026}")

        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-skill-replace")) != nil }
        try t.window.click(t.window.element(identifier: "settings-theme-skill-replace"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-install-theme-skill"))?.label == "Theme skill installed" }
        #expect(t.installer.status(files: t.files) == .current)
        #expect((try? t.window.element(identifier: "settings-theme-skill-confirm")) == nil)
    }

    @Test func failureShowsInlineError() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        _ = try await label(t)
        // A file where the directory should go makes the install fail.
        let blocker = t.installer.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: blocker, atomically: true, encoding: .utf8)
        try t.window.click(t.window.element(identifier: "settings-install-theme-skill"))
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-skill-error")) != nil }
        let error = try t.window.element(identifier: "settings-theme-skill-error")
        #expect((error.value ?? error.label ?? "").hasPrefix("Could not install the theme skill"))
    }

    @Test func withoutAnInstallerThereIsNoButton() async throws {
        let rig = Rig()
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace))
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.testApp.app, watcher: ScriptedChangeSource())
        defer { controller.stop() }
        holder.controller = controller
        window.installAlloyMenu(rig.workspace, themes: controller)
        window.tick(); window.tick()
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-theme-section")) != nil }
        #expect((try? settings.element(identifier: "settings-install-theme-skill")) == nil)
    }
}
