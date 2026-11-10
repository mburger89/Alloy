import MetalUI

/// Where a theme is installed: MetalUI's `App` (every window, present and future) or a single `Window`.
@MainActor
public protocol ThemeHost: AnyObject {
    var lightTheme: Theme { get set }
    var darkTheme: Theme { get set }
    var preferredColorScheme: ColorScheme? { get set }
}

extension App: ThemeHost {}
extension Window: ThemeHost {}
