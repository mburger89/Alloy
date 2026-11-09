import MetalUI

/// Padding of `horizontal` points left and right and `vertical` top and bottom.
func inset(_ horizontal: Float, _ vertical: Float) -> Edges<Pixels> {
    Edges(top: Pixels(vertical), right: Pixels(horizontal), bottom: Pixels(vertical), left: Pixels(horizontal))
}
