import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import MetalUI
import MetalUITesting
import Foundation
import Testing

@MainActor @Suite struct CommandRegistryTests {
    private func chord(_ s: String) -> KeyChord { KeyChord.parse(s)! }
    private func d(_ id: String, chord c: String? = nil, source: CommandSource = .builtin, recent: Bool = false) -> CommandDescriptor {
        CommandDescriptor(id: id, title: id, category: .app, shortcut: c.map(chord), recordsRecent: recent, source: source)
    }
    private func registry(_ ws: Workspace? = nil) -> CommandRegistry { CommandRegistry(workspace: { ws }) }

    @Test func registerAndUnregisterBySource() {
        let r = registry()
        #expect(r.register(d("a"), run: {}) == .added)
        #expect(r.register(d("p1", source: .plugin(id: "x")), run: {}) == .added)
        #expect(r.register(d("p2", source: .plugin(id: "y")), run: {}) == .added)
        #expect(r.commands.map(\.descriptor.id) == ["a", "p1", "p2"])
        r.unregister(source: .plugin(id: "x"))
        #expect(r.commands.map(\.descriptor.id) == ["a", "p2"])
        #expect(r.command(id: "p2") != nil && r.command(id: "p1") == nil)
    }

    @Test func duplicateIDIsRejectedAndLogged() {
        let r = registry()
        r.register(d("a"), run: {})
        #expect(r.register(d("a", source: .plugin(id: "x")), run: {}) == .rejected(.duplicateID))
        #expect(r.commands.count == 1 && r.command(id: "a")?.descriptor.source == .builtin)
        #expect(r.rejections.map(\.reason) == [.duplicateID])
    }

    @Test func chordClashFirstWinsAndPluginShortcutDropped() {
        let r = registry()
        r.register(d("a", chord: "primary+k"), run: {})
        #expect(r.register(d("b", chord: "primary+k"), run: {}) == .rejected(.chordTaken(by: "a")))
        #expect(r.command(id: "b") == nil)
        #expect(r.register(d("p1", chord: "primary+k", source: .plugin(id: "x")), run: {}) == .added)
        #expect(r.register(d("p2", chord: "primary+j", source: .plugin(id: "y")), run: {}) == .added)
        #expect(r.register(d("p3", chord: "primary+j", source: .plugin(id: "z")), run: {}) == .added)
        #expect(r.command(id: "p1")?.descriptor.shortcut == nil && r.command(id: "p2")?.descriptor.shortcut == nil)
        #expect(r.keymap.chord(for: "a") == chord("primary+k") && r.keymap.chord(for: "p2") == nil)
        #expect(r.rejections.filter { $0.reason == .pluginShortcutDropped }.count == 3)
    }

    @Test func revisionBumpsOnRegisterAndUnregisterOnly() {
        let r = registry()
        let start = r.revision
        r.register(d("a"), run: {})
        #expect(r.revision == start + 1)
        r.register(d("a"), run: {})
        #expect(r.revision == start + 1)
        r.unregister(source: .plugin(id: "none"))
        #expect(r.revision == start + 1)
        r.unregister(source: .builtin)
        #expect(r.revision == start + 2)
        _ = r.run(id: "a"); _ = r.commands
        #expect(r.revision == start + 2)
    }

    @Test func runRefusesMissingAndDisabled() {
        let r = registry()
        final class Box { var ran = 0; var enabled = false }
        let box = Box()
        r.register(d("a"), isEnabled: { box.enabled }, run: { box.ran += 1 })
        #expect(!r.run(id: "a") && !r.run(id: "zzz") && box.ran == 0)
        box.enabled = true
        #expect(r.run(id: "a") && box.ran == 1)
    }

    @Test func unregisterDuringRunIsSafe() {
        let r = registry()
        let src = CommandSource.plugin(id: "x")
        r.register(d("p", source: src, recent: true), run: { r.unregister(source: src) })
        #expect(r.run(id: "p"))
        #expect(r.command(id: "p") == nil)
    }

    @Test func recentsOnlyForRecordingCommandsAndKeepUnknownIDs() {
        let h = Harness()
        let ws = h.workspace
        let r = registry(ws)
        r.register(d("rec", recent: true), run: {})
        r.register(d("quiet"), run: {})
        r.run(id: "quiet")
        #expect(ws.recentCommands.isEmpty)
        r.run(id: "rec")
        #expect(ws.recentCommands == ["rec"])
        ws.noteCommandRun(id: "gone")
        r.run(id: "rec")
        #expect(ws.recentCommands == ["rec", "gone"])
    }

    @Test func keymapFollowsRegisteredDefaultsAndOverrides() {
        let r = registry()
        r.register(d("a", chord: "primary+k"), run: {})
        #expect(r.keymap.chord(for: "a") == chord("primary+k"))
        r.overrides = ["a": "primary+j", "ghost": "x"]
        #expect(r.keymap.chord(for: "a") == chord("primary+j"))
        r.overrides = ["a": Keymap.unbound]
        #expect(r.keymap.chord(for: "a") == nil)
        r.unregister(source: .builtin)
        #expect(r.keymap.chord(for: "a") == nil)
    }
}

@MainActor private final class Harness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("alloy-reg-\(UUID().uuidString)")
    lazy var workspace: Workspace = {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Workspace(projectRoot: root, appSupport: root.appendingPathComponent("support"), settings: AlloySettings(),
                         locate: { _ in URL(fileURLWithPath: "/fake/claude") })
    }()
}

extension CommandRegistryTests {
    @Test func noBuiltInDefaultCollidesWithASystemReservedKey() {
        let h = Harness()
        let registry = testCenter(for: h.workspace).registry
        let reserved = KeyboardShortcut.systemReserved(on: .current)
        // Known, unresolved collisions awaiting a product decision (not changed unasked): ctrl+space is the system's
        // "Next Input Source" when that shortcut is enabled. Do not add to this list without a decision.
        let knownCollisions: Set<String> = ["edit.triggerCompletion"]
        for command in registry.commands {
            guard let chord = command.descriptor.shortcut, !knownCollisions.contains(command.descriptor.id) else { continue }
            for claim in reserved where claim.shortcut.conflicts(with: chord.shortcut) {
                Issue.record("\(command.descriptor.id) default collides with system key \"\(claim.title)\"")
            }
        }
    }

    @Test func skipNextOccurrenceHasNoDefaultOnMacOS() {
        let h = Harness()
        let command = testCenter(for: h.workspace).registry.command(id: "editor.skipNextOccurrence")
        #expect(command?.descriptor.menuID == "cmd-editor.skipNextOccurrence")
        #if os(macOS)
        #expect(command?.descriptor.shortcut == nil)
        #endif
    }

    @Test func centerOwnsOneQuickOpen() throws {
        let h = Harness()
        let center = testCenter(for: h.workspace)
        #expect(center.quickOpenModel === center.quickOpen)
        #expect(testCenter(for: h.workspace) === center)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: h.workspace, center: testCenter(for: h.workspace))
        }
        window.tick(); window.tick()
        #expect(!center.quickOpen.isShowing)
        window.typeKey("p", modifierFlags: .command)
        window.tick()
        #expect(center.quickOpen.isShowing)
        #expect((try? window.element(identifier: "quick-open-field")) != nil)
    }
}
