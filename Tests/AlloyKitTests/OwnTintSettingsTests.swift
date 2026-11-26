@testable import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Settings > Editor > "Tint my own edits" and its colour.
@MainActor
@Suite struct OwnTintSettingsTests {
    private func settingsWindow(_ workspace: Workspace) async throws -> TestWindow {
        let main = try alloyWindow(workspace)
        let settings = try main.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-own-tint")) != nil }
        return settings
    }

    /// The elements carrying `id` (the colour picker's id is on its row and its well).
    private func all(_ window: TestWindow, _ id: String) -> [TestElement] {
        (try? window.elements(where: { $0.identifier == id })) ?? []
    }

    private func exists(_ window: TestWindow, _ id: String) -> Bool { !all(window, id).isEmpty }

    private func settle(_ window: TestWindow, _ n: Int = 10) async {
        for _ in 0..<n { window.tick(); await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    @Test func ownTintToggleDefaultsOffAndHidesPicker() async throws {
        let rig = Rig()
        let window = try await settingsWindow(rig.workspace)
        #expect(!rig.workspace.settings.ownEditTint.enabled)
        #expect(!exists(window, "settings-own-tint-color"))
        #expect(!exists(window, "settings-own-tint-reset"))
        try window.click(window.element(identifier: "settings-own-tint"))
        await settle(window)
        #expect(rig.workspace.settings.ownEditTint.enabled)
        #expect(exists(window, "settings-own-tint-color"))
        #expect(!exists(window, "settings-own-tint-reset"), "nothing picked yet")
        #expect(AlloySettings.load(appSupport: rig.workspace.appSupport).ownEditTint.enabled, "persisted")
        try window.click(window.element(identifier: "settings-own-tint"))
        await settle(window)
        #expect(!rig.workspace.settings.ownEditTint.enabled)
        #expect(!exists(window, "settings-own-tint-color"))
    }

    private func pick(_ hex: String, in window: TestWindow) async throws {
        try window.click(#require(all(window, "settings-own-tint-color").last))
        await settle(window)
        let field = try #require(try window.elements(where: { $0.role == .textField }).last, "no hex field")
        try window.click(field)
        window.typeKey("a", modifierFlags: .command)
        window.typeText(hex + "\n")
        await settle(window)
    }

    @Test func pickingAColourStoresHexAndTintsWithIt() async throws {
        let rig = Rig()
        var s = rig.workspace.settings
        s.ownEditTint.enabled = true
        try rig.workspace.updateSettings(s, persist: false)
        let window = try await settingsWindow(rig.workspace)
        try await pick("#00FF00", in: window)
        #expect(rig.workspace.settings.ownEditTint.colorHex == "#00FF00")
        #expect(exists(window, "settings-own-tint-reset"))
        let c = Color.ownEditTint(rig.workspace.settings).resolve(in: EnvironmentValues())
        #expect(c.red == 0 && c.green == 1 && c.blue == 0 && c.opacity == 1)
        #expect(AlloySettings.load(appSupport: rig.workspace.appSupport).ownEditTint.colorHex == "#00FF00")
    }

    @Test func resetReturnsToThemeColour() async throws {
        let rig = Rig()
        var s = rig.workspace.settings
        s.ownEditTint = OwnEditTint(enabled: true, colorHex: "#FF0000")
        try rig.workspace.updateSettings(s, persist: false)
        let window = try await settingsWindow(rig.workspace)
        try window.click(window.element(identifier: "settings-own-tint-reset"))
        await settle(window)
        #expect(rig.workspace.settings.ownEditTint.colorHex == nil)
        #expect(rig.workspace.settings.ownEditTint.enabled)
        #expect(!exists(window, "settings-own-tint-reset"))
    }

    @Test func themeSwitchFollowsThemeOnlyWithoutPickedColour() throws {
        // A window's light and dark themes stand in for two themes: the "you" slot differs between them.
        let slot = try resolvedInWindow([.userAuthor], dark: false)[0], darkSlot = try resolvedInWindow([.userAuthor], dark: true)[0]
        try #require(slot != darkSlot, "the slot differs between the two themes")
        let unpicked = AlloySettings()
        #expect(try resolvedInWindow([Color.ownEditTint(unpicked)], dark: false)[0] == slot)
        #expect(try resolvedInWindow([Color.ownEditTint(unpicked)], dark: true)[0] == darkSlot, "follows the new theme")
        var picked = AlloySettings()
        picked.ownEditTint.colorHex = "#FF8000"
        let light = try resolvedInWindow([Color.ownEditTint(picked)], dark: false)[0]
        let dark = try resolvedInWindow([Color.ownEditTint(picked)], dark: true)[0]
        #expect(light == dark, "a picked colour holds across themes")
        #expect(abs(light.red - 1) < 0.003 && abs(light.green - 128.0 / 255) < 0.003 && light.blue < 0.003)
    }
}
