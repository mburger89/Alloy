import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

@MainActor
@Suite struct GlassControlTests {
    private let gutter = Float(AppearanceStyle.defaults.gutter)

    private func chatRig(messages: Int = 0) async throws -> (rig: Rig, session: Session, window: TestWindow) {
        let rig = Rig()
        let session = await rig.workspace.newSession(name: "A")
        let window = try alloyWindow(rig.workspace)
        for i in 0..<messages {
            await rig.transports[0].emit(.assistantBlock(messageID: "m\(i)", block: .text("message \(i)")))
        }
        if messages > 0 { try await window.runUntil { session.transcript.blocks.count == messages } }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        return (rig, session, window)
    }

    @Test func composerFloatsOverTheTranscript() async throws {
        let (_, _, window) = try await chatRig()
        let composer = try window.element(identifier: "composer-box").frame
        // The transcript's scroll view fills the chat area; the composer sits inside it, one gutter up from the bottom.
        let chatBottom = Float(800)
        #expect(composer.maxY.value <= chatBottom - gutter)
        #expect(composer.maxY.value > chatBottom - gutter - 40)
        let send = try window.element(identifier: "send").frame
        #expect(send.maxY.value <= chatBottom - gutter)
    }

    @Test func lastMessageClearsTheComposer() async throws {
        let (_, _, window) = try await chatRig(messages: 60)
        func gap() throws -> Float {
            let last = try window.element(label: "message 59").frame
            let top = try window.element(identifier: "composer-box").frame.minY.value
            return top - last.maxY.value
        }
        #expect(try gap() >= 0)
        try window.focus(window.element(identifier: "composer"))
        for i in 0..<3 {
            window.typeText("line \(i)")
            if i < 2 { window.typeKey(.return, modifierFlags: .shift) }
        }
        for _ in 0..<5 { window.tick(); await Task.yield() }
        #expect(try gap() >= 0)
    }

    @Test func codeScrollsUnderTheBar() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        for _ in 0..<6 { window.tick(); await Task.yield() }
        let code = try window.element(identifier: "code-view").frame
        let bar = try window.element(identifier: "file-panel-bar").frame
        #expect(code.minY.value <= bar.minY.value, "the code view starts under the bar")
        // The bench clicks inside the code view at the window's right edge minus 180, mid height.
        #expect(code.minX.value <= 1200 - 180 && code.maxX.value >= 1200 - 180)
        #expect(code.minY.value <= 400 && code.maxY.value >= 400)
        // At scroll 0 the first code row below the bar sits just below it (the top margin leaves one gutter). The bar's
        // own text is glyphs in the same rect, so code rows under the bar cannot be told apart here; the exact margin is
        // asserted for the side-by-side panes (SideBySideTests), whose rows are located from the find-open state.
        let inCode = window.allGlyphs.filter { g in
            Float(code.minX.value) + 40 <= g.bounds.origin.x && g.bounds.origin.x < Float(code.maxX.value)
                && g.bounds.origin.y >= Float(bar.minY.value) - 0.5
        }
        let below = inCode.filter { $0.bounds.origin.y >= Float(bar.maxY.value) - 0.5 }
        #expect(!below.isEmpty)
        let first = try #require(below.map(\.bounds.origin.y).min())
        #expect(first - Float(bar.maxY.value) < 40, "the first line sits just below the bar (\(first) vs \(bar.maxY.value))")
    }

    /// The bar's height is measured a frame after the first build; until then the code's top margin is the style's
    /// estimate, so the code's first glyph is already where it will stay (no one-frame jump on first open).
    @Test func codeDoesNotJumpWhenTheBarIsMeasured() async throws {
        let (rig, _) = try await editedRig()
        rig.workspace.openFilePath = "login.swift"
        let window = try alloyWindow(rig.workspace)
        try await window.runUntil { (try? window.element(identifier: "code-view")) != nil }
        func firstRowBelowBar() throws -> Float? {
            let bar = try window.element(identifier: "file-panel-bar").frame
            let code = try window.element(identifier: "code-view").frame
            let left = Float(code.minX.value) + 40, top = Float(bar.maxY.value) - 0.5
            let ys: [Float] = window.allGlyphs.compactMap { g in
                let x = g.bounds.origin.x, y = g.bounds.origin.y
                return x >= left && y >= top ? y : nil
            }
            return ys.min()
        }
        let first = try #require(try firstRowBelowBar())
        for _ in 0..<10 { window.tick(); await Task.yield() }
        let settled = try #require(try firstRowBelowBar())
        #expect(abs(first - settled) < 0.5, "first frame \(first), settled \(settled)")
        let barHeight = try window.element(identifier: "file-panel-bar").frame.maxY.value - (try window.element(identifier: "file-panel-bar").frame.minY.value) + 2 * gutter
        #expect(abs(Double(barHeight) - AppearanceStyle.defaults.filePanelBarHeightEstimate) < 1, "estimate \(AppearanceStyle.defaults.filePanelBarHeightEstimate), measured \(barHeight)")
    }

    /// The transcript's bottom clearance is `contentMargins(.bottom, composerHeight)`, not a filler element. The margin is
    /// the glass bar plus a gutter above and below, so the last message ends exactly one gutter plus the transcript's own
    /// bottom padding (12) above the bar's top edge. The old trailing spacer left the gutter, the padding, the stack
    /// spacing (10) and the whole composer height between them, which this exact gap rejects; and because the scroll
    /// content ends at the last message plus its padding, the exact gap also proves no filler element follows the last
    /// message.
    @Test func transcriptUsesContentMargins() async throws {
        let (_, _, window) = try await chatRig(messages: 60)
        let transcriptBottomPadding: Float = 12
        let composerBarPadding: Float = 10 // ComposerView's outer vertical padding: bar top = its first row's top - this
        let last = try window.element(label: "message 59").frame
        let modeRowTop = try window.elements(where: { $0.identifier == "mode-picker" }).map { $0.frame.minY.value }.min()
        let barTop = try #require(modeRowTop) - composerBarPadding
        let gap = barTop - last.maxY.value
        let expected = gutter + transcriptBottomPadding
        #expect(abs(gap - expected) <= 1, "last message to the composer bar top is \(gap), expected one gutter plus the padding: \(expected)")
        // It stays a clear of the composer box too.
        #expect(try window.element(identifier: "composer-box").frame.minY.value > last.maxY.value)
    }

    /// A session switch rebuilds the column (`.id(session.id)`), so its measured composer height starts over. The first frame
    /// must still clear the bar: the seed is the window's last measured height, not zero (which put the last message under the composer for a frame).
    @Test func sessionSwitchFirstFrameClearsTheComposer() async throws {
        let rig = Rig()
        let a = await rig.workspace.newSession(name: "A")
        let b = await rig.workspace.newSession(name: "B")
        rig.workspace.selectedSessionID = a.id
        let window = try alloyWindow(rig.workspace)
        for i in 0..<40 {
            await rig.transports[0].emit(.assistantBlock(messageID: "a\(i)", block: .text("a message \(i)")))
            await rig.transports[1].emit(.assistantBlock(messageID: "b\(i)", block: .text("b message \(i)")))
        }
        try await window.runUntil { a.transcript.blocks.count == 40 && b.transcript.blocks.count == 40 }
        for _ in 0..<10 { window.tick(); await Task.yield() }
        for target in [b, a, b] {
            let builds = BodyProbe.count("TranscriptView")
            rig.workspace.selectedSessionID = target.id
            window.tick()
            let name = target === a ? "a message 39" : "b message 39"
            let last = try window.element(label: name).frame
            let box = try window.element(identifier: "composer-box").frame
            #expect(last.maxY.value <= box.minY.value + 0.5, "first frame after switching: last message bottom \(last.maxY.value) vs composer top \(box.minY.value)")
            // The inset never changes after the column's first frame: the transcript is built once, not again when the bar is measured.
            for _ in 0..<6 { window.tick(); await Task.yield() }
            #expect(BodyProbe.count("TranscriptView") - builds == 1, "the transcript was built \(BodyProbe.count("TranscriptView") - builds) times for one switch")
        }
    }

    /// With nothing measured yet (the window's first column), the style's estimate is the exact bar height, so the transcript is built once.
    @Test func composerEstimateMatchesTheMeasuredBar() async throws {
        let rig = Rig()
        _ = await rig.workspace.newSession(name: "A")
        let builds = BodyProbe.count("TranscriptView")
        let window = try alloyWindow(rig.workspace)
        for _ in 0..<10 { window.tick(); await Task.yield() }
        _ = window
        #expect(BodyProbe.count("TranscriptView") - builds == 1, "built \(BodyProbe.count("TranscriptView") - builds) times: the estimate \(AppearanceStyle.defaults.composerBarHeightEstimate) is off")
    }

    @Test func reduceTransparencyDrawsSolid() {
        let style = AppearanceStyle.defaults
        #expect(GlassLook.resolve(style: style, reduceTransparency: true, glassEnabled: true) == .solid)
        #expect(GlassLook.resolve(style: style, reduceTransparency: false, glassEnabled: false) == .solid)
        #expect(GlassLook.resolve(style: style, reduceTransparency: false, glassEnabled: true) != .solid)
    }

    @Test func glassMapsBlurSteps() {
        var style = AppearanceStyle.defaults
        style.controlBlur = .light
        #expect(GlassLook.glass(for: style) == .clear)
        #expect(GlassLook.resolve(style: style, reduceTransparency: false, glassEnabled: true) == .glass(.clear, thickMaterial: false))
        style.controlBlur = .medium
        #expect(GlassLook.glass(for: style) == .regular)
        #expect(GlassLook.resolve(style: style, reduceTransparency: false, glassEnabled: true) == .glass(.regular, thickMaterial: false))
        style.controlBlur = .heavy
        #expect(GlassLook.glass(for: style) == .regular)
        #expect(GlassLook.resolve(style: style, reduceTransparency: false, glassEnabled: true) == .glass(.regular, thickMaterial: true))
    }

    @Test func themeControllerPublishesTheStyle() throws {
        let rig = Rig()
        let window = try alloyWindow(rig.workspace)
        let controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        #expect(controller.style == AppearanceStyle.defaults.applying(rig.workspace.settings.appearance))
        var s = rig.workspace.settings
        s.appearance = AppearanceOverrides(gutter: 12)
        try rig.workspace.updateSettings(s)
        controller.refreshStyle()
        #expect(controller.style.gutter == 12)
    }
}
