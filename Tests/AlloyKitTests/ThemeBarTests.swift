import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ThemeBarTests {
    private final class Holder { var controller: ThemeController? }

    private struct Setup {
        let rig: Rig
        let window: TestWindow
        let controller: ThemeController
    }

    private func rgba(_ value: String) -> ThemeRGBA { ThemeRGBA(hex: value)! }

    private func setup(settings: AlloySettings? = nil) async throws -> Setup {
        let rig = Rig()
        if let settings { try rig.workspace.updateSettings(settings) }
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        holder.controller = controller
        window.tick(); window.tick()
        return Setup(rig: rig, window: window, controller: controller)
    }

    private func paper() -> ThemeFile {
        ThemeFile(name: "Paper", appearance: .light, base: "solarized-light", colors: ["chatFill": rgba("#FFF8E7")])
    }

    private func startPreview(_ t: Setup, _ draft: ThemeFile) {
        t.controller.preview(draft, resolved: t.controller.library.resolve(draft: draft).theme, session: UUID())
    }

    private func text(_ e: TestElement) -> String { e.value ?? e.label ?? "" }

    /// A dark user theme whose text is nearly the colour of its chat fill, so it has contrast findings.
    private func writeBadTheme(_ t: Setup) async throws -> String {
        let dir = ThemeLibrary.userDirectory(appSupport: t.rig.root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try ##"{"name":"Murky","appearance":"dark","base":"dracula","colors":{"textPrimary":"#2A2C38","mutedInk":"#2A2C38"}}"##
            .write(to: dir.appendingPathComponent("murky.json"), atomically: true, encoding: .utf8)
        await t.controller.reload()
        return "user/murky"
    }

    private func openSettings(_ t: Setup) async throws {
        try t.window.openSettingsFromMenu()
        try await t.window.runUntil { (try? t.window.element(identifier: "settings-theme-section")) != nil }
    }

    @Test func noBarWithoutPreviewOrWarning() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        #expect((try? t.window.element(identifier: "theme-preview-bar")) == nil)
        #expect((try? t.window.element(identifier: "theme-activation-warning")) == nil)
    }

    @Test func barAppearsOnPreviewAndKeepActivates() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        startPreview(t, paper())
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-preview-bar")) != nil }
        let label = try t.window.element(identifier: "theme-preview-bar")
        let all = ([label] + descendants(of: label, in: t.window)).map(text)
        #expect(all.contains("Previewing Paper"), "\(all)")
        try t.window.click(t.window.element(identifier: "theme-preview-keep"))
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-preview-bar")) == nil }
        #expect(t.controller.currentSettings.theme == "user/paper")
    }

    @Test func discardButtonRestores() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let dracula = ThemeApplier.theme(for: try #require(t.controller.library.resolve("dracula")))
        startPreview(t, paper())
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-preview-discard")) != nil }
        #expect(t.window.window.darkTheme != dracula)
        try t.window.click(t.window.element(identifier: "theme-preview-discard"))
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-preview-bar")) == nil }
        #expect(t.window.window.darkTheme == dracula)
        #expect(t.controller.preview == nil)
    }

    @Test func findingsLineShowsOnAPreviewWithFindings() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let draft = ThemeFile(name: "Murky", appearance: .dark, base: "dracula",
                              colors: ["textPrimary": rgba("#2A2C38"), "mutedInk": rgba("#2A2C38")])
        startPreview(t, draft)
        let count = try #require(t.controller.preview).findings.count
        #expect(count > 1)
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-preview-findings")) != nil }
        let line = try t.window.element(identifier: "theme-preview-findings")
        let all = ([line] + descendants(of: line, in: t.window)).map(text)
        #expect(all.contains("\(count) colour pairs are hard to read"), "\(all)")
        startPreview(t, paper())
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-preview-findings")) == nil }
    }

    @Test func keepSaveErrorShowsInline() async throws {
        // A file where the support directory should be: the theme cannot be saved.
        let rig = Rig()
        try Data().write(to: rig.root.appendingPathComponent("support"))
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        holder.controller = controller
        defer { controller.stop() }
        window.tick(); window.tick()
        let draft = paper()
        controller.preview(draft, resolved: controller.library.resolve(draft: draft).theme, session: UUID())
        try await window.runUntil { (try? window.element(identifier: "theme-preview-keep")) != nil }
        try window.click(window.element(identifier: "theme-preview-keep"))
        try await window.runUntil { (try? window.element(identifier: "theme-preview-error")) != nil }
        #expect((try? window.element(identifier: "theme-preview-bar")) != nil)
    }

    @Test func keepErrorDoesNotOutliveItsPreview() async throws {
        let rig = Rig()
        try Data().write(to: rig.root.appendingPathComponent("support"))
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        holder.controller = controller
        defer { controller.stop() }
        window.tick(); window.tick()
        let draft = paper()
        controller.preview(draft, resolved: controller.library.resolve(draft: draft).theme, session: UUID())
        try await window.runUntil { (try? window.element(identifier: "theme-preview-keep")) != nil }
        try window.click(window.element(identifier: "theme-preview-keep"))
        try await window.runUntil { (try? window.element(identifier: "theme-preview-error")) != nil }
        var newer = paper(); newer.name = "Newer"
        controller.preview(newer, resolved: controller.library.resolve(draft: newer).theme, session: UUID())
        try await window.runUntil { (try? window.element(identifier: "theme-preview-error")) == nil }
        #expect((try? window.element(identifier: "theme-preview-bar")) != nil)
    }

    @Test func warningUseAnywayAndCancel() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let id = try await writeBadTheme(t)
        let count = ThemeContrast.findings(try #require(t.controller.library.resolve(id))).count
        #expect(count > 1)
        try await openSettings(t)
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-row-\(id)")) != nil }
        try t.window.click(t.window.element(identifier: "theme-row-\(id)"))
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-activation-warning")) != nil }
        let warning = try t.window.element(identifier: "theme-activation-warning")
        let all = ([warning] + descendants(of: warning, in: t.window)).map(text)
        #expect(all.contains("\(count) colour pairs are hard to read"), "\(all)")
        #expect(t.controller.currentSettings.theme == "dracula")
        try t.window.click(t.window.element(identifier: "theme-activation-use"))
        try await t.window.runUntil { t.controller.currentSettings.theme == id }
        #expect((try? t.window.element(identifier: "theme-activation-warning")) == nil)

        // Second try: Cancel applies nothing.
        try t.controller.choose(theme: "dracula")
        try t.window.click(t.window.element(identifier: "theme-row-\(id)"))
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-activation-cancel")) != nil }
        try t.window.click(t.window.element(identifier: "theme-activation-cancel"))
        try await t.window.runUntil { (try? t.window.element(identifier: "theme-activation-warning")) == nil }
        #expect(t.controller.currentSettings.theme == "dracula")
    }
}
