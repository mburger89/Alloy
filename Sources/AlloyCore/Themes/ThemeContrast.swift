import Foundation

/// One colour pair of a resolved theme that falls below its WCAG minimum.
public struct ContrastFinding: Equatable, Sendable, Codable {
    /// e.g. `mutedInk on readTint`, or `syntax.keyword on surface over codeSelectionFill` for layers.
    public var pair: String
    public var foreground: String
    /// Background slot names, bottom first.
    public var layers: [String]
    /// The measured ratio, truncated (rounded down) to 2 decimals, so a near miss never reads as the minimum.
    public var ratio: Double
    public var minimum: Double

    public init(pair: String, foreground: String, layers: [String], ratio: Double, minimum: Double) {
        self.pair = pair
        self.foreground = foreground
        self.layers = layers
        self.ratio = ratio
        self.minimum = minimum
    }
}

/// A pure WCAG 2.1 contrast check over a resolved theme.
public enum ThemeContrast {
    /// WCAG 2.1 contrast ratio of two colours (alpha is ignored; composite first).
    public static func ratio(_ a: ThemeRGBA, _ b: ThemeRGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The layers drawn over each other, bottom first, over white. The result is opaque.
    static func composite(_ layers: [ThemeRGBA]) -> ThemeRGBA {
        var base = ThemeRGBA(r: 1, g: 1, b: 1, a: 1)
        for layer in layers { base = over(layer, base) }
        return base
    }

    public static func findings(_ theme: ResolvedTheme) -> [ContrastFinding] {
        var out: [ContrastFinding] = []
        var seen: Set<String> = []

        // Layers that are not slots: the segmented picker's selected segment ("thumb").
        // `check` reads `synthetic` lazily at call time: a later check that needs the thumb must come after it is filled.
        var synthetic: [String: ThemeRGBA] = [:]
        func check(_ fgName: String, _ fg: ThemeRGBA?, on layerNames: [String], _ minimum: Double, label: String? = nil) {
            guard let fg else { return }
            var layers: [ThemeRGBA] = []
            for name in layerNames {
                guard let color = synthetic[name] ?? theme.colors[name] else { return }
                layers.append(color)
            }
            let pair = (label ?? fgName) + " on " + layerNames.joined(separator: " over ")
            guard seen.insert(pair).inserted else { return }
            let base = composite(layers)
            let value = ratio(over(fg, base), base)
            if value < minimum {
                out.append(ContrastFinding(pair: pair, foreground: label ?? fgName, layers: layerNames,
                                           ratio: (value * 100).rounded(.down) / 100, minimum: minimum))
            }
        }
        func slot(_ name: String) -> ThemeRGBA? { theme.colors[name] }

        // Secondary text: the slot when set, else textPrimary at MetalUI's derived alpha.
        var secondary: ThemeRGBA? = slot("textSecondary")
        if secondary == nil, var derived = slot("textPrimary") {
            derived.a = theme.appearance == .dark ? 0.648 : 0.588
            secondary = derived
        }

        // Text on backgrounds.
        for bg in ["background", "surface", "sidebarFill", "chatFill", "panelFill", "markdownCodeFill"] {
            check("textPrimary", slot("textPrimary"), on: [bg], 4.5)
            check("mutedInk", slot("mutedInk"), on: [bg], 4.5)
            check("textSecondary", secondary, on: [bg], 4.5)
        }
        check("textPrimary", slot("textPrimary"), on: ["surfaceSecondary"], 4.5)
        check("textSecondary", secondary, on: ["surfaceSecondary"], 4.5)

        // Text on tints.
        let tints = ["thinkingTint", "readTint", "shellTint", "editAddTint", "editRemoveTint", "errorTint", "warningTint",
                     "questionTint", "planTint", "commandTint", "webTint"]
        for tint in tints {
            check("textPrimary", slot("textPrimary"), on: [tint], 4.5)
            check("mutedInk", slot("mutedInk"), on: [tint], 4.5)
        }

        // Code.
        check("textPrimary", slot("textPrimary"), on: ["markdownCodeFill"], 4.5)
        check("textPrimary", slot("textPrimary"), on: ["surface"], 4.5)
        for name in theme.colors.keys.filter({ $0.hasPrefix("syntax.") }).sorted() {
            let fg = slot(name)
            let plain = name == "syntax.comment" ? 3.0 : 4.5
            check(name, fg, on: ["markdownCodeFill"], plain)
            check(name, fg, on: ["surface"], plain)
            check(name, fg, on: ["editAddTint"], 3)
            check(name, fg, on: ["editRemoveTint"], 3)
            check(name, fg, on: ["surface", "codeSelectionFill"], 3)
        }

        // Inks on tints.
        for (ink, tint) in [("thinkingInk", "thinkingTint"), ("readInk", "readTint"), ("shellInk", "shellTint"),
                            ("editInk", "editAddTint"), ("webInk", "webTint"), ("questionInk", "questionTint"),
                            ("planInk", "planTint")] {
            check(ink, slot(ink), on: [tint], 3)
        }
        check("errorInk", slot("errorInk"), on: ["errorTint"], 4.5)
        check("warningInk", slot("warningInk"), on: ["warningTint"], 4.5)
        check("linkInk", slot("linkInk"), on: ["chatFill"], 4.5)
        check("linkInk", slot("linkInk"), on: ["markdownCodeFill"], 4.5)
        check("errorInk", slot("errorInk"), on: ["panelFill"], 4.5)

        // The selected segment's outline: 3:1 against the track and against the thumb. The thumb is `surface` in a light
        // theme and `textPrimary` at 0.18 over the track in a dark one (what MetalUI paints).
        if theme.appearance == .dark {
            if var thumb = slot("textPrimary") { thumb.a *= 0.18; synthetic["pickerThumb"] = thumb }
        } else if let thumb = slot("surface") {
            synthetic["pickerThumb"] = thumb
        }
        check("pickerThumbEdge", slot("pickerThumbEdge"), on: ["surfaceSecondary"], 3)
        check("pickerThumbEdge", slot("pickerThumbEdge"), on: ["surfaceSecondary", "pickerThumb"], 3)

        // Session colours.
        for (i, color) in theme.sessionColors.enumerated() {
            check("sessionColors[\(i)]", color, on: ["sidebarFill"], 3)
        }
        return out
    }

    private static func over(_ top: ThemeRGBA, _ base: ThemeRGBA) -> ThemeRGBA {
        let a = top.a
        return ThemeRGBA(r: top.r * a + base.r * (1 - a), g: top.g * a + base.g * (1 - a),
                         b: top.b * a + base.b * (1 - a), a: 1)
    }

    private static func luminance(_ c: ThemeRGBA) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
}
