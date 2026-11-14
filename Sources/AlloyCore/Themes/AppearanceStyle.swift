import Foundation

public enum ControlBlur: String, Sendable, Codable, CaseIterable { case light, medium, heavy }

/// The layout and glass look of the window: island gutter, corner radius, panel and control opacity.
/// Opacities are 0...1 fractions.
public struct AppearanceStyle: Equatable, Sendable {
    public static let gutterRange: ClosedRange<Double> = 0...16
    public static let cornerRadiusRange: ClosedRange<Double> = 0...20
    public static let opacityRange: ClosedRange<Double> = 0.40...1.0

    public var gutter: Double
    public var cornerRadius: Double
    public var islandOpacity: Double
    public var controlOpacity: Double
    public var controlBlur: ControlBlur
    public var pillButtons: Bool
    /// Glass on: blurred controls and a see-through window. Off (the Glass setting, or `ALLOY_GLASS=0`) draws solid
    /// controls and an opaque window and islands; the opacity and blur values stay as they are.
    public var glass: Bool

    public init(gutter: Double, cornerRadius: Double, islandOpacity: Double, controlOpacity: Double,
                controlBlur: ControlBlur, pillButtons: Bool, glass: Bool = true) {
        self.glass = glass
        self.gutter = gutter
        self.cornerRadius = cornerRadius
        self.islandOpacity = islandOpacity
        self.controlOpacity = controlOpacity
        self.controlBlur = controlBlur
        self.pillButtons = pillButtons
    }

    public static let defaults = AppearanceStyle(gutter: 6, cornerRadius: 10, islandOpacity: 0.70,
                                                 controlOpacity: 0.60, controlBlur: .heavy, pillButtons: true)

    // MARK: Derived look (the views carry no numbers of their own)

    /// Whether the window lets the desktop show through its gutters and islands: any island opacity below 1. At 1 there
    /// is no window material and the window is opaque.
    public var windowSeeThrough: Bool { glass && islandOpacity < 1 }
    /// The window background's tint alpha at island opacity 0 (the floor of ``windowTintOpacity``).
    public static let windowTintFloor = 0.60
    /// How much of the island opacity the window tint follows (the slope of ``windowTintOpacity``).
    public static let windowTintSlope = 0.50
    /// The black shade drawn over the tinted window background while see-through, so the gutters sit visibly darker than
    /// the islands (which the tint alone cannot do: the island fill is only a little lighter than the window background).
    public static let windowShade = 0.20
    /// The white sheen drawn over an island's fill while see-through, so a translucent island stays lighter than its gutter
    /// even for a theme whose island fill is barely lighter than its window background.
    public static let islandSheen = 0.05
    /// The alpha of the theme's window background over the window material: opaque at island opacity 1, and
    /// `windowTintFloor + windowTintSlope * islandOpacity` below that (0.95 at the default 0.70), denser than the islands
    /// so the gutters read as the theme's window colour with only a hint of the blurred desktop, and the islands, which let
    /// more of it through, stand out from them.
    public var windowTintOpacity: Double {
        windowSeeThrough ? Self.windowTintFloor + Self.windowTintSlope * islandOpacity : 1
    }
    /// The window background as one fill: the theme's colour at ``windowTintOpacity`` with the black ``windowShadeOpacity``
    /// shade over it, folded exactly into a single layer (alpha `1 - (1 - shade)(1 - tint)`, colour `(1 - shade) tint w / alpha`)
    /// so the window draws one element. Opaque and unchanged when not see-through.
    public func windowPaint(_ window: ThemeRGBA) -> ThemeRGBA {
        guard windowSeeThrough else { return window }
        let tint = windowTintOpacity * window.a, shade = windowShadeOpacity
        let alpha = 1 - (1 - shade) * (1 - tint)
        guard alpha > 0 else { return window }
        let k = (1 - shade) * tint / alpha
        return ThemeRGBA(r: window.r * k, g: window.g * k, b: window.b * k, a: alpha)
    }
    /// An island's fill as one layer: the theme's colour at the island opacity with the white ``islandSheenOpacity`` sheen over
    /// it, folded exactly (alpha `1 - (1 - opacity)(1 - sheen)`, colour `(sheen + (1 - sheen) opacity f) / alpha`).
    public func islandPaint(_ fill: ThemeRGBA) -> ThemeRGBA {
        let opacity = (glass ? islandOpacity : 1) * fill.a, sheen = islandSheenOpacity
        let alpha = 1 - (1 - opacity) * (1 - sheen)
        guard alpha > 0 else { return fill }
        func mix(_ c: Double) -> Double { (sheen + (1 - sheen) * opacity * c) / alpha }
        return ThemeRGBA(r: mix(fill.r), g: mix(fill.g), b: mix(fill.b), a: alpha)
    }
    /// The alpha of the black shade over the tinted window background: ``windowShade`` while see-through, else none.
    public var windowShadeOpacity: Double { windowSeeThrough ? Self.windowShade : 0 }
    /// The alpha of the white sheen over an island's fill: ``islandSheen`` while see-through, else none.
    public var islandSheenOpacity: Double { windowSeeThrough ? Self.islandSheen : 0 }
    /// The see-through setting: 0 (opaque) to 0.60, the complement of the island opacity.
    public static let seeThroughRange: ClosedRange<Double> = 0...(1 - opacityRange.lowerBound)
    /// The file panel's glass bar content (the tab strip and the header) before it is measured.
    public static let filePanelBarContentEstimate = 72.0
    /// The file panel's glass bar height with a gutter above and below, as the code's top margin on the first frame
    /// (before the bar's measured height arrives): the content estimate plus the gutters.
    public var filePanelBarHeightEstimate: Double { Self.filePanelBarContentEstimate + 2 * gutter }
    /// The composer's glass bar content (one line of text, the mode row) before it is measured.
    public static let composerBarContentEstimate = 86.0
    /// The composer's glass bar height with a gutter above and below, as the transcript's bottom margin on a column's first frame.
    public var composerBarHeightEstimate: Double { Self.composerBarContentEstimate + 2 * gutter }
    /// The title island's height.
    public var titleIslandHeight: Double { 38 }
    /// The title-bar band the window reserves: the island with a gutter above and below it, so the traffic lights are
    /// centred in the island.
    public var titleBandHeight: Double { titleIslandHeight + 2 * gutter }
    /// Where the first traffic light's left edge sits from the window's left: inside the island's rounded corner.
    public var titleControlsLeading: Double { gutter + titleLightsInset }
    /// How far the first light sits inside the title island's left edge.
    public var titleLightsInset: Double { 14 }
    /// The standard three window buttons' width. Must track MetalUI's measured cluster width
    /// (`HeadlessPlatformWindow.controlsClusterWidth`, AppKit's `titleBarInsets.left - controlsLeading`).
    public var titleLightsWidth: Double { 60 }
    /// The least space between the lights and the island's text.
    public var titleLightsBreathing: Double { max(gutter, 8) }
    /// The spacer at the title island's start, measured from the island's left edge (one gutter in from the window's).
    /// The text starts `titleLightsBreathing` after the lights' right edge: `rightEdge` (MetalUI's
    /// `titleBarInsets.left`) when the window reports a cluster wider than the reserve, else the reserve
    /// (`titleControlsLeading + titleLightsWidth`). Insets can arrive a frame after the build that sends the metrics;
    /// within the reserve (AppKit reports exactly the reserve) the spacer does not depend on them.
    public func titleLightsSpacer(rightEdge: Double) -> Double {
        max(rightEdge, titleControlsLeading + titleLightsWidth) + titleLightsBreathing - gutter
    }
    /// The corner radius of the title island's pill buttons: fully round, or half the island radius when pills are off.
    public var titleButtonCornerRadius: Double { buttonCornerRadius }
    /// A button's corner radius: fully round, or half the island radius when pills are off.
    public var buttonCornerRadius: Double { pillButtons ? 999 : cornerRadius / 2 }
    /// A button's resting fill alpha: light, half the control opacity, so the pill reads over an island.
    public var buttonFillOpacity: Double { controlOpacity / 2 }
    /// A pressed button's fill alpha: the full control opacity.
    public var buttonPressedOpacity: Double { controlOpacity }
    /// A button's horizontal and vertical padding.
    public var buttonPaddingHorizontal: Double { 11 }
    public var buttonPaddingVertical: Double { 4 }

    public func clamped() -> AppearanceStyle {
        var s = self
        s.gutter = Self.clamp(gutter, Self.gutterRange)
        s.cornerRadius = Self.clamp(cornerRadius, Self.cornerRadiusRange)
        s.islandOpacity = Self.clamp(islandOpacity, Self.opacityRange)
        s.controlOpacity = Self.clamp(controlOpacity, Self.opacityRange)
        return s
    }

    /// The style with the user's overrides on top, clamped. Empty overrides return the clamped style.
    public func applying(_ o: AppearanceOverrides) -> AppearanceStyle {
        var s = self
        if let v = o.gutter { s.gutter = v }
        if let v = o.cornerRadius { s.cornerRadius = v }
        if let v = o.islandOpacity { s.islandOpacity = v }
        if let v = o.controlOpacity { s.controlOpacity = v }
        if let v = o.controlBlur { s.controlBlur = v }
        return s.clamped()
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isNaN ? range.lowerBound : min(max(value, range.lowerBound), range.upperBound)
    }
}

/// The `style` object of a theme file. Every field is optional; a missing or wrong-typed key is nil.
public struct AppearanceStyleFile: Equatable, Sendable {
    public var gutter: Double?
    public var cornerRadius: Double?
    public var islandOpacity: Double?
    public var controlOpacity: Double?
    public var controlBlur: ControlBlur?
    public var pillButtons: Bool?

    public init(gutter: Double? = nil, cornerRadius: Double? = nil, islandOpacity: Double? = nil,
                controlOpacity: Double? = nil, controlBlur: ControlBlur? = nil, pillButtons: Bool? = nil) {
        self.gutter = gutter
        self.cornerRadius = cornerRadius
        self.islandOpacity = islandOpacity
        self.controlOpacity = controlOpacity
        self.controlBlur = controlBlur
        self.pillButtons = pillButtons
    }

    init(json dict: [String: Any]) {
        func number(_ key: String) -> Double? {
            guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        gutter = number("gutter")
        cornerRadius = number("cornerRadius")
        islandOpacity = number("islandOpacity")
        controlOpacity = number("controlOpacity")
        controlBlur = (dict["controlBlur"] as? String).flatMap { ControlBlur(rawValue: $0) }
        if let n = dict["pillButtons"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            pillButtons = n.boolValue
        } else {
            pillButtons = nil
        }
    }

    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let gutter { d["gutter"] = gutter }
        if let cornerRadius { d["cornerRadius"] = cornerRadius }
        if let islandOpacity { d["islandOpacity"] = islandOpacity }
        if let controlOpacity { d["controlOpacity"] = controlOpacity }
        if let controlBlur { d["controlBlur"] = controlBlur.rawValue }
        if let pillButtons { d["pillButtons"] = pillButtons }
        return d
    }
}

/// The user's overrides from settings.json. Decoding is lenient per field, so a malformed value never fails settings.
public struct AppearanceOverrides: Equatable, Sendable, Codable {
    public var gutter: Double?
    public var cornerRadius: Double?
    public var islandOpacity: Double?
    public var controlOpacity: Double?
    public var controlBlur: ControlBlur?

    public init(gutter: Double? = nil, cornerRadius: Double? = nil, islandOpacity: Double? = nil,
                controlOpacity: Double? = nil, controlBlur: ControlBlur? = nil) {
        self.gutter = gutter
        self.cornerRadius = cornerRadius
        self.islandOpacity = islandOpacity
        self.controlOpacity = controlOpacity
        self.controlBlur = controlBlur
    }

    public var isEmpty: Bool { self == AppearanceOverrides() }

    private enum CodingKeys: String, CodingKey { case gutter, cornerRadius, islandOpacity, controlOpacity, controlBlur }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gutter = (try? c.decodeIfPresent(Double.self, forKey: .gutter)) ?? nil
        cornerRadius = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadius)) ?? nil
        islandOpacity = (try? c.decodeIfPresent(Double.self, forKey: .islandOpacity)) ?? nil
        controlOpacity = (try? c.decodeIfPresent(Double.self, forKey: .controlOpacity)) ?? nil
        controlBlur = (try? c.decodeIfPresent(ControlBlur.self, forKey: .controlBlur)) ?? nil
    }
}
