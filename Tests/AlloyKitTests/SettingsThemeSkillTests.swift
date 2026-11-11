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
        let files: [String: String]
    }

    private func setup(prepare: (ThemeSkillInstaller, [String: String]) throws -> Void = { _, _ in }) async throws -> Setup {
        let rig = Rig()
        let home = rig.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installer = ThemeSkillInstaller(home: home)
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: ScriptedChangeSource())
        controller.skillInstaller = installer
        holder.controller = controller
        try prepare(installer, ThemeSkill.files(themesFolder: controller.themesFolderPath))
        window.tick(); window.tick()
        try window.click(window.element(identifier: "settings"))
        try await window.runUntil { (try? window.element(identifier: "settings-theme-section")) != nil }
        return Setup(rig: rig, window: window, controller: controller, installer: installer,
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
        #expect(t.installer.directory.path.hasPrefix(t.rig.root.path))
    }

    @Test func currentShowsDisabledInstalled() async throws {
        let t = try await setup(prepare: { installer, files in try installer.install(files: files) })
        defer { t.controller.stop() }
        #expect(try await label(t) == "Theme skill installed")
        #expect(try !t.window.element(identifier: "settings-install-theme-skill").isEnabled)
    }

    @Test func differentAsksBeforeReplacingAndCancelWritesNothing() async throws {
        var skill: URL!
        let t = try await setup(prepare: { installer, files in
            try installer.install(files: files)
            skill = installer.directory.appendingPathComponent("SKILL.md")
            try "my edits".write(to: skill, atomically: true, encoding: .utf8)
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
        #expect(try String(contentsOf: skill, encoding: .utf8) == "my edits")
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
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: ScriptedChangeSource())
        defer { controller.stop() }
        holder.controller = controller
        window.tick(); window.tick()
        try window.click(window.element(identifier: "settings"))
        try await window.runUntil { (try? window.element(identifier: "settings-theme-section")) != nil }
        #expect((try? window.element(identifier: "settings-install-theme-skill")) == nil)
    }
}
