import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor @Suite struct ShortcutClashesTests {
    private func chord(_ s: String) -> KeyChord { KeyChord.parse(s)! }

    private func setup() throws -> (rig: Rig, window: TestWindow, center: CommandCenter) {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        return (rig, window, testCenter(for: rig.workspace))
    }

    private func descriptor(_ id: String, _ shortcut: String?) -> CommandDescriptor {
        CommandDescriptor(id: id, title: "Title \(id)", category: .app, shortcut: shortcut.map(chord), recordsRecent: false, source: .builtin)
    }

    @Test func chordHeldByAnotherCommandNamesIt() throws {
        let (_, _, center) = try setup()
        center.registry.register(descriptor("t.a", "primary+alt+shift+y"), run: {})
        let found = ShortcutClashes(center: center).clashes(for: chord("primary+alt+shift+y"), excluding: "t.b", overrides: [:])
        #expect(found.first == ShortcutClash(kind: .command(id: "t.a"), title: "Title t.a", condition: nil))
        let own = ShortcutClashes(center: center).clashes(for: chord("primary+alt+shift+y"), excluding: "t.a", overrides: [:])
        #expect(!own.contains { $0.kind == .command(id: "t.a") })
        let moved = ShortcutClashes(center: center).clashes(for: chord("primary+alt+shift+y"), excluding: "t.b", overrides: ["t.a": "none"])
        #expect(moved.isEmpty)
    }

    @Test func commandSharingOnlyAfterPrimaryResolutionClashesOffMacOnly() throws {
        let (_, _, center) = try setup()
        center.registry.register(descriptor("t.a", "primary+alt+shift+y"), run: {})
        let candidate = chord("ctrl+alt+shift+y")
        let linux = ShortcutClashes(center: center, platform: .linux).clashes(for: candidate, excluding: "t.b", overrides: [:])
        #expect(linux.contains { $0.kind == .command(id: "t.a") })
        let mac = ShortcutClashes(center: center, platform: .macOS).clashes(for: candidate, excluding: "t.b", overrides: [:])
        #expect(!mac.contains { $0.kind == .command(id: "t.a") })
    }

    @Test func systemKeyFlagged() throws {
        let (_, _, center) = try setup()
        let found = ShortcutClashes(center: center, platform: .macOS).clashes(for: chord("ctrl+cmd+q"), excluding: "t.b", overrides: [:])
        #expect(found.contains { $0.kind == .system })
    }

    @Test func standardMenuKeyFlagged() throws {
        let (_, _, center) = try setup()
        let found = ShortcutClashes(center: center).clashes(for: chord("primary+q"), excluding: "t.b", overrides: [:])
        #expect(found.contains { $0.kind == .standardMenu })
    }

    @Test func conditionalCodeViewKeyIsSoftWithCondition() throws {
        let (_, _, center) = try setup()
        let found = ShortcutClashes(center: center, platform: .macOS).clashes(for: chord("cmd+g"), excluding: "t.b", overrides: [:])
        let soft = found.filter { $0.kind == .codeViewSoft }
        #expect(soft.count == 1)
        #expect(soft.first?.condition == "only with find matches")
        #expect(!ShortcutClashes(center: center).hard(soft[0]))
    }

    @Test func unconditionalCodeViewKeyIsHard() throws {
        let (_, _, center) = try setup()
        let clashes = ShortcutClashes(center: center, platform: .macOS)
        let found = clashes.clashes(for: chord("cmd+left"), excluding: "t.b", overrides: [:])
        let hard = found.filter { $0.kind == .codeViewHard }
        #expect(!hard.isEmpty)
        #expect(hard.allSatisfy { clashes.hard($0) && $0.condition == nil })
    }

    @Test func ownDefaultsOnlyClashWithBuiltInsKnowingly() throws {
        let (_, _, center) = try setup()
        let clashes = ShortcutClashes(center: center)
        // Defaults that knowingly share a key with a MetalUI menu item or an unconditional code view key (`id: title`).
        // A new default that shadows a built-in must be added here on purpose.
        // Close Tab deliberately takes the standard Close item's key (the app's own item replaces it).
        // The terminal's copy, paste and select all take the standard items' keys, but only while a terminal is focused
        // (disabled otherwise, so the standard item keeps the key everywhere else).
        let allowed: Set<String> = ["tab.close: Close", "terminal.copy: Copy",
                                    "terminal.selectAll: Select All"]
        var seen: Set<String> = []
        for command in center.registry.commands {
            guard let own = command.descriptor.shortcut else { continue }
            for clash in clashes.clashes(for: own, excluding: command.descriptor.id, overrides: [:]) {
                switch clash.kind {
                case .system:
                    // Known, unresolved (see CommandRegistryTests): ctrl+space is the system's "Next Input Source".
                    if command.descriptor.id != "edit.triggerCompletion" { Issue.record("\(command.descriptor.id) clashes with system key \(clash.title)") }
                case .standardMenu, .codeViewHard:
                    seen.insert("\(command.descriptor.id): \(clash.title)")
                case .command, .codeViewSoft:
                    break
                }
            }
        }
        #expect(seen.subtracting(allowed).isEmpty, "unlisted default clashes: \(seen.subtracting(allowed).sorted())")
    }
}
