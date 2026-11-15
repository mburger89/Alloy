import AlloyCore
import MetalUI

/// The root of the Settings window: the settings view, and an Esc cancel shortcut that closes the window wherever the
/// focus is (a click on a plain area drops the view's own focus), after the focused view declined the key.
public struct SettingsWindowRoot: Component {
    let workspace: Workspace
    var themes: ThemeController?
    let close: @MainActor () -> Void
    /// Runs when the window goes away (its `onDisappear`), so the opener forgets it.
    let gone: @MainActor () -> Void

    init(workspace: Workspace, themes: ThemeController?, close: @escaping @MainActor () -> Void, gone: @escaping @MainActor () -> Void) {
        self.workspace = workspace; self.themes = themes; self.close = close; self.gone = gone
    }

    public var content: some ElementGroup {
        let close = close, gone = gone
        let style = themes?.style ?? .defaults
        let gutter = Pixels(Float(style.gutter))
        ZStack {
            VStack(spacing: 0) {
                SettingsTitleIsland(style: style).equatable()
                VStack(spacing: 0) {
                    SettingsView(workspace: workspace, themes: themes, close: close)
                        .island(style: style, identifier: "island-settings")
                }
                .padding(Edges(top: Pixels(0), right: gutter, bottom: gutter, left: gutter))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .windowTitleBarMetrics(height: Pixels(Float(style.titleBandHeight)),
                                   controlsLeading: Pixels(Float(style.titleControlsLeading)))
            Button("Close Settings") { close() }
                .keyboardShortcut(.cancelAction)
                .frame(width: Pixels(0), height: Pixels(0))
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WindowBackdropView(style: style).equatable() }
        .onDisappear { gone() }
    }
}

/// The Settings window's title island: room for the traffic lights, then "Settings" in the main title island's text
/// style (the traffic lights close the window). Laid out as ``TitleIsland`` is, without its pills.
struct SettingsTitleIsland: Component, Equatable {
    let style: AppearanceStyle
    @Environment(\.titleBarInsets) var titleBarInsets

    nonisolated static func == (a: Self, b: Self) -> Bool { a.style == b.style }

    var content: some ElementGroup {
        let style = style
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer().frame(width: Pixels(Float(style.titleLightsSpacer(rightEdge: Double(titleBarInsets.left.value)))))
                Text("Settings").font(size: 13).accessibilityIdentifier("settings-title")
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: Pixels(Float(style.titleIslandHeight)))
            .island(style: style, identifier: "island-settings-title")
        }
        .padding(style.gutterInsets)
    }
}

/// The window's root as an element (a window's root is an element; a component is not one).
@MainActor
public func settingsWindowElement(_ root: SettingsWindowRoot) -> some Element {
    VStack(spacing: 0) { root }
}

/// Opens Settings as a window of its own (the app menu's "Settings…", ⌘,), one at a time: asking again brings the open
/// one to the front. The theme and the appearance reach it, and every other window, through the app's themes
/// (`ThemeController`'s host), which each window takes from the app.
@MainActor
public final class SettingsWindowController {
    /// Opens a window with the given title, size, minimum size and root, shown through `settingsWindowElement`
    /// (`App.openWindow` in the app).
    /// The window has a hidden title bar (`windowStyle: .hiddenTitleBar`), as the main window does.
    public typealias Opener = @MainActor (_ title: String, _ size: Size<Pixels>, _ minSize: Size<Pixels>,
                                          _ root: SettingsWindowRoot) throws -> Window

    public static let windowSize = Size(width: Pixels(560), height: Pixels(820))
    public static let minimumSize = Size(width: Pixels(420), height: Pixels(360))

    private let opener: Opener
    /// The open Settings window, nil once it closed.
    public private(set) var window: Window?

    public init(opener: @escaping Opener) { self.opener = opener }

    public var isOpen: Bool { window != nil }

    /// Opens Settings for `workspace`, or fronts the window that is open.
    public func open(workspace: Workspace, themes: ThemeController?) {
        if let window {
            window.makeKeyAndOrderFront()
            return
        }
        // `claude` is looked for when Settings opens, so the field can show what was found.
        Task { await workspace.detectClaude() }
        let box = WindowBox()
        let root = SettingsWindowRoot(workspace: workspace, themes: themes,
                                      close: { box.window?.close() },
                                      gone: { [weak self] in self?.window = nil })
        guard let opened = try? opener("Settings", Self.windowSize, Self.minimumSize, root) else { return }
        box.window = opened
        window = opened
    }

    /// Closes the window if it is open (the main window's close takes Settings with it).
    public func close() {
        window?.close()
        window = nil
    }

    @MainActor private final class WindowBox { var window: Window? }
}
