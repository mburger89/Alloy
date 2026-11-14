import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct SettingsAppearanceTests {
    private final class Holder { var controller: ThemeController? }

    private struct Setup {
        let rig: Rig
        let window: TestWindow
        let controller: ThemeController
    }

    private func setup(openFile: Bool = false, reduceTransparency: Bool = false) async throws -> Setup {
        let rig: Rig
        if openFile {
            rig = try await editedRig().rig
            rig.workspace.openFilePath = "login.swift"
        } else {
            rig = Rig()
        }
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(900))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: ScriptedChangeSource())
        holder.controller = controller
        window.tick(); window.tick()
        if reduceTransparency { window.platformWindow.simulateReduceTransparencyChange(to: true) }
        try window.openSettingsFromMenu()
        try await window.runUntil { (try? window.element(identifier: "settings-appearance-section")) != nil }
        return Setup(rig: rig, window: window, controller: controller)
    }

    private func increment(_ id: String, times: Int, _ t: Setup) throws {
        for _ in 0..<times { try t.window.performAccessibilityAction(.increment, on: t.window.element(identifier: id)) }
    }

    @Test func slidersWriteOverrides() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        #expect(t.rig.workspace.settings.appearance.isEmpty)
        try increment("settings-appearance-gutter", times: 4, t)   // 6 -> 10
        #expect(t.rig.workspace.settings.appearance.gutter == 10)
        #expect(t.controller.style.gutter == 10)
        try increment("settings-appearance-corners", times: 2, t)  // 10 -> 12
        #expect(t.rig.workspace.settings.appearance.cornerRadius == 12)
        try increment("settings-appearance-control-opacity", times: 5, t)  // 60% -> 65%
        let opacity = try #require(t.rig.workspace.settings.appearance.controlOpacity)
        #expect(abs(opacity - 0.65) < 1e-9)
        let support = t.rig.root.appendingPathComponent("support")
        let reloaded = AlloySettings.load(appSupport: support)
        #expect(reloaded.appearance.gutter == 10)
        #expect(reloaded.appearance.cornerRadius == 12)
    }

    @Test func seeThroughSliderWritesIslandOpacity() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        func backdrop() -> WindowBackdrop? { t.window.platformWindow.windowBackdropRequests.last }
        #expect(t.controller.style.windowSeeThrough)
        #expect(backdrop() != .some(.none) && backdrop() != nil, "see-through asks for the window material")
        try increment("settings-appearance-see-through", times: 10, t)   // 30% -> 40%
        let opacity = try #require(t.rig.workspace.settings.appearance.islandOpacity)
        #expect(abs(opacity - 0.60) < 1e-9)
        #expect(abs(t.controller.style.islandOpacity - 0.60) < 1e-9)
        for _ in 0..<40 { try t.window.performAccessibilityAction(.decrement, on: t.window.element(identifier: "settings-appearance-see-through")) }
        #expect(t.rig.workspace.settings.appearance.islandOpacity == 1.0)
        #expect(!t.controller.style.windowSeeThrough)
        t.window.tick(); t.window.tick()
        #expect(backdrop() == WindowBackdrop.none, "0% see-through removes the window material")
    }

    /// The see-through slider changes the derived window and island paints, which are installed with the theme: both the light and the dark
    /// theme in Match-system mode are reinstalled with the new values.
    @Test func seeThroughSliderReinstallsTheDerivedPaints() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        try t.controller.choose(mode: .matchSystem)
        let host = t.window.window
        func paints() -> [Color] {
            [host.lightTheme[WindowPaintKey.self], host.lightTheme[IslandPaintKey.self],
             host.darkTheme[WindowPaintKey.self], host.darkTheme[IslandPaintKey.self]]
        }
        func expected() throws -> [Color] {
            let style = t.controller.style
            let library = t.controller.library
            let light = try #require(library.resolve(t.rig.workspace.settings.lightTheme))
            let dark = try #require(library.resolve(t.rig.workspace.settings.darkTheme))
            func paint(_ r: ResolvedTheme, _ slot: String, _ f: (ThemeRGBA) -> ThemeRGBA) throws -> Color {
                Color(f(try #require(r.colors[slot])).hsla)
            }
            return [try paint(light, "windowBackground", style.windowPaint), try paint(light, "islandFill", style.islandPaint),
                    try paint(dark, "windowBackground", style.windowPaint), try paint(dark, "islandFill", style.islandPaint)]
        }
        let before = paints()
        #expect(before == (try expected()))
        try increment("settings-appearance-see-through", times: 10, t)   // 30% -> 40%
        let after = paints()
        #expect(after == (try expected()), "the installed paints follow the slider")
        for i in after.indices { #expect(after[i] != before[i], "paint \(i) changed with the slider") }
        for _ in 0..<40 { try t.window.performAccessibilityAction(.decrement, on: t.window.element(identifier: "settings-appearance-see-through")) }
        #expect(paints() == (try expected()))
        #expect(!t.controller.style.windowSeeThrough)
    }

    /// A drag repaints live on every step but writes settings.json once, when it ends (`onEditingChanged(false)`).
    @Test func sliderDragSavesOnce() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let slider = try t.window.element(identifier: "settings-appearance-gutter")
        let f = slider.frame
        let y = (f.minY.value + f.maxY.value) / 2
        let saves = t.rig.workspace.settingsSaveCount
        var seen: [Double] = []
        let start = Point(x: Pixels(f.minX.value + 12), y: Pixels(y))
        let end = Point(x: Pixels(f.maxX.value - 12), y: Pixels(y))
        t.window.drag(from: start, to: end, steps: 12)
        seen.append(t.controller.style.gutter)
        #expect(t.controller.style.gutter != AppearanceStyle.defaults.gutter, "the drag changed the live style")
        #expect(t.rig.workspace.settingsSaveCount == saves + 1, "one save for the whole drag, got \(t.rig.workspace.settingsSaveCount - saves)")
        let reloaded = AlloySettings.load(appSupport: t.rig.root.appendingPathComponent("support"))
        #expect(reloaded.appearance.gutter == t.controller.style.gutter, "the final value is on disk")
        _ = seen
    }

    @Test func seeThroughTintIsDerived() {
        var style = AppearanceStyle.defaults
        #expect(style.windowSeeThrough)
        #expect(style.windowTintOpacity < 1 && style.windowTintOpacity > 0)
        style.islandOpacity = 1.0
        #expect(!style.windowSeeThrough)
        #expect(style.windowTintOpacity == 1)
    }

    @Test func blurPickerWritesOverride() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        let picker = try t.window.element(identifier: "settings-appearance-blur")
        let light = try #require(descendants(of: picker, in: t.window).first { $0.label == "Light" })
        try t.window.click(light)
        #expect(t.rig.workspace.settings.appearance.controlBlur == .light)
        #expect(t.controller.style.controlBlur == .light)
    }

    @Test func resetClearsOverrides() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        try increment("settings-appearance-gutter", times: 2, t)
        #expect(!t.rig.workspace.settings.appearance.isEmpty)
        #expect(try t.window.element(identifier: "settings-appearance-reset").label == "Reset to theme")
        try t.window.click(t.window.element(identifier: "settings-appearance-reset"))
        #expect(t.rig.workspace.settings.appearance.isEmpty)
        #expect(t.controller.style.gutter == AppearanceStyle.defaults.gutter)
    }

    @Test func backToDraculaClearsOverrides() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        try increment("settings-appearance-gutter", times: 2, t)
        #expect(!t.rig.workspace.settings.appearance.isEmpty)
        try t.window.click(t.window.element(identifier: "settings-back-to-dracula"))
        #expect(t.rig.workspace.settings.appearance.isEmpty)
        #expect(t.rig.workspace.settings.theme == "dracula")
    }

    @Test func sliderChangeKeepsDocumentAndFocus() async throws {
        let t = try await setup(openFile: true)
        defer { t.controller.stop() }
        let doc = try #require(t.rig.workspace.document("login.swift"))
        let version = doc.buffer.version
        let text = doc.buffer.snapshot().text
        try increment("settings-appearance-gutter", times: 3, t)
        #expect(t.rig.workspace.settings.appearance.gutter == 9)
        #expect(t.rig.workspace.document("login.swift") === doc)
        #expect(t.rig.workspace.openFilePath == "login.swift")
        #expect(doc.buffer.version == version)
        #expect(doc.buffer.snapshot().text == text)
        #expect((try? t.window.element(identifier: "settings-view")) != nil)
    }

    @Test func reduceTransparencyShowsTheNote() async throws {
        let off = try await setup()
        defer { off.controller.stop() }
        #expect((try? off.window.element(identifier: "settings-appearance-reduce-transparency-note")) == nil)
        let on = try await setup(reduceTransparency: true)
        defer { on.controller.stop() }
        let note = try on.window.element(identifier: "settings-appearance-reduce-transparency-note")
        #expect((note.label ?? note.value ?? "").contains("Reduce Transparency is on in macOS, so glass is drawn solid."))
    }

    // MARK: Glass toggle

    @Test func glassSettingDefaultsOnAndOldFilesLoad() throws {
        #expect(AlloySettings().glass)
        let old = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"theme":"dracula","followEdits":false}"#.utf8))
        #expect(old.glass && !old.followEdits)
        var off = AlloySettings()
        off.glass = false
        let back = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(off))
        #expect(!back.glass)
    }

    @Test func glassToggleTurnsGlassOffAndOnLive() async throws {
        let t = try await setup()
        defer { t.controller.stop() }
        func backdrop() -> WindowBackdrop? { t.window.platformWindow.windowBackdropRequests.last }
        let support = t.rig.root.appendingPathComponent("support")
        #expect(t.controller.style.glass && t.controller.style.windowSeeThrough)
        #expect(GlassLook.resolve(style: t.controller.style, reduceTransparency: false) != .solid)
        #expect(backdrop() != .some(.none) && backdrop() != nil)
        let toggle = try t.window.element(identifier: "settings-appearance-glass")
        #expect(toggle.isEnabled)

        try t.window.click(toggle)
        for _ in 0..<4 { t.window.tick(); await Task.yield() }
        #expect(!t.rig.workspace.settings.glass)
        #expect(!AlloySettings.load(appSupport: support).glass, "persisted")
        #expect(GlassLook.resolve(style: t.controller.style, reduceTransparency: false) == .solid)
        #expect(!t.controller.style.windowSeeThrough)
        #expect(backdrop() == WindowBackdrop.none, "no window material: opaque")
        // The values are kept while glass is off, and the two controls are disabled.
        #expect(t.rig.workspace.settings.appearance.isEmpty)
        #expect(t.controller.style.islandOpacity == AppearanceStyle.defaults.islandOpacity)
        #expect(try !t.window.element(identifier: "settings-appearance-see-through").isEnabled)
        #expect(try !t.window.element(identifier: "settings-appearance-blur").isEnabled)
        #expect(try t.window.element(identifier: "settings-appearance-gutter").isEnabled)

        try t.window.click(t.window.element(identifier: "settings-appearance-glass"))
        for _ in 0..<4 { t.window.tick(); await Task.yield() }
        #expect(t.rig.workspace.settings.glass && AlloySettings.load(appSupport: support).glass)
        #expect(GlassLook.resolve(style: t.controller.style, reduceTransparency: false) != .solid)
        #expect(backdrop() != .some(.none) && backdrop() != nil, "the material is back")
        #expect(try t.window.element(identifier: "settings-appearance-see-through").isEnabled)
        #expect(try t.window.element(identifier: "settings-appearance-blur").isEnabled)
    }

    @Test func reduceTransparencyStaysSolidWhateverGlassSays() {
        #expect(GlassLook.resolve(style: .defaults, reduceTransparency: true) == .solid)
        var style = AppearanceStyle.defaults
        style.glass = false
        #expect(GlassLook.resolve(style: style, reduceTransparency: false) == .solid)
        #expect(GlassLook.resolve(style: .defaults, reduceTransparency: false, glassEnabled: false) == .solid)
    }

    @Test func glassToggleKeepsDocumentAndComposerFocus() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(900))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        holder.controller = controller
        defer { controller.stop() }
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let id = try #require(rig.workspace.activeTab.flatMap { rig.workspace.document($0)?.id })
        try window.focus(window.element(identifier: "composer"))
        for _ in 0..<4 { window.tick(); await Task.yield() }
        var s = rig.workspace.settings
        s.glass = false
        try rig.workspace.updateSettings(s)
        for _ in 0..<6 { window.tick(); await Task.yield() }
        #expect(!controller.style.glass)
        #expect(rig.workspace.activeTab.flatMap { rig.workspace.document($0)?.id } == id)
        #expect(try window.element(identifier: "composer").isFocused)
        s.glass = true
        try rig.workspace.updateSettings(s)
        for _ in 0..<6 { window.tick(); await Task.yield() }
        #expect(rig.workspace.activeTab.flatMap { rig.workspace.document($0)?.id } == id)
        #expect(try window.element(identifier: "composer").isFocused)
    }

    /// Alloy Light: MetalUI's default code background is `surface`, opaque white, on an island that is light grey. The code
    /// view draws no fill of its own, so the file island's surface shows through.
    @Test func codeViewBackgroundIsClearSoItSitsOnTheIsland() {
        #expect(CodeTheme.alloy.background == Color.clear)
    }

    @Test func pillButtonRadiusFollowsStyle() {
        var style = AppearanceStyle.defaults
        #expect(style.buttonCornerRadius == style.titleButtonCornerRadius)
        style.pillButtons = false
        style.cornerRadius = 12
        #expect(style.buttonCornerRadius == 6)
        #expect(style.buttonFillOpacity < style.buttonPressedOpacity)
    }
}
