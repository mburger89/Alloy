import AlloyCore
import Foundation
import MetalUI

/// What a control bar draws, decided from the style, Reduce Transparency and the `ALLOY_GLASS` switch.
enum GlassLook {
    /// What the bar draws: glass (and whether it sits on a thick material), or the solid fill.
    enum Resolved: Equatable {
        case glass(Glass, thickMaterial: Bool)
        case solid
    }

    /// `ALLOY_GLASS`, read once at launch: `0` forces glass off everywhere whatever the Glass setting says (the
    /// measurement switch for benchmarks; `ThemeController.refreshStyle` folds it into `AppearanceStyle.glass`).
    static let glassEnabledAtLaunch: Bool = ProcessInfo.processInfo.environment["ALLOY_GLASS"] != "0"

    static func glass(for style: AppearanceStyle) -> Glass {
        switch style.controlBlur {
        case .light: .clear
        case .medium, .heavy: .regular
        }
    }

    static func resolve(style: AppearanceStyle, reduceTransparency: Bool, glassEnabled: Bool = glassEnabledAtLaunch) -> Resolved {
        guard glassEnabled, style.glass, !reduceTransparency else { return .solid }
        return .glass(glass(for: style), thickMaterial: style.controlBlur == .heavy)
    }
}

/// The glass behind a control bar: liquid glass tinted with the theme's `controlFill` at the style's control opacity,
/// with a `glassRim` stroke. Under Reduce Transparency, with the Glass setting off, or with `ALLOY_GLASS=0`, it draws `controlFill` solid and no
/// glass. Deliberately not inside a `GlassEffectContainer`, whose subtree refuses retention.
///
/// Equatable on style and radius, and a background of the bar rather than a wrapper of its content: a generic wrapper
/// component cannot be skipped (its content closure is a new value every build), so it would re-run each frame; this
/// leaf is skipped until the style changes, and the bar's content is built by its own parent.
struct GlassBackdrop: Component, Equatable {
    let style: AppearanceStyle
    let cornerRadius: Double
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    nonisolated static func == (a: Self, b: Self) -> Bool { a.style == b.style && a.cornerRadius == b.cornerRadius }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("GlassBackdrop")
        let shape = RoundedRectangle(cornerRadius: Pixels(Float(cornerRadius)))
        let rim = Color.glassRim
        switch GlassLook.resolve(style: style, reduceTransparency: reduceTransparency) {
        case .glass(let glass, let thick):
            let tinted = glass.tint(Color.controlFill.opacity(style.controlOpacity))
            if thick {
                shape.fill(Color.clear).background(.thickMaterial, in: shape).glassEffect(tinted, in: shape)
                    .overlay { shape.stroke(rim) }
            } else {
                shape.fill(Color.clear).glassEffect(tinted, in: shape)
                    .overlay { shape.stroke(rim) }
            }
        case .solid:
            shape.fill(Color.controlFill)
                .overlay { shape.stroke(rim) }
        }
    }
}

extension ElementGroup {
    /// Draws a glass control bar behind this view. `GlassControl` in the plan: a modifier, not a wrapper component, so
    /// the bar's own content stays skippable (see ``GlassBackdrop``).
    func glassControl(style: AppearanceStyle, cornerRadius: Double) -> BackgroundModifier<Self, EquatableComponent<GlassBackdrop>> {
        background { GlassBackdrop(style: style, cornerRadius: cornerRadius).equatable() }
    }
}

extension AppearanceStyle {
    /// One gutter on every side.
    var gutterInsets: Edges<Pixels> {
        let g = Pixels(Float(gutter))
        return Edges(top: g, right: g, bottom: g, left: g)
    }
}
