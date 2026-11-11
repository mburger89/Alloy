import AlloyCore
import AlloyHighlight
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct ThemeSlotTests {
    private static let library = ThemeLibrary(builtIns: BuiltInThemes.all)

    private func resolve(_ id: String) throws -> ResolvedTheme {
        try #require(Self.library.resolve(id))
    }

    private func close(_ a: Color.Resolved, _ b: Color.Resolved) -> Bool {
        let tolerance: Float = 1.0 / 255 + 0.0005
        return abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance && abs(a.opacity - b.opacity) <= tolerance
    }

    @Test func slotNamesAreUniqueAndPurposed() {
        let names = ThemeSlots.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate slot names")
        #expect(ThemeSlots.all.allSatisfy { !$0.purpose.isEmpty })
        #expect(names.first == "background")
        #expect(names.contains("syntax.keyword") && !names.contains("syntax.plain") && !names.contains("syntax.variable"))
    }

    @Test func alloyDarkAndLightDefineEverySlot() throws {
        for id in ["alloy-dark", "alloy-light"] {
            let theme = try resolve(id)
            for slot in ThemeSlots.all { #expect(theme.colors[slot.name] != nil, "\(id) lacks \(slot.name)") }
            #expect(theme.sessionColors.count == 8, "\(id) session colours")
        }
        #expect(BuiltInThemes.all.map(\.id).filter { $0.hasPrefix("alloy-") } == ["alloy-dark", "alloy-light"])
    }

    @Test(arguments: [true, false])
    func alloyDarkMatchesTodaysLook(dark: Bool) throws {
        let theme = try resolve(dark ? "alloy-dark" : "alloy-light")
        let applied = ThemeApplier.theme(for: theme)
        let sessions = (0..<8).map { Color.sessionColor($0) }
        let colors = ThemeSlots.all.map(\.color) + sessions

        let plain = try resolvedInWindow(colors, dark: dark)
        let themed = try themedResolve(colors, theme: applied, dark: dark)
        let names = ThemeSlots.all.map(\.name) + (1...8).map { "session\($0)" }
        #expect(plain.count == themed.count)
        // textSecondary and textTertiary differ from the plain window on purpose: the plain window derives them from
        // textPrimary at an opacity, the built-in sets them exactly. pickerThumbEdge differs too: both Alloy themes
        // outline the selected segment at 3:1 (Ruling 12), where MetalUI's default is a faint hairline.
        for (index, name) in names.enumerated() where !["textSecondary", "textTertiary", "pickerThumbEdge"].contains(name) && !close(plain[index], themed[index]) {
            Issue.record("\(dark ? "dark" : "light") \(name): \(plain[index]) vs \(themed[index])")
        }
    }

    /// `colors` resolved by a window that has `theme` installed for its scheme from the start.
    private func themedResolve(_ colors: [Color], theme: Theme, dark: Bool) throws -> [Color.Resolved] {
        let box = ResolvedBox()
        let window = try TestWindow(size: Size(width: Pixels(100), height: Pixels(100)), colorScheme: dark ? .dark : .light) {
            ColorProbe(colors: colors, box: box)
        }
        if dark { window.window.darkTheme = theme } else { window.window.lightTheme = theme }
        window.window.setNeedsRedraw()
        window.tick()
        window.tick()
        return box.colors
    }

    @Test func textLevelSlotsAreOptionalAndReachTheTheme() throws {
        var base = try resolve("alloy-dark")
        let plain = ThemeApplier.theme(for: base)
        #expect(plain.textSecondary != nil && plain.textTertiary != nil)
        base.colors["textSecondary"] = nil
        base.colors["textTertiary"] = nil
        let derived = ThemeApplier.theme(for: base)
        #expect(derived.textSecondary == nil && derived.textTertiary == nil, "absent slots keep MetalUI's derivation")
        base.colors["textSecondary"] = ThemeRGBA(hex: "#112233")
        base.colors["textTertiary"] = ThemeRGBA(hex: "#445566")
        let set = ThemeApplier.theme(for: base)
        #expect(set.textSecondary == ThemeRGBA(hex: "#112233")!.hsla)
        #expect(set.textTertiary == ThemeRGBA(hex: "#445566")!.hsla)
        let resolved = try themedResolve([Color.secondary], theme: set, dark: true)
        #expect(abs(resolved[0].red - 0x11 / 255.0) < 0.01 && abs(resolved[0].blue - 0x33 / 255.0) < 0.01)
    }

    @Test func applierSetsKeysTokensAndSyntax() throws {
        var base = try resolve("alloy-dark")
        base.colors["accent"] = ThemeRGBA(hex: "#FF0000")
        base.colors["thinkingInk"] = ThemeRGBA(hex: "#00FF00")
        base.colors["syntax.keyword"] = ThemeRGBA(hex: "#0000FF")
        base.colors["notASlot"] = ThemeRGBA(hex: "#123456")
        let theme = ThemeApplier.theme(for: base)
        let resolved = try themedResolve([Color(ColorToken.accent), .thinkingInk, SyntaxPalette.color(.keyword)],
                                         theme: theme, dark: true)
        func expect(_ c: Color.Resolved, _ r: Float, _ g: Float, _ b: Float) -> Bool {
            abs(c.red - r) < 0.01 && abs(c.green - g) < 0.01 && abs(c.blue - b) < 0.01 && c.opacity > 0.99
        }
        #expect(expect(resolved[0], 1, 0, 0))
        #expect(expect(resolved[1], 0, 1, 0))
        #expect(expect(resolved[2], 0, 0, 1))
    }

    @Test func sessionColorsCycle() throws {
        var base = try resolve("alloy-dark")
        base.sessionColors = ["#101010", "#202020", "#303030", "#404040", "#505050", "#606060"].compactMap { ThemeRGBA(hex: $0) }
        let theme = ThemeApplier.theme(for: base)
        let resolved = try themedResolve((0..<12).map { Color.sessionColor($0) }, theme: theme, dark: true)
        #expect(close(resolved[6], resolved[0]))
        #expect(close(resolved[11], resolved[5]))
        #expect(!close(resolved[0], resolved[1]))
    }

    @Test func fenceHighlighterFollowsTheTheme() async throws {
        var base = try resolve("alloy-dark")
        base.colors["syntax.keyword"] = ThemeRGBA(hex: "#0000FF")
        let theme = ThemeApplier.theme(for: base)
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        await rig.transports[0].emit(.assistantBlock(messageID: "m0", block: .text("```swift\nfunc\n```")))
        for _ in 0..<20_000 where session.transcript.blocks.isEmpty { await Task.yield() }
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800)), colorScheme: .dark) {
            rootView(workspace: rig.workspace)
        }
        window.tick()
        window.tick()
        func blueGlyphs() -> Int { window.scene.glyphs.filter { abs($0.color.h - 0.6667) < 0.002 && $0.color.s > 0.9 }.count }
        #expect(blueGlyphs() == 0)
        window.window.darkTheme = theme
        window.tick()
        window.tick()
        #expect(blueGlyphs() == 4, "the func glyph run takes the keyword key colour")
    }

    @Test func newSessionsUseTwelveColours() async {
        let rig = Rig()
        var indices: [Int] = []
        for i in 0..<9 { indices.append(await rig.workspace.newSession(name: "S\(i)").colorIndex) }
        #expect(indices == Array(0..<9))
    }

    @Test func editTintsAlsoDriveTheDiffRowTints() throws {
        var base = try resolve("alloy-dark")
        base.colors["editAddTint"] = ThemeRGBA(hex: "#00FF00")
        base.colors["editRemoveTint"] = ThemeRGBA(hex: "#FF00FF")
        let theme = ThemeApplier.theme(for: base)
        let r = try themedResolve([.addedRowTint, .removedRowTint, .editAddTint, .editRemoveTint], theme: theme, dark: true)
        #expect(close(r[0], r[2]) && close(r[1], r[3]))
        #expect(abs(r[0].green - 1) < 0.01 && abs(r[0].red) < 0.01)
        #expect(abs(r[1].red - 1) < 0.01 && abs(r[1].blue - 1) < 0.01 && abs(r[1].green) < 0.01)
    }

    @Test func keywordColourFollowsTheScheme() throws {
        let light = try resolvedInWindow([SyntaxPalette.color(.keyword)], dark: false)[0]
        let dark = try resolvedInWindow([SyntaxPalette.color(.keyword)], dark: true)[0]
        func hex(_ c: Color.Resolved) -> UInt32 {
            func b(_ v: Float) -> UInt32 { UInt32((v * 255).rounded()) }
            return b(c.red) << 16 | b(c.green) << 8 | b(c.blue)
        }
        #expect(hex(light) == 0xBF1D29)
        #expect(hex(dark) == 0xFF8F88)
    }

    @Test(arguments: [true, false])
    func extraSessionKeysRepeatTheFirstFourByDefault(dark: Bool) throws {
        let r = try resolvedInWindow((0..<12).map { Color.sessionColor($0) }, dark: dark)
        for i in 0..<4 {
            #expect(r[8 + i] == r[i], "key \(9 + i) equals key \(1 + i)")
        }
        #expect(r[0] != r[1])
    }
}
