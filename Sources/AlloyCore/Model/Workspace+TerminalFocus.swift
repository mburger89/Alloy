import Foundation

/// What the tab commands do instead of their editor behaviour while a terminal pane has keyboard focus. The terminal panel
/// installs it; the commands read it inside their closures only, never from a view body.
public struct TerminalFocusActions {
    public var isFocused: @MainActor () -> Bool
    public var closeTab: @MainActor () -> Void
    public var cycleTab: @MainActor (Int) -> Void
    public var newTab: @MainActor () -> Void
    /// The terminal commands (copy, select all, find, clear scrollback), acting on the focused pane.
    public var copy: @MainActor () -> Void
    public var selectAll: @MainActor () -> Void
    public var openFind: @MainActor () -> Void
    public var clearScrollback: @MainActor () -> Void

    public init(isFocused: @escaping @MainActor () -> Bool, closeTab: @escaping @MainActor () -> Void,
                cycleTab: @escaping @MainActor (Int) -> Void, newTab: @escaping @MainActor () -> Void,
                copy: @escaping @MainActor () -> Void = {},
                selectAll: @escaping @MainActor () -> Void = {}, openFind: @escaping @MainActor () -> Void = {},
                clearScrollback: @escaping @MainActor () -> Void = {}) {
        self.isFocused = isFocused
        self.closeTab = closeTab
        self.cycleTab = cycleTab
        self.newTab = newTab
        self.copy = copy
        self.selectAll = selectAll
        self.openFind = openFind
        self.clearScrollback = clearScrollback
    }
}

extension Workspace {
    /// True while a terminal pane has keyboard focus (Code mode only).
    @MainActor public var terminalHasFocus: Bool { terminalFocusActions?.isFocused() ?? false }
}
