import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A plugin's proposed shortcut is bound only when nothing else claims the chord; otherwise the row says who does.
@MainActor
@Suite(.serialized) struct PluginShortcutTests {
    private let todo = "dev.example.todo"
    private var commandID: String { "\(todo).add" }

    private func rig(keybindings: [String: String] = [:]) throws -> (PluginRig, CommandCenter, TestWindow) {
        let workspaceRig = Rig()
        if !keybindings.isEmpty {
            var s = workspaceRig.workspace.settings
            s.keybindings = keybindings
            try workspaceRig.workspace.updateSettings(s)
        }
        let window = try alloyWindow(workspaceRig.workspace)
        let center = testCenter(for: workspaceRig.workspace)
        let p = PluginRig(rig: workspaceRig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], center: center)
        return (p, center, window)
    }

    private func enable(_ p: PluginRig, shortcut: String, menu: Bool = false) throws {
        let menuField = menu ? #","menu":"plugins""# : ""
        try p.fake(todo, contributes: .object(["commands": JSONValue.parse(
            Data(#"[{"id":"add","title":"Add Item","shortcut":"\#(shortcut)"\#(menuField)}]"#.utf8)) ?? .null]))
    }

    private func note(_ p: PluginRig) -> String? { p.coordinator.shortcutNote(for: commandID) }

    @Test func freeChordIsBound() async throws {
        let (p, center, window) = try rig()
        try enable(p, shortcut: "ctrl+alt+cmd+j")
        let command = try #require(center.registry.command(id: commandID))
        #expect(command.descriptor.shortcut != nil && command.descriptor.binding == .global)
        #expect(note(p) == nil)
        window.tick()
        center.palette.show(registry: center.registry, workspace: p.rig.workspace)
        center.palette.setQuery("Add Item")
        let shown = center.palette.rows.first { $0.id == commandID }?.shortcutText
        center.palette.hide()
        #expect(shown?.isEmpty == false, "\(String(describing: shown))")
        await p.coordinator.shutdown()
    }

    @Test func chordWithoutCommandControlOrOptionIsNotBound() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "j")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil, "a bare letter would fire while typing")
        #expect(note(p)?.contains("needs Command, Control or Option") == true, "\(String(describing: note(p)))")
        #expect(p.row(todo)?.notes.contains { $0.contains("needs Command, Control or Option") } == true)
        await p.coordinator.shutdown()
    }

    @Test func commandShiftChordIsBound() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "cmd+shift+j")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut != nil)
        #expect(note(p) == nil)
        await p.coordinator.shutdown()
    }

    @Test func requiredModifierRule() {
        func ok(_ text: String) -> Bool { PluginCoordinator.hasRequiredModifier(KeyChord.parse(text)!) }
        #expect(!ok("j") && !ok("shift+j") && !ok("tab") && !ok("shift+tab") && !ok("space"))
        #expect(ok("cmd+shift+j") && ok("ctrl+j") && ok("alt+j") && ok("primary+j") && ok("f5") && ok("shift+f12"))
    }

    @Test func changingOnePluginKeepsTheNotesOfAnotherWhoseIDExtendsIt() async throws {
        // `dev.a.b` starts with `dev.a.`: its note must survive `dev.a` being switched off.
        let (p, _, _) = try rig()
        let commands = JSONValue.object(["commands": JSONValue.parse(
            Data(#"[{"id":"x","title":"X","shortcut":"primary+shift+p"}]"#.utf8)) ?? .null])
        try p.fake("dev.a", contributes: commands)
        try p.fake("dev.a.b", contributes: commands)
        #expect(p.coordinator.shortcutNote(for: "dev.a.x") != nil)
        #expect(p.coordinator.shortcutNote(for: "dev.a.b.x") != nil)
        try p.coordinator.disable("dev.a")
        #expect(p.coordinator.shortcutNote(for: "dev.a.x") == nil)
        #expect(p.coordinator.shortcutNote(for: "dev.a.b.x") != nil, "the other plugin's note stays")
        #expect(p.row("dev.a.b")?.notes.contains { $0.contains("not bound") } == true)
        await p.coordinator.shutdown()
    }

    @Test func menuCommandWithFreeChordKeepsMenuBinding() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "ctrl+alt+cmd+j", menu: true)
        let d = try #require(center.registry.command(id: commandID)?.descriptor)
        #expect(d.binding == .menu && d.shortcut != nil)
        await p.coordinator.shutdown()
    }

    @Test func freeChordRunsTheCommand() async throws {
        let (p, center, window) = try rig()
        try enable(p, shortcut: "ctrl+alt+cmd+j")
        window.tick()
        window.typeKey("j", modifierFlags: [.control, .option, .command])
        let deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while p.coordinator.commandOutcomes.isEmpty, ContinuousClock().now < deadline {
            window.tick()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(p.coordinator.commandOutcomes.contains { $0.command == "add" }, "the key ran the command")
        _ = center
        await p.coordinator.shutdown()
    }

    @Test func builtinChordIsDropped() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "primary+shift+p")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil)
        let text = try #require(note(p))
        #expect(text.hasPrefix("Shortcut ") && text.contains("not bound: used by Command Palette"), "\(text)")
        #expect(p.row(todo)?.notes.contains(text) == true)
        await p.coordinator.shutdown()
    }

    @Test func userOverrideChordIsDropped() async throws {
        let (p, center, _) = try rig(keybindings: ["view.commandPalette": "ctrl+alt+cmd+k"])
        try enable(p, shortcut: "ctrl+alt+cmd+k")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil)
        #expect(note(p)?.contains("not bound: used by") == true, "\(String(describing: note(p)))")
        await p.coordinator.shutdown()
    }

    @Test func standardMenuChordIsDropped() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "cmd+q")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil)
        #expect(note(p)?.contains("used by Quit") == true, "\(String(describing: note(p)))")
        await p.coordinator.shutdown()
    }

    @Test func systemReservedChordIsDropped() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "cmd+space")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil)
        #expect(note(p)?.hasSuffix("used by the system") == true, "\(String(describing: note(p)))")
        await p.coordinator.shutdown()
    }

    @Test func codeViewSoftKeyAlsoDrops() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "primary+g")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil)
        #expect(note(p)?.contains("not bound: used by") == true, "\(String(describing: note(p)))")
        await p.coordinator.shutdown()
    }

    @Test func rebindingLaterLetsBuiltinWin() async throws {
        let (p, center, _) = try rig()
        try enable(p, shortcut: "ctrl+alt+cmd+j")
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut != nil)
        var s = p.rig.workspace.settings
        s.keybindings["view.commandPalette"] = "ctrl+alt+cmd+j"
        try p.rig.workspace.updateSettings(s)
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut == nil, "re-vetted after the rebind")
        #expect(center.registry.keymap.chord(for: "view.commandPalette") != nil)
        #expect(center.registry.keymap.chord(for: commandID) == nil)
        #expect(note(p)?.contains("used by Command Palette") == true, "\(String(describing: note(p)))")
        await p.coordinator.shutdown()
    }

    /// With a bound plugin key idle frames are free and typing holds the code guard.
    @Test func boundPluginKeyAddsNoFrameWork() async throws {
        final class Keeper { var rigs: [PluginRig] = [] }
        let keeper = Keeper()
        let perf = CodeModePerformanceTests()
        let (rig, window, _) = try await perf.rigged(.code1, install: { rig in
            let center = testCenter(for: rig.workspace)
            let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], center: center)
            keeper.rigs.append(p)
            _ = try? p.fake(self.todo, contributes: .object(["commands": JSONValue.parse(
                Data(#"[{"id":"add","title":"Add Item","shortcut":"ctrl+alt+cmd+j"}]"#.utf8)) ?? .null]))
        })
        let center = testCenter(for: rig.workspace)
        #expect(center.registry.command(id: commandID)?.descriptor.shortcut != nil, "the key is bound")
        for _ in 0..<5 { window.tick(); await Task.yield() }
        var reruns: [String: Int] = [:]
        for _ in 0..<20 {
            for (k, v) in perf.allProbes({ window.tick() }) { reruns[k, default: 0] += v }
            await Task.yield()
        }
        #expect(reruns.isEmpty, "idle ticks re-ran bodies: \(reruns)")
        for p in keeper.rigs { await p.coordinator.shutdown() }
        withExtendedLifetime((rig, window)) {}
        try await CodeModePerformanceTests().guardTyping(.code1, steady: CodeModePerformanceTests.steadyCode1, install: { rig in
            let center = testCenter(for: rig.workspace)
            let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], center: center)
            keeper.rigs.append(p)
            _ = try? p.fake(self.todo, contributes: .object(["commands": JSONValue.parse(
                Data(#"[{"id":"add","title":"Add Item","shortcut":"ctrl+alt+cmd+j"}]"#.utf8)) ?? .null]))
        })
        for p in keeper.rigs { await p.coordinator.shutdown() }
    }
}
