import AlloyCore
@testable import AlloyKit
import AlloyTestSupport
import Foundation
import MetalUI
import MetalUITesting
import Testing

/// The transcript's scroll viewport stays clear of the chat island's rounded corner squares, so MetalUI draws it without an offscreen
/// mask group (`boxReachesACornerCut`: a square box crosses a rounded clip only where it overlaps a radius x radius corner square).
/// The rows keep their x frames: the inset moves out of the rows' padding into the viewport.
@MainActor
@Suite struct TranscriptViewportInsetTests {
    private final class Holder { var controller: ThemeController? }

    private struct Frames {
        var island: Bounds<Pixels>, viewport: Bounds<Pixels>, composer: Bounds<Pixels>
        var user: Bounds<Pixels>, tool: Bounds<Pixels>, reply: Bounds<Pixels>
        var groupsMasked = 0, maskScopesPushed = 0
    }

    private func frames(width: Double, radius: Double, scale: Float) async throws -> Frames {
        let rig = Rig()
        var s = rig.workspace.settings
        s.appearance = AppearanceOverrides(gutter: 6, cornerRadius: radius)
        try rig.workspace.updateSettings(s)
        let holder = Holder()
        let window = try TestWindow(size: Size(width: Pixels(Float(width)), height: Pixels(800)), scaleFactor: scale) {
            rootView(workspace: rig.workspace, themes: holder.controller, center: testCenter(for: rig.workspace))
        }
        window.installAlloyMenu(rig.workspace)
        holder.controller = ThemeController(workspace: rig.workspace, host: window.window, watcher: nil)
        // The chat column is built after the controller exists, so it reads the style's radius (it is not rebuilt for a later theme).
        for _ in 0..<4 { window.tick() }
        let session = await rig.workspace.newSession(name: "A")
        await rig.workspace.send(OutgoingMessage(text: "question one", images: [], priority: .later), to: session.id)
        await rig.transports[0].emit(.assistantBlock(messageID: "tl", block: .toolUse(id: "tool1", name: "Read", input: .object(["file_path": .string("/tmp/f.txt")]))))
        await rig.transports[0].emit(.assistantBlock(messageID: "a1", block: .text("Answer paragraph with `code` and some words.\n\nsecond paragraph")))
        try await acpUntil { session.transcript.blocks.count >= 3 }
        rig.workspace.selectedSessionID = session.id
        for _ in 0..<20 { window.tick(); await Task.yield() }
        // An idle frame of the short transcript: no row straddles the viewport's top or bottom edge.
        window.resetFrameWork()
        window.window.setNeedsRedraw(); window.tick()
        let work = window.lastFrameWork
        func frame(_ id: String) throws -> Bounds<Pixels> { try window.element(identifier: id).frame }
        let all = try window.elements(where: { _ in true })
        func row(_ match: (String) -> Bool) throws -> Bounds<Pixels> {
            try #require(all.first { $0.identifier.map(match) == true }).frame
        }
        var f = Frames(island: try frame("island-chat"), viewport: try frame("transcript"), composer: try frame("composer-box"),
                      user: try row { $0.hasPrefix("block-") && $0.count == 42 }, tool: try row { $0 == "block-tool1" },
                      reply: try row { $0.hasPrefix("block-m") && $0.hasSuffix("#0") })
        f.groupsMasked = work.groupsMasked; f.maskScopesPushed = work.maskScopesPushed
        return f
    }

    @Test(arguments: [(700.0, 10.0), (1200.0, 10.0), (1800.0, 10.0), (1200.0, 16.0)])
    func viewportClearsTheIslandCorners(width: Double, radius: Double) async throws {
        for scale: Float in [1, 2] {
            let f = try await frames(width: width, radius: radius, scale: scale)
            let r = Float(radius)
            #expect(f.groupsMasked == 0 && f.maskScopesPushed == 0,
                    "idle frame pushed \(f.maskScopesPushed) mask scopes and masked \(f.groupsMasked) groups at \(width) x r\(radius) @\(scale)x")
            #expect(f.viewport.minX.value >= f.island.minX.value + r, "left \(f.viewport.minX.value) vs island \(f.island.minX.value) + \(r) at \(scale)x")
            #expect(f.viewport.maxX.value <= f.island.maxX.value - r, "right \(f.viewport.maxX.value) vs island \(f.island.maxX.value) - \(r) at \(scale)x")
        }
    }

    /// Frames recorded on master before the inset (width 1200, gutter 6, radius 10, scale 1): island x 262 w 566, rows (user bubble, tool
    /// row, reply paragraph) x 282 w 530, composer bar x 284 w 490 y 750 h 28. The rows and the composer sit a fixed distance from the
    /// island's edges at any width, so the pins hold at a narrow and a wide chat.
    @Test(arguments: [700.0, 1200.0, 1800.0]) func rowsAndComposerKeepTheirFrames(width: Double) async throws {
        let f = try await frames(width: width, radius: 10, scale: 1)
        for (name, row) in [("user", f.user), ("tool", f.tool), ("reply", f.reply)] {
            #expect(row.minX.value == f.island.minX.value + 20, "\(name) minX \(row.minX.value) vs island \(f.island.minX.value)")
            #expect(row.maxX.value == f.island.maxX.value - 16, "\(name) maxX \(row.maxX.value) vs island \(f.island.maxX.value)")
        }
        #expect(f.composer.minX.value == f.island.minX.value + 22 && f.composer.minY.value == 750 && f.composer.size.height.value == 28)
        #expect(f.composer.size.width.value == f.island.size.width.value - 76)
        if width == 1200 { #expect(f.island.minX.value == 262 && f.user.minX.value == 282 && f.user.size.width.value == 530 && f.composer.minX.value == 284 && f.composer.size.width.value == 490) }
    }
}
