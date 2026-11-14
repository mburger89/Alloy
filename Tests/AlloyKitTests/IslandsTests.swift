import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct IslandsTests {
    private final class Holder { var controller: ThemeController? }

    private struct Setup {
        let rig: Rig
        let window: TestWindow
        let controller: ThemeController
    }

    private func setup(gutter: Double? = nil, cornerRadius: Double? = nil, branch: String? = nil) throws -> Setup {
        let rig = Rig(branch: branch)
        var s = rig.workspace.settings
        s.appearance = AppearanceOverrides(gutter: gutter, cornerRadius: cornerRadius)
        try rig.workspace.updateSettings(s)
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        holder.controller = controller
        for _ in 0..<4 { window.tick() }
        return Setup(rig: rig, window: window, controller: controller)
    }

    private func frame(_ window: TestWindow, _ id: String) throws -> Bounds<Pixels> { try window.element(identifier: id).frame }

    /// A hidden-title-bar window whose platform reports its insets only once the metrics are accepted and, later, a wider
    /// cluster. The island and the title text must not move while the report fits the reserve (a moved rect invalidates
    /// the island backdrop's paint key and suspends prepaint replay window-wide); a wider cluster still pushes the text.
    @Test func titleIslandRectIsStableFromFirstLayout() throws {
        let rig = Rig()
        let style = AppearanceStyle.defaults
        let reserve = Float(style.titleControlsLeading + style.titleLightsWidth)
        let options = HeadlessPlatformWindow.Options(hiddenTitleBarInsets: Edges(top: Pixels(32), right: Pixels(0), bottom: Pixels(0), left: Pixels(1)))
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800)), options: options) { rootView(workspace: rig.workspace) }
        window.installAlloyMenu(rig.workspace)
        window.window.windowStyle = .hiddenTitleBar
        func rects() throws -> [Bounds<Pixels>] {
            try ["island-title", "title-project", "title-new-session", "title-settings"].map { try window.element(identifier: $0).frame }
        }
        func same(_ a: Bounds<Pixels>, _ b: Bounds<Pixels>) -> Bool {
            a.minX == b.minX && a.minY == b.minY && a.maxX == b.maxX && a.maxY == b.maxY
        }
        window.tick()
        let first = try rects()
        // The metrics are accepted a frame after the build that sends them: the insets arrive at left = reserve.
        for n in 1...10 {
            window.tick()
            for (a, b) in zip(first, try rects()) { #expect(same(a, b), "frame \(n) moved \(a) to \(b)") }
        }
        // A narrower report than the reserve changes nothing either.
        window.platformWindow.titleBarInsets = Edges(top: Pixels(32), right: Pixels(0), bottom: Pixels(0), left: Pixels(reserve - 20))
        window.window.setNeedsRedraw(); window.tick()
        for (a, b) in zip(first, try rects()) { #expect(same(a, b), "narrow report moved \(a) to \(b)") }
        // A wider cluster (a bigger lights set) still clears the text.
        window.platformWindow.titleBarInsets = Edges(top: Pixels(32), right: Pixels(0), bottom: Pixels(0), left: Pixels(reserve + 20))
        window.window.setNeedsRedraw(); window.tick()
        let wide = try rects()
        #expect(wide[1].minX.value >= first[1].minX.value + 20 - 0.5, "text \(first[1].minX.value) -> \(wide[1].minX.value)")
    }

    @Test func islandsAreInsetByTheGutter() throws {
        let t = try setup(gutter: 6)
        let sidebar = try frame(t.window, "island-sidebar"), chat = try frame(t.window, "island-chat")
        let files = try frame(t.window, "island-files"), title = try frame(t.window, "island-title")
        #expect(abs(sidebar.minX.value - 6) < 0.5)
        #expect(abs(chat.minX.value - sidebar.maxX.value - 6) < 1.5)
        #expect(abs(files.minX.value - chat.maxX.value - 6) < 1.5)
        #expect(abs(files.maxX.value - (1200 - 6)) < 0.5)
        #expect(abs(sidebar.maxY.value - (800 - 6)) < 0.5)
        #expect(abs(title.minY.value - 6) < 0.5)
        #expect(abs((title.maxY.value - title.minY.value) - 38) < 0.5)
        #expect(abs(sidebar.minY.value - (title.maxY.value + 6)) < 0.5)
    }

    @Test func gutterChangeRelayoutsWithoutRebuild() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: holder.controller)
        }
        window.installAlloyMenu(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        holder.controller = controller
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        let id = try #require(rig.workspace.activeTab.flatMap { rig.workspace.document($0)?.id })
        try window.focus(window.element(identifier: "composer"))
        for _ in 0..<4 { window.tick(); await Task.yield() }
        let before = try frame(window, "island-chat")
        #expect(abs(before.minX.value - (try frame(window, "island-sidebar").maxX.value) - 6) < 1.5)
        var s = rig.workspace.settings
        s.appearance = AppearanceOverrides(gutter: 12)
        try rig.workspace.updateSettings(s)
        for _ in 0..<6 { window.tick(); await Task.yield() }
        let sidebar = try frame(window, "island-sidebar")
        #expect(abs(sidebar.minX.value - 12) < 0.5)
        #expect(abs(try frame(window, "island-chat").minX.value - sidebar.maxX.value - 12) < 1.5)
        #expect(rig.workspace.activeTab.flatMap { rig.workspace.document($0)?.id } == id)
        #expect(try window.element(identifier: "composer").isFocused)
    }

    @Test func titleIslandButtonsAct() async throws {
        let t = try setup()
        try t.window.click(t.window.element(identifier: "title-new-session"))
        try await t.window.runUntil { t.rig.workspace.selectedSessionID != nil }
        #expect(t.rig.workspace.sessions.count == 1)
        try t.window.click(t.window.element(identifier: "title-quick-open"))
        for _ in 0..<4 { t.window.tick(); await Task.yield() }
        #expect((try? t.window.element(identifier: "quick-open-field")) != nil)
        try t.window.click(t.window.element(identifier: "title-settings"))
        for _ in 0..<4 { t.window.tick(); await Task.yield() }
        #expect((try? t.window.element(identifier: "settings-view")) != nil)
    }

    @Test func titleShowsProjectAndBranch() throws {
        let plain = try setup()
        #expect(try plain.window.element(identifier: "title-project").label == plain.rig.root.lastPathComponent
                || plain.window.element(identifier: "title-project").value == plain.rig.root.lastPathComponent)
        #expect((try? plain.window.element(identifier: "title-branch")) == nil)
        let git = try setup(branch: "feat/x")
        let branch = try git.window.element(identifier: "title-branch")
        #expect((branch.label ?? branch.value ?? "").contains("feat/x"))
    }

    @Test func appearanceOnlySettingsChangeRefreshesTheStyle() throws {
        let t = try setup()
        #expect(t.controller.style.gutter == AppearanceStyle.defaults.gutter)
        var s = t.rig.workspace.settings
        s.appearance = AppearanceOverrides(gutter: 12)
        try t.rig.workspace.updateSettings(s)
        #expect(t.controller.style.gutter == 12)
    }
}

extension IslandsTests {
    /// The Settings overlay keeps the island radius, opens, and closes on Esc.
    @MainActor @Test func settingsOverlayOpensAndEscCloses() async throws {
        let rig = Rig()
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) { rootView(workspace: rig.workspace) }
        window.installAlloyMenu(rig.workspace)
        for _ in 0..<3 { window.tick() }
        try window.click(window.element(identifier: "title-settings"))
        for _ in 0..<4 { window.tick(); await Task.yield() }
        #expect((try? window.element(identifier: "settings-view")) != nil)
        window.typeKey(.escape, modifierFlags: [])
        for _ in 0..<4 { window.tick(); await Task.yield() }
        #expect((try? window.element(identifier: "settings-view")) == nil)
    }
}

extension IslandsTests {
    /// The window root (launcherRoot, as the app opens it) paints the theme's window background behind the gutters.
    @MainActor @Test func windowRootPaintsTheWindowBackground() throws {
        let rig = Rig()
        let theme = try #require(ThemeLibrary(builtIns: BuiltInThemes.all).resolve("dracula"))
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800)), colorScheme: .dark) {
            launcherRoot(model: LauncherModel(workspace: rig.workspace))
        }
        window.window.darkTheme = ThemeApplier.theme(for: theme)
        window.window.setNeedsRedraw()
        for _ in 0..<4 { window.tick() }
        // The window background folded with its tint and shade into one fill.
        let style = AppearanceStyle.defaults
        let expected = style.windowPaint(try #require(ThemeRGBA(hex: "#1A1B24"))).hsla
        let full = window.scene.rects.filter { $0.bounds.size.width >= 1199 && $0.bounds.size.height >= 799 && $0.background.a > 0 }
        let last = try #require(full.last)
        #expect(abs(last.background.l - expected.l) < 0.01 && abs(last.background.h - expected.h) < 0.01
                && abs(last.background.a - expected.a) < 0.01, "\(last.background) vs \(expected)")
    }

    /// The title text clears the traffic lights (which MetalUI reports as zero insets headless, so the fallback width applies).
    @MainActor @Test func titleTextClearsTheTrafficLights() throws {
        let t = try setup(gutter: 6)
        let style = t.controller.style
        let text = try t.window.element(identifier: "title-project").frame
        #expect(text.minX.value >= Float(style.titleControlsLeading + style.titleLightsWidth + style.titleLightsBreathing) - 0.5)
    }
}

extension IslandsTests {
    /// Each island's content is clipped to its rounded shape: every rect the island draws (apart from its own backdrop,
    /// which is the shape) carries a content mask equal to the island's frame with the style's corner radius on all four
    /// corners, including a full-bleed child (the chat's session stripe starts at the island's left edge). Text inside is
    /// reached through `allGlyphs` and clipped the same way.
    @MainActor @Test(arguments: [10.0, 16.0]) func islandsClipToCorners(radius: Double) async throws {
        let t = try setup(gutter: 6, cornerRadius: radius)
        let session = await t.rig.workspace.newSession(name: "A")
        await t.rig.transports[0].emit(.assistantBlock(messageID: "m0", block: .text("hello islands")))
        try await t.window.runUntil { session.transcript.blocks.count == 1 }
        for _ in 0..<6 { t.window.tick(); await Task.yield() }
        let r = Float(radius)
        for id in ["island-sidebar", "island-chat", "island-title"] {
            let island = try frame(t.window, id)
            let x0 = Float(island.minX.value), y0 = Float(island.minY.value)
            let x1 = Float(island.maxX.value), y1 = Float(island.maxY.value)
            // Rects the island draws inside its frame with a mask (the backdrop and the rim are unmasked: they are the shape).
            let masked = t.window.allRects.filter { rect in
                let b = rect.bounds
                return rect.contentMask.size.width > 0 && b.origin.x >= x0 - 1 && b.origin.y >= y0 - 1
                    && b.origin.x + b.size.width <= x1 + 1 && b.origin.y + b.size.height <= y1 + 1
                    && rect.contentMask.origin.x == x0 && rect.contentMask.origin.y == y0
            }
            #expect(!masked.isEmpty, "\(id) draws content under its clip")
            for rect in masked {
                let c = rect.maskCornerRadii
                #expect(c.topLeft == r && c.topRight == r && c.bottomRight == r && c.bottomLeft == r, "\(id) clip radius \(c) vs \(r)")
                #expect(rect.contentMask.size.width == Float(island.size.width.value) && rect.contentMask.size.height == Float(island.size.height.value))
            }
        }
        // The full-bleed child: the session stripe's left edge is the island's, and it is clipped by the rounded mask.
        let chat = try frame(t.window, "island-chat")
        let stripe = try #require(t.window.allRects.first { $0.bounds.origin.x == Float(chat.minX.value) && $0.bounds.size.width == 4 })
        #expect(stripe.maskCornerRadii.topLeft == r && stripe.contentMask.origin.x == Float(chat.minX.value))
        let text = try t.window.element(label: "hello islands").frame
        #expect(chat.minX.value <= text.minX.value && text.maxX.value <= chat.maxX.value)
        let inChat = t.window.allGlyphs.filter { Float(chat.minX.value) <= $0.bounds.origin.x && $0.bounds.origin.x <= Float(chat.maxX.value)
            && Float(chat.minY.value) <= $0.bounds.origin.y && $0.bounds.origin.y <= Float(chat.maxY.value) }
        #expect(!inChat.isEmpty)
    }
}

extension IslandsTests {
    /// Under custom window chrome (SDL: `.hiddenTitleBar`, drag regions) the empty middle of the title island moves the window, while the
    /// project name's neighbours (the pills) keep the pointer. MetalUI publishes the regions carved around every control (`ChromeRegions`).
    /// Native AppKit chrome (the macOS app) drags in the title bar without the app's help, which headless cannot observe.
    @MainActor @Test func emptyTitleIslandIsAWindowDragRegion() throws {
        let rig = Rig()
        let app = try TestApp()
        let window = try app.openWindow(size: Size(width: Pixels(1200), height: Pixels(800)), windowStyle: .hiddenTitleBar,
                                        colorScheme: .dark, options: .sdlChrome) { rootView(workspace: rig.workspace) }
        for _ in 0..<5 { window.tick() }
        let island = try window.element(identifier: "island-title").frame
        let name = try window.element(identifier: "title-project").frame
        let pill = try window.element(identifier: "title-new-session").frame
        let y = (island.minY.value + island.maxY.value) / 2
        let gap = Point(x: Pixels((name.maxX.value + pill.minX.value) / 2), y: Pixels(y))
        let regions = window.windowDragRegions
        #expect(regions.contains { $0.contains(gap) }, "the empty title island at \(gap) is not a drag region")
        let onPill = Point(x: Pixels((pill.minX.value + pill.maxX.value) / 2), y: Pixels(y))
        #expect(!regions.contains { $0.contains(onPill) }, "a pill keeps its clicks")
    }
}
