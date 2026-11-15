import AlloyCore
import MetalUI

extension AppearanceStyle {
    /// The border shape of the style's buttons, menus and pickers: a capsule when `pillButtons` is on, else a rounded
    /// rectangle at ``buttonCornerRadius``. MetalUI clamps the radius to half the control's height.
    var buttonShape: ButtonBorderShape {
        pillButtons ? .capsule : .roundedRectangle(radius: Pixels(Float(buttonCornerRadius)))
    }

    /// The shape of the selected tab (and the hover wash) in a `TabStrip`, following ``buttonShape``.
    var tabSelectionShape: TabStripSelectionShape {
        pillButtons ? .capsule : .roundedRectangle(radius: Pixels(Float(buttonCornerRadius)))
    }

    /// The composer message box's padding: wider than a rectangle's so text and caret clear the rounded ends.
    var composerFieldPaddingHorizontal: Double { pillButtons ? 16 : 8 }
    var composerFieldPaddingVertical: Double { 6 }
    /// One line of the message field's text (13 pt system font).
    static let composerLineHeight = 16.0
    /// The one-line height of the message box: a line of text with the vertical padding above and below.
    var composerFieldOneLineHeight: Double { Self.composerLineHeight + 2 * composerFieldPaddingVertical }

    /// The message box's shape: with pills on, the end radius is half the one-line height, so one line is a capsule and
    /// several lines keep the same pill ends as a rounded rectangle; with pills off, ``buttonCornerRadius``.
    @MainActor var composerFieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Pixels(Float(pillButtons ? composerFieldOneLineHeight / 2 : buttonCornerRadius)))
    }
}

extension ElementGroup {
    /// The composer message box's chrome: filled with `surface` and outlined in one stroke of the style's field shape,
    /// in the accent colour while the field is focused and `controlBorder` otherwise.
    @MainActor func composerBox(style: AppearanceStyle, focused: Bool) -> some ElementGroup {
        let shape = style.composerFieldShape
        let outline: Color = focused ? Color(.accent) : Color.controlBorder
        return self
            .background(alignment: .center) { shape.fill(Color.surface) }
            .overlay { shape.stroke(outline) }
    }
}
