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
    /// File > Open…'s chooser: the files the user picked (empty for Cancel or an error), given the folder to start in (the
    /// project's). The entry point sets the system open dialog; tests set a stub.
    public var chooseFiles: @MainActor (_ directory: URL?) async -> [URL] = { _ in [] }
    /// Opens a file outside the project the way `alloy <file>` does (a new Alloy on the file's own project). Set by the
    /// entry point.
    public var openOutsideProject: @MainActor (URL) -> Void = { _ in }
    /// File > Save As…'s dialog: the file name to propose and the folder to start in; nil for Cancel or an error. The entry
    /// point sets the system save dialog; tests set a stub.
    public var chooseSaveURL: @MainActor (_ name: String, _ directory: URL) async -> URL? = { _, _ in nil }
    /// Closes the key window as its close button does (File > Close Window). Set by the entry point.
    public var closeKeyWindow: @MainActor () -> Void = {}
    /// Whether the project window is the key window. ⌘W (Close Tab) closes the key window instead of a tab when it is not,
    /// so it never closes an editor tab from behind Settings. Set by the entry point; true by default.
    public var isProjectWindowKey: @MainActor () -> Bool = { true }
    /// The app's standard menu items and their keys (`App.standardMenuShortcuts()`), set by the entry point; read only
    /// when the Keyboard settings classify a clash.
    public var standardMenuClaims: @MainActor () -> [ClaimedShortcut] = { [] }

    /// The plugin system (set by the entry point before `bind`). Not observable; nothing in a view body reads it.
    public var plugins: PluginCoordinator? { didSet { plugins?.center = self } }

    private let launcher: LauncherModel
    /// A workspace bound directly (a window that has no launcher adopting it); wins over the launcher's.
    private weak var bound: Workspace?

    public init(launcher: LauncherModel) {
        self.launcher = launcher
        quickOpen = QuickOpenModel()
        palette = CommandPaletteModel()
        var current: (@MainActor () -> Workspace?)?
        registry = CommandRegistry(workspace: { current?() })
        current = { [weak self] in
            guard let self else { return nil }
            return bound ?? launcher.workspace
        }
    }

    /// The workspace commands act on: the bound one, else the launcher's.
    var workspace: Workspace? { bound ?? launcher.workspace }

    /// Makes `workspace` the one commands act on (recents are recorded in it), applies its key overrides to the keymap
    /// and keeps them current: a settings change to `keybindings` re-resolves the menus and global keys.
    public func bind(_ workspace: Workspace) {
        guard bound !== workspace else { return }
        bound = workspace
        registry.overrides = workspace.settings.keybindings
        workspace.onKeybindingsChanged = { [weak self] overrides in
            self?.registry.overrides = overrides
            self?.plugins?.keybindingsChanged()
        }
        plugins?.bind(workspace)
    }

    /// The quick-open model's identity, for tests.
    var quickOpenModel: QuickOpenModel { quickOpen }
}
