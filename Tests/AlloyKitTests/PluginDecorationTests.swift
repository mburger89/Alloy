import AlloyCore
@testable import AlloyKit
@testable import AlloyPlugins
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUICodeBuffer
import MetalUITesting
import Testing

@MainActor
func waitForDecorations(_ timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A Code-mode window with login.swift open (in one or two groups), and a plugin rig on the same workspace.
@MainActor
struct DecorationRig {
    static let text = (0..<8).map { "let line\($0) = \($0)\n" }.joined()
    let p: PluginRig
    let window: TestWindow
    let doc: EditorDocument
    let views: [OpenDocumentView]
    var workspace: Workspace { p.rig.workspace }
    var uri: String { p.rig.root.appendingPathComponent("login.swift").absoluteString }
    var otherURI: String { p.rig.root.appendingPathComponent("other.swift").absoluteString }

    static func make(groups: Int = 1) async throws -> DecorationRig {
        let rig = Rig()
        try text.write(to: rig.root.appendingPathComponent("login.swift"), atomically: true, encoding: .utf8)
        try "let other = 1\n".write(to: rig.root.appendingPathComponent("other.swift"), atomically: true, encoding: .utf8)
        var limits = PluginLimits()
        limits.messagesPerSecond = 100_000
        let p = PluginRig(rig: rig, pathDirs: [fakePluginDirectory, "/usr/bin", "/bin"], limits: limits)
        let workspace = rig.workspace
        await workspace.restoreUIState()
        workspace.setMode(.code)
        let g0 = workspace.codeLayout.focusedGroupID
        await workspace.open("login.swift", in: .group(g0))
        if groups > 1 { workspace.splitFocused(.horizontal) }
        workspace.focusGroup(id: g0)
        let window = try alloyWindow(workspace)
        let ids = workspace.codeLayout.tree.groupIDs
        try await window.runUntil { ids.allSatisfy { (try? window.element(identifier: "code-group-\($0.uuidString)")) != nil } }
        let doc = try #require(workspace.document("login.swift"))
        var views: [OpenDocumentView] = []
        for _ in 0..<2000 where views.count < groups {
            views = ids.compactMap { CodePanelStore.existingView(for: doc, in: .group($0)) }
            window.tick(); await Task.yield()
        }
        #expect(views.count == groups)
        return DecorationRig(p: p, window: window, doc: doc, views: views)
    }

    /// Enables a fake plugin whose script sends `items` for `uri` (at the document's version) once initialized, and starts it.
    @discardableResult
    func plugin(_ id: String, items: String, uri: String? = nil, version: Int? = nil, permissions: [String] = [],
                extra: [String: JSONValue] = [:]) async throws -> URL {
        let version = version ?? Int(doc.buffer.version)
        let params = JSONValue.parse(Data(#"{"uri":"\#(uri ?? self.uri)","version":\#(version),"items":\#(items)}"#.utf8)) ?? .null
        var script: [String: JSONValue] = ["afterInitialized": .array([.object(["method": .string("decorations/set"), "params": params])])]
        for (k, v) in extra { script[k] = v }
        let folder = try p.fake(id, script: .object(script), permissions: permissions)
        _ = await p.coordinator.activate(plugin: id, .command)
        return folder
    }

    /// Ticks until `condition` holds. A window that went idle without observing the code view (MetalUI's `RX-S` lost
    /// wake-up: a decoration change landing when no observation session covers the view dirties nothing, and a plain
    /// redraw does not rebuild a retained view) is nudged with a one-point resize, which rebuilds everything and
    /// re-arms it, whenever the condition has not held for a while. No sleeps decide the outcome; the deadline is a ceiling.
    /// TEMPORARY: the nudge masks a MetalUI bug (CodeDecorations writes lost under retained prepaint in an `.equatable()`
    /// group; it fails without the nudge, passes with METALUI_RETAINED_PREPAINT=0). Remove the resize once MetalUI fixes it.
    func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var idleRounds = 0
        var wide = false
        while clock.now < deadline {
            if condition() { return true }
            window.tick()
            idleRounds += 1
            if idleRounds % 15 == 0 {
                wide.toggle()
                window.resize(to: Size(width: Pixels(wide ? 1201 : 1200), height: Pixels(800)))
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The code views' frames (one per group), where the bars of their rows can be.
    func codeFrames() -> [Bounds<Pixels>] {
        workspace.codeLayout.tree.groupIDs.compactMap { (try? window.element(identifier: "code-group-\($0.uuidString)"))?.frame }
    }

    /// The 3 pt bars drawn in the code views' left half (y of each), top to bottom. Measured against the views' own frames,
    /// not a fixed x, so the sidebar's width does not matter.
    func bars() -> [Float] {
        let frames = codeFrames().map { f in (minX: Float(f.minX.value), midX: Float((f.minX.value + f.maxX.value) / 2), minY: Float(f.minY.value), maxY: Float(f.maxY.value)) }
        return window.allRects.filter { r in
            r.bounds.size.width == 3 && r.bounds.size.height > 4 && r.bounds.size.height <= 40
                && frames.contains { r.bounds.origin.x >= $0.minX && r.bounds.origin.x < $0.midX && r.bounds.origin.y >= $0.minY && r.bounds.origin.y < $0.maxY }
        }.map { $0.bounds.origin.y }.sorted()
    }
}

@MainActor
@Suite(.serialized) struct PluginDecorationTests {
    private let lint = "dev.example.lint"

    @Test func linesPaintUnderPluginOwner() async throws {
        let d = try await DecorationRig.make()
        try await d.plugin(lint, items: #"[{"line":2,"gutterBar":"info"},{"line":4,"background":"warning","message":{"text":"look here","role":"warning"}}]"#)
        #expect(await d.settle { d.views[0].pluginOwnerNames == ["plugin.\(lint)"] })
        #expect(d.views[0].decorations.virtualLineCount == 1, "one message row")
        #expect(await d.settle { d.bars().count == 2 }, "bar for the gutter bar line and the message row's bar: \(d.bars())")
        await d.p.coordinator.shutdown()
    }

    @Test func rangesUnderlineAndTint() async throws {
        let d = try await DecorationRig.make()
        try await d.plugin(lint, items: #"[{"start":4,"end":9,"underline":"error"},{"start":14,"end":18,"tint":"accent"}]"#)
        let view = d.views[0]
        let owner = OpenDocumentView.pluginOwner(lint)
        #expect(await d.settle { !view.decorations.highlights(in: 0..<100, layer: .diagnostics, owner: owner).isEmpty })
        let runs = view.decorations.highlights(in: 0..<100, layer: .diagnostics, owner: owner)
        let styled = runs.filter { $0.range.lowerBound == 4 || $0.range.lowerBound == 14 }
        #expect(styled.count == 2, "\(runs.map(\.range))")
        let under = try #require(styled.first { $0.range.lowerBound == 4 })
        #expect(view.decorations.style(under.style).underline != nil)
        let tint = try #require(styled.first { $0.range.lowerBound == 14 })
        #expect(view.decorations.style(tint.style).background != nil)
        await d.p.coordinator.shutdown()
    }

    @Test func diffAndDiagnosticsWinASharedRow() async throws {
        let d = try await DecorationRig.make()
        let view = d.views[0]
        // An Alloy owner (the default one: the diff's and the diagnostics') underlines bytes 0..<5 and bars row 1.
        let red = Color(red: 1, green: 0, blue: 0)
        let version = d.doc.buffer.version
        let style = view.decorations.register(CodeStyle(underline: CodeUnderline(.line(.solid), color: red)))
        view.decorations.setHighlights([CodeStyleRun(range: 0..<5, style: style)], in: 0..<(1 << 40), layer: .diagnostics, asOf: version)
        view.decorations.setLineDecorations([CodeLineDecoration(lines: 1..<2, gutterBar: red)], asOf: version)
        try #require(await d.settle { d.bars().count == 1 })
        let alone = d.bars()
        try await d.plugin(lint, items: #"[{"start":0,"end":5,"underline":"info"},{"line":1,"gutterBar":"info"}]"#)
        #expect(await d.settle { view.pluginOwnerNames == ["plugin.\(lint)"] })
        for _ in 0..<5 { d.window.tick(); await Task.yield() }
        let painted = view.decorations.paintedRuns(in: 0..<5)
        #expect(painted.first?.style.underline?.color == red, "the default owner's underline wins the shared bytes")
        #expect(await d.settle { d.bars() == alone }, "one bar column on the shared row: \(alone) \(d.bars())")
        await d.p.coordinator.shutdown()
    }

    @Test func twoViewsOfOneDocumentBothPaint() async throws {
        let d = try await DecorationRig.make(groups: 2)
        try await d.plugin(lint, items: #"[{"line":1,"background":"info","message":{"text":"hi","role":"info"}}]"#)
        #expect(await d.settle { d.views.allSatisfy { $0.pluginOwnerNames == ["plugin.\(lint)"] } })
        #expect(d.views.allSatisfy { $0.decorations.virtualLineCount == 1 })
        await d.p.coordinator.shutdown()
    }

    @Test func unopenedUriIsDropped() async throws {
        let d = try await DecorationRig.make()
        let other = JSONValue.parse(Data(#"{"uri":"\#(d.otherURI)","version":1,"items":[{"line":0,"background":"info"}]}"#.utf8)) ?? .null
        let mine = JSONValue.parse(Data(#"{"uri":"\#(d.uri)","version":\#(d.doc.buffer.version),"items":[{"line":0,"background":"info"}]}"#.utf8)) ?? .null
        let outside = JSONValue.parse(Data(#"{"uri":"file:///elsewhere/x.swift","version":1,"items":[{"line":0,"background":"info"}]}"#.utf8)) ?? .null
        let send: [JSONValue] = [other, outside, mine].map { .object(["method": .string("decorations/set"), "params": $0]) }
        _ = try d.p.fake(lint, script: .object(["afterInitialized": .array(send)]))
        _ = await d.p.coordinator.activate(plugin: lint, .command)
        #expect(await d.settle { d.views[0].pluginOwnerNames == ["plugin.\(lint)"] })
        #expect(d.p.coordinator.decorations.snapshots(for: "other.swift").isEmpty)
        #expect(d.p.coordinator.decorations.applyCount == 1, "only the open document's set was applied")
        await d.p.coordinator.shutdown()
    }

    @Test func closeAndStopRemoveThem() async throws {
        let d = try await DecorationRig.make()
        try await d.plugin(lint, items: #"[{"line":1,"background":"info","message":{"text":"hi","role":"info"}}]"#)
        let view = d.views[0]
        #expect(await d.settle { view.pluginOwnerNames == ["plugin.\(lint)"] })
        // Stopping the plugin (switching it off) removes its owner from every view.
        try d.p.coordinator.disable(lint)
        #expect(await d.settle { view.pluginOwnerNames.isEmpty && view.decorations.virtualLineCount == 0 })
        #expect(d.p.coordinator.decorations.snapshots(for: "login.swift").isEmpty)
        // Closing the document drops what was set for it.
        try d.p.coordinator.enable(lint)
        _ = await d.p.coordinator.activate(plugin: lint, .command)
        #expect(await d.settle { !d.p.coordinator.decorations.snapshots(for: "login.swift").isEmpty })
        await d.workspace.close("login.swift", in: .group(d.workspace.codeLayout.focusedGroupID))
        #expect(await d.settle { d.p.coordinator.decorations.snapshots(for: "login.swift").isEmpty })
        await d.p.coordinator.shutdown()
    }

    @Test func editsShiftLineDecorations() async throws {
        let d = try await DecorationRig.make()
        try await d.plugin(lint, items: #"[{"line":1,"gutterBar":"info"},{"line":3,"gutterBar":"info"}]"#)
        try #require(await d.settle { d.bars().count == 2 })
        let before = d.bars()
        try #require(before.count == 2)
        let twoRows = before[1] - before[0]
        d.doc.buffer.replace(0..<0, with: "a\nb\n")
        try #require(await d.settle { d.bars().count == 2 && (d.bars().first ?? 0) > before[0] })
        let after = d.bars()
        try #require(after.count == 2)
        #expect(abs(after[0] - (before[0] + twoRows / 2 * 2)) < 0.5, "bar moved two rows: \(before) -> \(after)")
        await d.p.coordinator.shutdown()
    }

    @Test func aReopenedDocumentPaintsTheSameSetAgain() async throws {
        let d = try await DecorationRig.make()
        let items = #"[{"line":1,"background":"info","message":{"text":"hi","role":"info"}}]"#
        let params = JSONValue.parse(Data(#"{"uri":"\#(d.uri)","version":\#(d.doc.buffer.version),"items":\#(items)}"#.utf8)) ?? .null
        let resend = JSONValue.object(["method": .string("decorations/set"), "params": params])
        try await d.plugin(lint, items: items, permissions: ["project.read"], extra: ["onReceive": .object(["document/opened": .array([resend])])])
        #expect(await d.settle { !d.p.coordinator.decorations.snapshots(for: "login.swift").isEmpty })
        let group = d.workspace.codeLayout.focusedGroupID
        await d.workspace.close("login.swift", in: .group(group))
        #expect(await d.settle { d.p.coordinator.decorations.snapshots(for: "login.swift").isEmpty })
        let applied = d.p.coordinator.decorations.applyCount
        await d.workspace.open("login.swift", in: .group(group))
        // The plugin hears document/opened and sends the identical set; the host must not take it for a repeat.
        #expect(await d.settle { !d.p.coordinator.decorations.snapshots(for: "login.swift").isEmpty })
        #expect(d.p.coordinator.decorations.applyCount > applied)
        await d.p.coordinator.shutdown()
    }

    @Test func hostMemoryDoesNotGrowForUrisThatAreNotOpen() async throws {
        let d = try await DecorationRig.make()
        var send: [JSONValue] = (0..<30).map { i in
            let uri = d.p.rig.root.appendingPathComponent("gone\(i).swift").absoluteString
            return .object(["method": .string("decorations/set"),
                            "params": JSONValue.parse(Data(#"{"uri":"\#(uri)","version":1,"items":[{"line":0,"background":"info"}]}"#.utf8)) ?? .null])
        }
        send.append(.object(["method": .string("decorations/set"),
                             "params": JSONValue.parse(Data(#"{"uri":"\#(d.uri)","version":\#(d.doc.buffer.version),"items":[{"line":0,"background":"info"}]}"#.utf8)) ?? .null]))
        _ = try d.p.fake(lint, script: .object(["afterInitialized": .array(send)]))
        _ = await d.p.coordinator.activate(plugin: lint, .command)
        #expect(await d.settle { d.p.coordinator.decorations.applyCount == 1 })
        let host = try #require(d.p.coordinator.host)
        // Only the open document's set stays remembered; each dropped uri is forgotten again.
        var remembered = await host.decorationMemoryCount
        for _ in 0..<500 where remembered != 1 {
            try await Task.sleep(for: .milliseconds(20))
            remembered = await host.decorationMemoryCount
        }
        #expect(remembered == 1, "\(remembered)")
        await d.p.coordinator.shutdown()
    }

    @Test func identicalSetsApplyOnce() async throws {
        let d = try await DecorationRig.make()
        let items = #"[{"line":1,"background":"info"}]"#
        let params = JSONValue.parse(Data(#"{"uri":"\#(d.uri)","version":\#(d.doc.buffer.version),"items":\#(items)}"#.utf8)) ?? .null
        let script: [String: JSONValue] = ["flood": .object(["method": .string("decorations/set"), "params": params,
                                                             "perSecond": .number(200), "seconds": .number(1)])]
        _ = try d.p.fake(lint, script: .object(script))
        _ = await d.p.coordinator.activate(plugin: lint, .command)
        #expect(await d.settle { d.p.coordinator.decorations.applyCount >= 1 })
        try? await Task.sleep(for: .milliseconds(1300))
        #expect(d.p.coordinator.decorations.applyCount == 1, "\(d.p.coordinator.decorations.applyCount)")
        await d.p.coordinator.shutdown()
    }
}
