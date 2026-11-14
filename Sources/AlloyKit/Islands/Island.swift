import AlloyCore
import Foundation
import MetalUI

/// The look behind an island: `islandFill` at the style's island opacity (solid under Reduce Transparency) with a faint
/// white sheen folded in (one fill), inside a `glassRim` stroke, in a rounded rectangle of the style's corner radius.
///
/// Equatable on the style, and a background of the island rather than a wrapper around its content: a generic wrapper
/// component cannot be skipped (its content closure is a new value every build), so it would re-run each frame; this
/// leaf is skipped until the style changes (see ``GlassBackdrop``).
struct IslandBackdrop: Component, Equatable {
    let style: AppearanceStyle
    let identifier: String
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency

    nonisolated static func == (a: Self, b: Self) -> Bool { a.style == b.style && a.identifier == b.identifier }

    var content: some ElementGroup {
        let _ = BodyProbe.hit("IslandBackdrop")
        let shape = RoundedRectangle(cornerRadius: Pixels(Float(style.cornerRadius)))
        shape.fill(reduceTransparency ? Color.islandFill : Color.islandPaint)
            .overlay { shape.stroke(Color.glassRim) }
            .accessibilityIdentifier(identifier)
    }
}

extension ElementGroup {
    /// Makes this view an island: its content, clipped to the rounded shape, over the island backdrop (the identifier names the
    /// backdrop's frame for tests). The backdrop is not clipped (it is the shape); only the content is.
    func island(style: AppearanceStyle, identifier: String) -> some ElementGroup {
        let radius = Pixels(Float(style.cornerRadius))
        return VStack(spacing: 0) { self }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .background(alignment: .center) { IslandBackdrop(style: style, identifier: identifier).equatable() }
    }
}
