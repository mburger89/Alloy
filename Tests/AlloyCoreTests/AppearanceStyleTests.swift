@testable import AlloyCore
import Foundation
import Testing

@Suite struct AppearanceStyleTests {
    private func parse(_ json: String) throws -> ThemeFile { try ThemeFile.parse(Data(json.utf8)) }

    private func library(_ files: [(String, ThemeFile)]) -> ThemeLibrary {
        let base = ThemeFile(name: "alloy-dark", appearance: .dark)
        var entries = [ThemeEntry(id: "alloy-dark", file: base, isBuiltIn: true),
                       ThemeEntry(id: "alloy-light", file: ThemeFile(name: "alloy-light", appearance: .light), isBuiltIn: true)]
        for (id, file) in files { entries.append(ThemeEntry(id: id, file: file, isBuiltIn: false)) }
        return ThemeLibrary(builtIns: Array(entries.prefix(2)), user: Array(entries.dropFirst(2)))
    }

    @Test func glassOffIsOpaqueAndKeepsIslandsDistinct() {
        let library = ThemeLibrary(builtIns: BuiltInThemes.all)
        func lum(_ c: ThemeRGBA) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        for theme in BuiltInThemes.all {
            guard let resolved = library.resolve(theme.id),
                  let island = resolved.colors["islandFill"], let window = resolved.colors["windowBackground"] else {
                Issue.record("\(theme.id) lacks islandFill or windowBackground"); continue
            }
            var style = resolved.style
            style.glass = false
            #expect(!style.windowSeeThrough, "\(theme.id)")
            #expect(style.islandSheenOpacity == 0 && style.windowShadeOpacity == 0, "\(theme.id)")
            #expect(style.islandPaint(island) == island, "\(theme.id): the island paints its fill as is")
            #expect(style.windowPaint(window) == window, "\(theme.id)")
            #expect(island != window, "\(theme.id): island and gutter differ")
            let (hi, lo) = (max(lum(island), lum(window)), min(lum(island), lum(window)))
            #expect((hi + 0.05) / (lo + 0.05) > 1.0, "\(theme.id): island vs gutter contrast")
        }
    }

    @Test func defaultsMatchTheSpec() {
        let d = AppearanceStyle.defaults
        #expect(d == AppearanceStyle(gutter: 6, cornerRadius: 10, islandOpacity: 0.70, controlOpacity: 0.60,
                                     controlBlur: .heavy, pillButtons: true))
    }

    @Test func styleRoundTripsThroughTheThemeFile() throws {
        let json = #"{"name":"t","appearance":"dark","style":{"gutter":4,"cornerRadius":14,"islandOpacity":0.8,"controlOpacity":0.5,"controlBlur":"light","pillButtons":false}}"#
        let file = try parse(json)
        #expect(file.style == AppearanceStyleFile(gutter: 4, cornerRadius: 14, islandOpacity: 0.8, controlOpacity: 0.5,
                                                  controlBlur: .light, pillButtons: false))
        #expect(try ThemeFile.parse(file.encoded()) == file)
    }

    @Test func missingStyleKeysFallBackAlongBase() throws {
        let parent = try parse(#"{"name":"p","appearance":"dark","style":{"gutter":4}}"#)
        let child = try parse(#"{"name":"c","appearance":"dark","base":"p","style":{"cornerRadius":14}}"#)
        let lib = library([("user/p", parent), ("user/c", child)])
        let resolved = try #require(lib.resolve("user/c")).style
        #expect(resolved.gutter == 4)
        #expect(resolved.cornerRadius == 14)
        #expect(resolved.islandOpacity == AppearanceStyle.defaults.islandOpacity)
        #expect(resolved.controlOpacity == AppearanceStyle.defaults.controlOpacity)
        #expect(try #require(lib.resolve("alloy-dark")).style == .defaults)
        #expect(lib.resolve(draft: child).theme.style.cornerRadius == 14)
    }

    @Test func outOfRangeValuesClamp() throws {
        let file = try parse(#"{"name":"t","appearance":"dark","style":{"gutter":40,"controlOpacity":0.05,"controlBlur":"extreme","pillButtons":"yes"}}"#)
        let style = try #require(library([("user/t", file)]).resolve("user/t")).style
        #expect(style.gutter == 16)
        #expect(style.controlOpacity == 0.40)
        #expect(style.controlBlur == .heavy)
        #expect(style.pillButtons == true)
        let bad = try parse(#"{"name":"t","appearance":"dark","style":"nope"}"#)
        #expect(bad.style == nil)
    }

    @Test func overridesApplyOnTopAndEmptyIsTheTheme() {
        let style = AppearanceStyle.defaults
        var o = AppearanceOverrides()
        #expect(o.isEmpty)
        #expect(style.applying(o) == style)
        o.gutter = 12
        var expected = style
        expected.gutter = 12
        #expect(style.applying(o) == expected)
        #expect(style.applying(AppearanceOverrides(cornerRadius: 99)).cornerRadius == 20)
    }

    @Test func settingsWithoutAppearanceDecode() throws {
        let old = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"theme":"dracula"}"#.utf8))
        #expect(old.appearance.isEmpty)
        let set = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"appearance":{"gutter":8}}"#.utf8))
        #expect(set.appearance.gutter == 8)
        let again = try JSONDecoder().decode(AlloySettings.self, from: JSONEncoder().encode(set))
        #expect(again == set)
        let bad = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"appearance":{"gutter":"x","controlBlur":"zz","cornerRadius":5}}"#.utf8))
        #expect(bad.appearance == AppearanceOverrides(cornerRadius: 5))
        let worse = try JSONDecoder().decode(AlloySettings.self, from: Data(#"{"appearance":7,"theme":"x"}"#.utf8))
        #expect(worse.appearance.isEmpty && worse.theme == "x")
    }

    /// What a window material shows over the desktop, as a grey level, measured from a release screenshot (Dracula's gutter
    /// #24242B with the earlier tint 0.79 solved for the material: about #494644) for a dark desktop (#1E1E1E), and the
    /// light equivalent. The model composites in sRGB space like the renderer.
    private static let materialOverDarkDesktop = 0.28
    /// An assumption, not a measurement: no release screenshot over a light desktop exists yet.
    private static let materialOverLightDesktop = 0.93
    private static let minimumIslandStep = 1.15

    /// The gutter and island colours the window shows: the folded window paint over the material, and the folded island
    /// paint over that.
    private func gutterAndIsland(_ theme: ResolvedTheme, style: AppearanceStyle) throws -> (gutter: ThemeRGBA, island: ThemeRGBA) {
        let grey = theme.appearance == .dark ? Self.materialOverDarkDesktop : Self.materialOverLightDesktop
        let material = ThemeRGBA(r: grey, g: grey, b: grey)
        let window = try #require(theme.colors["windowBackground"]), fill = try #require(theme.colors["islandFill"])
        let gutter = ThemeContrast.composite([material, style.windowPaint(window)])
        let island = ThemeContrast.composite([gutter, style.islandPaint(fill)])
        return (gutter, island)
    }

    /// The folded paints equal the layers they replace: the window background at the tint with the black shade over it,
    /// and the island fill at its opacity with the white sheen over it, on any backdrop.
    @Test func foldedPaintsEqualTheirLayers() throws {
        let style = AppearanceStyle.defaults
        let window = try #require(ThemeRGBA(hex: "#1A1B24")), fill = try #require(ThemeRGBA(hex: "#282A36"))
        let backdrop = ThemeRGBA(r: 0.4, g: 0.3, b: 0.5)
        func withAlpha(_ c: ThemeRGBA, _ a: Double) -> ThemeRGBA { ThemeRGBA(r: c.r, g: c.g, b: c.b, a: a) }
        let black = ThemeRGBA(r: 0, g: 0, b: 0, a: style.windowShadeOpacity), white = ThemeRGBA(r: 1, g: 1, b: 1, a: style.islandSheenOpacity)
        let windowLayers = ThemeContrast.composite([backdrop, withAlpha(window, style.windowTintOpacity), black])
        let windowFolded = ThemeContrast.composite([backdrop, style.windowPaint(window)])
        let islandLayers = ThemeContrast.composite([backdrop, withAlpha(fill, style.islandOpacity), white])
        let islandFolded = ThemeContrast.composite([backdrop, style.islandPaint(fill)])
        for (a, b) in [(windowLayers, windowFolded), (islandLayers, islandFolded)] {
            #expect(abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9)
        }
        var opaque = style
        opaque.islandOpacity = 1
        #expect(opaque.windowPaint(window) == window && opaque.islandPaint(fill) == fill, "not see-through: the plain colours")
    }

    /// At the default see-through setting every built-in theme's islands stand out from the gutters around them (the
    /// release screenshot with the earlier tint measured Dracula at 1.05:1: one flat surface), over a dark or light desktop.
    @Test func islandsStandOutFromTheGuttersAtTheDefault() throws {
        let library = ThemeLibrary(builtIns: BuiltInThemes.all)
        #expect(BuiltInThemes.all.count >= 6)
        for entry in BuiltInThemes.all {
            let theme = library.resolve(draft: entry.file).theme
            let style = AppearanceStyle.defaults
            let (gutter, island) = try gutterAndIsland(theme, style: style)
            let ratio = ThemeContrast.ratio(island, gutter)
            #expect(ratio >= Self.minimumIslandStep, "\(entry.id): island vs gutter \(ratio)")
        }
    }

    @Test func windowTintFollowsTheNamedFloorAndSlope() {
        var style = AppearanceStyle.defaults
        #expect(abs(style.windowTintOpacity - (AppearanceStyle.windowTintFloor + AppearanceStyle.windowTintSlope * 0.70)) < 1e-9)
        #expect(style.windowTintOpacity > style.islandOpacity, "the gutters are denser than the islands")
        style.islandOpacity = 1
        #expect(style.windowTintOpacity == 1 && style.windowShadeOpacity == 0 && style.islandSheenOpacity == 0)
    }
}
