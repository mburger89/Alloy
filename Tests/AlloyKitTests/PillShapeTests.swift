import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// Pill buttons throughout (islands goal 5): the composer's Mode picker and model menu, the diff-layout picker and the
/// selected tab follow `style.pillButtons`: a capsule when on, else a rounded rectangle at `buttonCornerRadius`.
@MainActor
@Suite struct PillShapeTests {
    /// Takes the themes the controller installs; the window under test is built after the controller, so the views see it
    /// from their first frame (a column that captured no controller never gets one: its identity ignores it).
    private final class Host: ThemeHost {
        var lightTheme: Theme = .light
        var darkTheme: Theme = .dark
        var preferredColorScheme: ColorScheme?
    }

    private struct Setup {
        let rig: Rig
        let window: TestWindow
        let controller: ThemeController
    }

    /// An open file with a diff (so the header's layout picker and a tab exist) and a session (so the composer does).
    private func setup() async throws -> Setup {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let controller = ThemeController(workspace: rig.workspace, host: Host(), watcher: nil)
        let window = try TestWindow(size: Size(width: Pixels(1200), height: Pixels(800))) {
            rootView(workspace: rig.workspace, themes: controller)
        }
        window.installAlloyMenu(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<6 { window.tick(); await Task.yield() }
        return Setup(rig: rig, window: window, controller: controller)
    }

    /// The theme with square buttons, chosen through the controller the way Settings does.
    private func chooseSquare(_ s: Setup) async throws {
        let dir = ThemeLibrary.userDirectory(appSupport: s.rig.root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"name":"Square","appearance":"dark","base":"dracula","style":{"pillButtons":false,"cornerRadius":12}}"#
            .write(to: dir.appendingPathComponent("square.json"), atomically: true, encoding: .utf8)
        await s.controller.reload()
        try s.controller.choose(theme: "user/square")
        for _ in 0..<6 { s.window.tick(); await Task.yield() }
    }

    /// The corner radii of the filled or stroked rects around a control's centre that are no bigger than the control
    /// (a tab's selection capsule is wider than its button by the cell's inset), with each rect's half-shorter-side beside it.
    private func corners(_ window: TestWindow, _ element: TestElement) -> [(radius: Float, half: Float)] {
        let f = element.frame
        let cx = Float(f.minX.value + f.maxX.value) / 2, cy = Float(f.minY.value + f.maxY.value) / 2
        let w = Float(f.size.width.value), h = Float(f.size.height.value)
        return window.allRects.compactMap { r in
            let b = r.bounds
            guard b.origin.x <= cx, cx <= b.origin.x + b.size.width, b.origin.y <= cy, cy <= b.origin.y + b.size.height,
                  b.size.height >= 16, b.size.height <= h + 1, b.size.width <= w + 40,
                  r.background.a > 0 || r.borderWidths.top > 0 else { return nil }
            return (r.cornerRadii.topLeft, min(b.size.width, b.size.height) / 2)
        }
    }

    private func expectPills(_ window: TestWindow, _ id: String, _ pill: Bool, _ radius: Float, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let matches = try window.elements(where: { $0.identifier == id })
        try #require(!matches.isEmpty, "\(id) exists")
        let c = matches.flatMap { corners(window, $0) }
        #expect(!c.isEmpty, "\(id) draws chrome", sourceLocation: sourceLocation)
        if pill {
            #expect(c.contains { $0.radius > 0 && abs($0.radius - $0.half) < 0.5 }, "\(id) is a capsule: \(c)", sourceLocation: sourceLocation)
        } else {
            #expect(c.contains { abs($0.radius - radius) < 0.5 }, "\(id) has radius \(radius): \(c)", sourceLocation: sourceLocation)
            #expect(!c.contains { $0.radius > 0 && abs($0.radius - $0.half) < 0.5 && $0.half > radius + 0.5 }, "\(id) is no capsule: \(c)", sourceLocation: sourceLocation)
        }
    }

    @Test func shapeFollowsStyle() {
        var style = AppearanceStyle.defaults
        #expect(style.pillButtons && style.buttonShape == .capsule && style.tabSelectionShape == .capsule)
        style.pillButtons = false
        style.cornerRadius = 12
        #expect(style.buttonShape == .roundedRectangle(radius: Pixels(6)))
        #expect(style.tabSelectionShape == .roundedRectangle(radius: Pixels(6)))
    }

    @Test func composerPickersAndDiffPickerArePillsAndFollowTheStyle() async throws {
        let s = try await setup()
        try expectPills(s.window, "mode-picker", true, 0)
        try expectPills(s.window, "model-menu", true, 0)
        try expectPills(s.window, "diff-mode-toggle", true, 0)
        try await chooseSquare(s)
        let r = Float(s.controller.style.buttonCornerRadius)
        #expect(!s.controller.style.pillButtons && r == 6)
        try expectPills(s.window, "mode-picker", false, r)
        try expectPills(s.window, "model-menu", false, r)
        try expectPills(s.window, "diff-mode-toggle", false, r)
    }

    @Test func selectedTabFollowsTheStyle() async throws {
        let s = try await setup()
        try expectPills(s.window, "tab-login.swift", true, 0)
        try await chooseSquare(s)
        try expectPills(s.window, "tab-login.swift", false, Float(s.controller.style.buttonCornerRadius))
    }
}
