import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// A Code-mode window with a plugin that has one panel ("main", titled "Todo"); the fake renders `tree` when the panel opens.
@MainActor
struct PanelRig {
    static let id = "dev.example.todo"
    static let tabID = "code-sidebar-tab-plugin-\(id)-main"
    static let tree = """
    {"type":"vstack","key":"root","children":[
      {"type":"text","key":"title","text":"Todos"},
      {"type":"button","key":"add","title":"Add"},
      {"type":"toggle","key":"done","title":"Done","isOn":false},
      {"type":"picker","key":"mode","title":"Mode","options":[{"value":"all","title":"All"},{"value":"open","title":"Open"}],"selection":"all"},
      {"type":"textField","key":"name","placeholder":"Name","text":""},
      {"type":"divider","key":"rule"}
    ]}
    """
    let p: PluginRig
    let window: TestWindow
    let folder: URL
    var workspace: Workspace { p.rig.workspace }

    static func make(tree: String = tree, script extra: [String: JSONValue] = [:], limits: PluginLimits = PluginLimits(),
                     enabled: Bool = true) async throws -> PanelRig {
        let rig = Rig()
        var limits = limits
        limits.messagesPerSecond = 100_000
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], limits: limits)
        let render = JSONValue.parse(Data(#"{"panelId":"main","tree":\#(tree)}"#.utf8)) ?? .null
        var script: [String: JSONValue] = ["onReceive": .object(["panel/opened": .array([
            .object(["method": .string("panel/render"), "params": render])])])]
        for (k, v) in extra { script[k] = v }
        let folder = try p.fake(id, script: .object(script), activation: ["onPanel:main"],
                                contributes: .object(["panels": .array([.object(["id": .string("main"), "title": .string("Todo")])])]),
                                enable: enabled)
        await rig.workspace.restoreUIState()
        rig.workspace.setMode(.code)
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<6 { window.tick() }
        return PanelRig(p: p, window: window, folder: folder)
    }

    func exists(_ id: String) -> Bool { (try? window.element(identifier: id)) != nil }
    func element(_ widget: String) throws -> TestElement { try window.element(identifier: "plugin.panel.\(Self.id).\(widget)") }

    func settle(_ condition: @MainActor () -> Bool, timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            window.tick()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func selectTab() async throws {
        try window.click(window.element(identifier: Self.tabID))
        for _ in 0..<4 { window.tick() }
    }

    func log() -> [JSONValue] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("log.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { JSONValue.parse(Data($0.utf8)) }
    }

    func methods() -> [String] { log().compactMap { $0["method"]?.stringValue } }
    func events(_ kind: String) -> [JSONValue] {
        log().filter { $0["method"]?.stringValue == "panel/event" && $0["params"]?["kind"]?.stringValue == kind }.compactMap { $0["params"] }
    }

    /// The value of the first `changed` event for `key`.
    func changed(_ key: String) -> JSONValue? {
        for event in events("changed") where event["key"]?.stringValue == key { return event["value"] }
        return nil
    }

    /// Selects the tab and waits until the tree is on screen.
    func open() async throws {
        try await selectTab()
        #expect(await settle { exists("plugin.panel.\(Self.id).title") }, "tree rendered")
    }
}

@MainActor
@Suite(.serialized) struct PluginPanelTests {
    @Test func tabAppearsOnEnableAndGoesOnDisable() async throws {
        let r = try await PanelRig.make(enabled: false)
        #expect(!r.exists(PanelRig.tabID), "a plugin that is not enabled has no tab")
        try r.p.coordinator.enable(PanelRig.id)
        #expect(await r.settle { r.exists(PanelRig.tabID) })
        let tab = try r.window.element(identifier: PanelRig.tabID)
        #expect(tab.label == "Todo")
        try r.p.coordinator.disable(PanelRig.id)
        #expect(await r.settle { !r.exists(PanelRig.tabID) })
        await r.p.coordinator.shutdown()
    }

    @Test func selectingTabStartsPluginAndRenders() async throws {
        let r = try await PanelRig.make()
        #expect(r.methods().isEmpty, "no process before the tab is selected")
        try await r.open()
        #expect(r.workspace.codeLayout.pluginPanel == "\(PanelRig.id)/main")
        #expect(try r.window.element(identifier: PanelRig.tabID).isSelected)
        #expect(await r.settle { r.methods().contains("panel/opened") })
        let opened = try #require(r.log().first { $0["method"]?.stringValue == "panel/opened" })
        #expect(opened["params"]?["panelId"]?.stringValue == "main")
        let title = try r.element("title")
        #expect((title.value ?? title.label) == "Todos")
        _ = try r.window.element(identifier: "plugin.panel.\(PanelRig.id).main")
        await r.p.coordinator.shutdown()
    }

    @Test func buttonSendsClick() async throws {
        let r = try await PanelRig.make()
        try await r.open()
        try r.window.click(r.element("add"))
        #expect(await r.settle { !r.events("click").isEmpty })
        let click = try #require(r.events("click").first)
        #expect(click["panelId"]?.stringValue == "main" && click["key"]?.stringValue == "add")
        await r.p.coordinator.shutdown()
    }

    @Test func toggleAndPickerSendChanged() async throws {
        let r = try await PanelRig.make()
        try await r.open()
        try r.window.click(r.element("done"))
        #expect(await r.settle { r.events("changed").contains { $0["key"]?.stringValue == "done" } })
        #expect(r.changed("done")?.boolValue == true)
        let picker = try r.element("mode")
        let open = try #require(descendants(of: picker, in: r.window).first { $0.label == "Open" })
        try r.window.click(open)
        #expect(await r.settle { r.changed("mode") != nil })
        #expect(r.changed("mode")?.stringValue == "open")
        await r.p.coordinator.shutdown()
    }

    @Test func textFieldSendsChangedOnceAfterTypingStops() async throws {
        let r = try await PanelRig.make()
        try await r.open()
        let field = try r.element("name")
        try r.window.click(field)
        for ch in "hello" {
            r.window.typeText(String(ch))
            r.window.tick()
            try await Task.sleep(for: .milliseconds(100))
        }
        let lastEdit = ContinuousClock().now
        let early = r.events("changed").filter { $0["key"]?.stringValue == "name" }
        #expect(early.isEmpty, "nothing during typing")
        #expect(await r.settle { r.events("changed").contains { $0["key"]?.stringValue == "name" } })
        let waited = ContinuousClock().now - lastEdit
        #expect(waited >= .milliseconds(150), "sent after the debounce, not at the last key: \(waited)")
        try await Task.sleep(for: .milliseconds(600))
        let changes = r.events("changed").filter { $0["key"]?.stringValue == "name" }
        #expect(changes.count == 1)
        #expect(changes.first?["value"]?.stringValue == "hello")
        await r.p.coordinator.shutdown()
    }

    @Test func returnSendsSubmit() async throws {
        let r = try await PanelRig.make()
        try await r.open()
        try r.window.click(r.element("name"))
        r.window.typeText("go")
        r.window.tick()
        r.window.typeKey(.return)
        r.window.tick()
        #expect(await r.settle { !r.events("submit").isEmpty })
        let submit = try #require(r.events("submit").first)
        #expect(submit["key"]?.stringValue == "name" && submit["value"]?.stringValue == "go")
        await r.p.coordinator.shutdown()
    }

    @Test func rerenderKeepsFocusedFieldText() async throws {
        // Once the plugin hears the field's `changed`, it renders again with other text for the field and the title.
        let updated = """
        {"type":"vstack","key":"root","children":[{"type":"text","key":"title","text":"Updated"},
          {"type":"textField","key":"name","placeholder":"Name","text":"server"}]}
        """
        let render = JSONValue.parse(Data(#"{"panelId":"main","tree":\#(updated)}"#.utf8)) ?? .null
        let r = try await PanelRig.make(script: ["onReceive": .object([
            "panel/opened": .array([.object(["method": .string("panel/render"), "params":
                JSONValue.parse(Data(#"{"panelId":"main","tree":\#(PanelRig.tree)}"#.utf8)) ?? .null])]),
            "panel/event": .array([.object(["method": .string("panel/render"), "params": render])]),
        ])])
        try await r.open()
        try r.window.click(r.element("name"))
        r.window.typeText("abc")
        r.window.tick()
        #expect(await r.settle { ((try? r.element("title"))?.value ?? (try? r.element("title"))?.label) == "Updated" }, "re-rendered")
        for _ in 0..<4 { r.window.tick() }
        let field = try r.element("name")
        #expect((field.value ?? "") == "abc", "the focused field keeps what was typed: \(field.value ?? "nil")")
        await r.p.coordinator.shutdown()
    }

    @Test func deselectSendsClosedAndRemovesElement() async throws {
        let r = try await PanelRig.make()
        try await r.open()
        try r.window.click(r.window.element(identifier: "code-sidebar-tab-files"))
        for _ in 0..<4 { r.window.tick() }
        #expect(r.workspace.codeLayout.pluginPanel == nil)
        #expect(!r.exists("plugin.panel.\(PanelRig.id).title"), "no element for an unselected panel")
        #expect(await r.settle { r.methods().contains("panel/closed") })
        let closed = try #require(r.log().first { $0["method"]?.stringValue == "panel/closed" })
        #expect(closed["params"]?["panelId"]?.stringValue == "main")
        await r.p.coordinator.shutdown()
    }

    @Test func restartWhileVisibleKeepsFocusedText() async throws {
        // The plugin dies on the message after the first panel/opened (initialize, initialized, workspace/opened, panel/opened = 4).
        let r = try await PanelRig.make(script: ["crashAfter": .number(5)], limits: {
            var l = PluginLimits(); l.backoff = [0.2]; return l
        }())
        try await r.open()
        try r.window.click(r.element("name"))
        r.window.typeText("keep")
        r.window.tick()
        let model = r.p.coordinator.panels.model(PanelRig.id, "main")
        // Typing's debounced `changed` is the fifth message and ends the process.
        #expect(await r.settle { model.stopped }, "the stopped label appears")
        #expect(await r.settle { r.exists("plugin.panel.\(PanelRig.id).main.stopped") })
        let field = try r.element("name")
        #expect((field.value ?? "") == "keep", "the field keeps its text while the plugin is down")
        // After the restart the panel is opened again and renders once more.
        #expect(await r.settle { r.methods().filter { $0 == "panel/opened" }.count >= 2 && !model.stopped })
        for _ in 0..<6 { r.window.tick() }
        #expect(!r.exists("plugin.panel.\(PanelRig.id).main.stopped"))
        let after = try r.element("name")
        #expect((after.value ?? "") == "keep", "still there after the re-render")
        await r.p.coordinator.shutdown()
    }

    @Test func rejectedTreeIsLoggedNotShown() async throws {
        let bad = #"{"type":"vstack","key":"root","children":[{"type":"text","key":"a","text":"1"},{"type":"text","key":"a","text":"2"}]}"#
        let r = try await PanelRig.make(tree: bad)
        try await r.selectTab()
        #expect(await r.settle { !(r.p.coordinator.commandErrors[PanelRig.id] ?? []).isEmpty })
        #expect(r.p.coordinator.commandErrors[PanelRig.id]?.first?.contains("duplicate key") == true)
        #expect(!r.exists("plugin.panel.\(PanelRig.id).a"))
        await r.p.coordinator.shutdown()
    }
}
