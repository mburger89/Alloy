import AlloyPlugins
import MetalUI

/// Theme roles for the colours a plugin may name; a plugin never supplies a literal colour.
extension PluginColorRole {
    /// Bars, markers, underlines and message text.
    var ink: Color {
        switch self {
        case .info: .diagnosticInfo
        case .warning: .diagnosticWarning
        case .error: .diagnosticError
        case .success: .gitAddedInk
        case .accent: .linkInk
        case .muted: .mutedInk
        }
    }

    /// Row and range tints.
    var tint: Color {
        switch self {
        case .info: .questionTint
        case .warning: .warningTint
        case .error: .errorTint
        case .success: .addedRowTint
        case .accent: .planTint
        case .muted: .controlFill
        }
    }
}
