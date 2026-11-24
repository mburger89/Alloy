import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A plugin command added after the window is up fires its shortcut from the Plugins menu.
@MainActor
@Suite(.serialized) struct PluginMenuShortcutTests {
    @Test func menuItemAddedAfterLaunchFiresItsShortcut() async throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let center = testCenter(for: rig.workspace)
        window.tick()
        final class Box { var ran = 0 }
        let box = Box()
        let source = CommandSource.plugin(id: "fake")
        let chord = try #require(KeyChord.parse("ctrl+alt+cmd+j"))
        center.registry.register(CommandDescriptor(id: "fake.menuKey", title: "Menu Key", category: CommandCategory(name: "Fake"),
                                                   shortcut: chord, binding: .menu, menu: .plugins, source: source),
                                 run: { box.ran += 1 }, keepsPluginShortcut: true)
        window.tick()
        window.typeKey("j", modifierFlags: [.control, .option, .command])
        #expect(box.ran == 1, "ran \(box.ran) times")
        center.registry.unregister(source: source)
        window.tick()
    }
}
