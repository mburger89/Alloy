import AlloyCore
import MetalUI

/// A button drawn as a pill: a capsule when `style.pillButtons` is on, else a rounded rectangle at half the island
/// radius. The fill is `controlFill` at a light alpha (full control opacity while pressed) with a `glassRim` stroke.
/// A value of the style only, so a button using it re-runs for a style change and nothing else.
struct PillButtonStyle: ButtonStyle {
    let style: AppearanceStyle

    func makeBody(configuration: Configuration) -> some ElementGroup {
        let shape = RoundedRectangle(cornerRadius: Pixels(Float(style.buttonCornerRadius)))
        let alpha = configuration.isPressed ? style.buttonPressedOpacity : style.buttonFillOpacity
        let h = Pixels(Float(style.buttonPaddingHorizontal)), v = Pixels(Float(style.buttonPaddingVertical))
        configuration.label
            .padding(Edges(top: v, right: h, bottom: v, left: h))
            .background(alignment: .center) { shape.fill(Color.controlFill.opacity(alpha)) }
            .overlay { shape.stroke(Color.glassRim) }
    }
}
