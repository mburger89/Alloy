import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The app's real root element in a headless 1200x800 window, settled so lists have built their rows.
@MainActor
func alloyWindow(_ workspace: Workspace, terminal: TerminalPanelStore? = nil) throws -> TestWindow {
    // Scripted ptys, so a test that opens the panel never starts a real shell.
    let store = terminal ?? TerminalPanelStore(workspace: workspace, spawner: ScriptedPtySpawner())
    let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
        rootView(workspace: workspace, themes: nil, center: testCenter(for: workspace), terminal: store)
    }
    // The menu bar as main.swift installs it: Settings… lives there now.
    window.installAlloyMenu(workspace)
    window.tick()
    window.tick()
    return window
}

extension TestWindow {
    /// Every rect the last frame draws: the scene's own and, recursively, those of each offscreen group (the islands'
    /// clipped content is drawn in groups), as `allGlyphs` does for text.
    var allRects: [MUIRect] {
        func collect(_ scene: Scene, into out: inout [MUIRect]) {
            out.append(contentsOf: scene.rects)
            for group in scene.groupScenes { collect(group, into: &out) }
        }
        var rects: [MUIRect] = []
        collect(scene, into: &rects)
        return rects
    }

    /// The menu bar as main.swift installs it: Settings… lives there, and opens a Settings window of this test app.
    /// `themes` is what the Settings window picks themes through; install the menu again once the controller exists.
    func installAlloyMenu(_ workspace: Workspace, themes: ThemeController? = nil, center: CommandCenter? = nil) {
        installAlloyMenu(model: LauncherModel(workspace: workspace), themes: themes, center: center ?? testCenter(for: workspace))
    }

    /// The same for a launcher model (without a project, Settings… is disabled).
    func installAlloyMenu(model: LauncherModel, themes: ThemeController? = nil, center: CommandCenter? = nil) {
        let center = center ?? testCenter(for: model)
        let testApp = self.testApp
        let rig = SettingsRig()
        rig.controller = SettingsWindowController { title, size, minSize, root in
            // As tall as every section needs, so the tests find all of them without scrolling.
            let tall = Size(width: size.width, height: Pixels(2400))
            let opened = try testApp.openWindow(title: title, size: tall, minSize: minSize, windowStyle: .hiddenTitleBar) { settingsWindowElement(root) }
            opened.tick()
            rig.windows.append(opened)
            return opened.window
        }
        settingsRigs[ObjectIdentifier(testApp)] = rig
        // The center's built-in commands read these through closures, so installing again swaps them.
        testSettingsControllers[ObjectIdentifier(center)] = rig.controller
        testThemeControllers[ObjectIdentifier(center)] = themes
        testApp.app.commands { alloyCommands(center: center) }
    }

    /// The test app's Settings controller (from `installAlloyMenu`).
    var settingsController: SettingsWindowController { settingsRigs[ObjectIdentifier(testApp)]!.controller }

    /// Opens Settings through the application menu's "Settings…" item and returns its window (the open one, if it was).
    @discardableResult
    func openSettingsFromMenu() throws -> TestWindow {
        try testApp.performMenuBarItem(accessibilityIdentifier: "app-settings")
        return try #require(settingsRigs[ObjectIdentifier(testApp)]?.windows.last)
    }
}

/// One center per workspace (or launcher model) for the life of the test: the root closure runs every frame and the
/// menu is installed separately, and both must see the same registry and quick-open model. The entry holds the key
/// weakly and is only reused while that very object is alive, so a recycled address never returns a stale center.
@MainActor private var testCenters: [ObjectIdentifier: (key: WeakBox, center: CommandCenter)] = [:]
private final class WeakBox { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

@MainActor
func testCenter(for workspace: Workspace) -> CommandCenter {
    cachedCenter(key: workspace) {
        let launcher = LauncherModel(workspace: workspace)
        let center = makeTestCenter(launcher: launcher)
        center.bind(workspace)
        return center
    }
}

@MainActor
func testCenter(for model: LauncherModel) -> CommandCenter {
    cachedCenter(key: model) {
        let center = makeTestCenter(launcher: model)
        if let workspace = model.workspace { center.bind(workspace) }
        return center
    }
}

/// The Settings controller and theme controller a center's built-in commands use, keyed by the center; set by `installAlloyMenu`.
@MainActor private var testSettingsControllers: [ObjectIdentifier: SettingsWindowController] = [:]
@MainActor private var testThemeControllers: [ObjectIdentifier: ThemeController] = [:]

@MainActor
private func makeTestCenter(launcher: LauncherModel) -> CommandCenter {
    let center = CommandCenter(launcher: launcher)
    let id = ObjectIdentifier(center)
    BuiltinCommands.register(into: center, launcher: launcher, settings: { testSettingsControllers[id] },
                             themes: { testThemeControllers[id] })
    return center
}

@MainActor
private func cachedCenter(key: AnyObject, make: () -> CommandCenter) -> CommandCenter {
    let id = ObjectIdentifier(key)
    if let entry = testCenters[id], entry.key.object === key { return entry.center }
    let center = make()
    testCenters[id] = (WeakBox(key), center)
    return center
}

/// The Settings windows a test app opened, in order.
@MainActor
final class SettingsRig {
    var controller: SettingsWindowController!
    var windows: [TestWindow] = []
}

@MainActor private var settingsRigs: [ObjectIdentifier: SettingsRig] = [:]

/// A workspace whose sessions run on `ScriptedTransport`s, collected in order.
@MainActor
final class Rig {
    let workspace: Workspace
    let root: URL
    let transports = TransportBag()
    /// Autosave never fires on its own, so a save in a test comes from the code under test.
    let clock = ManualClock()
    /// Delivers file-system events by hand, so a test decides when an outside change arrives.
    let changes = ScriptedChangeSource()

    /// `followEdits` is off by default: the UI tests drive the panel by hand and expect it to stay where they put it.
    init(followEdits: Bool = false, branch: String? = nil) {
        var settings = AlloySettings()
        settings.followEdits = followEdits
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ui-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let branch {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try? "ref: refs/heads/\(branch)\n".write(to: root.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        }
        let bag = transports, source = changes
        workspace = Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: settings,
                              locate: { _ in URL(fileURLWithPath: "/fake/claude") },
                              makeTransport: { _ in bag.make() }, autosaveClock: clock,
                              changes: { _ in source })
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

final class TransportBag: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ScriptedTransport] = []
    func make() -> ScriptedTransport {
        let t = ScriptedTransport()
        lock.withLock { all.append(t) }
        return t
    }
    subscript(i: Int) -> ScriptedTransport { lock.withLock { all[i] } }
    var count: Int { lock.withLock { all.count } }
}

/// Every element below `element` in the last published tree, pre-order.
@MainActor
func descendants(of element: TestElement, in window: TestWindow) -> [TestElement] {
    guard let all = try? window.elements(where: { _ in true }) else { return [] }
    let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    var out: [TestElement] = []
    var stack = element.children.reversed().map { $0 }
    while let id = stack.popLast() {
        guard let e = byID[id] else { continue }
        out.append(e)
        stack.append(contentsOf: e.children.reversed())
    }
    return out
}
