import AlloyCore

/// AlloyCore's theme-side terminal palette, under a name that cannot clash with MetalUITerminalUI's `TerminalPalette`
/// in files that import both (`AlloyCore.TerminalPalette` does not resolve: the `AlloyCore` enum shadows the module).
typealias ThemeTerminalPalette = TerminalPalette
