import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyRPC
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
private func waitFor(_ timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

@MainActor
@Suite(.serialized) struct PluginCommandTests {
    private let todo = "dev.example.todo"

    private func rig() -> (PluginRig, CommandCenter) {
        let workspaceRig = Rig()
        let center = testCenter(for: workspaceRig.workspace)
        let p = PluginRig(rig: workspaceRig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], registry: center.registry, center: center)
        return (p, center)
    }

    private func commands(_ list: String) -> JSONValue {
        .object(["commands": JSONValue.parse(Data(list.utf8)) ?? .null])
    }

    private func todoCommands(_ extra: String = "") -> JSONValue {
        commands(#"[{"id":"add","title":"Add Item","menu":"plugins"\#(extra)}]"#)
    }

    private func paletteTitles(_ center: CommandCenter, _ workspace: Workspace) -> [String] {
        center.palette.show(registry: center.registry, workspace: workspace)
        center.palette.setQuery("Add Item")
        defer { center.palette.hide() }
        return center.palette.rows.map(\.displayTitle)
    }

    private func methods(_ folder: URL) -> [String] { log(folder).compactMap { $0["method"]?.stringValue } }

    private func log(_ folder: URL) -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    @Test func enableRegistersUnderPluginSource() async throws {
        let (p, center) = rig()
        try p.fake(todo, contributes: todoCommands(), enable: false, name: "Todo")
        #expect(center.registry.command(id: "\(todo).add") == nil, "not before it is enabled")
        try p.coordinator.enable(todo)
        let command = try #require(center.registry.command(id: "\(todo).add"))
        #expect(command.descriptor.source == .plugin(id: todo))
        #expect(command.descriptor.category.name == "Todo")
        let titles = paletteTitles(center, p.rig.workspace)
        #expect(titles.contains("Todo: Add Item"), "\(titles.filter { $0.contains("Add") })")
        await p.coordinator.shutdown()
    }

    @Test func pluginsMenuItemAppearsForMenuCommands() async throws {
        let (p, center) = rig()
        let window = try alloyWindow(p.rig.workspace)
        try p.fake(todo, contributes: commands(#"[{"id":"add","title":"Add Item","menu":"plugins"},{"id":"quiet","title":"Quiet"}]"#))
        window.tick()
        let command = try #require(center.registry.command(id: "\(todo).add"))
        #expect(command.descriptor.menu == .plugins && command.descriptor.binding == .menu)
        let quiet = try #require(center.registry.command(id: "\(todo).quiet"))
        #expect(quiet.descriptor.menu == nil && quiet.descriptor.binding == CommandBinding.none)
        func ids(_ items: [PlatformMenuItem]) -> [String] {
            items.flatMap { item -> [String] in
                if case .submenu(let sub) = item.kind { return ids(sub) }
                return [item.accessibilityIdentifier ?? ""]
            }
        }
        let menu = try #require(window.testApp.menuBar.first { $0.title == "Plugins" })
        #expect(ids(menu.items).contains("menu-\(todo).add"))
        #expect(!ids(menu.items).contains("menu-\(todo).quiet"))
        await p.coordinator.shutdown()
    }

    @Test func disableUnregisters() async throws {
        let (p, center) = rig()
        try p.fake(todo, contributes: todoCommands())
        #expect(center.registry.command(id: "\(todo).add") != nil)
        try p.coordinator.disable(todo)
        #expect(center.registry.command(id: "\(todo).add") == nil)
        #expect(!center.registry.commands.contains { $0.descriptor.source == .plugin(id: todo) })
        await p.coordinator.shutdown()
    }

    @Test func autoDisableUnregisters() async throws {
        let workspaceRig = Rig()
        let center = testCenter(for: workspaceRig.workspace)
        var limits = PluginLimits()
        limits.crashesToDisable = 1
        let p = PluginRig(rig: workspaceRig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], limits: limits, registry: center.registry)
        try p.fake(todo, script: .object(["exitOnInitialize": .bool(true)]), contributes: todoCommands())
        #expect(center.registry.command(id: "\(todo).add") != nil)
        _ = await p.coordinator.activate(plugin: todo, .command)
        #expect(await waitFor { p.row(todo)?.status == .disabledAfterCrashes })
        #expect(center.registry.command(id: "\(todo).add") == nil)
        await p.coordinator.shutdown()
    }

    @Test func runStartsThePluginAndExecutes() async throws {
        let (p, center) = rig()
        let folder = try p.fake(todo, contributes: todoCommands())
        #expect(methods(folder).isEmpty, "enabling alone starts nothing")
        #expect(center.registry.run(id: "\(todo).add"))
        #expect(await waitFor { methods(folder).contains("commands/execute") })
        let names = methods(folder)
        #expect(names.first == "initialize")
        let execute = try #require(log(folder).first { $0["method"]?.stringValue == "commands/execute" })
        #expect(execute["params"]?["command"]?.stringValue == "add")
        await p.coordinator.shutdown()
    }

    @Test func whenCodeModeDisablesInChat() async throws {
        let (p, center) = rig()
        try p.fake(todo, contributes: commands(#"[{"id":"add","title":"Add","when":"codeMode"},{"id":"edit","title":"Edit","when":"editorFocused"}]"#))
        let add = try #require(center.registry.command(id: "\(todo).add"))
        let edit = try #require(center.registry.command(id: "\(todo).edit"))
        #expect(!add.isEnabled() && !edit.isEnabled(), "chat mode")
        p.rig.workspace.setMode(.code)
        #expect(add.isEnabled())
        await p.coordinator.shutdown()
    }

    @Test func whenLanguageFollowsActiveDocument() async throws {
        let (p, center) = rig()
        try p.fake(todo, contributes: commands(#"[{"id":"fmt","title":"Format","when":"language:swift"}]"#))
        let command = try #require(center.registry.command(id: "\(todo).fmt"))
        let root = p.rig.workspace.projectRoot
        try "let x = 1\n".write(to: root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        try "hello\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        p.rig.workspace.setMode(.code)
        await p.rig.workspace.open("login.swift")
        #expect(command.isEnabled())
        await p.rig.workspace.open("notes.txt")
        #expect(!command.isEnabled())
        await p.coordinator.shutdown()
    }

    @Test func clashingShortcutIsNotBoundAndNoted() async throws {
        let (p, center) = rig()
        try p.fake(todo, contributes: todoCommands(#","shortcut":"cmd+shift+p""#))
        let command = try #require(center.registry.command(id: "\(todo).add"))
        #expect(command.descriptor.shortcut == nil)
        let note = try #require(p.row(todo)?.notes.first)
        #expect(note.hasPrefix("Shortcut ") && note.contains(" not bound: used by "), "\(note)")
        await p.coordinator.shutdown()
    }

    @Test func duplicateIdIsNotedOnTheRow() async throws {
        let (p, center) = rig()
        center.registry.register(CommandDescriptor(id: "\(todo).add", title: "Taken", category: .app), run: {})
        try p.fake(todo, contributes: todoCommands())
        #expect(p.row(todo)?.notes.contains("Command \(todo).add clashes with an existing command") == true, "\(String(describing: p.row(todo)?.notes))")
        #expect(center.registry.command(id: "\(todo).add")?.descriptor.title == "Taken")
        await p.coordinator.shutdown()
    }

    @Test func disableDuringCommandEndsQuietly() async throws {
        let (p, center) = rig()
        let folder = try p.fake(todo, script: .object(["replies": .object(["commands/execute": .array([.object(["hold": .bool(true)])])])]),
                                contributes: todoCommands())
        #expect(center.registry.run(id: "\(todo).add"))
        #expect(await waitFor { methods(folder).contains("commands/execute") })
        try p.coordinator.disable(todo)
        #expect(await waitFor { !p.coordinator.commandOutcomes.isEmpty })
        let outcome = try #require(p.coordinator.commandOutcomes.first)
        #expect(outcome.code == JSONRPCError.requestCancelled, "\(String(describing: outcome.code))")
        #expect(p.coordinator.commandErrors[todo] == nil, "nothing reaches the log")
        #expect(p.rig.workspace.notices.isEmpty)
        #expect(!p.coordinator.hasHost || p.row(todo)?.status != .crashed(1))
        await p.coordinator.shutdown()
    }

    // MARK: Guard

    @Test func registeringPluginCommandsCostsNoScreenRerun() async throws {
        let (p, _) = rig()
        let window = try alloyWindow(p.rig.workspace)
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
        _ = await idle()
        let before = BodyProbe.counts["AlloyScreen", default: 0]
        let list = (1...5).map { #"{"id":"c\#($0)","title":"Command \#($0)"}"# }.joined(separator: ",")
        try p.fake(todo, contributes: commands("[\(list)]"))
        _ = await idle()
        #expect(BodyProbe.counts["AlloyScreen", default: 0] == before, "AlloyScreen reran")
        window.resetFrameWork()
        for _ in 0..<5 { window.tick() }
        #expect(window.frameWork.reduce(0) { $0 + $1.elementRequests } == 0)
        await p.coordinator.shutdown()
    }
}
