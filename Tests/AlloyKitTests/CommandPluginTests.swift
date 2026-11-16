import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The plugin seam, driven by a test-only fake source: palette-only and menu-placed commands, the Plugins menu, the
/// clash rule against built-ins, and what registering costs a frame. No plugin loading exists yet; this is the contract it will use.
@MainActor @Suite struct CommandPluginTests {
    private let fake = CommandSource.plugin(id: "fake")

    private func descriptor(_ id: String, title: String = "Do It", category: String = "Fake", source: CommandSource? = nil,
                            menu: MenuPlacement? = nil, shortcut: String? = nil) -> CommandDescriptor {
        CommandDescriptor(id: id, title: title, category: CommandCategory(name: category), shortcut: shortcut.flatMap(KeyChord.parse),
                          menu: menu, source: source ?? fake)
    }

    private func menuItem(_ window: TestWindow, _ id: String) -> PlatformMenuItem? {
        func flatten(_ items: [PlatformMenuItem]) -> [PlatformMenuItem] {
            items.flatMap { item -> [PlatformMenuItem] in
                if case .submenu(let sub) = item.kind { return flatten(sub) }
                return [item]
            }
        }
        return window.testApp.menuBar.flatMap { flatten($0.items) }.first { $0.accessibilityIdentifier == id }
    }

    private func pluginsMenu(_ window: TestWindow) -> PlatformMenu? { window.testApp.menuBar.first { $0.title == "Plugins" } }

    private func paletteTitles(_ center: CommandCenter, _ workspace: Workspace) -> [String] {
        center.palette.show(registry: center.registry, workspace: workspace)
        defer { center.palette.hide() }
        return center.palette.rows.map(\.displayTitle)
    }

    @Test func paletteOnlyCommandIsInNoMenu() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        center.registry.register(descriptor("fake.hello"), run: {})
        window.tick()
        #expect(paletteTitles(center, rig.workspace).contains("Fake: Do It"))
        #expect(menuItem(window, "menu-fake.hello") == nil)
        #expect(pluginsMenu(window) == nil)
        center.registry.unregister(source: fake)
    }

    @Test func pluginsMenuAppearsAndDisappearsWithItsCommands() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        #expect(pluginsMenu(window) == nil, "hidden while empty")
        final class Box { var ran = 0 }
        let box = Box()
        // Registered after launch: no observation, so the item shows at the next menu evaluation.
        center.registry.register(descriptor("fake.menu", title: "Run Fake", menu: .plugins), run: { box.ran += 1 })
        window.tick()
        #expect(paletteTitles(center, rig.workspace).contains("Fake: Run Fake"))
        let menus = window.testApp.menuBar.map(\.title)
        #expect(menus.last == "Plugins" || menus.firstIndex(of: "Plugins")! > menus.firstIndex(of: "View")!, "\(menus)")
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "menu-fake.menu")
        #expect(box.ran == 1)
        center.registry.unregister(source: fake)
        window.tick()
        #expect(pluginsMenu(window) == nil)
        #expect(menuItem(window, "menu-fake.menu") == nil)
    }

    @Test func pluginShortcutIsDroppedAndRecorded() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        final class Box { var ran = 0 }
        let box = Box()
        center.registry.register(descriptor("fake.key", menu: .plugins, shortcut: "cmd+shift+j"), run: { box.ran += 1 })
        window.tick()
        window.typeKey("j", modifierFlags: [.command, .shift])
        #expect(box.ran == 0, "a plugin shortcut must not fire")
        #expect(menuItem(window, "menu-fake.key")?.shortcut == nil)
        #expect(center.registry.command(id: "fake.key")?.descriptor.shortcut == nil)
        #expect(center.registry.rejections.contains { $0.id == "fake.key" && $0.reason == .pluginShortcutDropped })
        center.registry.unregister(source: fake)
    }

    @Test func pluginCannotShadowABuiltinIDOrChord() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        let builtin = try #require(center.registry.commands.first { $0.descriptor.shortcut != nil && $0.descriptor.binding == .global })
        let bd = builtin.descriptor
        let before = center.registry.commands.count
        #expect(center.registry.register(descriptor(bd.id), run: {}) == .rejected(.duplicateID))
        #expect(center.registry.commands.count == before)
        #expect(center.registry.command(id: bd.id)?.descriptor.source == .builtin)
        // A fresh id on the built-in's chord is added with the shortcut dropped; the built-in keeps the key.
        #expect(center.registry.register(CommandDescriptor(id: "fake.clash", title: "Clash", category: CommandCategory(name: "Fake"),
                                                           shortcut: bd.shortcut, source: fake), run: {}) == .added)
        #expect(center.registry.keymap.chord(for: "fake.clash") == nil)
        #expect(center.registry.keymap.chord(for: bd.id) == bd.shortcut)
        window.tick()
        center.registry.unregister(source: fake)
    }

    @Test func registeringReRunsGlobalKeysOnceAndTheScreenNever() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        for _ in 0..<6 { window.tick(); await Task.yield() }
        let keys = BodyProbe.count("GlobalKeys"), screen = BodyProbe.count("AlloyScreen")
        center.registry.register(descriptor("fake.one", menu: .plugins), run: {})
        for _ in 0..<4 { window.tick(); await Task.yield() }
        #expect(BodyProbe.count("GlobalKeys") - keys == 1, "GlobalKeys re-ran \(BodyProbe.count("GlobalKeys") - keys) times")
        #expect(BodyProbe.count("AlloyScreen") - screen == 0, "AlloyScreen re-ran")
        center.registry.unregister(source: fake)
        window.tick()
    }

    /// The Chat idle frame costs the same with a plugin registered (the guard counts, 88 for typing, live in ViewRerunTests
    /// and CodeModePerformanceTests; this pins that a registered plugin adds no per-frame work at all).
    @Test func aRegisteredPluginAddsNothingToAFrame() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        func idle() async -> Int {
            var last = -1
            for _ in 0..<40 {
                window.resetFrameWork(); window.tick(); await Task.yield()
                let now = window.frameWork.last?.elementRequests ?? -1
                if now == last { return now }
                last = now
            }
            return last
        }
        let before = await idle()
        center.registry.register(descriptor("fake.idle", menu: .plugins), run: {})
        let after = await idle()
        #expect(after == before, "\(before) before, \(after) with a plugin")
        window.resetFrameWork()
        for _ in 0..<5 { window.tick() }
        #expect(window.frameWork.reduce(0) { $0 + $1.elementRequests } == 0)
        center.registry.unregister(source: fake)
        await rig.workspace.stopAll()
    }

    @Test func pluginUnregisteringItselfInsideRunIsSafe() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        let registry = center.registry
        let source = fake
        registry.register(descriptor("fake.self", menu: .plugins), run: { registry.unregister(source: source) })
        window.tick()
        try window.testApp.performMenuBarItem(accessibilityIdentifier: "menu-fake.self")
        #expect(registry.command(id: "fake.self") == nil)
        window.tick()
        #expect(pluginsMenu(window) == nil)
    }

    @Test func twoPluginsWithTheSameTitleAreBothListedInOrder() async throws {
        let rig = Rig()
        let center = testCenter(for: rig.workspace)
        let other = CommandSource.plugin(id: "other")
        center.registry.register(descriptor("fake.dup"), run: {})
        center.registry.register(descriptor("other.dup", source: other), run: {})
        let rows = { () -> [String] in
            center.palette.show(registry: center.registry, workspace: rig.workspace)
            defer { center.palette.hide() }
            return center.palette.rows.filter { $0.displayTitle == "Fake: Do It" }.map(\.id)
        }()
        #expect(rows == ["fake.dup", "other.dup"])
        center.registry.unregister(source: fake)
        center.registry.unregister(source: other)
    }

    @Test func recordedPluginIDStaysInRecentsAfterUnloadAndIsSkipped() async throws {
        let rig = Rig()
        let center = testCenter(for: rig.workspace)
        center.registry.register(CommandDescriptor(id: "fake.recent", title: "Recent", category: CommandCategory(name: "Fake"),
                                                   recordsRecent: true, source: fake), run: {})
        #expect(center.registry.run(id: "fake.recent"))
        #expect(rig.workspace.recentCommands.first == "fake.recent")
        center.registry.unregister(source: fake)
        #expect(rig.workspace.recentCommands.contains("fake.recent"))
        center.palette.show(registry: center.registry, workspace: rig.workspace)
        defer { center.palette.hide() }
        #expect(!center.palette.rows.contains { $0.id == "fake.recent" })
    }
}
