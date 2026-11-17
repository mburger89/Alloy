import AlloyCore
import Foundation
import MetalUI

/// The app-wide objects every window shares: the command registry and quick open. Created once by the entry point
/// before the window, handed to `rootView`/`launcherRoot`, and kept for the life of the process, so views that compare
/// `quickOpen ===` see one stable identity. Not Observable: nothing reads it in a body except through its members.
@MainActor
public final class CommandCenter {
    public let registry: CommandRegistry
    let quickOpen: QuickOpenModel
    let palette: CommandPaletteModel
    /// Raises the project window (set by the entry point; the palette and plugin commands call it).
    public var bringProjectWindowForward: @MainActor () -> Void = {}
    /// The app's standard menu items and their keys (`App.standardMenuShortcuts()`), set by the entry point; read only
    /// when the Keyboard settings classify a clash.
    public var standardMenuClaims: @MainActor () -> [ClaimedShortcut] = { [] }

    private let launcher: LauncherModel
    /// A workspace bound directly (a window that has no launcher adopting it); wins over the launcher's.
    private weak var bound: Workspace?

    public init(launcher: LauncherModel) {
        self.launcher = launcher
        quickOpen = QuickOpenModel()
        palette = CommandPaletteModel()
        var current: (@MainActor () -> Workspace?)?
        registry = CommandRegistry(workspace: { current?() })
        current = { [unowned self] in bound ?? self.launcher.workspace }
    }

    /// The workspace commands act on: the bound one, else the launcher's.
    var workspace: Workspace? { bound ?? launcher.workspace }

    /// Makes `workspace` the one commands act on (recents are recorded in it), applies its key overrides to the keymap
    /// and keeps them current: a settings change to `keybindings` re-resolves the menus and global keys.
    public func bind(_ workspace: Workspace) {
        guard bound !== workspace else { return }
        bound = workspace
        registry.overrides = workspace.settings.keybindings
        workspace.onKeybindingsChanged = { [weak registry] overrides in registry?.overrides = overrides }
    }

    /// The quick-open model's identity, for tests.
    var quickOpenModel: QuickOpenModel { quickOpen }
}
