import AlloyCore
import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting

/// The app's real root element in a headless 1200x800 window, settled so lists have built their rows.
@MainActor
func alloyWindow(_ workspace: Workspace) throws -> TestWindow {
    let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: workspace) }
    // The menu bar as main.swift installs it: Settings… lives there now.
    window.installAlloyMenu(workspace)
    window.tick()
    window.tick()
    return window
}

extension TestWindow {
    /// The menu bar as main.swift installs it: Settings… lives there.
    func installAlloyMenu(_ workspace: Workspace) {
        let model = LauncherModel(workspace: workspace)
        testApp.app.commands { alloyCommands(model: model) }
    }

    /// Opens Settings through the application menu's "Settings…" item.
    func openSettingsFromMenu() throws {
        try testApp.performMenuBarItem(accessibilityIdentifier: "app-settings")
    }
}

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

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-ui-\(UUID().uuidString)").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bag = transports, source = changes
        workspace = Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: AlloySettings(),
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
