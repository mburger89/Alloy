import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import CoreGraphics
import Foundation
import MetalUI
import MetalUITesting
import MetalUITestingSnapshot
import Testing

@MainActor
@Suite struct BackgroundGradientTests {
    private final class Holder { var controller: ThemeController? }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return data.map(Int.init)
    }

    /// Renders the backdrop alone over a drawn theme and returns its top-left and bottom-right pixels.
    private func corners(_ style: AppearanceStyle, theme id: String = "dracula") throws -> ([Int], [Int]) {
        let resolved = try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve(id))
        let window = try TestWindow(size: Size(width: Pixels(400), height: Pixels(300)), colorScheme: .dark) {
            VStack(spacing: 0) { }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { WindowBackdropView(style: style).equatable() }
        }
        window.window.darkTheme = ThemeApplier.theme(for: resolved)
        window.window.setNeedsRedraw()
        for _ in 0..<4 { window.tick() }
        let image = try window.snapshot()
        return (pixel(image, 2, 2), pixel(image, image.width - 3, image.height - 3))
    }

    @Test func backdropDrawsAGradientWhenOnAndFlatWhenOff() throws {
        var style = AppearanceStyle.defaults
        style.glass = false   // opaque, so the pixels are the theme's colours
        style.backgroundGradient = true
        let (tl, br) = try corners(style)
        #expect(tl != br, "gradient: \(tl) vs \(br)")
        // Subtle: no channel moves more than a fraction of the range.
        for i in 0..<3 { #expect(abs(tl[i] - br[i]) < 90) }
        style.backgroundGradient = false
        let (ftl, fbr) = try corners(style)
        #expect(ftl == fbr, "flat: \(ftl) vs \(fbr)")
    }

    @Test func glassBackdropGradientIsAlsoDrawn() throws {
        let style = AppearanceStyle.defaults
        #expect(style.backgroundGradient && style.windowSeeThrough)
        let (tl, br) = try corners(style)
        #expect(tl != br)
    }

    @Test func defaultsAndMixing() throws {
        #expect(AppearanceStyle.defaults.backgroundGradient)
        #expect(AppearanceStyle.defaults.backgroundGradientStrength == 0.18)
        let a = ThemeRGBA(r: 0, g: 0, b: 0, a: 0.5), b = ThemeRGBA(r: 1, g: 0.5, b: 0.2)
        let m = a.mixed(with: b, amount: 0.2)
        #expect(abs(m.r - 0.2) < 1e-9 && abs(m.g - 0.1) < 1e-9 && m.a == 0.5)
        let end = AppearanceStyle.defaults.windowPaintEnd(window: a, accent: b)
        #expect(end != AppearanceStyle.defaults.windowPaint(a))
    }

    @Test func themeStyleKeyDecodesAndFallsBack() throws {
        let on = try ThemeFile.parse(Data(#"{"name":"t","appearance":"dark","style":{"backgroundGradient":false,"backgroundGradientStrength":0.3}}"#.utf8))
        #expect(on.style?.backgroundGradient == false && on.style?.backgroundGradientStrength == 0.3)
        var library = ThemeLibrary(builtIns: BuiltInThemes.all)
        library.user = [ThemeEntry(id: "t", file: on, isBuiltIn: false)]
        let resolved = try #require(library.resolve("t"))
        #expect(!resolved.style.backgroundGradient && resolved.style.backgroundGradientStrength == 0.3)
        let plain = try #require(library.resolve("dracula"))
        #expect(plain.style.backgroundGradient && plain.style.backgroundGradientStrength == 0.18)
        let wrong = try ThemeFile.parse(Data(#"{"name":"w","appearance":"dark","style":{"backgroundGradient":"yes","backgroundGradientStrength":9}}"#.utf8))
        #expect(wrong.style?.backgroundGradient == nil)
        library.user = [ThemeEntry(id: "w", file: wrong, isBuiltIn: false)]
        #expect(try #require(library.resolve("w")).style.backgroundGradientStrength == 0.40, "clamped")
    }

    @Test func overridePersistsAndResets() throws {
        var s = AlloySettings()
        #expect(s.appearance.backgroundGradient == nil)
        s.appearance.backgroundGradient = false
        let back = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(s))
        #expect(back.appearance.backgroundGradient == false)
        #expect(!AppearanceStyle.defaults.applying(back.appearance).backgroundGradient)
        let old = try JSONDecoder().decode(AlloySettings.self, from: Data("{}".utf8))
        #expect(old.appearance.backgroundGradient == nil && old.appearance.isEmpty)
    }

    @Test func settingsCheckboxTogglesItLiveAndResetClearsIt() async throws {
        let rig = Rig()
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(900))) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace))
        }
        let controller = ThemeController(workspace: rig.workspace, host: window.testApp.app, watcher: ScriptedChangeSource())
        holder.controller = controller
        defer { controller.stop() }
        window.installAlloyMenu(rig.workspace, themes: controller)
        window.tick(); window.tick()
        let settings = try window.openSettingsFromMenu()
        try await settings.runUntil { (try? settings.element(identifier: "settings-appearance-reset")) != nil }
        let support = rig.appSupport
        #expect(controller.style.backgroundGradient)
        try settings.click(settings.element(identifier: "settings-appearance-background-gradient"))
        for _ in 0..<4 { window.tick(); settings.tick(); await Task.yield() }
        #expect(!controller.style.backgroundGradient)
        #expect(rig.workspace.settings.appearance.backgroundGradient == false)
        #expect(AlloySettings.load(appSupport: support).appearance.backgroundGradient == false, "persisted")
        try settings.click(settings.element(identifier: "settings-appearance-reset"))
        for _ in 0..<4 { window.tick(); settings.tick(); await Task.yield() }
        #expect(rig.workspace.settings.appearance.backgroundGradient == nil)
        #expect(controller.style.backgroundGradient)
    }
}
